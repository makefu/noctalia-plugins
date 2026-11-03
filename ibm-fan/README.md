# ibm-fan

ThinkPad fan control for [noctalia](https://github.com/noctalia-dev/noctalia) v5:
fan RPM + level in the bar, click to cycle levels, slide-out panel with a
level grid (Auto / Full / 0–7), RPM and temperature readout.

All `/proc/acpi/ibm/fan` access goes through the bundled
`scripts/thinkpad-fan.sh` helper — the plugin never writes procfs itself, and
at runtime nothing needs sudo (a one-time udev rule grants group access).

![ibm-fan panel](https://github.com/makefu/noctalia-plugins/releases/download/assets/ibm-fan-screenshot.png)

## Plugin

- id: `makefu/ibm-fan`
- entries: bar widget `bar` (`makefu/ibm-fan:bar`), panel `control`
  (`makefu/ibm-fan:control`), headless service `service`
  (`makefu/ibm-fan:service`)

## Requirements

- A ThinkPad with the `thinkpad_acpi` kernel module loaded with
  `fan_control=1` (check: `cat /proc/acpi/ibm/fan` shows a `commands:` line
  mentioning `level`).
- `/proc/acpi/ibm/fan` writable by your user — group `fan_ctl`, mode `0664`
  (set up by the script below or the NixOS config). Without it the readout
  still works and writes fail with an actionable error hint in the UI.
- Tools: `bash`, `cat`, and for the one-time setup `sudo`, `chgrp`, `chmod`,
  `udevadm`.
- noctalia v5 (plugin API ≥ 24).

## Setup (one-time, enables level writes)

```sh
sudo ./scripts/setup-fan-permissions.sh
```

- Creates group `fan_ctl`, adds you to it → **log out and back in**.
- Installs `/etc/udev/rules.d/99-noctalia-ibm-fan.rules` so the fan node is
  `fan_ctl`-group-writable every time `thinkpad_acpi` binds.
- Writes `/etc/modprobe.d/99-noctalia-ibm-fan.conf` with
  `options thinkpad_acpi fan_control=1` — only if nothing else already sets
  it. If it was just enabled, reboot (or reload `thinkpad_acpi`) once.

## Install

Copy or symlink this directory into the plugins dir and enable it:

```sh
ln -s "$PWD" ~/.local/share/noctalia/plugins/ibm-fan
```

Then in `~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = ["makefu/ibm-fan"]
```

Add the widget `makefu/ibm-fan:bar` to a bar in the bar settings, and restart
noctalia (`systemctl --user restart noctalia.service`).

## NixOS

```nix
# flake inputs
inputs.noctalia-plugins.url = "github:makefu/noctalia-plugins";

# system config: fan access
users.groups.fan_ctl = { };
users.users.makefu.extraGroups = [ "fan_ctl" ];
boot.extraModprobeConfig = ''
  options thinkpad_acpi fan_control=1
'';
services.udev.extraRules = ''
  ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="thinkpad_acpi", RUN+="${pkgs.coreutils}/bin/chgrp fan_ctl /proc/acpi/ibm/fan", RUN+="${pkgs.coreutils}/bin/chmod 0664 /proc/acpi/ibm/fan"
'';

# user config: install + enable the plugin
home-manager.users.makefu = {
  home.file.".local/share/noctalia/plugins/ibm-fan".source =
    "${inputs.noctalia-plugins.outPath}/ibm-fan";
  programs.noctalia.settings = {
    plugins.enabled = [ "makefu/ibm-fan" ];
    plugin_settings."makefu/ibm-fan" = { poll_interval = 3; };
  };
};
```

## Settings

| Setting         | Default         | Purpose                                    |
| --------------- | --------------- | ------------------------------------------ |
| `poll_interval` | `3`             | Seconds between fan/temp re-reads          |
| `thermal_zone`  | `thermal_zone0` | sysfs zone for the temperature readout     |
| `show_rpm`      | `true`          | Show RPM in the bar instead of the level   |

## Usage

- **Left-click** the bar widget: cycle `auto → 0 → … → 7 → disengaged → auto`.
- **Right-click**: open the control panel (slides out under the widget).
- Keybinds / scripts via IPC:

```sh
noctalia msg plugin makefu/ibm-fan:service all set auto
noctalia msg plugin makefu/ibm-fan:service all cycle
noctalia msg plugin makefu/ibm-fan:bar all toggle     # anchored panel toggle
noctalia msg panel-toggle makefu/ibm-fan:control      # opens centred (no anchor)
```

## Safety

Levels `0` and `disengaged` take the fan out of firmware control — sustained
use can overheat the machine under load. `Auto` (or killing the plugin)
returns control to the EC; the watchdog setting is untouched.
