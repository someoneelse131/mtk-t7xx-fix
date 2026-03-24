#!/bin/bash
# Rebuild and reinstall the patched mtk_t7xx module, then reboot.
# Safe to run multiple times — fully idempotent.
#
# Usage:  bash reinstall.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODULE_NAME="mtk_t7xx"
MODULE_VERSION="1.1.1"
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
# suspend-then-hibernate fires the hook 4 times:
#   pre(1) → suspend → wake → post(2) → pre(3) → hibernate → wake → post(4)
# We must only restart MM at post(4), not post(2) — otherwise pre(3) kills
# the pending restart <1s later and the driver enters hibernate mid-reprobe.
# A flag file in /run (tmpfs, cleared on reboot) tracks the phase.
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
cat > "$SLEEP_HOOK" <<'HOOKEOF'
#!/bin/bash
# Restart ModemManager after resume so it opens a fresh MBIM session.
# Without this, the modem's MBIM channel is stale after s2idle and MM
# endlessly fails with "Operation aborted".
#
# Debug with:  journalctl -b | grep modem-fix
LOG_TAG="modem-fix"
STH_FLAG="/run/modem-fix-sth-phase"

logger -t "$LOG_TAG" "hook called: action=$1 target=${2:-unknown}"

case "$1" in
    pre)
        # Cancel any pending MM restart from a previous resume cycle.
        systemctl stop modem-fix-resume 2>/dev/null || true
        systemctl reset-failed modem-fix-resume 2>/dev/null || true

        if [[ "${2:-}" == "suspend-then-hibernate" ]]; then
            if [ -f "$STH_FLAG" ]; then
                # pre(3): about to hibernate — remove flag so post(4) proceeds
                rm -f "$STH_FLAG"
                logger -t "$LOG_TAG" "entering hibernate phase"
            else
                # pre(1): about to suspend — set flag to suppress post(2)
                touch "$STH_FLAG"
            fi
        fi
        ;;
    post)
        if [ -f "$STH_FLAG" ]; then
            # post(2): intermediate wake between s2idle and hibernate — skip
            logger -t "$LOG_TAG" "s2idle→hibernate transition, deferring MM restart"
            exit 0
        fi

        logger -t "$LOG_TAG" "resume detected, restarting ModemManager in 2s"
        systemd-run --no-block --unit=modem-fix-resume \
            bash -c 'sleep 2; systemctl restart ModemManager; logger -t modem-fix "ModemManager restart exit code: $?"'
        ;;
esac
HOOKEOF
chmod 755 "$SLEEP_HOOK"
restorecon "$SLEEP_HOOK" 2>/dev/null || true

# Rebuild initramfs
echo "Rebuilding initramfs..."
dracut --force

echo ""
echo "=== Done! Rebooting in 3 seconds (Ctrl+C to cancel) ==="
sleep 3
reboot
