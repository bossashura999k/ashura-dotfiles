#!/usr/bin/env zsh
# ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
# ┃   AdGuard DNS Toggle — by IZZI     ┃
# ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
# Usage: adblock [on|off|toggle|status]

# ── Config ────────────────────────────────────────────────────────────────────
CONN="Wired connection 1"       # nmcli connection name for your USB tether
IFACE="usb0"                    # network interface
AG_DNS="94.140.14.14 94.140.15.15"   # AdGuard IPv4 DNS servers

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log_info()  { echo -e "  ${CYAN}◈${NC} $1" }
log_ok()    { echo -e "  ${GREEN}✔${NC} $1" }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $1" }
log_error() { echo -e "  ${RED}✘${NC} $1" >&2 }
log_step()  { echo -e "\n${MAGENTA}${BOLD}::${NC} $1" }

# ── Check current state ───────────────────────────────────────────────────────
# Returns 0 (true) if AdGuard DNS is active, 1 (false) if not
is_enabled() {
  local dns
  dns=$(nmcli connection show "$CONN" 2>/dev/null | awk '/^ipv4\.dns:/{print $2}')
  [[ "$dns" == *"94.140.14.14"* ]]
}

# ── Enable ────────────────────────────────────────────────────────────────────
enable_adblocker() {
  log_step "Enabling AdGuard DNS..."

  log_info "Setting DNS servers → ${DIM}$AG_DNS${NC}"
  sudo nmcli connection modify "$CONN" ipv4.dns "$AG_DNS" 2>/dev/null \
    || { log_error "Failed to set DNS servers"; return 1 }

  log_info "Locking out ISP DNS..."
  sudo nmcli connection modify "$CONN" ipv4.ignore-auto-dns yes 2>/dev/null \
    || { log_error "Failed to set ignore-auto-dns"; return 1 }

  log_info "Restarting connection..."
  sudo nmcli connection down "$CONN" &>/dev/null \
    && sudo nmcli connection up "$CONN" &>/dev/null \
    || { log_error "Failed to restart '$CONN'"; return 1 }

  log_info "Reloading systemd-resolved..."
  sudo systemctl restart systemd-resolved 2>/dev/null \
    || { log_error "Failed to restart systemd-resolved"; return 1 }

  echo ""
  echo -e "  ${GREEN}${BOLD}AdGuard DNS is ON${NC} — Ads getting cooked 🔥"
  _show_dns_line
}

# ── Disable ───────────────────────────────────────────────────────────────────
disable_adblocker() {
  log_step "Disabling AdGuard DNS..."

  log_info "Clearing custom DNS servers..."
  sudo nmcli connection modify "$CONN" ipv4.dns "" 2>/dev/null \
    || { log_error "Failed to clear DNS"; return 1 }

  log_info "Restoring auto-DNS from ISP..."
  sudo nmcli connection modify "$CONN" ipv4.ignore-auto-dns no 2>/dev/null \
    || { log_error "Failed to unset ignore-auto-dns"; return 1 }

  log_info "Restarting connection..."
  sudo nmcli connection down "$CONN" &>/dev/null \
    && sudo nmcli connection up "$CONN" &>/dev/null \
    || { log_error "Failed to restart '$CONN'"; return 1 }

  log_info "Reloading systemd-resolved..."
  sudo systemctl restart systemd-resolved 2>/dev/null \
    || { log_error "Failed to restart systemd-resolved"; return 1 }

  echo ""
  echo -e "  ${RED}${BOLD}AdGuard DNS is OFF${NC} — Back to ISP DNS"
  _show_dns_line
}

# ── Status display ────────────────────────────────────────────────────────────
show_status() {
  echo -e "\n${BOLD}  DNS Status — $IFACE${NC}"
  echo -e "  ${DIM}────────────────────────────${NC}"

  if is_enabled; then
    echo -e "  AdGuard:   ${GREEN}${BOLD}ACTIVE${NC}"
  else
    echo -e "  AdGuard:   ${RED}${BOLD}INACTIVE${NC}"
  fi

  local dns_line
  dns_line=$(resolvectl status "$IFACE" 2>/dev/null | grep "DNS Servers")
  if [[ -n "$dns_line" ]]; then
    echo -e "  Servers:   ${CYAN}$(echo $dns_line | awk '{$1=$2=""; print $0}' | xargs)${NC}"
  else
    echo -e "  Servers:   ${YELLOW}(none / not resolved yet)${NC}"
  fi

  local scope
  scope=$(resolvectl status "$IFACE" 2>/dev/null | grep "Current Scopes" | awk -F': ' '{print $2}')
  echo -e "  Scopes:    ${DIM}${scope:-unknown}${NC}\n"
}

# Helper — one-liner DNS confirmation after enable/disable
_show_dns_line() {
  sleep 0.5
  local dns_line
  dns_line=$(resolvectl status "$IFACE" 2>/dev/null | grep "DNS Servers")
  if [[ -n "$dns_line" ]]; then
    echo -e "  ${DIM}Active DNS: $(echo $dns_line | awk '{$1=$2=""; print $0}' | xargs)${NC}\n"
  fi
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
  echo -e "\n  ${BOLD}adblock${NC} ${DIM}[on|off|toggle|status]${NC}"
  echo -e "  ${DIM}──────────────────────────────────${NC}"
  echo -e "  ${GREEN}on${NC} / enable   — Activate AdGuard DNS"
  echo -e "  ${RED}off${NC} / disable  — Restore ISP DNS"
  echo -e "  toggle       — Flip current state ${DIM}(default)${NC}"
  echo -e "  status       — Show current DNS info\n"
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-toggle}" in
  on|enable)
    if is_enabled; then
      log_warn "AdGuard DNS is already ON. Nothing to do."
    else
      enable_adblocker
    fi
    ;;
  off|disable)
    if ! is_enabled; then
      log_warn "AdGuard DNS is already OFF. Nothing to do."
    else
      disable_adblocker
    fi
    ;;
  toggle)
    if is_enabled; then
      disable_adblocker
    else
      enable_adblocker
    fi
    ;;
  status)
    show_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    log_error "Unknown argument: '$1'"
    usage
    exit 1
    ;;
esac
