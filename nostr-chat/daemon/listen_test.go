package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"fiatjaf.com/nostr"
)

// syncBuffer collects NDJSON lines a subcommand writes to stdout and
// lets tests await them with a deadline.
type syncBuffer struct {
	lines chan string
}

func newSyncBuffer() *syncBuffer { return &syncBuffer{lines: make(chan string, 64)} }

func (b *syncBuffer) Write(p []byte) (int, error) {
	for _, l := range strings.Split(string(p), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			b.lines <- l
		}
	}
	return len(p), nil
}

func (b *syncBuffer) await(d time.Duration) (string, error) {
	select {
	case l := <-b.lines:
		return l, nil
	case <-time.After(d):
		return "", fmt.Errorf("timeout waiting for output line")
	}
}

func (b *syncBuffer) waitFor(pred func(string) bool, d time.Duration) (string, error) {
	deadline := time.After(d)
	for {
		select {
		case l := <-b.lines:
			if pred(l) {
				return l, nil
			}
		case <-deadline:
			return "", fmt.Errorf("timeout waiting for matching output line")
		}
	}
}

var _ io.Writer = (*syncBuffer)(nil)

// dialWait keeps dialing until the unix socket accepts, so tests do not
// race subcommand dial loops against Serve.
func dialWait(t *testing.T, sock string) net.Conn {
	t.Helper()
	var last error
	for i := 0; i < 250; i++ {
		c, err := net.DialTimeout("unix", sock, time.Second)
		if err == nil {
			return c
		}
		last = err
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("socket %s never accepted: %v", sock, last)
	return nil
}

func readCmd(t *testing.T, ch <-chan Command, d time.Duration) Command {
	t.Helper()
	select {
	case c := <-ch:
		return c
	case <-time.After(d):
		t.Fatal("timeout waiting for daemon-side command")
		return Command{}
	}
}

// TestListenReplaysAndPushes covers the stream contract the shell
// service relies on: dial, self-issue replay on connect (history is
// never lost on late connect), announce bridge-up only after the
// replay write, then forward daemon pushes verbatim.
func TestListenReplaysAndPushes(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "sock")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmds := make(chan Command, 8)
	br := NewBridge()
	go func() {
		if err := br.Serve(ctx, sock, func(c Command) { cmds <- c }); err != nil {
			t.Errorf("serve: %v", err)
		}
	}()

	out := newSyncBuffer()
	done := make(chan error, 1)
	go func() { done <- runListen(ctx, sock, 42, out) }()

	c := readCmd(t, cmds, 8*time.Second)
	if c.Cmd != CmdReplay || c.N != 42 {
		t.Fatalf("expected replay n=42 first, got %+v", c)
	}

	line, err := out.await(3 * time.Second)
	if err != nil {
		t.Fatalf("bridge-up missing: %v", err)
	}
	var up map[string]any
	if err := json.Unmarshal([]byte(line), &up); err != nil || up["kind"] != "bridge-up" {
		t.Fatalf("expected bridge-up marker, got %q", line)
	}

	// Pushes through the bridge must surface on the listen stdout.
	br.Push(Event{Kind: EvStatus, Streaming: true, RelaysUp: 2})
	line, err = out.await(3 * time.Second)
	if err != nil {
		t.Fatalf("push not forwarded: %v", err)
	}
	var ev Event
	if err := json.Unmarshal([]byte(line), &ev); err != nil || ev.Kind != EvStatus || !ev.Streaming || ev.RelaysUp != 2 {
		t.Fatalf("forwarded event wrong: %q", line)
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runListen returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("runListen did not exit on ctx cancel")
	}
}

// TestListenBridgeDownAndReconnect: when the daemon connection dies the
// client emits synthetic bridge-down (the shell flips the header
// offline) and keeps dialing; when a fresh bridge takes the socket over,
// a new replay write plus bridge-up prove the stream self-heals without
// shell intervention.
func TestListenBridgeDownAndReconnect(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "sock")
	sk := nostr.Generate()
	keys := Keys{SK: sk, PK: nostr.GetPublicKey(sk)}
	store, err := OpenStore(filepath.Join(dir, "state"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	_ = keys

	out := newSyncBuffer()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- runListen(ctx, sock, 50, out) }()

	// First daemon appears late; the dial loop must wait for it.
	dctx, dcancel := context.WithCancel(context.Background())
	cmds1 := make(chan Command, 8)
	br1 := NewBridge()
	go br1.Serve(dctx, sock, func(c Command) { cmds1 <- c })

	c := readCmd(t, cmds1, 8*time.Second)
	if c.Cmd != CmdReplay || c.N != 50 {
		t.Fatalf("want replay n=50, got %+v", c)
	}
	if _, err := out.waitFor(func(l string) bool { return strings.Contains(l, "bridge-up") }, 3*time.Second); err != nil {
		t.Fatalf("no bridge-up: %v", err)
	}

	// Daemon dies: Serve closes its conns on ctx-done, client sees EOF.
	dcancel()
	if _, err := out.waitFor(func(l string) bool { return strings.Contains(l, "bridge-down") }, 3*time.Second); err != nil {
		t.Fatalf("no bridge-down after daemon death: %v", err)
	}

	// Fresh daemon on the same path; Serve unlinks the stale socket.
	dctx2, dcancel2 := context.WithCancel(context.Background())
	defer dcancel2()
	cmds2 := make(chan Command, 8)
	br2 := NewBridge()
	go br2.Serve(dctx2, sock, func(c Command) { cmds2 <- c })

	c = readCmd(t, cmds2, 15*time.Second) // tolerate the reconnect backoff
	if c.Cmd != CmdReplay {
		t.Fatalf("want replay after reconnect, got %+v", c)
	}
	if _, err := out.waitFor(func(l string) bool { return strings.Contains(l, "bridge-up") }, 5*time.Second); err != nil {
		t.Fatalf("no second bridge-up: %v", err)
	}
	cancel()
	<-done
}

// TestSendCommandOneShot covers the cmd subcommand transport: one NDJSON
// line to the socket, then close. The daemon reads it as a Command.
func TestSendCommandOneShot(t *testing.T) {
	dir := t.TempDir()
	sock := filepath.Join(dir, "sock")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmds := make(chan Command, 4)
	br := NewBridge()
	go br.Serve(ctx, sock, func(c Command) { cmds <- c })

	conn := dialWait(t, sock)
	conn.Close() // the one-shot dialer is separate; just wait for the path

	if err := sendCommand(sock, `{"cmd":"mark-read"}`); err != nil {
		t.Fatalf("sendCommand: %v", err)
	}
	select {
	case c := <-cmds:
		if c.Cmd != CmdMarkRead {
			t.Fatalf("daemon got %+v", c)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("command never reached handler")
	}
}

func TestSendCommandDeadSocket(t *testing.T) {
	if err := sendCommand(filepath.Join(t.TempDir(), "gone"), `{}`); err == nil {
		t.Fatal("want error on missing socket")
	}
}
