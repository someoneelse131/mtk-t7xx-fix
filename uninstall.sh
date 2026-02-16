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
