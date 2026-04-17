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

# Install systemd sleep hook to manage ModemManager around suspend/hibernate.
#
# Two distinct problems this hook addresses:
#   (a) After any s2idle resume, the modem's MBIM channel is stale — MM keeps
#       the old handle and loops "Operation aborted" forever. Fix: restart MM
#       after every post event so a fresh MBIM_OPEN is issued.
#   (b) After an S4 resume, the modem returns junk register reads and the
#       mtk_t7xx driver enters L3/INIT reprobe. If MM is polling MBIM during
#       that window, libmbim hits a transaction timeout and abort()s with
#       SIGABRT (observed Fri 2026-04-17 09:36:30 and 09:37:06). Fix: stop
#       MM entirely on pre/hibernate|pre/STH and only start it back up after
#       a reprobe-settle delay on post.
#
# Target handling:
#   pre/suspend                    → cancel pending restart (MM keeps running)
#   pre/hibernate, pre/STH         → stop MM + cancel pending
#   post/suspend                   → schedule restart in 3 s
#   post/hibernate, post/STH       → schedule restart in 10 s
#
# STH cancellation math: during a full STH cycle systemd fires the hook four
# times: pre(entry), post(s2idle-wake for transition), pre(hibernate leg),
# post(after resume). The intermediate post→pre gap is ~140 ms, far shorter
# than the 10 s delay, so the scheduled restart is cancelled before its sleep
# elapses and the driver is not disturbed mid-reprobe.
SLEEP_HOOK="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
cat > "$SLEEP_HOOK" <<'HOOKEOF'
#!/bin/bash
# Restart ModemManager around suspend/hibernate.
#
#   - s2idle resume: stale MBIM session → restart MM for fresh MBIM_OPEN
#   - hibernate/STH resume: modem is in mtk_t7xx L3/INIT reprobe (up to
#     3 attempts; per driver source each attempt can span the 30 s port
#     enumeration + 60 s handshake window). If MM is polling MBIM during
#     that window libmbim abort()s on transaction timeout (signal 6) and
#     MM exits mid-init. Fix: stop MM on pre, start it after a 35 s delay
#     on post — covers the common PLDR reinit case.
#
# The schedule uses a systemd timer (--on-active), not an inner sleep, so
# cancellation on the intermediate pre of an STH cycle is race-free: we
# stop the timer unit before it fires, the target service never runs.
#
# Each schedule uses a unique unit name to avoid the transient-unit GC lag
# that can otherwise make `systemd-run --unit=NAME` fail with EEXIST if
# the same name is still Inactive/dead but not yet collected.
#
# Debug with:  journalctl -b | grep modem-fix
LOG_TAG="modem-fix"
UNIT_FILE=/run/modem-fix-resume.unit

logger -t "$LOG_TAG" "hook called: action=$1 target=${2:-unknown}"

cancel_pending() {
    [ -f "$UNIT_FILE" ] || return 0
    local unit
    unit=$(cat "$UNIT_FILE" 2>/dev/null)
    rm -f "$UNIT_FILE"
    [ -n "$unit" ] || return 0
    logger -t "$LOG_TAG" "cancelling pending ${unit}"
    systemctl stop "${unit}.timer" "${unit}.service" 2>/dev/null || true
    systemctl reset-failed "${unit}.timer" "${unit}.service" 2>/dev/null || true
}

schedule_mm() {
    local delay=$1
    [[ "$delay" =~ ^[0-9]+$ ]] || { logger -t "$LOG_TAG" "invalid delay: $delay"; return 1; }
    local unit="modem-fix-resume-$(date +%s%N)"
    echo "$unit" > "$UNIT_FILE"
    logger -t "$LOG_TAG" "scheduling ModemManager restart in ${delay}s as ${unit}"
    systemd-run --no-block --on-active="${delay}s" --unit="$unit" \
        bash -c 'systemctl restart ModemManager; logger -t modem-fix "ModemManager restart exit: $?"'
}

case "$1/$2" in
    pre/suspend)
        # Plain suspend: MM rides through s2idle, refreshed by post.
        cancel_pending
        ;;
    pre/hibernate|pre/suspend-then-hibernate)
        # Stop MM so it is not polling MBIM during the post-S4 L3/INIT
        # reprobe window (prevents libmbim transaction_timed_out SIGABRT).
        cancel_pending
        if systemctl is-active ModemManager >/dev/null 2>&1; then
            logger -t "$LOG_TAG" "stopping ModemManager before ${2}"
            systemctl stop ModemManager 2>/dev/null || true
        fi
        ;;
    post/suspend)
        # s2idle resume: MBIM may be stale — refresh via short-delay restart.
        schedule_mm 3
        ;;
    post/hibernate|post/suspend-then-hibernate)
        # Hibernate/STH resume: longer delay so kernel-side mtk_t7xx reprobe
        # can complete before MM opens MBIM. During an STH cycle this
        # schedule is cancelled by the immediately-following pre on its way
        # into the actual hibernate phase (~140 ms gap), far before 35 s.
        schedule_mm 35
        ;;
esac
HOOKEOF
chmod 755 "$SLEEP_HOOK"
restorecon "$SLEEP_HOOK" 2>/dev/null || true

# Install companion SDDM sleep hook. This lives outside the mtk_t7xx project
# proper but is bundled here because the same hibernate-resume scenario
# exposes a second bug: the existing 50-sddm-displays.sh unconditionally
# restarts SDDM on post/hibernate, which — if a user Plasma session survived
# the hibernate cycle — creates a DUPLICATE session on next login that
# conflicts over DRM master (observed 2026-04-17 09:36: blackscreen + mouse
# after password, hard-reset required).
SDDM_HOOK="/usr/lib/systemd/system-sleep/50-sddm-displays.sh"
if [ -x /usr/local/bin/generate-sddm-display-config ]; then
cat > "$SDDM_HOOK" <<'SDDMEOF'
#!/bin/bash
# /usr/lib/systemd/system-sleep/50-sddm-displays.sh
#
# Prevent SDDM's KWin from crashing on hibernate resume AND prevent the
# "duplicate user session on resume" bug that causes blackscreen + mouse.
#
# Original problem: On resume, GPU re-initializes and SDDM's greeter KWin
# tries to modeset all connected displays at native refresh rates. With
# 3 outputs this exceeds i915 DBUF bandwidth → ENOSPC → KWin SIGSEGV.
# Fix: Stop SDDM before hibernate so there is no greeter KWin to crash.
#
# Secondary problem: If we naively restart SDDM on post/hibernate while the
# user's Plasma session is still alive (thawed from cgroup freeze), SDDM
# spawns a greeter on tty1 and the user logs in via it → a SECOND session
# is created → the new session's kwin_wayland cannot take DRM master from
# the old session's still-running kwin_wayland → blackscreen + mouse.
# Fix: On post/hibernate, only restart SDDM if there is no healthy user
# Wayland session (its own kwin is alive); otherwise let kscreenlocker
# handle unlock on the existing session.

GENERATOR=/usr/local/bin/generate-sddm-display-config
LOG_TAG="sddm-displays"

has_healthy_user_wayland_session() {
    # 0 iff ≥1 user Wayland session has a live kwin_wayland that can self-compose.
    local id user type state
    while read -r id user; do
        [ -z "$id" ] && continue
        [ "$user" = "sddm" ] && continue
        type=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
        state=$(loginctl show-session "$id" -p State --value 2>/dev/null)
        [ "$type" = "wayland" ] || continue
        [ "$state" != "closing" ] || continue
        if pgrep -u "$user" -x kwin_wayland >/dev/null 2>&1; then
            return 0
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1" "$3}')
    return 1
}

lock_user_wayland_sessions() {
    # Guard against users who disabled lock-on-suspend: proactively lock
    # every user Wayland session so resume always lands on a lock screen.
    local id user type
    while read -r id user; do
        [ -z "$id" ] && continue
        [ "$user" = "sddm" ] && continue
        type=$(loginctl show-session "$id" -p Type --value 2>/dev/null)
        [ "$type" = "wayland" ] || continue
        loginctl lock-session "$id" 2>/dev/null || true
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1" "$3}')
}

case "$1/$2" in
    pre/hibernate)
        lock_user_wayland_sessions
        # Stop SDDM to release DRM master and prevent greeter KWin crash on resume.
        systemctl stop sddm 2>/dev/null
        ;;
    post/hibernate)
        # Regenerate SDDM config with current connector names (MST names
        # may change across hibernate cycles).
        $GENERATOR 2>/dev/null
        if has_healthy_user_wayland_session; then
            logger -t "$LOG_TAG" "user wayland session + live kwin present; leaving SDDM stopped — kscreenlocker handles unlock"
        else
            logger -t "$LOG_TAG" "no healthy user session; restarting SDDM"
            systemctl restart sddm 2>/dev/null
        fi
        ;;
    post/suspend)
        # Suspend is lighter — don't stop/start SDDM, just regenerate
        # config so the next SDDM restart picks up correct connector names.
        # Run in background to avoid blocking resume (~3s Thunderbolt wait).
        $GENERATOR &>/dev/null &
        ;;
esac
SDDMEOF
chmod 755 "$SDDM_HOOK"
restorecon "$SDDM_HOOK" 2>/dev/null || true
else
    echo "NOTE: /usr/local/bin/generate-sddm-display-config not found; skipping SDDM hook install."
    echo "      (This hook is for multi-monitor KDE/SDDM setups and needs that helper script.)"
fi

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
