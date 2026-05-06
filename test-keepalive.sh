#!/bin/bash
# Throwaway test helper for keepalive_s2idle POC.
# Loads the freshly-built ./src/mtk_t7xx.ko with keepalive_s2idle=1
# without touching DKMS or reboot. Run as: sudo bash test-keepalive.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KO="$SCRIPT_DIR/src/mtk_t7xx.ko"

if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

if [ ! -f "$KO" ]; then
    echo "ERROR: $KO not found — run a build first:"
    echo "  cd src && make -C /lib/modules/\$(uname -r)/build M=\$PWD modules"
    exit 1
fi

# Block auto-modprobe before we touch anything. /run/modprobe.d/ is tmpfs.
TEMP_BLOCK=/run/modprobe.d/test-block-mtk.conf
mkdir -p /run/modprobe.d
{
    echo "blacklist mtk_t7xx"
    echo "install mtk_t7xx /bin/false"
} > "$TEMP_BLOCK"
trap 'rm -f "$TEMP_BLOCK"' EXIT
echo "=== Wrote $TEMP_BLOCK ==="

echo "=== Stopping ModemManager ==="
systemctl stop ModemManager
sleep 2

echo "=== rmmod mtk_t7xx ==="
if lsmod | grep -q '^mtk_t7xx'; then
    if out=$(rmmod mtk_t7xx 2>&1); then
        echo "  rmmod ok"
    else
        echo "  rmmod failed: $out"
        echo "  refcnt: $(cat /sys/module/mtk_t7xx/refcnt 2>/dev/null)"
        echo "  holders: $(ls /sys/module/mtk_t7xx/holders 2>/dev/null)"
        echo "  giving up."
        exit 1
    fi
else
    echo "  not loaded"
fi

echo "=== Waiting for /sys/module/mtk_t7xx to disappear ==="
for i in $(seq 1 40); do   # up to 20 s
    if [ ! -d /sys/module/mtk_t7xx ]; then
        echo "  gone after ~$((i*500))ms"
        break
    fi
    sleep 0.5
done
if [ -d /sys/module/mtk_t7xx ]; then
    echo "  WARNING: /sys/module/mtk_t7xx still here after 20s"
    echo "  state: $(cat /sys/module/mtk_t7xx/state 2>/dev/null)"
fi

echo "=== insmod $KO keepalive_s2idle=1 ==="
if ! out=$(insmod "$KO" keepalive_s2idle=1 2>&1); then
    echo "  FAILED: $out"
    echo "  dmesg tail:"
    dmesg | tail -20
    exit 1
fi
echo "  ok"

echo "=== Param ==="
cat /sys/module/mtk_t7xx/parameters/keepalive_s2idle

# Drop the block now that the right module is loaded.
rm -f "$TEMP_BLOCK"
trap - EXIT

echo "=== Starting ModemManager ==="
systemctl start ModemManager

echo "Waiting 25s for modem to register..."
sleep 25

mmcli -m 0 2>/dev/null | head -20 || echo "(modem not ready yet — check 'mmcli -L' in a few seconds)"

cat <<'EOF'

=== Now do this ===

1. Close the lid for ~30 seconds, then open it.
2. Kernel log:    journalctl -k -b | grep keepalive_s2idle
3. Hook log:      journalctl -b   | grep modem-fix
4. Modem state:   mmcli -m 0 | grep -E 'state|signal'

=== If anything breaks ===

Disable at runtime:
   echo N | sudo tee /sys/module/mtk_t7xx/parameters/keepalive_s2idle

Full revert to DKMS module:
   sudo systemctl stop ModemManager
   sudo rmmod mtk_t7xx
   sudo modprobe mtk_t7xx
   sudo systemctl start ModemManager
EOF
