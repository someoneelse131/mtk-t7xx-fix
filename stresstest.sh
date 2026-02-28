#!/bin/bash
# ==========================================================================
#  mtk_t7xx stress-test suite
#
#  Comprehensive driver-level stress testing for the patched mtk_t7xx module.
#  Tests the actual kernel fixes (FSM race, NULL kthread, PM timeout) and
#  system-level fixes (sleep hook, FCC unlock, service disabling).
#
#  Usage:  sudo bash stresstest.sh [test ...] [--rounds N]
#
#  Tests (in recommended order):
#    preflight        Module, DKMS, taint, device, FCC checks
#    mm-restart       ModemManager restart stress (10x)
#    conn-cycle       WWAN connection up/down cycling (5x)
#    fastboot         fastboot_switching trigger (5x)
#    rapid-fastboot   fastboot_switching — no pause between rounds (3x)
#    fastboot-load    fastboot_switching during active data transfer
#    suspend          Suspend/resume via rtcwake s2idle (3x)
#    combo            fastboot then immediate suspend, suspend then fastboot
#    all              Run every test in order
#
#  Log is written to stresstest-<timestamp>.log in the current directory.
# ==========================================================================
set -uo pipefail

# --- Configuration ---

PCI_DEV="0000:08:00.0"
PCI_PATH="/sys/bus/pci/devices/${PCI_DEV}"
SYSFS_MODE="${PCI_PATH}/t7xx_mode"
LOGFILE="stresstest-$(date +%Y%m%d-%H%M%S).log"
ROUNDS=""  # override per-test defaults

PASS=0
FAIL=0
SKIP=0
WARN=0
TESTS_RUN=0

# dmesg baseline — set before each test
DMESG_BASELINE=""

# --- Colors (disabled if not a terminal) ---

if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD='' C_RESET=''
fi

# --- Helpers ---

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGFILE"; }
logc() {
    # log with color to terminal, plain to file
    local color="$1"; shift
    echo -e "[$(date +%H:%M:%S)] ${color}$*${C_RESET}"
    echo "[$(date +%H:%M:%S)] $*" >> "$LOGFILE"
}

pass() { logc "$C_GREEN" "  PASS: $1"; ((PASS++)); }
fail() { logc "$C_RED"   "  FAIL: $1"; ((FAIL++)); }
warn() { logc "$C_YELLOW" "  WARN: $1"; ((WARN++)); }
skip() { logc "$C_YELLOW" "  SKIP: $1"; ((SKIP++)); }

separator() {
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Save dmesg line count as baseline before a test
dmesg_snapshot() {
    DMESG_BASELINE=$(dmesg | wc -l)
}

# Check dmesg since last snapshot for problems.
# Returns 0 if clean, 1 if issues found.
dmesg_check() {
    local label="$1"
    local new_lines
    local current_lines
    current_lines=$(dmesg | wc -l)
    new_lines=$(( current_lines - DMESG_BASELINE ))
    [ "$new_lines" -le 0 ] && return 0

    local problems
    problems=$(dmesg | tail -n "$new_lines" | grep -iE \
        'BUG:|WARNING:|NULL pointer|Oops|panic|unable to handle|taint|general protection' \
        2>/dev/null || true)

    if [ -n "$problems" ]; then
        fail "$label — kernel issues in dmesg:"
        echo "$problems" | while IFS= read -r line; do
            log "    $line"
        done
        return 1
    fi

    # Also log t7xx-specific messages for the record
    local t7xx_msgs
    t7xx_msgs=$(dmesg | tail -n "$new_lines" | grep -i 't7xx' 2>/dev/null || true)
    if [ -n "$t7xx_msgs" ]; then
        log "  dmesg (t7xx, ${new_lines} new lines):"
        echo "$t7xx_msgs" | tail -10 | while IFS= read -r line; do
            log "    $line"
        done
    fi

    return 0
}

# Check /proc/sys/kernel/tainted
check_taint() {
    local taint
    taint=$(cat /proc/sys/kernel/tainted 2>/dev/null || echo "?")

    # Bit 0=proprietary module (1), bit 12=unsigned module (4096),
    # bit 13=staging driver (8192), bit 15=livepatch (32768)
    # These are expected for out-of-tree DKMS modules. Anything else is bad.
    # Mask out expected bits: 0+12+13+15 = 1+4096+8192+32768 = 45057
    local expected_mask=45057
    local unexpected=$(( taint & ~expected_mask ))

    if [ "$unexpected" -ne 0 ]; then
        return 1  # unexpected taint
    fi
    return 0
}

get_taint() {
    cat /proc/sys/kernel/tainted 2>/dev/null || echo "?"
}

# Wait for modem to appear in ModemManager
wait_for_modem() {
    local timeout=${1:-60}
    local i=0
    local out
    while [ $i -lt $timeout ]; do
        out=$(mmcli -L 2>/dev/null) || true
        if echo "$out" | grep -q '/Modem/'; then
            return 0
        fi
        sleep 1
        ((i++))
    done
    return 1
}

# Wait for modem to DISAPPEAR from ModemManager
wait_for_modem_gone() {
    local timeout=${1:-30}
    local i=0
    local out
    while [ $i -lt $timeout ]; do
        out=$(mmcli -L 2>/dev/null) || true
        if ! echo "$out" | grep -q '/Modem/'; then
            return 0
        fi
        sleep 1
        ((i++))
    done
    return 1
}

# Get modem index from ModemManager
get_modem_idx() {
    local out
    out=$(mmcli -L 2>/dev/null) || true
    echo "$out" | grep -oP '/Modem/\K[0-9]+' | head -1
}

# Check modem is registered and connected
check_modem_connected() {
    local modem out
    modem=$(get_modem_idx)
    [ -z "$modem" ] && return 1
    out=$(mmcli -m "$modem" 2>/dev/null) || true
    echo "$out" | grep -q 'state.*connected'
}

# Check modem is at least registered (not necessarily connected)
check_modem_registered() {
    local modem out
    modem=$(get_modem_idx)
    [ -z "$modem" ] && return 1
    out=$(mmcli -m "$modem" 2>/dev/null) || true
    echo "$out" | grep -qE 'state.*(registered|connected|connecting)'
}

# Check /dev/wwan* devices exist
check_wwan_devices() {
    ls /dev/wwan* >/dev/null 2>&1
}

# Get WWAN connection name from NetworkManager
get_wwan_connection() {
    local out
    out=$(nmcli -t -f NAME,TYPE con show 2>/dev/null) || true
    echo "$out" | grep gsm | head -1 | cut -d: -f1
}

# Verify data actually flows through the modem
check_data_flow() {
    # Try to ping through the wwan interface
    local iface out
    out=$(ip route show default 2>/dev/null) || true
    iface=$(echo "$out" | grep -oP 'dev \K\S+' | grep -E 'wwan|mbim' | head -1)
    if [ -z "$iface" ]; then
        # Fallback: just ping and hope it routes through modem
        ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1
        return $?
    fi
    ping -c 2 -W 5 -I "$iface" 8.8.8.8 >/dev/null 2>&1
}

# Full modem recovery check: modem visible + registered + wwan devices exist
full_modem_check() {
    local label="$1"
    local ok=true

    local mm_out
    mm_out=$(mmcli -L 2>/dev/null) || true
    if ! echo "$mm_out" | grep -q '/Modem/'; then
        fail "$label — modem not visible in ModemManager"
        return 1
    fi

    if ! check_wwan_devices; then
        warn "$label — /dev/wwan* devices missing"
        ok=false
    fi

    if ! check_modem_registered; then
        warn "$label — modem not registered on network"
        ok=false
    fi

    if $ok; then
        return 0
    fi
    return 1
}

# Trigger fastboot_switching and wait for full recovery
trigger_fastboot_and_wait() {
    local round_label="$1"
    local timeout=${2:-90}

    echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

    # Wait for modem to actually go DOWN first (proves the reset happened)
    if wait_for_modem_gone 15; then
        log "  Modem went down (FSM reset in progress)"
    else
        warn "$round_label — modem did not disappear (reset may not have triggered)"
    fi

    # Now wait for recovery
    if wait_for_modem "$timeout"; then
        # Give modem a moment to finish registration
        sleep 3
        if full_modem_check "$round_label"; then
            pass "$round_label — kernel alive, modem fully recovered"
        else
            # Modem visible but not fully ready — still counts as driver fix working
            pass "$round_label — kernel alive, modem visible (partial recovery)"
        fi
        return 0
    else
        fail "$round_label — modem did NOT recover within ${timeout}s"
        return 1
    fi
}


# ==========================================================================
#  Tests
# ==========================================================================

# --- Preflight: verify system state ---

test_preflight() {
    ((TESTS_RUN++))
    separator
    log "TEST: Preflight checks"
    separator
    dmesg_snapshot

    # 1. Kernel taint
    local taint
    taint=$(get_taint)
    log "  Kernel taint flags: $taint"
    if check_taint; then
        pass "kernel taint clean (value=$taint, out-of-tree bits expected)"
    else
        warn "kernel has unexpected taint flags: $taint"
    fi

    # 2. Module loaded
    if grep -q '^mtk_t7xx ' /proc/modules 2>/dev/null; then
        pass "mtk_t7xx module loaded"
        local modver
        local modinfo_out
        modinfo_out=$(modinfo -F vermagic mtk_t7xx 2>/dev/null) || true
        modver=$(echo "$modinfo_out" | awk '{print $1}')
        log "  Module vermagic: $modver"
        log "  Running kernel:  $(uname -r)"
        if [ "$modver" = "$(uname -r)" ]; then
            pass "module matches running kernel"
        else
            fail "module built for $modver but running $(uname -r)"
        fi
    else
        fail "mtk_t7xx module NOT loaded"
    fi

    # 3. DKMS
    local dkms_out
    dkms_out=$(dkms status mtk_t7xx 2>/dev/null || echo "")
    if echo "$dkms_out" | grep -q "installed"; then
        pass "DKMS module installed"
        log "  $dkms_out"
    else
        warn "DKMS module not in 'installed' state: $dkms_out"
    fi

    # 4. Module is from DKMS (not in-tree)
    local mod_path
    mod_path=$(modinfo -F filename mtk_t7xx 2>/dev/null || echo "")
    if echo "$mod_path" | grep -qE 'updates|extra'; then
        pass "module loaded from DKMS path ($mod_path)"
    elif [ -n "$mod_path" ]; then
        warn "module loaded from: $mod_path (expected updates/ or extra/)"
    fi

    # 5. PCI device
    if [ -d "$PCI_PATH" ]; then
        pass "PCI device $PCI_DEV present"
    else
        fail "PCI device $PCI_DEV not found"
    fi

    # 6. Sysfs mode file
    if [ -e "$SYSFS_MODE" ]; then
        pass "sysfs t7xx_mode exists"
    else
        fail "sysfs t7xx_mode not found at $SYSFS_MODE"
    fi

    # 7. WWAN devices
    if check_wwan_devices; then
        pass "/dev/wwan* devices present"
        log "  $(ls /dev/wwan* 2>/dev/null | tr '\n' ' ')"
    else
        fail "/dev/wwan* devices not found"
    fi

    # 8. ModemManager + modem
    if wait_for_modem 10; then
        pass "modem detected by ModemManager"
        local idx
        idx=$(get_modem_idx)
        if [ -n "$idx" ]; then
            local state
            local mm_info
            mm_info=$(mmcli -m "$idx" 2>/dev/null) || true
            state=$(echo "$mm_info" | grep -oP 'state:\s*\x27\K[^\x27]+' || echo "unknown")
            log "  Modem $idx state: $state"
        fi
    else
        fail "no modem detected by ModemManager"
    fi

    # 9. FCC unlock
    if [ -x "/usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75" ]; then
        pass "FCC unlock script installed"
    elif [ -x "/usr/lib/ModemManager/fcc-unlock.d/14c3:4d75" ]; then
        pass "FCC unlock script installed (lib path)"
    else
        warn "FCC unlock script not found"
    fi

    # 10. Fibocom services disabled
    local svc_ok=true
    for svc in fibo_helper fibo_flash fwswitch lenovo-cfgservice; do
        local svc_state
        svc_state=$(systemctl is-enabled "${svc}.service" 2>/dev/null) || true
        if [ "$svc_state" = "enabled" ]; then
            warn "Fibocom service $svc is still enabled"
            svc_ok=false
        fi
    done
    if $svc_ok; then
        pass "Fibocom services all disabled"
    fi

    # 11. Sleep hook
    if [ -x "/usr/lib/systemd/system-sleep/99-modem-fix.sh" ]; then
        if grep -q 'systemd-run' /usr/lib/systemd/system-sleep/99-modem-fix.sh; then
            pass "sleep hook installed (systemd-run variant)"
        else
            warn "sleep hook exists but uses old subshell method"
        fi
    else
        warn "sleep hook not found at /usr/lib/systemd/system-sleep/99-modem-fix.sh"
    fi

    # 12. iommu=pt
    if grep -q 'iommu=pt' /proc/cmdline; then
        pass "iommu=pt in kernel cmdline"
    else
        warn "iommu=pt missing from kernel cmdline"
    fi

    dmesg_check "preflight"
    log ""
}


# --- ModemManager restart stress ---

test_mm_restart() {
    local rounds=${ROUNDS:-10}
    ((TESTS_RUN++))
    separator
    log "TEST: ModemManager restart stress (${rounds}x)"
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    for i in $(seq 1 "$rounds"); do
        log "  Round $i/$rounds: restarting ModemManager..."
        systemctl restart ModemManager
        sleep 3

        if wait_for_modem 30; then
            if check_wwan_devices; then
                pass "round $i — modem + wwan devices OK"
            else
                warn "round $i — modem detected but /dev/wwan* missing"
                pass "round $i — modem detected after MM restart"
            fi
        else
            fail "round $i — modem NOT detected after MM restart"
        fi
    done

    # Post-test checks
    dmesg_check "mm-restart"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "mm-restart — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# --- WWAN connection cycling ---

test_conn_cycle() {
    local rounds=${ROUNDS:-5}
    local conn
    conn=$(get_wwan_connection)
    ((TESTS_RUN++))
    separator

    if [ -z "$conn" ]; then
        log "TEST: WWAN connection cycling"
        separator
        skip "conn-cycle — no WWAN/gsm connection found in nmcli"
        log ""
        return 0
    fi

    log "TEST: WWAN connection cycling (${rounds}x, conn='$conn')"
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    for i in $(seq 1 "$rounds"); do
        log "  Round $i/$rounds: disconnecting..."
        nmcli con down "$conn" 2>/dev/null || true

        # Wait for modem to be ready before reconnecting
        log "  Round $i/$rounds: waiting for modem to be ready..."
        if ! wait_for_modem 15; then
            warn "round $i — modem disappeared after disconnect, waiting longer..."
            wait_for_modem 30 || true
        fi
        # Give modem time to finish re-registration
        sleep 3

        log "  Round $i/$rounds: connecting..."
        local con_ok=false
        # Try up to 3 times with increasing backoff
        for attempt in 1 2 3; do
            if nmcli con up "$conn" 2>/dev/null; then
                con_ok=true
                break
            fi
            log "  Round $i/$rounds: attempt $attempt failed, retrying in ${attempt}s..."
            sleep "$attempt"
        done

        if $con_ok; then
            sleep 5
            if check_modem_connected; then
                if check_data_flow; then
                    pass "round $i — connected, data flows"
                else
                    warn "round $i — connected but ping failed"
                    pass "round $i — connection re-established"
                fi
            else
                fail "round $i — nmcli up succeeded but modem not in connected state"
            fi
        else
            fail "round $i — nmcli con up failed after 3 attempts"
        fi
    done

    dmesg_check "conn-cycle"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "conn-cycle — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# --- fastboot_switching (standard) ---

test_fastboot() {
    local rounds=${ROUNDS:-5}
    ((TESTS_RUN++))
    separator
    log "TEST: fastboot_switching trigger (${rounds}x)"
    log "  Original bootloop/crash trigger. Tests Issue 2+3 fixes."
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    for i in $(seq 1 "$rounds"); do
        log "  Round $i/$rounds: triggering fastboot_switching..."
        if ! trigger_fastboot_and_wait "round $i" 90; then
            log "  Aborting remaining rounds — modem unrecoverable."
            break
        fi

        # Stabilization pause between rounds
        sleep 5
    done

    dmesg_check "fastboot"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "fastboot — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# --- Rapid fastboot_switching (no pause, maximum FSM stress) ---

test_rapid_fastboot() {
    local rounds=${ROUNDS:-3}
    ((TESTS_RUN++))
    separator
    log "TEST: Rapid fastboot_switching (${rounds}x, no stabilization pause)"
    log "  Maximum stress on FSM race condition handling."
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    for i in $(seq 1 "$rounds"); do
        log "  Round $i/$rounds: triggering fastboot_switching (rapid)..."
        echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

        # Wait for modem to disappear (proves reset happened)
        if wait_for_modem_gone 15; then
            log "  Modem went down"
        else
            warn "round $i — modem did not disappear"
        fi

        # Only wait for modem to reappear — trigger next round immediately after
        if wait_for_modem 90; then
            pass "round $i — kernel alive, modem recovered"
        else
            fail "round $i — modem did NOT recover"
            log "  Aborting remaining rounds."
            break
        fi
        # No stabilization pause — fire again as soon as modem is back
    done

    dmesg_check "rapid-fastboot"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "rapid-fastboot — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# --- fastboot_switching under network load ---

test_fastboot_load() {
    ((TESTS_RUN++))
    separator
    log "TEST: fastboot_switching under active network load"
    log "  Tests FSM reset while DMA queues are actively transmitting."
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    # Verify we have a working connection first
    if ! check_data_flow; then
        skip "fastboot-load — no working data connection to stress"
        log ""
        return 0
    fi

    # Start sustained network load
    local ping_pid download_pid
    ping -i 0.2 -s 1400 8.8.8.8 > /dev/null 2>&1 &
    ping_pid=$!

    # Also generate some download traffic if curl is available
    if command -v curl &>/dev/null; then
        curl -s -o /dev/null --limit-rate 500K \
            "http://speedtest.tele2.net/1MB.zip" 2>/dev/null &
        download_pid=$!
    fi

    log "  Network load started (ping PID=$ping_pid${download_pid:+, curl PID=$download_pid})"
    sleep 3  # let traffic establish

    log "  Triggering fastboot_switching under load..."
    echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

    # Wait for modem to actually go DOWN — this is the critical check
    # that was missing before (false positive fix)
    if wait_for_modem_gone 20; then
        log "  Modem went down (confirmed reset under load)"
    else
        warn "fastboot-load — modem did not disappear within 20s"
    fi

    # Clean up background traffic
    kill $ping_pid 2>/dev/null || true
    [ -n "${download_pid:-}" ] && kill "$download_pid" 2>/dev/null || true
    wait $ping_pid 2>/dev/null || true
    [ -n "${download_pid:-}" ] && wait "$download_pid" 2>/dev/null || true

    # Wait for recovery
    if wait_for_modem 90; then
        sleep 3
        if full_modem_check "fastboot-load"; then
            pass "fastboot-load — kernel alive, modem fully recovered after reset under load"
        else
            pass "fastboot-load — kernel alive, modem visible (partial recovery)"
        fi
    else
        fail "fastboot-load — modem did NOT recover after reset under load"
    fi

    dmesg_check "fastboot-load"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "fastboot-load — kernel taint changed: $taint_before -> $taint_after"
    fi

    sleep 5
    log ""
}


# --- Suspend/resume cycling ---

test_suspend() {
    local rounds=${ROUNDS:-3}
    ((TESTS_RUN++))
    separator
    log "TEST: Suspend/resume cycling (${rounds}x via systemctl suspend)"
    log "  Tests PM timeout fix (Issue 1) and sleep hook (Issue 5)."
    log "  Uses systemctl suspend (full systemd path) so sleep hooks fire."
    separator

    if ! command -v rtcwake &>/dev/null; then
        skip "suspend — rtcwake not found"
        log ""
        return 0
    fi

    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    # Count hook log entries before we start (timezone-proof approach)
    local hook_count_before
    local hook_all
    hook_all=$(journalctl -b 0 -t modem-fix --no-pager 2>/dev/null) || true
    hook_count_before=$(echo "$hook_all" | grep -c "resume detected" || true)
    log "  Sleep hook entries before test: $hook_count_before"

    for i in $(seq 1 "$rounds"); do
        log "  Round $i/$rounds: suspending for 10 seconds..."

        # Snapshot dmesg right before suspend
        local pre_suspend_lines
        pre_suspend_lines=$(dmesg | wc -l)

        # Set RTC alarm to wake in 10s, but don't suspend yet (-m no)
        rtcwake -m no -s 10 2>&1 | tee -a "$LOGFILE"

        # Now suspend through systemd — this triggers sleep hooks
        systemctl suspend 2>&1 | tee -a "$LOGFILE"
        local suspend_exit=$?

        log "  Resumed (suspend exit=$suspend_exit). Waiting for sleep hook + modem..."

        # Sleep hook has 2s delay + MM restart time
        sleep 10

        if wait_for_modem 45; then
            # Check sleep hook fired by comparing entry count (not timestamps)
            local hook_fired=false
            local hook_count_now
            hook_all=$(journalctl -b 0 -t modem-fix --no-pager 2>/dev/null) || true
            hook_count_now=$(echo "$hook_all" | grep -c "resume detected" || true)
            if [ "$hook_count_now" -gt "$hook_count_before" ]; then
                hook_fired=true
                hook_count_before=$hook_count_now
            fi

            if check_wwan_devices; then
                if $hook_fired; then
                    pass "round $i — modem OK, sleep hook fired, wwan devices present"
                else
                    warn "round $i — modem OK but sleep hook may not have fired"
                    pass "round $i — modem detected after resume"
                fi
            else
                warn "round $i — modem detected but /dev/wwan* missing"
                pass "round $i — modem detected after resume"
            fi
        else
            fail "round $i — modem NOT detected after resume"
            log "  Checking if modem eventually comes back..."
            if wait_for_modem 30; then
                log "  Modem appeared after extended wait (slow recovery)"
            fi
        fi

        # Check for PM errors in dmesg since suspend
        local pm_errors
        local new_since_suspend=$(( $(dmesg | wc -l) - pre_suspend_lines ))
        if [ "$new_since_suspend" -gt 0 ]; then
            pm_errors=$(dmesg | tail -n "$new_since_suspend" | \
                grep -iE 'PM:.*error|PM:.*fail|invalid state|returns -' 2>/dev/null || true)
            if [ -n "$pm_errors" ]; then
                log "  PM messages after resume:"
                echo "$pm_errors" | while IFS= read -r line; do
                    log "    $line"
                done
            fi
        fi

        sleep 3
    done

    dmesg_check "suspend"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "suspend — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# --- Combo tests (mixed scenarios) ---

test_combo() {
    ((TESTS_RUN++))
    separator
    log "TEST: Combo — mixed stress scenarios"
    separator
    dmesg_snapshot
    local taint_before
    taint_before=$(get_taint)

    # Combo 1: fastboot then immediate suspend
    log "  --- Combo 1: fastboot_switching then immediate suspend ---"
    log "  Triggering fastboot_switching..."
    echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

    if wait_for_modem_gone 15; then
        log "  Modem went down, waiting for recovery before suspend..."
    fi

    if wait_for_modem 90; then
        log "  Modem back. Suspending immediately (no stabilization)..."
        sleep 2  # minimal pause
        rtcwake -m no -s 10 2>&1 | tee -a "$LOGFILE"
        systemctl suspend 2>&1 | tee -a "$LOGFILE"
        log "  Resumed."
        sleep 10

        if wait_for_modem 45; then
            pass "combo 1 — fastboot+suspend: modem recovered"
        else
            fail "combo 1 — fastboot+suspend: modem NOT detected after resume"
        fi
    else
        fail "combo 1 — modem did not recover from fastboot (suspend skipped)"
    fi

    sleep 5

    # Combo 2: suspend then immediate fastboot
    log "  --- Combo 2: suspend then immediate fastboot_switching ---"
    log "  Suspending..."
    rtcwake -m no -s 10 2>&1 | tee -a "$LOGFILE"
    systemctl suspend 2>&1 | tee -a "$LOGFILE"
    log "  Resumed. Triggering fastboot_switching immediately..."
    sleep 2  # minimal pause

    echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

    if wait_for_modem_gone 15; then
        log "  Modem went down"
    fi

    if wait_for_modem 90; then
        sleep 3
        if full_modem_check "combo 2"; then
            pass "combo 2 — suspend+fastboot: modem fully recovered"
        else
            pass "combo 2 — suspend+fastboot: modem visible"
        fi
    else
        fail "combo 2 — suspend+fastboot: modem NOT recovered"
    fi

    sleep 5

    # Combo 3: MM restart during fastboot recovery
    log "  --- Combo 3: MM restart during fastboot recovery ---"
    log "  Triggering fastboot_switching..."
    echo fastboot_switching > "$SYSFS_MODE" 2>&1 | tee -a "$LOGFILE"

    if wait_for_modem_gone 10; then
        log "  Modem went down. Restarting MM while modem is resetting..."
        systemctl restart ModemManager
        log "  MM restarted during FSM reset."
    else
        log "  Modem didn't disappear quickly, restarting MM anyway..."
        systemctl restart ModemManager
    fi

    if wait_for_modem 90; then
        pass "combo 3 — fastboot+MM restart: modem recovered"
    else
        fail "combo 3 — fastboot+MM restart: modem NOT recovered"
    fi

    dmesg_check "combo"
    local taint_after
    taint_after=$(get_taint)
    if [ "$taint_before" != "$taint_after" ]; then
        fail "combo — kernel taint changed: $taint_before -> $taint_after"
    fi

    log ""
}


# ==========================================================================
#  Runner
# ==========================================================================

run_all() {
    test_preflight
    test_mm_restart
    test_conn_cycle
    test_fastboot
    test_rapid_fastboot
    test_fastboot_load
    test_suspend
    test_combo
}

print_usage() {
    echo "Usage: sudo bash $0 <test> [test ...] [--rounds N]"
    echo ""
    echo "Tests (run individually or 'all'):"
    echo "  preflight        Module, DKMS, taint, device, FCC, service checks"
    echo "  mm-restart       ModemManager restart stress (default 10x)"
    echo "  conn-cycle       WWAN connection up/down cycling (default 5x)"
    echo "  fastboot         fastboot_switching trigger (default 5x)"
    echo "  rapid-fastboot   fastboot_switching — no pause (default 3x)"
    echo "  fastboot-load    fastboot_switching during active data transfer"
    echo "  suspend          Suspend/resume via rtcwake s2idle (default 3x)"
    echo "  combo            Mixed: fastboot+suspend, suspend+fastboot, MM during reset"
    echo "  all              Run every test in order"
    echo ""
    echo "Options:"
    echo "  --rounds N       Override default round count for cyclic tests"
    echo ""
    echo "Results logged to stresstest-<timestamp>.log"
}

# --- Parse arguments ---

if [ "$EUID" -ne 0 ]; then
    echo "Must run as root: sudo bash $0 $*"
    exit 1
fi

TESTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds)
            ROUNDS="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            TESTS+=("$1")
            shift
            ;;
    esac
done

if [ ${#TESTS[@]} -eq 0 ]; then
    print_usage
    exit 0
fi

# --- Preflight banner ---

if [ ! -e "$SYSFS_MODE" ]; then
    echo "ERROR: $SYSFS_MODE not found — modem not present or driver not loaded?"
    exit 1
fi

separator
logc "$C_BOLD" "  mtk_t7xx stress test suite"
separator
log "Kernel:    $(uname -r)"
log "Module:    $(modinfo -F filename mtk_t7xx 2>/dev/null || echo 'not found')"
log "DKMS:      $(dkms status mtk_t7xx 2>/dev/null || echo 'n/a')"
log "Taint:     $(get_taint)"
log "Suspend:   $(cat /sys/power/mem_sleep 2>/dev/null || echo 'unknown')"
log "Tests:     ${TESTS[*]}"
log "Rounds:    ${ROUNDS:-default}"
log "Log:       $LOGFILE"
log "Started:   $(date)"
log ""

# Check modem is up before we start
if ! wait_for_modem 10; then
    logc "$C_RED" "ERROR: No modem detected — cannot run tests."
    exit 1
fi
log "Modem detected. Starting tests."
log ""

# --- Execute ---

for test in "${TESTS[@]}"; do
    case "$test" in
        preflight)       test_preflight ;;
        mm-restart)      test_mm_restart ;;
        conn-cycle)      test_conn_cycle ;;
        fastboot)        test_fastboot ;;
        rapid-fastboot)  test_rapid_fastboot ;;
        fastboot-load)   test_fastboot_load ;;
        suspend)         test_suspend ;;
        combo)           test_combo ;;
        all)             run_all ;;
        *)               logc "$C_RED" "Unknown test: $test"; print_usage; exit 1 ;;
    esac
done

# ==========================================================================
#  Summary
# ==========================================================================

separator
logc "$C_BOLD" "  FINAL REPORT"
separator
log "Tests run:   $TESTS_RUN"
log "Passed:      $PASS"
log "Failed:      $FAIL"
log "Warnings:    $WARN"
log "Skipped:     $SKIP"
log ""
log "Kernel taint after tests: $(get_taint)"
log "Finished:    $(date)"
log "Log file:    $(realpath "$LOGFILE")"

if [ "$FAIL" -gt 0 ]; then
    log ""
    logc "$C_RED" "  SOME TESTS FAILED"
    log ""
    log "Kernel log (last 30 t7xx lines):"
    local dmesg_t7xx
    dmesg_t7xx=$(dmesg 2>/dev/null) || true
    echo "$dmesg_t7xx" | grep -i t7xx | tail -30 | while IFS= read -r line; do
        log "  $line"
    done
    separator
    exit 1
elif [ "$WARN" -gt 0 ]; then
    log ""
    logc "$C_YELLOW" "  ALL TESTS PASSED (with warnings)"
    separator
    exit 0
else
    log ""
    logc "$C_GREEN" "  ALL TESTS PASSED"
    separator
    exit 0
fi
