#!/usr/bin/env bash
# install.sh – Set up IZZI dotfiles: backs up your current .zshrc, installs the
# new one, and copies the power/adblock scripts into ~/scripts.
#
# Usage: ./install.sh   (run from inside the cloned dotfiles repo, as your normal user — NOT root)

set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "${GREEN}✔${RESET} $*"; }
info() { echo -e "${CYAN}◈${RESET} $*"; }
warn() { echo -e "${YELLOW}⚠${RESET} $*"; }
err()  { echo -e "${RED}✘${RESET} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DEST="$HOME/scripts"
ZSHRC_DEST="$HOME/.zshrc"

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ $EUID -eq 0 ]]; then
    err "Don't run this as root/sudo — it installs into your own home directory."
    err "Just run: ./install.sh"
    exit 1
fi

if [[ ! -f "$SCRIPT_DIR/.zshrc" ]]; then
    err "Couldn't find .zshrc next to install.sh — run this from inside the cloned repo."
    exit 1
fi

echo -e "${BOLD}IZZI dotfiles installer${RESET}"
echo -e "${CYAN}────────────────────────${RESET}"

# ── 1. Back up existing .zshrc ────────────────────────────────────────────────
if [[ -f "$ZSHRC_DEST" || -L "$ZSHRC_DEST" ]]; then
    BACKUP="${ZSHRC_DEST}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$ZSHRC_DEST" "$BACKUP"
    ok "Backed up existing .zshrc → $BACKUP"
else
    info "No existing .zshrc found — nothing to back up."
fi

# ── 2. Install new .zshrc ─────────────────────────────────────────────────────
cp "$SCRIPT_DIR/.zshrc" "$ZSHRC_DEST"
ok "Installed new .zshrc → $ZSHRC_DEST"

# ── 3. Create ~/scripts and copy over the power/adblock scripts ──────────────
mkdir -p "$SCRIPTS_DEST"
ok "Ensured $SCRIPTS_DEST exists"

SCRIPT_FILES=(
    performance_mode.sh
    unPerformance_mode.sh
    powerSaverMode.sh
    unPowerSaverMode.sh
    adBlocker.sh
)

for f in "${SCRIPT_FILES[@]}"; do
    if [[ -f "$SCRIPT_DIR/scripts/$f" ]]; then
        cp "$SCRIPT_DIR/scripts/$f" "$SCRIPTS_DEST/$f"
        chmod +x "$SCRIPTS_DEST/$f"
        ok "Installed $f → $SCRIPTS_DEST/$f"
    else
        warn "Missing $f in repo — skipped"
    fi
done

# ── Reminders ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Done!${RESET}"
echo -e "  Run ${BOLD}source ~/.zshrc${RESET} (or open a new terminal) to load the new setup."
echo ""
echo -e "${YELLOW}${BOLD}Before you rely on the scripts, edit these for your own machine:${RESET}"
echo -e "  • ${BOLD}mountWindows${RESET} alias in .zshrc  → check your real partition with ${BOLD}lsblk${RESET}"
echo -e "  • ${BOLD}CONN${RESET}/${BOLD}IFACE${RESET} in ${BOLD}$SCRIPTS_DEST/adBlocker.sh${RESET} → check ${BOLD}nmcli connection show${RESET}"
echo -e "See the README for full details."
