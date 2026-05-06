#!/bin/bash
# Uninstall patched mtk_t7xx DKMS module and all system-level fixes.
# Restores the in-tree (unpatched) kernel module after reboot.
#
# Usage:  sudo bash uninstall.sh [-y|--yes]
#
# WARNING: The in-tree mtk_t7xx module does NOT have the crash fixes.
# If Lenovo Fibocom services trigger fastboot_switching, the kernel
# WILL crash (NULL pointer dereference → panic). This script does NOT
# re-enable those services for safety.

MODULE_NAME="mtk_t7xx"
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    echo "Error: must be run as root (sudo bash uninstall.sh)"
    exit 1
fi

confirm() {
    # confirm "prompt" → returns 0 on yes, 1 on no. Respects -y.
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    local ans
    read -rp "$1 [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

echo "=== Uninstalling patched mtk_t7xx ==="
echo ""
echo "This will remove:"
echo "  - DKMS module (patched driver)"
echo "  - FCC unlock script"
echo "  - Sleep hook (ModemManager resume fix)"
echo "  - ModemManager quick-stop dropin"
echo ""
echo "This will NOT re-enable Lenovo Fibocom services (they cause crashes"
echo "with the unpatched in-tree driver)."
echo ""
if ! confirm "Continue?"; then
    echo "Aborted."
    exit 0
fi

echo ""

# --- Remove every installed DKMS version of mtk_t7xx ---
# (reinstall.sh bumps PACKAGE_VERSION over time; we must tear down all
# versions, not just the hard-coded one, so a partial upgrade history
# doesn't leave stale trees in /usr/src and /var/lib/dkms.)
mapfile -t VERSIONS < <(dkms status 2>/dev/null | \
    awk -F'[/,: ]+' -v m="$MODULE_NAME" '$1==m {print $2}' | sort -u)
# Also catch any versions that exist on disk but are not registered with DKMS
for d in /usr/src/${MODULE_NAME}-*; do
    [ -d "$d" ] || continue
    v="${d#/usr/src/${MODULE_NAME}-}"
    [ -n "$v" ] && VERSIONS+=("$v")
done
# Deduplicate
mapfile -t VERSIONS < <(printf '%s\n' "${VERSIONS[@]}" | awk 'NF' | sort -u)

if [ "${#VERSIONS[@]}" -eq 0 ]; then
    echo "DKMS module not found (already removed or never installed)"
else
    for v in "${VERSIONS[@]}"; do
        echo "Removing DKMS module ${MODULE_NAME}/${v}..."
        dkms remove "${MODULE_NAME}/${v}" --all 2>/dev/null || true
        if [ -d "/usr/src/${MODULE_NAME}-${v}" ]; then
            echo "  removing /usr/src/${MODULE_NAME}-${v}"
            rm -rf "/usr/src/${MODULE_NAME}-${v}"
        fi
    done
fi

# --- Clean root-owned build artifacts from project source ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/src" ]; then
    echo "Cleaning build artifacts from source tree..."
    rm -rf "$SCRIPT_DIR"/src/.*.cmd "$SCRIPT_DIR"/src/*.o "$SCRIPT_DIR"/src/*.ko \
           "$SCRIPT_DIR"/src/*.mod "$SCRIPT_DIR"/src/*.mod.c \
           "$SCRIPT_DIR"/src/modules.order "$SCRIPT_DIR"/src/Module.symvers \
           "$SCRIPT_DIR"/src/.tmp_versions "$SCRIPT_DIR"/src/.cache.mk 2>/dev/null || true
fi

# --- Remove blacklist (legacy, shouldn't exist but clean up) ---
if [ -f /etc/modprobe.d/blacklist-mtk-t7xx.conf ]; then
    echo "Removing module blacklist..."
    rm /etc/modprobe.d/blacklist-mtk-t7xx.conf
fi

# --- Remove keepalive_s2idle modprobe.d conf (only present if user opted in) ---
KEEPALIVE_CONF="/etc/modprobe.d/mtk-t7xx-keepalive.conf"
if [ -f "$KEEPALIVE_CONF" ]; then
    echo "Removing keepalive_s2idle conf..."
    rm "$KEEPALIVE_CONF"
fi

# --- Remove sleep hook ---
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
if [ -f "$SLEEP_HOOK" ]; then
    echo "Removing sleep hook..."
    rm "$SLEEP_HOOK"
fi

# --- Remove SDDM sleep hook if it is ours (bundled in reinstall.sh) ---
# Marker: the reinstall.sh-installed file contains this exact comment line.
SDDM_HOOK="/usr/lib/systemd/system-sleep/50-sddm-displays.sh"
if [ -f "$SDDM_HOOK" ] && \
   grep -q "Prevent SDDM's KWin from crashing on hibernate resume" "$SDDM_HOOK"; then
    echo "Removing SDDM sleep hook..."
    rm "$SDDM_HOOK"
fi

# --- Remove FCC unlock script (check both lib64 and lib) ---
for fcc_path in \
    "/usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75" \
    "/usr/lib/ModemManager/fcc-unlock.d/14c3:4d75"; do
    if [ -f "$fcc_path" ]; then
        echo "Removing FCC unlock script ($fcc_path)..."
        rm "$fcc_path"
    fi
done

# --- Remove ModemManager drop-in ---
MM_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
MM_DROPIN="${MM_DROPIN_DIR}/quick-stop.conf"
if [ -f "$MM_DROPIN" ]; then
    echo "Removing ModemManager quick-stop dropin..."
    rm "$MM_DROPIN"
    rmdir "$MM_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
fi

# --- Fibocom services: DO NOT re-enable ---
# These services cause the kernel crash that this project fixes.
# Re-enabling them with the unpatched in-tree driver would cause
# bootloops (kernel panic on fastboot_switching).
echo ""
echo "NOTE: Lenovo Fibocom services remain disabled for safety."
echo "If you want to re-enable them (at your own risk), run:"
echo "  sudo systemctl enable fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service"

# --- Optionally remove iommu=pt ---
if grep -q 'iommu=pt' /proc/cmdline; then
    echo ""
    if confirm "Remove iommu=pt kernel parameter?"; then
        echo "Removing iommu=pt from kernel parameters..."
        grubby --update-kernel=ALL --remove-args="iommu=pt"
    fi
fi

# --- Rebuild initramfs ---
echo ""
echo "Rebuilding initramfs..."
if command -v dracut &>/dev/null; then
    dracut --force
elif command -v update-initramfs &>/dev/null; then
    update-initramfs -u
fi

echo ""
echo "=== Uninstall complete ==="
echo "The in-tree (unpatched) mtk_t7xx module will load after reboot."
echo ""
echo "WARNING: The in-tree driver does NOT have the crash fixes."
echo "Fibocom services remain disabled to prevent kernel panics."
echo ""
if confirm "Reboot now?"; then
    echo "Rebooting in 3 seconds (Ctrl+C to cancel)..."
    sleep 3
    reboot
fi
