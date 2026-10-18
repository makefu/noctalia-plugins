# nostr-chat

A noctalia (v5) chat panel for any Nostr DM peer. Originally built for
[OpenCrow] — hit `Mod+H`, ask it to plot your Prometheus metrics, get a chart
back inline — but point it at any bot or human with a pubkey.

[OpenCrow]: https://github.com/pinpox/opencrow

__omp_shell("[chat panel](https://github.com/Mic92/noctalia-plugins/releases/download/assets/nostr-chat-screenshot.png)")

## What you get

- **One keystroke away** — `Mod+H` from anywhere, or let it open itself when the
  bot replies; it always lands at the newest message
- **Snappy** — messages appear as you type, read receipts trickle in after
- **Images** — paste one from the clipboard with 📎, bot-generated charts render
  inline
- **Nothing gets lost** — history survives restarts, sends retry if the network
  is down
- **Search** — `Ctrl+F`, highlight + prev/next walking through matches

## Layout (noctalia v5 plugin)

```
nostr-chat/
├── plugin.toml        ← manifest: panel, service, settings
├── service.luau       ← daemon bridge (runStream/runAsync) + notifications
├── panel.luau         ← chat UI (declarative ui.* tree)
├── translations/      ← i18n bundles (<lang>.json)
├── daemon/            ← Go bridge (Nostr + sqlite) + listen/cmd subcommands
└── module.nix         ← NixOS module: builds daemon + systemd user unit
```

## Install

### 1. Install the plugin

Drop this directory into the shell's local plugin dir
(`$XDG_DATA_HOME/noctalia/plugins/nostr-chat`, i.e.
`~/.local/share/noctalia/plugins/nostr-chat`) and enable it in
`~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = ["makefu/nostr-chat"]

[plugin_settings."makefu/nostr-chat"]
daemon_bin = "/run/current-system/sw/bin/nostr-chatd"  # or any absolute path
```

On NixOS, declare both via home-manager (see the nixos-config wiring below).

### 2. Run the daemon

**NixOS** — add this repo as a flake input and import the module:

```nix
# flake.nix
inputs.noctalia-plugins.url = "github:Mic92/noctalia-plugins";

# configuration.nix
imports = [ inputs.noctalia-plugins.nixosModules.nostr-chat ];
services.nostr-chat = {
  peerPubkey  = "96dc8a8c…bf7e37";
  relays      = [ "wss://nostr.thalheim.io" "wss://nos.lol" ];
  blossom     = [ "https://nostr-files.thalheim.io" ];  # optional, for images
  displayName = "Janet";
};
```

Then `nixos-rebuild switch`. The daemon runs as a systemd _user_ unit (it needs
your rbw vault + noctalia session), so it starts with your graphical login.

**Manually:**

```bash
nix build ./daemon
NOSTR_CHAT_PEER_PUBKEY=96dc8a8c… \
NOSTR_CHAT_RELAYS=wss://nostr.thalheim.io,wss://nos.lol \
NOSTR_CHAT_BLOSSOM=https://nostr-files.thalheim.io \
NOSTR_CHAT_SECRET_CMD="rbw get 'nostr identity'" \
  ./result/bin/nostr-chatd
```

### 3. Secrets

The daemon runs whatever shell command you give it to fetch your nsec:

```nix
secretCommand = "rbw get 'nostr identity'";
# or: "pass show nostr/identity"
# or: "cat /run/agenix/nostr-nsec"
```

Add the tool to `extraPath` and any ordering deps (e.g.
`systemd.user.services.nostr-chatd.after = [ "rbw-agent.service" ]`) alongside.

## Configuration

**Daemon** (who to talk to) — NixOS options under `services.nostr-chat`:

| Option          | Purpose                                                   |
| --------------- | --------------------------------------------------------- |
| `peerPubkey`    | hex pubkey of the peer you're DMing                       |
| `relays`        | wss:// URLs both sides listen on                          |
| `blossom`       | Blossom servers for image upload (empty = no attachments) |
| `secretCommand` | shell command that prints your nsec to stdout             |
| `extraPath`     | packages on PATH (your secret tool)                       |
| `displayName`   | panel header label (default: `Chat`)                      |

**Plugin** (noctalia settings GUI / `[plugin_settings."makefu/nostr-chat"]`):

| Setting       | Purpose                                                    |
| ------------- | ---------------------------------------------------------- |
| `daemon_bin`  | path to `nostr-chatd` (used for the stream + one-shot cmds) |
| `max_history` | messages kept in the panel's in-memory mirror              |

State: `~/.local/state/nostr-chatd/messages.db`. Images:
`~/.cache/nostr-chatd/media/`.

## Keybind

The service listens for IPC events (`toggle`, `hide`, `send <text>`):

```nix
# hyprland
bind = SUPER, H, exec, noctalia msg plugin makefu/nostr-chat:service all toggle
# niri
binds."Mod+G".action = spawn ["noctalia" "msg" "plugin" "makefu/nostr-chat:service" "all" "toggle"]
```

`hide` closes the panel only while it is open (used by screenshot scripts);
`send` takes the message text as payload.

## Images

The v5 plugin API has no file picker: click 📎 and it grabs the **clipboard
image** (via `wl-paste`) and uploads it. Ask the bot for a chart, it renders
inline when ready.

Files are end-to-end encrypted — the storage server only ever sees ciphertext.
Needs `NOSTR_CHAT_BLOSSOM` set (see Configuration).

## Hacking

```bash
# rebuild + restart daemon with the real state dir
./daemon/dev.sh

# restart the shell (reloads luau entries)
systemctl --user restart noctalia.service

# poke it
noctalia msg plugin makefu/nostr-chat:service all toggle
echo '{"cmd":"send","text":"hi"}' | nc -U "$XDG_RUNTIME_DIR/nostr-chatd.sock"
sqlite3 ~/.local/state/nostr-chatd/messages.db \
  'select dir,ack,substr(content,1,40) from messages order by ts desc limit 10'
```

## How it works

A small Go daemon owns the Nostr connection and a sqlite history. The shell
side is a plain process contract: the service entry spawns
`nostr-chatd listen` via `runStream` (NDJSON events on stdout, with synthetic
`bridge-up`/`bridge-down` health markers) and posts `nostr-chatd cmd '<json>'`
one-shots for commands. The panel is a thin declarative view over
`noctalia.state`. Either side can restart without losing anything — the listen
client re-dials with backoff and self-issues a replay on every (re)connect.

Known limitations vs. the old QML UI: no OS-level file drag&drop (v5
drag&drop is intra-panel only) and no in-panel file picker (clipboard 📎
covers image attach).

Protocol details and design rationale live in the `daemon/*.go` comments.
