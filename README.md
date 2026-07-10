# ashura-dotfiles 🔥

My personal Kali Linux setup — a heavily customized `.zshrc` plus a set of scripts for
one-command power management and ad-blocking. Built for daily driving Kali on a laptop,
tuned over time to be fast, informative, and a little dramatic.

## What's in here

| File | What it does |
|---|---|
| `.zshrc` | Custom two-line prompt (`┏━━【user㉿host】━◤path◢`), git branch in prompt, handy aliases, and a `mode()` menu for toggling performance/power-saving |
| `scripts/performance_mode.sh` | Pushes the system to max performance: CPU governor → `performance`, turbo boost on, USB/audio power-saving disabled, PCIe ASPM off, throttling services stopped |
| `scripts/powerSaverMode.sh` | Aggressive battery saving: CPU governor → `powersave`, turbo off, brightness cut to 10%, Wi-Fi/Bluetooth off, disk spindown, non-essential services stopped |
| `scripts/unPerformance_mode.sh` | Reverts everything `performance_mode.sh` changed, using the state it saved |
| `scripts/unPowerSaverMode.sh` | Reverts everything `powerSaverMode.sh` changed, using the state it saved |
| `scripts/adBlocker.sh` | Toggles system-wide AdGuard DNS on your active connection |
| `install.sh` | One-command installer — backs up your current `.zshrc`, installs this one, and copies all scripts into `~/scripts/` |

## Why this exists

Most "performance mode" scripts online just flip the CPU governor and call it a day.
These go further — CPU turbo, PCIe ASPM, USB/audio autosuspend, NIC power management,
disk APM/spindown, and relevant systemd services — and **every single change is
reversible**. Each "on" script snapshots the original value of everything it touches
into `/tmp/performance_state/` or `/tmp/powersave_state/` before modifying it, so the
matching "un-" script can put your system back exactly how it was.

## Setup

### Quick install (recommended)

```bash
git clone https://github.com/YOUR_USERNAME/ashura-dotfiles.git
cd ashura-dotfiles
./install.sh
```

`install.sh` runs as your normal user (not root) and will:
- back up your current `~/.zshrc` to `~/.zshrc.bak.<timestamp>` (never overwrites silently)
- install the new `.zshrc`
- create `~/scripts/` and copy in all five scripts, chmod'd executable
- print a reminder of the machine-specific bits you still need to edit (see below)

Then reload your shell:
```bash
source ~/.zshrc
```

### Manual install

If you'd rather do it by hand:

1. Clone the repo:
   ```bash
   git clone https://github.com/YOUR_USERNAME/ashura-dotfiles.git
   cd ashura-dotfiles
   ```

2. Back up your existing `.zshrc`, then copy this one over:
   ```bash
   mv ~/.zshrc ~/.zshrc.bak
   cp .zshrc ~/.zshrc
   ```

3. Put the scripts where `.zshrc`'s `mode()` and `adBlocker()` functions expect them
   (`~/scripts/`), and make them executable:
   ```bash
   mkdir -p ~/scripts
   cp scripts/*.sh ~/scripts/
   chmod +x ~/scripts/*.sh
   ```

4. Reload your shell:
   ```bash
   source ~/.zshrc
   ```

### Dependencies

Requires `zsh-syntax-highlighting`, `zsh-autosuggestions`, `figlet`, and `fastfetch`
for the full experience:
```bash
sudo apt install zsh-syntax-highlighting zsh-autosuggestions figlet fastfetch
```

## Usage

Once installed, just run:
```bash
mode        # interactive menu: turn performance/power-saver mode on or off
adBlocker   # interactive menu: turn AdGuard DNS on/off, or check status
```

Or call scripts directly:
```bash
sudo ~/scripts/performance_mode.sh          # apply
sudo ~/scripts/performance_mode.sh --dry-run # preview changes without applying
sudo ~/scripts/unPerformance_mode.sh        # revert
```

## ⚠️ Things you'll need to edit for your own machine

These dotfiles came out of *my* specific setup, so a few things won't work as-is on
yours — check these before you rely on them:

- **`mountWindows` alias** — hardcodes `/dev/nvme0n1p3` as the Windows partition. Run
  `lsblk` on your own machine and update the device path, or you risk mounting (or
  worse, later modifying) the wrong disk.
- **`youtube` alias** — points at a specific Chrome PWA `.desktop` file. Either remove
  it or regenerate your own (right-click the installed PWA icon → "Show in folder").
- **`adBlocker.sh`** — the `CONN` and `IFACE` variables at the top are set to my USB
  tethering connection name (`"Wired connection 1"` / `usb0`). Run `nmcli connection
  show` to find your own connection name and interface, then edit those two lines.
- **`darkmod` alias** — only useful if you have The Dark Mod installed at
  `/opt/darkmod`.

## Notes

- All power-management scripts require root (`sudo`) since they write to `/sys` and
  manage systemd services.
- State files live under `/tmp`, so they don't survive a reboot — if you reboot while
  a mode is "on," you'll need to manually reset governors/services, since there'll be
  nothing to restore from.
- Tested on Kali Linux (rolling), zsh 5.9. Should work on most Debian-based distros
  with minor tweaks.

## License

MIT — use it, fork it, rip it apart for your own dotfiles.
