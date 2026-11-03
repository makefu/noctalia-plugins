#!/usr/bin/env bash
# setup-fan-permissions.sh — one-time privileged setup so the noctalia
# ibm-fan plugin can write /proc/acpi/ibm/fan without sudo at runtime.
# Run once with sudo; the plugin never invokes this.
#
# Grants: user ∈ fan_ctl, fan file group-writable via udev, and
# thinkpad_acpi fan_control=1 (if nothing else already sets it).
set -eu

RULES=/etc/udev/rules.d/99-noctalia-ibm-fan.rules
MODPROBE=/etc/modprobe.d/99-noctalia-ibm-fan.conf
GROUP=fan_ctl

[ "$(id -u)" -eq 0 ] || {
  echo "run me with sudo" >&2
  exit 1
}

# udev RUN+= executes off-PATH: bake absolute coreutils paths in at generation.
CHGRP=$(command -v chgrp)
CHMOD=$(command -v chmod)

groupadd -f "$GROUP"
TARGET_USER=${SUDO_USER:-$(id -un)}
usermod -aG "$GROUP" "$TARGET_USER"
echo "added $TARGET_USER to $GROUP (log out and back in)"

cat >"$RULES" <<EOF
# Installed by noctalia ibm-fan (scripts/setup-fan-permissions.sh)
ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="thinkpad_acpi", RUN+="$CHGRP $GROUP /proc/acpi/ibm/fan", RUN+="$CHMOD 0664 /proc/acpi/ibm/fan"
EOF

# Only claim fan_control=1 when no other modprobe file already sets it —
# don't fight a distro/vendor default.
if ! grep -qs 'options thinkpad_acpi .*fan_control=1' /etc/modprobe.d/*.conf; then
  cat >"$MODPROBE" <<'EOF'
# Installed by noctalia ibm-fan (scripts/setup-fan-permissions.sh)
options thinkpad_acpi fan_control=1
EOF
  echo "wrote $MODPROBE — reboot (or reload thinkpad_acpi) to enable fan control"
fi

# Apply the group change to the live procfs node without a reboot.
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=platform 2>/dev/null || true
udevadm trigger --action=bind --subsystem-match=platform 2>/dev/null || true

ls -l /proc/acpi/ibm/fan || echo "(no /proc/acpi/ibm/fan — is this a ThinkPad with thinkpad_acpi?)"
