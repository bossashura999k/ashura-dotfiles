#!/bin/bash
# unpowersaver_mode.sh – Restore original settings saved by powersaver_mode.sh
# Usage: sudo ./unpowersaver_mode.sh [--dry-run]

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

write() {    # write <value> <path>  — respects --dry-run
    if $DRY_RUN; then
        skip "DRY-RUN: would write '$1' → $2"
    else
        echo "$1" > "$2" 2>/dev/null || warn "Could not write to $2"
    fi
}

# ── Preflight ──────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${RESET}" >&2
    exit 1
fi

if [ ! -d "$STATE_DIR" ]; then
    echo -e "${RED}No saved state found at $STATE_DIR — was powersaver_mode.sh run?${RESET}" >&2
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
else
    skip "CPU governor: no saved state"
fi

# ── 2. CPU turbo boost ─────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/cpu_turbo_intel" ]; then
    ORIG=$(cat "$STATE_DIR/cpu_turbo_intel")
    write "$ORIG" "/sys/devices/system/cpu/intel_pstate/no_turbo"
    ok "Intel turbo boost → $ORIG"
    RESTORED+=("Turbo boost (Intel)")
elif [ -f "$STATE_DIR/cpu_turbo_amd" ]; then
    ORIG=$(cat "$STATE_DIR/cpu_turbo_amd")
    write "$ORIG" "/sys/devices/system/cpu/cpufreq/boost"
    ok "AMD boost → $ORIG"
    RESTORED+=("Turbo boost (AMD)")
fi

# ── 3. Screen brightness ───────────────────────────────────────────────────────
for f in "$STATE_DIR"/brightness_*; do
    [ -e "$f" ] || continue
    name="${f##*brightness_}"
    orig_val=$(cat "$f")
    bl_path="/sys/class/backlight/$name/brightness"
    if [ -f "$bl_path" ]; then
        write "$orig_val" "$bl_path"
        ok "Brightness ($name) → $orig_val"
        RESTORED+=("Brightness ($name)")
    else
        warn "Brightness path not found: $bl_path"
        FAILED+=("Brightness ($name)")
    fi
done

# ── 4. DPMS ────────────────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/dpms_state" ] && command -v xset &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    dpms_was=$(cat "$STATE_DIR/dpms_state")
    if ! $DRY_RUN; then
        if [ "$dpms_was" = "enabled" ]; then
            xset +dpms
        else
            xset -dpms
        fi
    fi
    ok "DPMS → $dpms_was"
    RESTORED+=("DPMS")
else
    skip "DPMS: no saved state or no X11 display"
fi

# ── 5. Bluetooth (rfkill) ─────────────────────────────────────────────────────
if [ -f "$STATE_DIR/rfkill_bluetooth" ] && command -v rfkill &>/dev/null; then
    while read -r id soft_state; do
        # rfkill list output uses "unblocked"/"blocked" — restore accordingly
        if [ "$soft_state" = "unblocked" ]; then
            $DRY_RUN || rfkill unblock "$id" 2>/dev/null || warn "rfkill unblock $id failed"
        else
            $DRY_RUN || rfkill block   "$id" 2>/dev/null || warn "rfkill block $id failed"
        fi
    done < "$STATE_DIR/rfkill_bluetooth"
    ok "Bluetooth rfkill states restored"
    RESTORED+=("Bluetooth")
else
    skip "Bluetooth: no saved state or rfkill unavailable"
fi

# ── 6. Wi-Fi (nmcli) ──────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/nmcli_wifi" ] && command -v nmcli &>/dev/null; then
    WIFI_STATE=$(cat "$STATE_DIR/nmcli_wifi")
    if ! $DRY_RUN; then
        if [ "$WIFI_STATE" = "enabled" ]; then
            nmcli radio wifi on  2>/dev/null || warn "Could not enable Wi-Fi"
        else
            nmcli radio wifi off 2>/dev/null || warn "Could not disable Wi-Fi"
        fi
    fi
    ok "Wi-Fi → $WIFI_STATE"
    RESTORED+=("Wi-Fi")
else
    skip "Wi-Fi: no saved state or nmcli unavailable"
fi

# ── 7. NIC (EEE / WoL) ────────────────────────────────────────────────────────
if [ -f "$STATE_DIR/nic_wol" ] && command -v ethtool &>/dev/null; then
    while read -r iface wol_orig; do
        $DRY_RUN || ethtool -s "$iface" wol "$wol_orig" 2>/dev/null || warn "WoL restore failed for $iface"
    done < "$STATE_DIR/nic_wol"
    ok "NIC Wake-on-LAN restored"
    RESTORED+=("NIC WoL")
fi

# ── 8. USB autosuspend ─────────────────────────────────────────────────────────
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
    ok "USB power control restored"
fi

# ── 9. PCIe ASPM ──────────────────────────────────────────────────────────────
ASPM="/sys/module/pcie_aspm/parameters/policy"
if [ -f "$STATE_DIR/pcie_aspm" ] && [ -f "$ASPM" ] && [ -w "$ASPM" ]; then
    ORIG=$(cat "$STATE_DIR/pcie_aspm")
    write "$ORIG" "$ASPM"
    ok "PCIe ASPM → $ORIG"
    RESTORED+=("PCIe ASPM")
elif [ -f "$STATE_DIR/pcie_aspm" ]; then
    skip "PCIe ASPM: policy file is read-only, cannot restore (harmless)"
fi

# ── 10. Audio power saving ─────────────────────────────────────────────────────
AUDIO_PM="/sys/module/snd_hda_intel/parameters/power_save"
AUDIO_PM_CTL="/sys/module/snd_hda_intel/parameters/power_save_controller"
if [ -f "$STATE_DIR/audio_power_save" ] && [ -f "$AUDIO_PM" ]; then
    write "$(cat "$STATE_DIR/audio_power_save")" "$AUDIO_PM"
    ok "Audio power_save restored"
    RESTORED+=("Audio power save")
fi
if [ -f "$STATE_DIR/audio_power_save_ctl" ] && [ -f "$AUDIO_PM_CTL" ]; then
    write "$(cat "$STATE_DIR/audio_power_save_ctl")" "$AUDIO_PM_CTL"
fi

# ── 11. GPU ────────────────────────────────────────────────────────────────────
# NVIDIA
if [ -f "$STATE_DIR/nvidia_persistence" ] && command -v nvidia-smi &>/dev/null; then
    orig_persist=$(cat "$STATE_DIR/nvidia_persistence")
    if [ "$orig_persist" = "Enabled" ]; then
        $DRY_RUN || nvidia-smi --persistence-mode=1 &>/dev/null || true
    fi
    $DRY_RUN || nvidia-smi --auto-boost-default=1 &>/dev/null || true
    ok "NVIDIA settings restored"
    RESTORED+=("GPU (NVIDIA)")
fi
# DRM runtime PM
if [ -f "$STATE_DIR/drm_power_control" ]; then
    while read -r dev_path orig_val; do
        [ -f "$dev_path" ] && write "$orig_val" "$dev_path"
    done < "$STATE_DIR/drm_power_control"
    ok "DRM GPU power control restored"
    RESTORED+=("GPU (DRM)")
fi

# ── 12. Disk spindown (hdparm) ────────────────────────────────────────────────
if [ -f "$STATE_DIR/hdparm_apm" ] && command -v hdparm &>/dev/null; then
    while read -r disk orig_apm; do
        [ -b "$disk" ] || continue
        # Restore APM; disable spindown timer (0 = off)
        $DRY_RUN || hdparm -B "${orig_apm:-254}" -S 0 "$disk" &>/dev/null || warn "hdparm restore failed for $disk"
    done < "$STATE_DIR/hdparm_apm"
    ok "Disk APM and spindown restored"
    RESTORED+=("Disk (hdparm)")
fi

# ── 13. Kernel VM / sysctl parameters ─────────────────────────────────────────
# State file format (written by powersaver): one "param.name=value" per line
if [ -f "$STATE_DIR/sysctl_params" ]; then
    while IFS='=' read -r param orig_val; do
        [[ -z "$param" || "$param" == \#* ]] && continue
        $DRY_RUN || sysctl -w "${param}=${orig_val}" >/dev/null
        ok "sysctl $param → $orig_val"
        RESTORED+=("sysctl $param")
    done < "$STATE_DIR/sysctl_params"
else
    skip "sysctl: no saved state (state file missing)"
fi

# ── 14. Services ───────────────────────────────────────────────────────────────
for active_file in "$STATE_DIR"/*_active; do
    [ -f "$active_file" ] || continue
    svc="${active_file##*/}"    # e.g. bluetooth.service_active
    svc="${svc%_active}"        # bluetooth.service

    active_state=$(cat "$active_file")
    enabled_file="${STATE_DIR}/${svc}_enabled"
    enabled_state="disabled"
    [ -f "$enabled_file" ] && enabled_state=$(cat "$enabled_file")

    if ! $DRY_RUN; then
        if [ "$active_state" = "active" ]; then
            systemctl start  "$svc" 2>/dev/null || warn "Could not start $svc"
        else
            systemctl stop   "$svc" 2>/dev/null || true
        fi
        if [ "$enabled_state" = "enabled" ]; then
            systemctl enable "$svc" 2>/dev/null || warn "Could not enable $svc"
        else
            systemctl disable "$svc" 2>/dev/null || true
        fi
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
