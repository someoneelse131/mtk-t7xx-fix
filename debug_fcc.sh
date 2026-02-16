#!/bin/bash

# Fix ownership and SELinux context on the FCC unlock script
chown root:root /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75
restorecon /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75

# Stop ModemManager so it releases the AT port
echo "=== Stopping ModemManager ==="
systemctl stop ModemManager
sleep 2

# Run the FCC unlock script manually with debug logging
echo "=== Running FCC unlock script manually ==="
FCC_UNLOCK_DEBUG_LOG=1 /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75 /dev/null wwan0at0
echo "=== Exit code: $? ==="

echo ""
echo "=== Debug log (if any): ==="
cat /var/log/mm-fm350-fcc.log 2>/dev/null || echo "(no log file)"

echo ""
echo "=== Restarting ModemManager ==="
systemctl restart ModemManager

echo "Waiting 20s for modem to enable..."
sleep 20

mmcli -m 0 | grep -E "state|power"
