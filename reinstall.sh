#!/bin/bash
# Rebuild and reinstall the patched mtk_t7xx module, then reboot.
# Safe to run multiple times — fully idempotent.
#
# Usage:  bash reinstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.1.2"
DKMS_DIR="/usr/src/${MODULE_NAME}-${MODULE_VERSION}"
BLACKLIST_CONF="/etc/modprobe.d/blacklist-mtk-t7xx.conf"
KVER="$(uname -r)"
SKIP_BUILD=0

for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
    esac
done

# --- Preflight checks ---

# Must have kernel-devel for the running kernel
if [ ! -d "/usr/src/kernels/$KVER" ] && [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "ERROR: kernel-devel headers not found for $KVER"
    echo "Run:   sudo dnf install kernel-devel-$KVER"
    exit 1
fi

# Warn if iommu=pt is missing from kernel command line
if ! grep -q 'iommu=pt' /proc/cmdline; then
    echo "WARNING: 'iommu=pt' is not in your kernel boot parameters."
    echo "The modem may not work without it. To add it, run:"
    echo ""
    echo "    sudo grubby --update-kernel=ALL --args=\"iommu=pt\""
    echo ""
    read -rp "Continue anyway? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# --- Build (no root needed) ---
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "=== Building patched mtk_t7xx module ==="
    cd "$SCRIPT_DIR/src"
    # Remove root-owned DKMS build artifacts that 'make clean' can't delete
    sudo rm -rf .*.cmd *.o *.ko *.mod *.mod.c modules.order Module.symvers .tmp_versions .cache.mk 2>/dev/null || true
    make -C /lib/modules/"$KVER"/build M="$SCRIPT_DIR/src" clean 2>/dev/null || true
    make -C /lib/modules/"$KVER"/build M="$SCRIPT_DIR/src" modules
    echo ""
fi

# --- Install (needs root) ---
if [ "$EUID" -ne 0 ]; then
    echo "Build succeeded. Elevating for install..."
    exec sudo bash "$SCRIPT_DIR/reinstall.sh" --skip-build
fi

echo "=== Installing via DKMS ==="

# Tear down any existing DKMS state for this module, regardless of what
# state it's in (added, built, installed). Ignore errors — it may not exist.
dkms remove "${MODULE_NAME}/${MODULE_VERSION}" --all 2>/dev/null || true

# Copy source tree into DKMS source directory
rm -rf "${DKMS_DIR}"
mkdir -p "${DKMS_DIR}/src"
cp "$SCRIPT_DIR"/src/*.c "$SCRIPT_DIR"/src/*.h "$SCRIPT_DIR"/src/Makefile "${DKMS_DIR}/src/"
cp "$SCRIPT_DIR/dkms.conf" "${DKMS_DIR}/"

# Register, build, install
dkms add    "${MODULE_NAME}/${MODULE_VERSION}"
dkms build  "${MODULE_NAME}/${MODULE_VERSION}" -k "$KVER"
dkms install "${MODULE_NAME}/${MODULE_VERSION}" -k "$KVER"

# Remove stale blacklist if present — DKMS updates/ dir already takes
# priority over the in-tree kernel/ dir via depmod ordering.
rm -f "$BLACKLIST_CONF"

# Install ModemManager's built-in FCC unlock script for FM350 (14c3:4d75).
# The Lenovo binary (DPR_Fcc_unlock_service) segfaults; this AT-based script works.
FCC_UNLOCK_DIR="/usr/lib64/ModemManager/fcc-unlock.d"
FCC_UNLOCK_SRC="/usr/share/ModemManager/fcc-unlock.available.d/14c3"
if [ -f "$FCC_UNLOCK_SRC" ]; then
    mkdir -p "$FCC_UNLOCK_DIR"
    cp "$FCC_UNLOCK_SRC" "$FCC_UNLOCK_DIR/14c3:4d75"
    chmod 755 "$FCC_UNLOCK_DIR/14c3:4d75"
    restorecon "$FCC_UNLOCK_DIR/14c3:4d75" 2>/dev/null || true
fi

# Ensure xxd is installed (needed by the FCC unlock script)
if ! command -v xxd &>/dev/null; then
    dnf install -y vim-common
fi

# Disable Lenovo Fibocom services — they interfere with the working modem
# by forcing it into fastboot mode after it has already connected.
for svc in fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service; do
    systemctl disable --now "$svc" 2>/dev/null || true
done

# Cap ModemManager stop timeout at 5 seconds. MM gets stuck reprobing the
# modem during shutdown and blocks for the full default 45s until SIGABRT.
MM_DROPIN_DIR="/etc/systemd/system/ModemManager.service.d"
MM_DROPIN="${MM_DROPIN_DIR}/quick-stop.conf"
mkdir -p "$MM_DROPIN_DIR"
cat > "$MM_DROPIN" <<'EOF'
[Service]
TimeoutStopSec=5
EOF
systemctl daemon-reload

# Install systemd sleep hook to restart ModemManager after resume.
# The modem's MBIM session becomes stale after s2idle — MM doesn't know and
# loops "Operation aborted" forever. Restarting MM forces a fresh MBIM_OPEN.
#
# suspend-then-hibernate only fires the hook 4 times (pre/post for suspend,
# pre/post for hibernate) if hibernate ACTUALLY happens within the same
# systemd-suspend-then-hibernate.service invocation. When the user wakes
# from s2idle before the hibernate delay (the common case), only 2 hooks
# fire and post IS the real wake.
#
# Design: always schedule MM restart on post with a short delay. On pre,
# cancel any pending restart. For full STH (s2idle→hibernate→wake):
#   post(2) schedules → pre(3) cancels before restart fires → post(4)
#   schedules again → restart executes after resume.
# For s2idle-only wake or plain suspend:
#   post fires → restart executes after the delay, uninterrupted.
# Observed post→pre gap inside a full STH cycle is ~140 ms, so a 3 s
# delay gives a >20x safety margin for cancellation.
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
cat > "$SLEEP_HOOK" <<'HOOKEOF'
#!/bin/bash
# Restart ModemManager after resume so it opens a fresh MBIM session.
# Without this, the modem's MBIM channel is stale after s2idle and MM
# endlessly fails with "Operation aborted".
#
# Debug with:  journalctl -b | grep modem-fix
LOG_TAG="modem-fix"

logger -t "$LOG_TAG" "hook called: action=$1 target=${2:-unknown}"

case "$1" in
    pre)
        # Cancel any pending MM restart from the previous resume cycle.
        # During a full suspend-then-hibernate chain, this fires as pre(3)
        # after the intermediate post(2) and kills the in-flight restart
        # before its sleep elapses, so the driver does not enter hibernate
        # mid-reprobe. For plain suspend or s2idle-only wake it is a
        # harmless no-op on an already-inactive unit.
        systemctl stop modem-fix-resume 2>/dev/null || true
        systemctl reset-failed modem-fix-resume 2>/dev/null || true
        # Self-heal from a prior broken install that left its flag behind.
        rm -f /run/modem-fix-sth-phase
        ;;
    post)
        # Schedule MM restart with a delay large enough to be cancelable
        # by a follow-up pre (the STH intermediate wake case).
        logger -t "$LOG_TAG" "resume detected, restarting ModemManager in 3s"
        systemd-run --no-block --unit=modem-fix-resume \
            bash -c 'sleep 3; systemctl restart ModemManager; logger -t modem-fix "ModemManager restart exit code: $?"'
        ;;
esac
HOOKEOF
chmod 755 "$SLEEP_HOOK"
restorecon "$SLEEP_HOOK" 2>/dev/null || true

# Rebuild initramfs
echo "Rebuilding initramfs..."
dracut --force

echo ""
read -rp "=== Done! Reboot now? [y/N] " REPLY
if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    reboot
else
    echo "Skipping reboot. Please reboot manually to load the new module."
fi
