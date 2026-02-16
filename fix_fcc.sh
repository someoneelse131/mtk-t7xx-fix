#!/bin/bash
# Install ModemManager's built-in FCC unlock for FM350 (14c3:4d75)
# and restart ModemManager. Does not require a reboot.
#
# Must be run as root (sudo bash fix_fcc.sh)
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "Error: must be run as root (sudo bash fix_fcc.sh)"
    exit 1
fi

FCC_UNLOCK_DIR="/usr/lib64/ModemManager/fcc-unlock.d"
FCC_UNLOCK_SRC="/usr/share/ModemManager/fcc-unlock.available.d/14c3"

if [ ! -f "$FCC_UNLOCK_SRC" ]; then
    echo "ERROR: FCC unlock source not found at $FCC_UNLOCK_SRC"
    echo "Is ModemManager installed?"
    exit 1
fi

# Ensure xxd is available (the FCC unlock script needs it)
if ! command -v xxd &>/dev/null; then
    echo "Installing xxd (vim-common)..."
    dnf install -y vim-common
fi

mkdir -p "$FCC_UNLOCK_DIR"
cp "$FCC_UNLOCK_SRC" "$FCC_UNLOCK_DIR/14c3:4d75"
chmod 755 "$FCC_UNLOCK_DIR/14c3:4d75"
restorecon "$FCC_UNLOCK_DIR/14c3:4d75" 2>/dev/null || true

echo "FCC unlock script installed."
echo "Restarting ModemManager..."
systemctl restart ModemManager

echo "Waiting for FCC unlock..."
sleep 15

mmcli -m 0
