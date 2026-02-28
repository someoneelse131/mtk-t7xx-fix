#!/bin/bash
# Uninstall patched mtk_t7xx DKMS module and all system-level fixes.
# Restores the in-tree (unpatched) kernel module after reboot.
#
# Usage:  sudo bash uninstall.sh
#
# WARNING: The in-tree mtk_t7xx module does NOT have the crash fixes.
# If Lenovo Fibocom services trigger fastboot_switching, the kernel
# WILL crash (NULL pointer dereference → panic). This script does NOT
# re-enable those services for safety.

MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.0.0"
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"

if [ "$EUID" -ne 0 ]; then
    echo "Error: must be run as root (sudo bash uninstall.sh)"
    exit 1
fi

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
read -rp "Continue? [y/N] " ans
if [[ ! "$ans" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# --- Remove DKMS module ---
dkms_out=$(dkms status "${MODULE_NAME}/${MODULE_VERSION}" 2>/dev/null) || true
if echo "$dkms_out" | grep -q "${MODULE_NAME}"; then
    echo "Removing DKMS module..."
    dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all 2>/dev/null || true
else
    echo "DKMS module not found (already removed or never installed)"
fi

# --- Remove DKMS source directory ---
if [ -d "${DKMS_DIR}" ]; then
    echo "Removing source directory..."
    rm -rf "${DKMS_DIR}"
fi

# --- Remove blacklist (legacy, shouldn't exist but clean up) ---
if [ -f /etc/modprobe.d/blacklist-mtk-t7xx.conf ]; then
    echo "Removing module blacklist..."
    rm /etc/modprobe.d/blacklist-mtk-t7xx.conf
fi

# --- Remove sleep hook ---
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
if [ -f "$SLEEP_HOOK" ]; then
    echo "Removing sleep hook..."
    rm "$SLEEP_HOOK"
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
    read -rp "Remove iommu=pt kernel parameter? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
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
read -rp "Reboot now? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo "Rebooting in 3 seconds (Ctrl+C to cancel)..."
    sleep 3
    reboot
fi
