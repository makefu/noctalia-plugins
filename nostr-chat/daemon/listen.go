package main

// Client subcommands for the noctalia shell (the v5 plugin API has no
// unix socket access; runStream/runAsync spawn these instead):
//
//   nostr-chatd listen [n]   - dial the bridge, self-issue replay(n),
//                              print NDJSON events to stdout forever
//   nostr-chatd cmd '<json>' - one-shot NDJSON command to the bridge
//
// listen is the shell's event stream: it survives daemon restarts
// internally (2s redial backoff) and signals bridge state with the
// synthetic lines {"kind":"bridge-up"} / {"kind":"bridge-down"}, which
// only this client can know (it owns the connection).

import (
	"bufio"
	"cmp"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"
)

// defaultSocket mirrors loadConfig's derivation without the rest of the
// config: listen/cmd need only the socket path.
func defaultSocket() string {
	runtime := cmp.Or(os.Getenv("XDG_RUNTIME_DIR"), fmt.Sprintf("/run/user/%d", os.Getuid()))
	return runtime + "/nostr-chatd.sock"
}

// listenBackoff is short: a restart of the user daemon should heal the
// shell UI within a second or two.
const listenBackoff = 2 * time.Second

// runListen keeps one bridge connection alive for the lifetime of ctx.
// Per connection: dial, write the replay command (the daemon answers on
// this same connection), announce bridge-up, then copy every event line
// to out. On read error: announce bridge-down and redial.
func runListen(ctx context.Context, socket string, n int, out io.Writer) error {
	emit := func(s string) { fmt.Fprintln(out, s) }
	for ctx.Err() == nil {
		conn, err := net.Dial("unix", socket)
		if err != nil {
			time.Sleep(listenBackoff)
			continue
		}
		b, _ := json.Marshal(Command{Cmd: CmdReplay, N: n})
		if _, err := conn.Write(append(b, '\n')); err != nil {
			conn.Close()
			emit(`{"kind":"bridge-down"}`)
			time.Sleep(listenBackoff)
			continue
		}
		emit(`{"kind":"bridge-up"}`)

		// Unblock the Scan below the moment ctx ends: a unix conn Read
		// otherwise parks forever (the daemon keeps its end open).
		connDone := make(chan struct{})
		go func() {
			select {
			case <-ctx.Done():
				conn.Close()
			case <-connDone:
			}
		}()

		sc := bufio.NewScanner(conn)
		sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024) // media events can be chunky
		for sc.Scan() && ctx.Err() == nil {
			fmt.Fprintln(out, sc.Text())
		}
		close(connDone)
		conn.Close()
		if ctx.Err() != nil {
			return nil
		}
		emit(`{"kind":"bridge-down"}`)
		time.Sleep(listenBackoff)
	}
	return nil
}

// sendCommand writes one NDJSON line and hangs up. The daemon drops
// dead conns on Push, so no handshake or linger is needed.
func sendCommand(socket, line string) error {
	conn, err := net.DialTimeout("unix", socket, 3*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = io.WriteString(conn, line+"\n")
	return err
}

// runListenCmd is the "listen" subcommand entry.
func runListenCmd(argv []string) int {
	fs := flag.NewFlagSet("listen", flag.ContinueOnError)
	socket := fs.String("socket", defaultSocket(), "unix socket path")
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	n := 200
	if fs.Arg(0) != "" {
		if _, err := fmt.Sscanf(fs.Arg(0), "%d", &n); err != nil || n <= 0 {
			fmt.Fprintln(os.Stderr, "listen: bad n:", fs.Arg(0))
			return 2
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := runListen(ctx, *socket, n, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		return 1
	}
	return 0
}

// runCmdSub is the "cmd" subcommand entry: the single positional
// argument is the NDJSON command line.
func runCmdSub(argv []string) int {
	fs := flag.NewFlagSet("cmd", flag.ContinueOnError)
	socket := fs.String("socket", defaultSocket(), "unix socket path")
	if err := fs.Parse(argv); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: nostr-chatd cmd [-socket p] '<json>'")
		return 2
	}
	if err := sendCommand(*socket, fs.Arg(0)); err != nil {
		fmt.Fprintln(os.Stderr, "cmd:", err)
		return 1
	}
	return 0
}
