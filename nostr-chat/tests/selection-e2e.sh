#!/usr/bin/env bash
# Nested-compositor E2E for mouse text selection in nostr-chat bubbles.
#
# Chain: weston headless -> labwc nested -> the flake-pinned noctalia, with
# the real plugin deployed and a scripted daemon feeding two seeded
# incoming messages over the listen stream (no network, no keys needed).
#
# Proves the feature the plugin ships: bubbles carry no click wrapper, the
# message text is a focusable multiline Input, so pointer gestures drive the
# host Input's own selection machine:
#   1. drag across the first bubble        -> Ctrl+C puts a strict substring
#                                             of the message on the clipboard
#   2. double-click a word                 -> clipboard == that word
#   3. triple-click a wrapped row          -> clipboard == that logical line
# Clipboard is read back with wl-paste from the nested session.
#
# Bubble geometry comes from selection_check.py (pixel calibration on a grim
# shot), never hardcoded.
#
# Needs: weston, labwc, grim, wl-clipboard, wtype, python3. Invoked by
# `nix flake check` (selection-e2e) or manually.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd) # nostr-chat/
: "${NOCTALIA:=noctalia}"
: "${WESTON:=weston}"
: "${LABWC:=labwc}"
: "${GRIM:=grim}"
: "${WL_PASTE:=wl-paste}"
: "${WTYPE:=wtype}"
PANEL=makefu/nostr-chat:chat


# Message corpus: A is selected by drag/double-click. B is two logical lines
# (explicit newline -> the wrap model and pango must agree on 2 rendered
# rows regardless of font metrics; triple-click targets the second line).
# Expected clipboard strings are derived by selection_check.py from these
# exact texts + the wrap model, never duplicated here.
MSG_A="alpha bravo charlie delta echo foxtrot golf"
MSG_B=$'hotel india juliett kilo lima mike\noscar papa quebec romeo'
# Same dbus bootstrap as composer-e2e.sh: the shell wants a session bus and
# sandbox images have none.
if [[ -z ${DBUS_SESSION_BUS_ADDRESS:-} && -z ${E2E_DBUS_BOOTSTRAPPED:-} ]] \
   && command -v dbus-run-session >/dev/null; then
  boot=$(mktemp -d "${TMPDIR:-/tmp}/nostr-chat-sel-e2e-dbus.XXXXXX")
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
  exec dbus-run-session --config-file="$boot/session.conf" -- bash "$0" "$@"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/nostr-chat-sel-e2e.XXXXXX")
# KEEP_WORK=1 leaves the temp dir (screenshots, logs) behind for debugging.
trap 'kill 0 2>/dev/null || true; [[ ${KEEP_WORK:-} == 1 ]] || rm -rf "$work"' EXIT

export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config XDG_STATE_HOME=$work/home/.local/state
export XDG_DATA_HOME=$work/home/.local/share XDG_RUNTIME_DIR=$work/xdg
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_DATA_HOME/noctalia/plugins" "$XDG_CONFIG_HOME/noctalia"
chmod 700 "$XDG_RUNTIME_DIR"

cp -r "$here" "$XDG_DATA_HOME/noctalia/plugins/nostr-chat"

# Scripted daemon: `listen` replays the seeded NDJSON forever (sleep keeps
# stdout open so the service never sees stream exit); `cmd` accepts posts
# silently. The real daemon would need relays + a keypair; this exercises
# the identical service/panel path.
mkdir -p "$work/bin"
python3 - "$work/seed.ndjson" "$MSG_A" "$MSG_B" <<'PY'
import json, sys
path, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "w") as fh:
    fh.write(json.dumps({"kind": "status", "streaming": True, "relaysUp": 1, "relaysTotal": 1, "name": "E2E Peer"}) + "\n")
    for i, (mid, content) in enumerate((("selA", a), ("selB", b))):
        fh.write(json.dumps({"kind": "msg", "msg": {"id": mid, "pubkey": "aa", "content": content,
                  "ts": 1700000001 + i, "dir": "in", "ack": "", "read": True, "state": "sent"}}) + "\n")
PY
cat >"$work/bin/nostr-chatd" <<EOF
#!/bin/sh
case "\$1" in
  listen) cat "$work/seed.ndjson"; sleep 3600 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/bin/nostr-chatd"

cat >"$XDG_CONFIG_HOME/noctalia/config.toml" <<EOF
[plugins]
enabled = ["makefu/nostr-chat"]

[plugin_settings."makefu/nostr-chat"]
daemon_bin = "$work/bin/nostr-chatd"

[bar.main]
position = "top"
height = 30
modules = []
EOF

"$WESTON" --backend=headless --socket=e2e --width=1440 --height=900 --idle-time=0 \
  >"$work/weston.log" 2>&1 &
for _ in $(seq 100); do
  [[ -S $XDG_RUNTIME_DIR/e2e ]] && break
  sleep 0.2
done
[[ -S $XDG_RUNTIME_DIR/e2e ]] || { tail -30 "$work/weston.log"; exit 1; }

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

# Open the panel; the service streams the seeded messages asynchronously.
for _ in $(seq 25); do
  "$NOCTALIA" msg panel-open "$PANEL" >/dev/null 2>&1 && break
  sleep 0.2
done
sleep 1.5 # panel animation + stream replay + render ticks

vptr() { python3 "$here/tests/wl_vptr.py" "$@"; }

sentinel_reset() { "$NOCTALIA" msg clipboard-copy "SEL-SENTINEL-$RANDOM-$RANDOM" >/dev/null; sleep 0.4; }
clip() { timeout 5 "$WL_PASTE" --no-newline 2>/dev/null || true; }

fail=0
note() { echo "== $*"; }
expect_clip() {
  local want=$1 label=$2 got
  got=$(clip)
  if [[ $got != "$want" ]]; then
    echo "selection-e2e: $label: clipboard=$(printf '%q' "$got") want=$(printf '%q' "$want")" >&2
    fail=$((fail + 1))
  else
    note "$label ok"
  fi
}


# Calibrate bubble geometry from a live screenshot. The wrap capacity comes
# from panel.luau itself so the checker's model tracks the plugin's.
MSG_CAP=$(sed -n 's/^\(local \)\?MSG_CHARS_PER_ROW = \([0-9][0-9]*\).*/\2/p' "$here/panel.luau")
: "${MSG_CAP:?MSG_CHARS_PER_ROW not found in panel.luau}"
"$GRIM" -t png "$work/panel.png"
if ! geom=$(python3 "$here/tests/selection_check.py" "$work/panel.png" "$MSG_CAP" "$MSG_A" "$MSG_B"); then
  echo "selection-e2e: bubble calibration failed (see $work/panel.png)" >&2
  exit 1
fi
eval "$geom"
note "drag=$DRAG_X0,$DRAG_Y->$DRAG_X1 word=$WORD_X,$WORD_Y line=$LINE_X,$LINE_Y copy=$COPY_X,$COPY_Y"

# 1. Drag-select + Ctrl+C: a strict substring of the message lands on the
#    clipboard (not the full content — that would mean the copy button path).
sentinel_reset
vptr drag "$DRAG_X0" "$DRAG_Y" "$DRAG_X1" "$DRAG_Y" 14
sleep 0.3
$WTYPE -M ctrl -k c -m ctrl
sleep 0.5
got=$(clip)
if [[ -z $got || $got == *SEL-SENTINEL* || $got == "$MSG_A" ]] || [[ $MSG_A != *"$got"* ]]; then
  echo "selection-e2e: drag+ctrl+c: clipboard=$(printf '%q' "$got") not a strict substring of MSG_A" >&2
  fail=$((fail + 1))
  cp "$work/panel.png" "$work/fail-drag.png"
else
  note "drag+ctrl+c ok: $(printf '%q' "$got")"
fi

# 2. Double-click selects the word under the pointer.
sentinel_reset
vptr clicks "$WORD_X" "$WORD_Y" 2
sleep 0.3
$WTYPE -M ctrl -k c -m ctrl
sleep 0.5
expect_clip "$WORD_TEXT" "double-click word"

# 3. Triple-click selects the wrapped continuation row of B.
sentinel_reset
vptr clicks "$LINE_X" "$LINE_Y" 3
sleep 0.3
$WTYPE -M ctrl -k c -m ctrl
sleep 0.5
expect_clip "$LINE_TEXT" "triple-click line"

# 4. The per-bubble copy button still copies the whole message. Its slot is
#    located from the meta row's ink clusters (second from right = copy).
sentinel_reset
vptr click "$COPY_X" "$COPY_Y"
sleep 0.6
expect_clip "$MSG_A" "copy button"

"$GRIM" -t png "$work/final.png"
"$NOCTALIA" msg panel-close "$PANEL" || true

if ((fail > 0)); then
  echo "selection-e2e: $fail check(s) failed (shots in $work)"
  exit 1
fi
echo "selection-e2e: all checks pass (shots in $work)"
trap - EXIT # keep artifacts on manual runs
