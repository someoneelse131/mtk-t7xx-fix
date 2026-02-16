#!/bin/bash
# Install patched mtk_t7xx module via DKMS
# Must be run as root (sudo)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.0.0"
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"

if [ "$EUID" -ne 0 ]; then
    echo "Error: must be run as root (sudo bash install.sh)"
    exit 1
fi

echo "=== Installing patched mtk_t7xx via DKMS ==="

# Remove previous DKMS version if present
if dkms status "${MODULE_NAME}/${MODULE_VERSION}" 2>/dev/null | grep -q "${MODULE_NAME}"; then
    echo "Removing previous DKMS installation..."
    dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all 2>/dev/null || true
fi

# Copy source to DKMS directory
echo "Copying source to ${DKMS_DIR}..."
rm -rf "${DKMS_DIR}"
mkdir -p "${DKMS_DIR}/src"
cp "${SCRIPT_DIR}"/src/*.c "${SCRIPT_DIR}"/src/*.h "${DKMS_DIR}/src/"
cp "${SCRIPT_DIR}/src/Makefile" "${DKMS_DIR}/src/"
cp "${SCRIPT_DIR}/dkms.conf" "${DKMS_DIR}/"

# DKMS add, build, install
echo "Running DKMS add..."
dkms add "${MODULE_NAME}/${MODULE_VERSION}"

echo "Running DKMS build..."
dkms build "${MODULE_NAME}/${MODULE_VERSION}"

echo "Running DKMS install..."
dkms install "${MODULE_NAME}/${MODULE_VERSION}"

# Remove stale blacklist if present — DKMS extra/ dir already takes
# priority over the in-tree kernel/ dir via depmod ordering.
rm -f /etc/modprobe.d/blacklist-mtk-t7xx.conf

# Rebuild initramfs
echo "Rebuilding initramfs..."
if command -v dracut &>/dev/null; then
    dracut --force
elif command -v update-initramfs &>/dev/null; then
    update-initramfs -u
fi

echo ""
echo "=== Installation complete ==="
echo "The patched module will be used after reboot."
echo "Run 'sudo reboot' and then 'bash verify.sh' to check."
