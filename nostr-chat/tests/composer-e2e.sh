#!/usr/bin/env bash
# Nested-compositor E2E for the nostr-chat composer.
#
# Runs the flake-pinned noctalia under weston (headless), opens the chat
# panel, injects a draft into the panel's draft.txt (the composer seeds from
# it on open), screenshots, and asserts pixel invariants:
#   - the composer border encloses every painted text row (no row bleeds
#     under the stroke) for 1..3 rows, and the box caps at MAX_ROWS with the
#     draft clipped beyond it for 4+ rows.
#   - box height tracks G.boxHeight(rows) exactly.
#
# Geometry facts it trusts (see compose_geometry.luau): LINE_H 17, PAD_V 16,
# BORDER_W 1, CHARS_PER_ROW 72, MAX_ROWS 3. Expected bands are computed from
# the module itself via the luau CLI, never hardcoded.
#
# Invoked by `nix flake check` (pkgs.runCommand with phases) and manually.
# Needs: wayland sockets (nesting), grim, a built nostr-chatd.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd) # nostr-chat/
: "${NOCTALIA:=noctalia}"
: "${WESTON:=weston}"
: "${LABWC:=labwc}"
: "${GRIM:=grim}"
: "${LUAU:=luau}"
: "${NOSTR_CHATD:=$here/daemon/nostr-chatd}"
PANEL=makefu/nostr-chat:chat
# The shell wants a session bus (notifications, i18n). In a sandbox there is
# none — and dbus-run-session's default --session config is the activated
# /etc/dbus-1/session.conf, which only exists on a real system. Write a
# minimal self-contained bus config and re-exec under it before any state
# (temp dir, trap) is created.
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && -z ${E2E_DBUS_BOOTSTRAPPED:-} ]] \
   && command -v dbus-run-session >/dev/null; then
  boot=$(mktemp -d "${TMPDIR:-/tmp}/nostr-chat-e2e-dbus.XXXXXX")
  cat >"$boot/session.conf" <<'CONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow eavesdrop="true"/>
    <allow own="*"/>
    <allow send_destination="*"/>
  </policy>
</busconfig>
CONF
  export E2E_DBUS_BOOTSTRAPPED=1
  # bash, not execve: the store copy's /usr/bin/env shebang does not resolve
  # inside the nixpkgs build sandbox.
  exec dbus-run-session --config-file="$boot/session.conf" -- bash "$0" "$@"
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/nostr-chat-e2e.XXXXXX")
trap 'kill 0 2>/dev/null || true; rm -rf "$work"' EXIT

export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config XDG_STATE_HOME=$work/home/.local/state
export XDG_DATA_HOME=$work/home/.local/share XDG_RUNTIME_DIR=$work/xdg
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME/noctalia/plugins" "$XDG_CONFIG_HOME/noctalia"
chmod 700 "$XDG_RUNTIME_DIR"

# Deploy the plugin exactly as shipped.
cp -r "$here" "$XDG_DATA_HOME/noctalia/plugins/nostr-chat"

# Minimal config: enable the plugin, a 1920x1080 bar so the shell comes up
# with a panel host, and the daemon binary.
cat >"$XDG_CONFIG_HOME/noctalia/config.toml" <<EOF
[plugins]
enabled = ["makefu/nostr-chat"]

[plugin_settings."makefu/nostr-chat"]
daemon_bin = "$NOSTR_CHATD"

[bar.main]
position = "top"
height = 30
modules = []
EOF

# Self-signed relays offline: the daemon retries silently, chat still renders.
# Offline is fine - the composer geometry is independent of message content.

# Chain: weston headless (bare, no screencopy) -> labwc nested (adds
# wlr-screencopy + layershell that grim and the shell need) -> noctalia.
"$WESTON" --backend=headless --socket=e2e --width=1440 --height=900 --idle-time=0 \
  >"$work/weston.log" 2>&1 &
for _ in $(seq 100); do
  [[ -S $XDG_RUNTIME_DIR/e2e ]] && break
  sleep 0.2
done

WAYLAND_DISPLAY=e2e "$LABWC" >"$work/labwc.log" 2>&1 &
NESTED=
for _ in $(seq 100); do
  for s in "$XDG_RUNTIME_DIR"/wayland-*; do
    [[ -S $s && $(basename "$s") != e2e ]] && NESTED=$(basename "$s") && break 2
  done
  sleep 0.2
done
[[ -n $NESTED ]] || { tail -30 "$work/labwc.log"; exit 1; }
export WAYLAND_DISPLAY=$NESTED

"$NOCTALIA" >"$work/noctalia.log" 2>&1 &
for _ in $(seq 100); do
  [[ -S $XDG_RUNTIME_DIR/noctalia-$WAYLAND_DISPLAY.sock ]] && break
  sleep 0.2
done
[[ -S $XDG_RUNTIME_DIR/noctalia-$WAYLAND_DISPLAY.sock ]] || { tail -30 "$work/noctalia.log"; exit 1; }

draft_file() {
  local home=$XDG_STATE_HOME/noctalia/plugins/data/makefu/nostr-chat
  mkdir -p "$home"
  printf '%s' "$1" >"$home/draft.txt"
}

# open_panel <draft>: the panel chunk seeds composeText from draft.txt only
# when the runtime is created, so each case cycles the plugin to force a
# fresh chunk before opening.
open_panel() {
  noctalia msg panel-close "$PANEL" || true
  sleep 0.3
  draft_file "$1"
  noctalia msg plugins disable makefu/nostr-chat || true
  sleep 0.3
  noctalia msg plugins enable makefu/nostr-chat || true
  # enable re-registers panel entries asynchronously; retry until known.
  for _ in $(seq 25); do
    noctalia msg panel-open "$PANEL" >/dev/null 2>&1 && break
    sleep 0.2
  done
  sleep 1.2 # panel animation + second tick
}

shot() { "$GRIM" -t png "$work/$1.png"; }

fail=0
# cases: name draft
run_case() {
  local name=$1 text=$2
  open_panel "$text"
  shot "$name"
  echo "== case=$name"
  if ! python3 "$here/tests/composer_check.py" "$work/$name.png" \
       "$here/compose_geometry.luau" "$text" "$LUAU"; then
    fail=$((fail + 1))
  fi
}

# 1..3 rows progressive, then cap.
run_case empty ""
run_case one "hello"
run_case two $'line one\nline two'
run_case three $'first row of the draft\nsecond row of the draft\nthird row of the draft'
run_case four "$(printf 'x%.0s' $(seq 72)) $(printf 'y%.0s' $(seq 72)) $(printf 'z%.0s' $(seq 72)) tail words forcing wrap"
run_case six $'one\ntwo\nthree\nfour\nfive\nsix'
run_case seven $'one\ntwo\nthree\nfour\nfive\nsix\nseven'
run_case longword "$(printf 'w%.0s' $(seq 200))"
run_case crlf $'a\r\nb'

noctalia msg panel-close makefu/nostr-chat:chat || true

if ((fail > 0)); then
  echo "composer-e2e: $fail case(s) failed (screenshots in $work)"
  exit 1
fi
echo "composer-e2e: all cases pass (screenshots in $work)"
trap - EXIT # keep artifacts on manual runs
