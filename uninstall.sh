#!/bin/bash
# Uninstall patched mtk_t7xx DKMS module and restore in-tree module
# Must be run as root (sudo)
set -e

MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.0.0"
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"

if [ "$EUID" -ne 0 ]; then
    echo "Error: must be run as root (sudo bash uninstall.sh)"
    exit 1
fi

echo "=== Uninstalling patched mtk_t7xx ==="

# Remove DKMS module
if dkms status "${MODULE_NAME}/${MODULE_VERSION}" 2>/dev/null | grep -q "${MODULE_NAME}"; then
    echo "Removing DKMS module..."
    dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all
fi

# Remove DKMS source directory
if [ -d "${DKMS_DIR}" ]; then
    echo "Removing source directory..."
    rm -rf "${DKMS_DIR}"
fi

# Remove blacklist
if [ -f /etc/modprobe.d/blacklist-mtk-t7xx.conf ]; then
    echo "Removing module blacklist..."
    rm /etc/modprobe.d/blacklist-mtk-t7xx.conf
fi

# Remove sleep hook
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
if [ -f "$SLEEP_HOOK" ]; then
    echo "Removing sleep hook..."
    rm "$SLEEP_HOOK"
fi

# Remove FCC unlock script
FCC_UNLOCK="/usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75"
if [ -f "$FCC_UNLOCK" ]; then
    echo "Removing FCC unlock script..."
    rm "$FCC_UNLOCK"
fi

# Remove ModemManager drop-in
MM_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
MM_DROPIN="${MM_DROPIN_DIR}/quick-stop.conf"
if [ -f "$MM_DROPIN" ]; then
    echo "Removing ModemManager drop-in..."
    rm "$MM_DROPIN"
    rmdir "$MM_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload
fi

# Re-enable Lenovo services (best-effort — they may not exist on all systems)
for svc in fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service; do
    systemctl enable "$svc" 2>/dev/null || true
done

# Rebuild initramfs
echo "Rebuilding initramfs..."
if command -v dracut &>/dev/null; then
    dracut --force
elif command -v update-initramfs &>/dev/null; then
    update-initramfs -u
fi

echo ""
echo "=== Uninstall complete ==="
echo "The in-tree mtk_t7xx module will be restored after reboot."
