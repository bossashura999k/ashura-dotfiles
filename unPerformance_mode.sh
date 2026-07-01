#!/bin/bash
# unperformance_mode.sh – Restore original settings saved by performance_mode.sh
# Usage: sudo ./unperformance_mode.sh [--dry-run]

set -euo pipefail

STATE_DIR="/tmp/performance_state"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date +%T)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(date +%T)] ✓${RESET} $*"; }
skip() { echo -e "${YELLOW}[$(date +%T)] –${RESET} $*"; }
warn() { echo -e "${RED}[$(date +%T)] !${RESET} $*"; }

write() {
    if $DRY_RUN; then
        skip "DRY-RUN: would write '$1' → $2"
        return 0
    else
        echo "$1" > "$2" 2>/dev/null && return 0
        warn "Could not write to $2"
        return 1
    fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}" >&2
    exit 1
fi

if [ ! -d "$STATE_DIR" ]; then
    echo -e "${RED}No saved state found at $STATE_DIR — was performance_mode.sh run?${RESET}" >&2
    exit 1
fi

$DRY_RUN && echo -e "\n${YELLOW}${BOLD}*** DRY-RUN MODE — no changes will be made ***${RESET}\n"

log "Restoring original system settings from $STATE_DIR ..."

RESTORED=()
FAILED=()

# ── 1. CPU governor ────────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/cpu_governor" ]; then
    ORIG_GOV=$(cat "$STATE_DIR/cpu_governor")
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && write "$ORIG_GOV" "$cpu"
    done
    ok "CPU governor → $ORIG_GOV"
    RESTORED+=("CPU governor")
fi

# ── 2. Turbo boost ────────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/cpu_turbo" ]; then
    ORIG=$(cat "$STATE_DIR/cpu_turbo")
    write "$ORIG" "/sys/devices/system/cpu/intel_pstate/no_turbo"
    ok "Intel turbo boost → $ORIG"
    RESTORED+=("Turbo boost")
fi

# ── 3. Energy performance preference ──────────────────────────────────────────
if [ -f "$STATE_DIR/energy_perf_pref" ]; then
    ORIG_EPP=$(cat "$STATE_DIR/energy_perf_pref")
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        [ -f "$cpu" ] && write "$ORIG_EPP" "$cpu"
    done
    ok "EPP → $ORIG_EPP"
    RESTORED+=("Energy Perf Pref")
fi

# ── 4. PCIe ASPM ──────────────────────────────────────────────────────────────
ASPM="/sys/module/pcie_aspm/parameters/policy"
if [ -f "$STATE_DIR/pcie_aspm" ]; then
    ORIG=$(cat "$STATE_DIR/pcie_aspm")
    if [ -f "$ASPM" ] && [ -w "$ASPM" ]; then
        if write "$ORIG" "$ASPM"; then
            ok "PCIe ASPM → $ORIG"
            RESTORED+=("PCIe ASPM")
        else
            warn "Could not restore PCIe ASPM policy to $ORIG"
            FAILED+=("PCIe ASPM")
        fi
    else
        skip "PCIe ASPM policy file not available/writable during restore"
        FAILED+=("PCIe ASPM")
    fi
fi

# ── 5. USB autosuspend ────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/usb_autosuspend" ]; then
    while read -r dev_path orig_val; do
        [ -f "$dev_path" ] && write "$orig_val" "$dev_path"
    done < "$STATE_DIR/usb_autosuspend"
    ok "USB autosuspend delays restored"
    RESTORED+=("USB autosuspend")
fi
if [ -f "$STATE_DIR/usb_control" ]; then
    while read -r dev_path orig_val; do
        [ -f "$dev_path" ] && write "$orig_val" "$dev_path"
    done < "$STATE_DIR/usb_control"
    ok "USB control restored"
fi

# ── 6. Audio PM ────────────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/audio_power_save" ]; then
    write "$(cat "$STATE_DIR/audio_power_save")" "/sys/module/snd_hda_intel/parameters/power_save"
    ok "Audio power_save restored"
    RESTORED+=("Audio PM")
fi
if [ -f "$STATE_DIR/audio_power_save_ctl" ]; then
    write "$(cat "$STATE_DIR/audio_power_save_ctl")" "/sys/module/snd_hda_intel/parameters/power_save_controller"
fi

# ── 7. Disk APM / spindown ────────────────────────────────────────────────────
if [ -f "$STATE_DIR/hdparm_apm" ] && command -v hdparm &>/dev/null; then
    while read -r disk orig_apm; do
        [ -b "$disk" ] || continue
        $DRY_RUN || hdparm -B "${orig_apm:-254}" -S 0 "$disk" &>/dev/null || warn "hdparm restore failed for $disk"
    done < "$STATE_DIR/hdparm_apm"
    ok "Disk APM restored"
    RESTORED+=("Disk APM")
fi

# ── 8. Services ───────────────────────────────────────────────────────────────
for active_file in "$STATE_DIR"/*_active; do
    [ -f "$active_file" ] || continue
    svc="${active_file##*/}"
    svc="${svc%_active}"

    active_state=$(cat "$active_file")
    enabled_file="${STATE_DIR}/${svc}_enabled"
    enabled_state="disabled"
    [ -f "$enabled_file" ] && enabled_state=$(cat "$enabled_file")

    if ! $DRY_RUN; then
        [ "$active_state"  = "active"  ] && systemctl start  "$svc" 2>/dev/null || true
        [ "$active_state"  = "inactive" ] && systemctl stop   "$svc" 2>/dev/null || true
        [ "$enabled_state" = "enabled"  ] && systemctl enable "$svc" 2>/dev/null || true
        [ "$enabled_state" = "disabled" ] && systemctl disable "$svc" 2>/dev/null || true
    fi
    ok "Service $svc → active=$active_state, enabled=$enabled_state"
    RESTORED+=("service:$svc")
done

# ── Cleanup ────────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
    rm -rf "$STATE_DIR"
    log "State directory removed: $STATE_DIR"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  System restored to original state${RESET}$(${DRY_RUN} && echo " ${YELLOW}[DRY-RUN]${RESET}")"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Restored : ${GREEN}${#RESTORED[@]} items${RESET}"
echo -e "  Failed   : ${RED}${#FAILED[@]} items${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
