#!/bin/bash
# performance_mode.sh – Enable maximum performance on Kali Linux
# Saves all original values into /tmp/performance_state/ for later restoration.
# Usage: sudo ./performance_mode.sh [--dry-run]

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

write() {          # write <value> <path>
    if $DRY_RUN; then
        skip "DRY-RUN: would write '$1' → $2"
        return 0
    else
        echo "$1" > "$2" 2>/dev/null && return 0
        warn "Could not write to $2"
        return 1
    fi
}

save() {           # save <value> <state-key>
    $DRY_RUN || echo "$1" > "$STATE_DIR/$2"
}

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}" >&2
    exit 1
fi

$DRY_RUN && echo -e "\n${YELLOW}${BOLD}*** DRY-RUN MODE — no changes will be made ***${RESET}\n"

mkdir -p "$STATE_DIR"

APPLIED=()
SKIPPED=()

# ── 1. CPU frequency governor ──────────────────────────────────────────────────
GOV_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [ -f "$GOV_FILE" ]; then
    ORIG_GOV=$(cat "$GOV_FILE")
    save "$ORIG_GOV" cpu_governor
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && write "performance" "$cpu"
    done
    ok "CPU governor: $ORIG_GOV → performance"
    APPLIED+=("CPU governor")
else
    skip "CPU governor sysfs not found"
    SKIPPED+=("CPU governor")
fi

# ── 2. CPU turbo boost (Intel) ─────────────────────────────────────────────────
TURBO_INTEL="/sys/devices/system/cpu/intel_pstate/no_turbo"
if [ -f "$TURBO_INTEL" ]; then
    ORIG=$(cat "$TURBO_INTEL")
    save "$ORIG" cpu_turbo
    write "0" "$TURBO_INTEL" && {
        ok "Intel turbo boost enabled (no_turbo=0)"
        APPLIED+=("Turbo boost")
    } || {
        warn "Could not enable turbo boost"
        SKIPPED+=("Turbo boost")
    }
else
    skip "Intel turbo control not available"
    SKIPPED+=("Turbo boost")
fi

# ── 3. Energy performance preference (Intel HWP) ──────────────────────────────
EPP_BASE="/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"
if [ -f "$EPP_BASE" ]; then
    ORIG_EPP=$(cat "$EPP_BASE")
    save "$ORIG_EPP" energy_perf_pref
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        [ -f "$cpu" ] && write "performance" "$cpu"
    done
    ok "Energy perf preference: $ORIG_EPP → performance"
    APPLIED+=("Energy Perf Pref")
else
    skip "EPP not available (no HWP?)"
    SKIPPED+=("Energy Perf Pref")
fi

# ── 4. PCIe ASPM → performance (off) ──────────────────────────────────────────
ASPM="/sys/module/pcie_aspm/parameters/policy"
if [ -f "$ASPM" ] && [ -w "$ASPM" ]; then
    ORIG=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$ASPM")
    if [ -z "$ORIG" ]; then
        skip "PCIe ASPM: could not parse current policy"
        SKIPPED+=("PCIe ASPM")
    else
        save "$ORIG" pcie_aspm
        if write "performance" "$ASPM"; then
            ok "PCIe ASPM policy: $ORIG → performance"
            APPLIED+=("PCIe ASPM")
        else
            warn "PCIe ASPM write failed (runtime change may not be supported)"
            SKIPPED+=("PCIe ASPM")
        fi
    fi
else
    skip "PCIe ASPM policy file not available or not writable"
    SKIPPED+=("PCIe ASPM")
fi

# ── 5. USB autosuspend → off ──────────────────────────────────────────────────
USB_SAVE="$STATE_DIR/usb_autosuspend"
> "$USB_SAVE"
for dev in /sys/bus/usb/devices/*/power/autosuspend_delay_ms; do
    [ -f "$dev" ] || continue
    echo "$dev $(cat "$dev")" >> "$USB_SAVE"
    write "-1" "$dev"
done
for dev in /sys/bus/usb/devices/*/power/control; do
    [ -f "$dev" ] || continue
    echo "$dev $(cat "$dev")" >> "$STATE_DIR/usb_control"
    write "on" "$dev"
done
ok "USB autosuspend: disabled, control=on"
APPLIED+=("USB autosuspend")

# ── 6. Audio power saving → off ──────────────────────────────────────────────
AUDIO_PM="/sys/module/snd_hda_intel/parameters/power_save"
AUDIO_PM_CTL="/sys/module/snd_hda_intel/parameters/power_save_controller"
if [ -f "$AUDIO_PM" ]; then
    save "$(cat "$AUDIO_PM")" audio_power_save
    write "0" "$AUDIO_PM"
    ok "Audio power_save: 0 (off)"
    APPLIED+=("Audio PM")
fi
if [ -f "$AUDIO_PM_CTL" ]; then
    save "$(cat "$AUDIO_PM_CTL")" audio_power_save_ctl
    write "N" "$AUDIO_PM_CTL"
fi

# ── 7. Rotational disks: APM max, spindown off (hdparm) ───────────────────────
if command -v hdparm &>/dev/null; then
    DISK_DONE=0
    while IFS= read -r line; do
        set -- $line
        disk="/dev/$1"
        rota="$2"
        if [ "$rota" -eq 1 ] && [ -b "$disk" ]; then
            orig_apm=$(hdparm -B "$disk" 2>/dev/null | awk '/APM_level/{print $NF}') || true
            echo "$disk $orig_apm" >> "$STATE_DIR/hdparm_apm" 2>/dev/null || true
            $DRY_RUN || hdparm -B 254 -S 0 "$disk" &>/dev/null || warn "hdparm failed for $disk"
            DISK_DONE=1
        fi
    done < <(lsblk -d -o NAME,ROTA -n)
    if [ $DISK_DONE -eq 1 ]; then
        ok "Rotational disk(s): APM max (254), spindown off"
        APPLIED+=("Disk APM")
    else
        skip "No rotational disk found (NVMe only?)"
        SKIPPED+=("Disk APM")
    fi
else
    skip "hdparm not available"
    SKIPPED+=("Disk APM")
fi

# ── 8. Stop / disable known power-saving services ────────────────────────────
SERVICES=(
    thermald.service
    tlp.service
    power-profiles-daemon.service
)

for svc in "${SERVICES[@]}"; do
    active_state="inactive"
    enabled_state="disabled"
    systemctl is-active  --quiet "$svc" 2>/dev/null && active_state="active"
    systemctl is-enabled --quiet "$svc" 2>/dev/null && enabled_state="enabled"

    save "$active_state"  "${svc}_active"
    save "$enabled_state" "${svc}_enabled"

    if ! $DRY_RUN; then
        [ "$active_state"  = "active"  ] && systemctl stop    "$svc" 2>/dev/null || true
        [ "$enabled_state" = "enabled" ] && systemctl disable "$svc" 2>/dev/null || true
    fi
    ok "Service $svc: stopped+disabled (was active=$active_state, enabled=$enabled_state)"
    APPLIED+=("service:$svc")
done

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  Performance mode active${RESET}$(${DRY_RUN} && echo " ${YELLOW}[DRY-RUN]${RESET}")"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Applied : ${GREEN}${#APPLIED[@]} tweaks${RESET}"
echo -e "  Skipped : ${YELLOW}${#SKIPPED[@]} tweaks${RESET}"
echo -e "  State   : ${CYAN}$STATE_DIR${RESET}"
echo -e "  Restore : ${BOLD}sudo ./unperformance_mode.sh${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
