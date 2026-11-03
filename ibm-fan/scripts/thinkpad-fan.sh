#!/usr/bin/env bash
# thinkpad-fan.sh — the only component that touches /proc/acpi/ibm/fan.
# Machine-readable results go to stdout as exactly one JSON object; prose
# diagnostics go to stderr. Callers branch on exit code + the JSON "error"
# field, never on stderr text.
#
#   thinkpad-fan.sh status [thermal_zone]
#     {"available":true,"status":"enabled","speed":2875,"level":"auto","temp":48}
#     {"available":false,"error":"missing"}      fan file absent        (exit 0)
#     {"available":false,"error":"unreadable"}   read blocked           (exit 0)
#   thinkpad-fan.sh set <level>
#     {"ok":true}                                exit 0
#     {"ok":false,"error":"permission-denied"}   exit 2
#     {"ok":false,"error":"invalid-level"}       exit 3
set -u

FAN_FILE=${FAN_FILE:-/proc/acpi/ibm/fan}
THERMAL_BASE=${THERMAL_BASE:-/sys/class/thermal}

# Kernel-accepted levels (thinkpad_acpi); full-speed is a disengaged alias on
# this driver version but the kernel accepts both spellings.
VALID_LEVELS="auto disengaged full-speed 0 1 2 3 4 5 6 7"

die() {
  # Script-level breakage: no JSON on stdout, exit 1 → caller shows "unknown".
  echo "thinkpad-fan.sh: $*" >&2
  exit 1
}

emit() {
  printf '%s\n' "$1"
  exit "${2:-0}"
}

get_field() {
  # Fan file fields are tab-indented ("speed:\t\t2875"); anchor on the label.
  sed -n "s/^$1:[[:space:]]*//p" <<<"$RAW" | head -n1
}

cmd_status() {
  local zone=${1:-thermal_zone0} temp=null speed level

  if [ ! -e "$FAN_FILE" ]; then
    emit '{"available":false,"error":"missing"}'
  fi

  if ! RAW=$(cat "$FAN_FILE" 2>/dev/null) || [ -z "$RAW" ]; then
    emit '{"available":false,"error":"unreadable"}'
  fi

  level=$(get_field level)
  speed=$(get_field speed)
  status=$(get_field status)
  [ -n "$status" ] || status="unknown"
  [ -n "$speed" ] || speed="na"
  [ -n "$level" ] || level="unknown"
  # Fan-off states report "speed: na" — the plugin renders null there.
  [ "$speed" = "na" ] && speed=null

  # Only interpolate a sysfs path after whitelisting the zone name.
  if [[ "$zone" =~ ^thermal_zone[0-9]+$ ]] \
    && [ -r "$THERMAL_BASE/$zone/temp" ] \
    && raw_temp=$(cat "$THERMAL_BASE/$zone/temp" 2>/dev/null); then
    temp=$((raw_temp / 1000))
  fi

  emit "{\"available\":true,\"status\":\"${status}\",\"speed\":${speed},\"level\":\"${level}\",\"temp\":${temp}}"
}

cmd_set() {
  local lvl=${1:-} ok=false

  if [ -z "$lvl" ]; then
    echo "usage: $0 set <level>" >&2
    emit '{"ok":false,"error":"invalid-level"}' 3
  fi
  for v in $VALID_LEVELS; do
    if [ "$lvl" = "$v" ]; then
      ok=true
      break
    fi
  done
  if [ "$ok" != true ]; then
    echo "invalid level: $lvl" >&2
    emit '{"ok":false,"error":"invalid-level"}' 3
  fi

  if [ ! -e "$FAN_FILE" ]; then
    echo "fan file missing: $FAN_FILE" >&2
    emit '{"ok":false,"error":"permission-denied"}' 2
  fi

  # [ -w ] is unreliable for procfs group semantics — attempt the write and
  # map the failure instead.
  if ! printf 'level %s\n' "$lvl" >"$FAN_FILE" 2>/dev/null; then
    echo "write blocked on $FAN_FILE" >&2
    emit '{"ok":false,"error":"permission-denied"}' 2
  fi

  emit '{"ok":true}'
}

case ${1:-} in
  status) shift; cmd_status "$@" ;;
  set) shift; cmd_set "$@" ;;
  *) die "unknown command: ${1:-}" ;;
esac
