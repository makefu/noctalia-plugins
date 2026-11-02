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
- **Images** — 📎 opens an attach menu: clipboard capture (PNG/JPEG/SVG), a
  file browse picker, or recent images from Downloads/Pictures; `Ctrl+V`
  captures a clipboard image directly and falls back to text; bot-generated
  charts render inline (drag-and-drop exists but is disabled — see Images)
- **Nothing gets lost** — history survives restarts, sends retry if the network
  is down
- **Search** — `Ctrl+F`, highlight + prev/next walking through matches

## Layout (noctalia v5 plugin)

```
nostr-chat/
├── plugin.toml           ← manifest: panel, service, settings
├── service.luau          ← daemon bridge (runStream/runAsync) + notifications
├── panel.luau            ← chat UI (declarative ui.* tree)
├── compose_geometry.luau ← composer box math (wrap rows, growth cap) — shared
│                            by the panel and its tests
├── translations/         ← i18n bundles (<lang>.json)
├── daemon/               ← Go bridge (Nostr + sqlite) + listen/cmd subcommands
├── tests/                ← luau unit tests + nested-weston pixel E2E
└── module.nix            ← NixOS module: builds daemon + systemd user unit
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

Click 📎 for the attach menu: **Clipboard** grabs the clipboard image (via
`wl-paste`, PNG/JPEG/SVG, from the selection or the primary buffer — if both
hold different images you get a small chooser row), **Browse** lists images
from Downloads/Pictures through the `noctalia dmenu` launcher, and **Recent**
offers the newest image files on disk. `Ctrl+V` with the panel open skips the
menu and captures the clipboard, falling back to pasting clipboard **text**
into the composer when no image is offered. The **Clipboard** button with no
image in the clipboard opens the **xdg-desktop-portal file picker** (`busctl`
on `FileChooser`; png, jpg, jpeg, svg, gif, webp). Anything non-image reports
*Unsupported file type* inline and sends nothing. **Drag-and-drop is disabled
for now:** the sender is implemented but the host only offers drops to a
plugin that defines the `onFilesDropped` global, and the shell-side
`wl_data_device` receiver is still an unmerged local patch.

Ask the bot for a chart, it renders inline when ready.

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

# checks: luau unit tests + nested-compositor pixel E2E (weston+labwc+grim)
nix build .#checks.x86_64-linux.luau-geometry .#checks.x86_64-linux.composer-e2e
```

## How it works

A small Go daemon owns the Nostr connection and a sqlite history. The shell
side is a plain process contract: the service entry spawns
`nostr-chatd listen` via `runStream` (NDJSON events on stdout, with synthetic
`bridge-up`/`bridge-down` health markers) and posts `nostr-chatd cmd '<json>'`
one-shots for commands. The panel is a thin declarative view over
`noctalia.state`. Either side can restart without losing anything — the listen
client re-dials with backoff and self-issues a replay on every (re)connect.

Known limitations vs. the old QML UI: OS-level file drag&drop is disabled
(`DROP_ENABLED = false` in `panel.luau`; needs the host `wl_data_device`
receiver patch plus plugin API 35), and the portal picker additionally
requires `busctl` plus a FileChooser portal.

Protocol details and design rationale live in the `daemon/*.go` comments.
