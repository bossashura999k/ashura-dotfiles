#!/bin/bash
# powersaver_mode.sh – Enable aggressive power saving on Kali Linux
# Saves all original values into /tmp/powersave_state/ for later restoration.
# Usage: sudo ./powersaver_mode.sh [--dry-run]

set -euo pipefail

STATE_DIR="/tmp/powersave_state"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[$(date +%T)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(date +%T)] ✓${RESET} $*"; }
skip() { echo -e "${YELLOW}[$(date +%T)] –${RESET} $*"; }
warn() { echo -e "${RED}[$(date +%T)] !${RESET} $*"; }

write() {          # write <value> <path>  — respects --dry-run
    if $DRY_RUN; then
        skip "DRY-RUN: would write '$1' → $2"
    else
        echo "$1" > "$2" 2>/dev/null || warn "Could not write to $2"
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

# Track applied tweaks for summary
APPLIED=()
SKIPPED=()

# ── 1. CPU frequency governor ──────────────────────────────────────────────────
GOV_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [ -f "$GOV_FILE" ]; then
    ORIG_GOV=$(cat "$GOV_FILE")
    save "$ORIG_GOV" cpu_governor
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] && write "powersave" "$cpu"
    done
    ok "CPU governor: $ORIG_GOV → powersave"
    APPLIED+=("CPU governor")
else
    skip "CPU governor sysfs not found (no cpufreq driver?)"
    SKIPPED+=("CPU governor")
fi

# ── 2. CPU turbo boost ─────────────────────────────────────────────────────────
# Intel
TURBO_INTEL="/sys/devices/system/cpu/intel_pstate/no_turbo"
# AMD
TURBO_AMD="/sys/devices/system/cpu/cpufreq/boost"
if [ -f "$TURBO_INTEL" ]; then
    save "$(cat "$TURBO_INTEL")" cpu_turbo_intel
    write "1" "$TURBO_INTEL"
    ok "Intel turbo boost disabled"
    APPLIED+=("Turbo boost (Intel)")
elif [ -f "$TURBO_AMD" ]; then
    save "$(cat "$TURBO_AMD")" cpu_turbo_amd
    write "0" "$TURBO_AMD"
    ok "AMD boost disabled"
    APPLIED+=("Turbo boost (AMD)")
else
    skip "Turbo boost control not available"
    SKIPPED+=("Turbo boost")
fi

# ── 3. Screen brightness (10 % of max) ────────────────────────────────────────
for bl in /sys/class/backlight/*; do
    [ -d "$bl" ] || continue
    if [ -f "$bl/brightness" ] && [ -f "$bl/max_brightness" ]; then
        name=$(basename "$bl")
        ORIG=$(cat "$bl/brightness")
        MAX=$(cat "$bl/max_brightness")
        NEW=$(( MAX / 10 ))
        [ "$NEW" -lt 1 ] && NEW=1
        save "$ORIG" "brightness_${name}"
        write "$NEW" "$bl/brightness"
        ok "Brightness ($name): $ORIG → $NEW / $MAX"
        APPLIED+=("Brightness ($name)")
    fi
done

# ── 4. DPMS / Screen blanking (X11) ───────────────────────────────────────────
if command -v xset &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    if xset q 2>/dev/null | grep -q "DPMS is Enabled"; then
        save "enabled" dpms_state
    else
        save "disabled" dpms_state
    fi
    if ! $DRY_RUN; then
        xset +dpms
        xset dpms 60 120 180
    fi
    ok "DPMS: standby=60s suspend=120s off=180s"
    APPLIED+=("DPMS")
else
    skip "DPMS: no X11 display detected"
    SKIPPED+=("DPMS")
fi

# ── 5. Bluetooth (rfkill) ─────────────────────────────────────────────────────
if command -v rfkill &>/dev/null; then
    # Parse: ID TYPE SOFT HARD — skip the header line
    rfkill list --output ID,TYPE,SOFT,HARD --noheadings 2>/dev/null \
        | awk '$2=="bluetooth"' \
        | while read -r id _type soft _hard; do
            echo "$id $soft" >> "$STATE_DIR/rfkill_bluetooth" 2>/dev/null || true
            $DRY_RUN || rfkill block "$id" 2>/dev/null || warn "Could not block rfkill id $id"
        done
    ok "Bluetooth blocked via rfkill"
    APPLIED+=("Bluetooth")
else
    skip "rfkill not available"
    SKIPPED+=("Bluetooth")
fi

# ── 6. Wi-Fi (nmcli) ──────────────────────────────────────────────────────────
if command -v nmcli &>/dev/null; then
    WIFI_STATE=$(nmcli radio wifi 2>/dev/null || echo "unknown")
    save "$WIFI_STATE" nmcli_wifi
    $DRY_RUN || nmcli radio wifi off 2>/dev/null || warn "Could not disable Wi-Fi via nmcli"
    ok "Wi-Fi: $WIFI_STATE → off"
    APPLIED+=("Wi-Fi")
else
    skip "nmcli not available"
    SKIPPED+=("Wi-Fi")
fi

# ── 7. NIC power management (ethtool) ─────────────────────────────────────────
if command -v ethtool &>/dev/null; then
    for iface in /sys/class/net/*; do
        name=$(basename "$iface")
        [[ "$name" == "lo" ]] && continue
        # Only physical NICs (have a device symlink)
        [ -e "$iface/device" ] || continue
        # Skip wireless — ethtool WoL/EEE ops are meaningless on wifi
        [ -d "$iface/wireless" ] && continue
        current=$(ethtool --show-eee "$name" 2>/dev/null | awk '/EEE status/{print $NF}') || true
        echo "$name $current" >> "$STATE_DIR/nic_eee" 2>/dev/null || true
        $DRY_RUN || ethtool --set-eee "$name" eee on 2>/dev/null || true
        current_wol=$(ethtool "$name" 2>/dev/null | awk '/Wake-on:/{print $NF}') || true
        echo "$name $current_wol" >> "$STATE_DIR/nic_wol" 2>/dev/null || true
        $DRY_RUN || ethtool -s "$name" wol d 2>/dev/null || true
    done
    ok "NIC: EEE enabled, Wake-on-LAN disabled (wired only)"
    APPLIED+=("NIC power (EEE/WoL)")
else
    skip "ethtool not available"
    SKIPPED+=("NIC power")
fi

# ── 8. USB autosuspend ─────────────────────────────────────────────────────────
USB_SAVE="$STATE_DIR/usb_autosuspend"
> "$USB_SAVE"
for dev in /sys/bus/usb/devices/*/power/autosuspend_delay_ms; do
    [ -f "$dev" ] || continue
    echo "$dev $(cat "$dev")" >> "$USB_SAVE"
    write "2000" "$dev"
done
for dev in /sys/bus/usb/devices/*/power/control; do
    [ -f "$dev" ] || continue
    echo "$dev $(cat "$dev")" >> "$STATE_DIR/usb_control"
    write "auto" "$dev"
done
ok "USB autosuspend: 2 s for all devices"
APPLIED+=("USB autosuspend")

# ── 9. PCI / PCIe ASPM ────────────────────────────────────────────────────────
ASPM="/sys/module/pcie_aspm/parameters/policy"
if [ -f "$ASPM" ] && [ -w "$ASPM" ]; then
    save "$(cat "$ASPM")" pcie_aspm
    write "powersupersave" "$ASPM"
    ok "PCIe ASPM: powersupersave"
    APPLIED+=("PCIe ASPM")
elif [ -f "$ASPM" ]; then
    skip "PCIe ASPM policy exists but is read-only (boot with pcie_aspm=force to enable)"
    SKIPPED+=("PCIe ASPM")
else
    skip "PCIe ASPM policy not available"
    SKIPPED+=("PCIe ASPM")
fi

# ── 10. Audio power saving (Intel HDA) ────────────────────────────────────────
AUDIO_PM="/sys/module/snd_hda_intel/parameters/power_save"
AUDIO_PM_CTL="/sys/module/snd_hda_intel/parameters/power_save_controller"
if [ -f "$AUDIO_PM" ]; then
    save "$(cat "$AUDIO_PM")" audio_power_save
    write "1" "$AUDIO_PM"
    ok "Audio power save: 1 s idle timeout"
    APPLIED+=("Audio power save")
fi
if [ -f "$AUDIO_PM_CTL" ]; then
    save "$(cat "$AUDIO_PM_CTL")" audio_power_save_ctl
    write "Y" "$AUDIO_PM_CTL"
fi

# ── 11. GPU ────────────────────────────────────────────────────────────────────
# NVIDIA
if command -v nvidia-smi &>/dev/null; then
    GPU_PERF=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1) || true
    save "${GPU_PERF:-unknown}" nvidia_persistence
    $DRY_RUN || nvidia-smi --persistence-mode=0 &>/dev/null || true
    $DRY_RUN || nvidia-smi --auto-boost-default=0 &>/dev/null || true
    ok "NVIDIA: persistence mode off, auto-boost off"
    APPLIED+=("GPU (NVIDIA)")
fi
# Intel/AMD DRM
for card in /sys/class/drm/card[0-9]*/device/power/control; do
    [ -f "$card" ] || continue
    echo "$card $(cat "$card")" >> "$STATE_DIR/drm_power_control" 2>/dev/null || true
    write "auto" "$card"
done
if [ -f "$STATE_DIR/drm_power_control" ]; then
    ok "DRM GPU: runtime PM set to auto"
    APPLIED+=("GPU (DRM/Intel/AMD)")
fi

# ── 12. Disk spindown (hdparm) ────────────────────────────────────────────────
if command -v hdparm &>/dev/null; then
    for disk in /dev/sd[a-z]; do
        [ -b "$disk" ] || continue
        orig=$(hdparm -B "$disk" 2>/dev/null | awk '/APM_level/{print $NF}') || true
        echo "$disk $orig" >> "$STATE_DIR/hdparm_apm" 2>/dev/null || true
        $DRY_RUN || hdparm -B 1 -S 12 "$disk" &>/dev/null || warn "hdparm failed for $disk"
    done
    ok "Disk: APM level 1, spindown after 60 s"
    APPLIED+=("Disk (hdparm)")
else
    skip "hdparm not available (NVMe only? spindown skipped)"
    SKIPPED+=("Disk spindown")
fi

# ── 13. Kernel VM parameters ───────────────────────────────────────────────────
declare -A VM_PARAMS=(
    [vm.swappiness]=1
    [vm.dirty_writeback_centisecs]=1500
    [vm.laptop_mode]=5
    [kernel.nmi_watchdog]=0
)

for param in "${!VM_PARAMS[@]}"; do
    sysfs_key="${param//.//}"
    proc_path="/proc/sys/$sysfs_key"
    [ -f "$proc_path" ] || { skip "sysctl $param not found"; continue; }
    ORIG=$(cat "$proc_path")
    # Store as "param_name=original_value" so the restore script needs no heuristic
    $DRY_RUN || printf '%s=%s\n' "$param" "$ORIG" >> "$STATE_DIR/sysctl_params"
    $DRY_RUN || sysctl -w "${param}=${VM_PARAMS[$param]}" >/dev/null
    ok "sysctl $param: $ORIG → ${VM_PARAMS[$param]}"
    APPLIED+=("sysctl $param")
done

# ── 14. Stop non-essential services ───────────────────────────────────────────
SERVICES=(
    bluetooth.service
    cups.service
    cups-browsed.service
    avahi-daemon.service
    apt-daily.timer
    apt-daily-upgrade.timer
    packagekit.service
    packagekit-offline-update.service
    ModemManager.service
    geoclue.service
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
echo -e "${BOLD}  Power saving mode active${RESET}$(${DRY_RUN} && echo " ${YELLOW}[DRY-RUN]${RESET}")"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  Applied : ${GREEN}${#APPLIED[@]} tweaks${RESET}"
echo -e "  Skipped : ${YELLOW}${#SKIPPED[@]} tweaks${RESET}"
echo -e "  State   : ${CYAN}$STATE_DIR${RESET}"
echo -e "  Restore : ${BOLD}sudo ./unpowersaver_mode.sh${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
