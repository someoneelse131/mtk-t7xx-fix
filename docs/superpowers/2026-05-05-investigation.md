# 2026-05-05 STH-Hibernate-Resume Failure — Investigation Notes

Context-snapshot dump so the next session can pick up cold.
Written 2026-05-05 ~10:30 CEST.

## TL;DR

After STH cycles that fully transition to S4, the post-resume `mtk_t7xx`
plain-reprobe path (taken when `atr=0x7f`) sometimes leaves the modem in
a state where:

- MD handshake (HS1/HS2 via MHCCIF) **completes successfully**
- `md_pm_state` reaches `MTK_PM_RESUMED`, `mode` reaches `T7XX_READY`
- `init_done` is signalled, ports are attached
- BUT every CLDMA TX/RX is broken because the driver's in-memory ring
  pointers (`tx_next`, `tr_done`) and pending GPDs were restored from the
  hibernate snapshot, while the firmware's hardware queue pointers are
  fresh from cold boot. They never converge.

Symptom: ModemManager hits `transaction_timed_out` from libmbim, SIGABRT,
respawns ~every 36 s, all crash the same way, until reboot. WiFi etc.
work fine — only mobile data is dead.

## What happened this morning (Boot -1, 2026-05-05)

```
06:13:08  cold boot, modem connects 06:13:33
06:14:22  Lid close → STH cycle 1 (s2idle prelude)
06:22:26  s2idle wake (8 min, BEFORE STH transition) → keepalive_skip → 3s MM restart → OK
06:51:58  Lid close → STH cycle 2
07:01:58  s2idle wake (10 min)
07:01:59  STH transitions to actual S4 hibernate (entry)
07:03:38  S4 wake (1 min 39 s in S4) → atr=0x7f, plain reprobe → 35s MM restart → OK
          07:04:17 [PM] Resume: handshake path (runtime PM = modem responsive)
07:41:22  Lid close → STH cycle 3
07:51:23  s2idle wake (10 min) → keepalive_skip → STH transitions
07:51:23  Hibernation entry
08:01:38  S4 wake (10 min 15 s in S4) → atr=0x7f, plain reprobe
          ⚠️ mtk_t7xx 0000:08:00.0: CLDMA1 queue 0 is not empty
          NO subsequent [PM] Resume: handshake path log ever appears
08:02:43  MM started (timer fired at +65s, not 35s, due to load post-resume)
08:02:59  wwan0at0 timed out 2 consecutive times
08:03:02  ModemManager SIGABRT (libmbim transaction_timed_out)
08:03:02  → 08:07:14: 8 more MM crashes, each ~36s after previous restart
08:07:50  User shutdown via systemctl (CLEAN — Reached target reboot.target)
```

Boot 0 (current) started at 08:09:20, modem works fine again from cold.

The "force shutdown" the user described was actually a clean systemctl
shutdown — system was responsive throughout the 6-min window. Only mobile
data was dead. WiFi (`wlp0s20f3`), GUI, keyboard all worked.

## Root cause (Agent 1's analysis)

In `__t7xx_pci_pm_resume()` (src/t7xx_pci.c:826-834), when prev_state is
L3/INIT and atr_reg_val is 0x7f, the driver does:

1. `t7xx_pci_reprobe_early()` → `FSM_CMD_STOP` (synchronous) →
   `fsm_routine_stopped` → `t7xx_md_reset` → `t7xx_cldma_reset(...)`
2. `t7xx_pci_reprobe(boot=true)` → `t7xx_pcie_reinit` (PCIe + MHCCIF +
   pm_reinit) → `FSM_CMD_START` (async)
3. FSM eventually completes HS1/HS2, `t7xx_pci_pm_init_late()` flips
   `md_pm_state` to MTK_PM_RESUMED, `complete_all(&init_done)`

The handshake itself uses MHCCIF (register-based interrupt), NOT CLDMA.
So the handshake can complete cleanly while CLDMA is still broken.

Smoking gun: `t7xx_cldma_txq_empty_hndl` (src/t7xx_hif_cldma.c:298-332).
After detecting the EQ_STA edge bit, it reads
`REG_CLDMA_UL_CURRENT_ADDRL_0` from hardware and compares to the address
of the GPD it expects to be "current". When they disagree, it bails with
`CLDMA%d queue %d is not empty`. That's exactly what fires today at
08:01:38.

Why short S4 worked, long S4 failed: this is largely **race / timing**,
not a duration threshold. Agent 2's data shows 16h 44m S4 cycles that
worked and 10m S4 cycles that failed. The smoke is the CLDMA-queue-
not-empty warning — only fired once across 4 boots, exactly on the
failed cycle.

## Why Option A (md_pm_state watchdog) is NOT reliable enough

User pushed back on this and was right.

A watchdog that fires PLDR when `md_pm_state != MTK_PM_RESUMED` after
25 s misses today's failure mode entirely:

- Today, MD handshake DID complete via MHCCIF.
- `md_pm_state` reached MTK_PM_RESUMED.
- `mode` reached T7XX_READY.
- `init_done` was completed.
- Watchdog would say "all good, no escalation needed."
- But MBIM was still dead because CLDMA ring SW state was stale.

For Option A to catch today's case it would need a CLDMA-level health
check (e.g. observe the CLDMA-queue-not-empty warning, or attempt a
self-test transaction). That makes it nearly as complex as the
deeper fixes and still has corner cases.

**Conclusion: Option A is rejected.**

## Fix options ranked

### Option B — Always-PLDR on `.restore` (with Agent 3's corrections)

`t7xx_pci_pm_restore` calls `t7xx_reset_device(t7xx_dev, PLDR)`
unconditionally instead of delegating to `__t7xx_pci_pm_resume`. PLDR
runs ACPI MRST._RST which is a chip-level hardware reset; after that
the firmware boots fresh AND all CLDMA state is reset by the
subsequent `t7xx_pci_reprobe(boot=true)` path through MD init.

Required hardening (per Agent 3's review):
1. `cancel_delayed_work_sync(&deferred_pldr_work)` at top — every
   other PM entry already does this; .restore must too.
2. Honor `MAX_RESUME_REPROBE_ATTEMPTS=3` — count attempts, give up
   after 3, complete init_done so suspend can still proceed.
3. `complete_all(&init_done)` on PLDR failure so .prepare doesn't
   block 20 s and trigger systemd suspend-retry loop (the e22d499 /
   April-9 regression).

Concerns from other agents:
- Agent 4: upstream uses plain reprobe; commit 5305cb5 explicitly
  narrowed PLDR usage to avoid the April-16 NVMe-wedge deadlock. BUT
  that wedge was `.resume` during sleep transition. `.restore` runs
  AFTER hibernation_exit, with `pm_suspend_target_state == PM_SUSPEND_ON`
  — the wedge condition (running PLDR while kernel proceeds to
  hibernate()) does NOT apply.
- Agent 1: "PLDR adds ~25 s to every clean hibernate-restore" — this
  is overstated. PLDR is just an ACPI call + reprobe. Real-world cost
  is more like 5-10 s on top of the existing 35 s post-resume MM delay.
  The 35 s delay is the wall the user already sees.

**Reliability: HIGH.** PLDR is the Lenovo-blessed FM350-GL reset path;
the existing link-up branch (line 804-807) already uses it from
.resume contexts. Forcing it on .restore aligns with that.

**Latency cost: ~5-10 s on every hibernate-resume**, on top of the
35 s MM restart delay. Acceptable.

**Risk: LOW** with the three corrections.

### Option C — Reset CLDMA ring SW state in plain-reprobe path

In the L3/INIT + atr=0x7f branch, before `t7xx_pci_reprobe_early`,
explicitly reset the per-queue SW state: clear `tr_done`/`tx_next`,
walk GPD ring freeing skbs, clear `txq_active`/`rxq_active` masks,
reinit `req_wq`. The MD handshake then runs on a clean ring, hardware
and SW agree.

Pros:
- Keeps the fast path fast (no PLDR latency)
- Targeted at the actual root cause

Cons:
- Higher implementation risk (skb walk, double-free hazards, locking)
- Requires understanding `t7xx_cldma_reset` internals to know what
  ALREADY gets reset and what doesn't (Agent 1 says SW ring pointers
  don't, but that needs verification before code is written)
- Diverges further from upstream
- Won't catch other failure modes that aren't pure CLDMA ring desync

### Option D — Instrumentation first, then fix

Add `dev_info` logging for: CLDMA queue state on resume, mode/pm_state
transitions with timestamps, PORT_ENUM event counts. Wait for next
failure, get cleaner data, then choose B or C.

Pros: zero risk
Cons: user has to live through another failure

### Option E — MBIM-health watchdog (Option A++)

Like Option A but the watchdog observes CLDMA-queue-not-empty
warnings and/or attempts a self-test MBIM transaction. If unhealthy,
PLDR.

Pros: only PLDRs when truly broken
Cons: complex, MBIM self-test is non-trivial in kernel context, the
CLDMA-warning detection is brittle

## Recommendation

**Option B** with the three corrections from Agent 3. This is the
cleanest, most reliable answer:

- Catches every failure mode (CLDMA ring desync, FSM stuck, etc.)
- Bounded latency cost (~5-10 s extra on hibernate-resume)
- Bounded retry count (MAX_RESUME_REPROBE_ATTEMPTS)
- Reuses existing battle-tested `t7xx_reset_device(PLDR)` path
- Safe in `.restore` context (past hibernation_exit, no NVMe-wedge
  risk)
- The `.resume` / `.runtime_resume` paths keep the existing fast
  plain-reprobe — this change is scoped to S4 wakes only

Code sketch (Agent 3's reviewed version, ready to apply):

```c
static int t7xx_pci_pm_restore(struct device *dev)
{
    struct pci_dev *pdev = to_pci_dev(dev);
    struct t7xx_pci_dev *t7xx_dev = pci_get_drvdata(pdev);
    int ret;

    /* Match every other PM entry point (cf. lines 552, 718, 986, 1031). */
    cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

    if (atomic_read(&t7xx_dev->md_pm_state) <= MTK_PM_INIT)
        atomic_set(&t7xx_dev->md_pm_state, MTK_PM_SUSPENDED);

    if (t7xx_dev->resume_reprobe_count >= MAX_RESUME_REPROBE_ATTEMPTS) {
        dev_err(&pdev->dev,
                "[PM] Restore: modem dead after %u attempts, giving up\n",
                MAX_RESUME_REPROBE_ATTEMPTS);
        complete_all(&t7xx_dev->init_done);
        return 0;
    }
    t7xx_dev->resume_reprobe_count++;

    dev_info(&pdev->dev, "[PM] Restore: forcing PLDR (attempt %u/%u)\n",
             t7xx_dev->resume_reprobe_count, MAX_RESUME_REPROBE_ATTEMPTS);

    ret = t7xx_reset_device(t7xx_dev, PLDR);
    if (ret) {
        dev_err(&pdev->dev,
                "[PM] Restore: PLDR failed (%d), unblocking suspend path\n",
                ret);
        complete_all(&t7xx_dev->init_done);
        return ret;
    }
    t7xx_dev->resume_reprobe_count = 0;
    return 0;
}
```

(Note: counter increments BEFORE the call so failures cap correctly,
zeros only on success — same convention as the existing PLDR worker.)

## PM ops mapping (verified)

```
.prepare        = t7xx_pci_pm_prepare      // all sleep ops
.suspend        = t7xx_pci_pm_suspend      // S2I/S3 + freeze + poweroff
.suspend_noirq  = t7xx_pci_pm_suspend_noirq
.resume         = t7xx_pci_pm_resume       // S2I/S3 wake (keepalive aware)
.resume_noirq   = t7xx_pci_pm_resume_noirq
.freeze         = t7xx_pci_pm_suspend      // hibernate snapshot
.freeze_noirq   = t7xx_pci_pm_suspend_noirq
.thaw           = t7xx_pci_pm_thaw         // post-snapshot, system continues
                                           //  (state_check=false, skips L3/INIT branch)
.poweroff       = t7xx_pci_pm_suspend      // S4 write-to-disk leg
.poweroff_noirq = t7xx_pci_pm_suspend_noirq
.restore        = t7xx_pci_pm_restore      // S4 wake — THIS is where Option B changes
.restore_noirq  = t7xx_pci_pm_resume_noirq
.runtime_*      = autosuspend / autoresume
```

Option B only changes the .restore path. .thaw goes through `__t7xx_pci_pm_resume(state_check=false)`
which bypasses the L3/INIT branch entirely (line 729 `if (state_check)`).
.resume, .runtime_resume keep their existing fast plain-reprobe behavior.

## Edge cases the fix must handle

1. **Three failed restores in a row** → counter caps, init_done completed,
   suspend can still proceed (system can still sleep with dead modem).
2. **PLDR returns ACPI error** → init_done completed, error returned to
   PM core, .prepare doesn't deadlock.
3. **Stale deferred_pldr_work scheduled before freeze** → cancelled at
   top of .restore, no concurrent ACPI eval.
4. **First .restore after probe (md_pm_state == MTK_PM_INIT)** →
   bumped to MTK_PM_SUSPENDED before the reset (matches existing
   restore behavior).
5. **STH s2idle leg via .resume** → unchanged, keepalive_s2idle skip
   path still applies.
6. **Runtime-PM resume hits L3/INIT** → unchanged, plain reprobe path
   in `__t7xx_pci_pm_resume` retained.
7. **Hibernate while modem already dead (mode=UNKNOWN)** → counter
   may already be non-zero from a prior failure; cap protects us.
8. **Shutdown (.shutdown)** → unchanged, still skips PM handshake.

## Verification plan after applying Option B

User-side, after `bash reinstall.sh`:

```bash
# Force STH cycle that actually transitions to S4
sudo systemctl suspend-then-hibernate
# (wait 10+ min for HibernateDelaySec to fire, then power button or lid)

# After resume:
journalctl -k -b | grep -E '\[PM\] Restore|forcing PLDR|MRST|hibernation: hibernation'
# Expected: "[PM] Restore: forcing PLDR (attempt 1/3)" once per hibernate wake
# Expected: NO "CLDMA1 queue 0 is not empty" warnings
# Expected: mobile data back within ~40 s of wake

mmcli -m 0 | grep -E 'state|signal'
# Expected: state changed to connected within reasonable time
```

Repeat for: 2 min S4, 10 min S4, 1 h S4, 8 h S4. Each should succeed.

## Files / line refs to load next session

- `/home/kirby/projects/mtk_t7xx_fix/src/t7xx_pci.c`
  - `__t7xx_pci_pm_resume`: lines 705-947 (the L3/INIT branch is 734-835)
  - `t7xx_pci_pm_restore`: lines 1079-1099 (this is what Option B changes)
  - `t7xx_pci_pm_ops` table: lines 1111-1126
  - `t7xx_deferred_pldr_worker`: lines 243-339
  - `MAX_RESUME_REPROBE_ATTEMPTS`: line 59 (=3)
  - `out_reprobe_failed:` label: lines 933-946 (the init_done unblock)
- `/home/kirby/projects/mtk_t7xx_fix/src/t7xx_modem_ops.c`
  - `t7xx_reset_device`: lines 194-218 (PLDR machinery)
  - `t7xx_md_reset`: lines 708-720
- `/home/kirby/projects/mtk_t7xx_fix/src/t7xx_hif_cldma.c`
  - `t7xx_cldma_txq_empty_hndl`: lines 298-332 (smoking gun warning)
- `/home/kirby/projects/mtk_t7xx_fix/docs/journal.md` (history of all fixes)
- `/home/kirby/projects/mtk_t7xx_fix/reinstall.sh` (lines 217-315 are the
  sleep hook; no change needed for Option B)

## Recurrence check

Same crash signature observed in earlier boots:
- 2026-05-02 20:21:46 → 20:25:58 after 5h21m S4 — 8 SIGABRTs, same stack
- 2026-05-04 22:39:48 — 1 SIGABRT at end of boot -2

So Option B isn't speculative — it would have prevented at least three
distinct user-visible incidents in the last 4 days.

## What was NOT the cause (ruled out)

- Not `keepalive_s2idle=Y` per se. Cycle 2 also had keepalive skip and
  worked. Same modprobe.d config.
- Not the MM 35 s post-resume restart delay being too short. Even at
  35 s + 65 s = 100 s post-wake, MBIM transactions still timed out.
  The modem firmware itself was unable to respond — more delay won't
  help.
- Not S4 duration threshold (16 h S4 worked, 10 min failed). It's a
  state-race, not a timer.
- Not a system freeze. System was healthy except for modem path.
- Not the modem firmware being "dead" in the literal sense. It accepted
  CLDMA writes; only responses didn't come back, consistent with the
  ring-pointer desync hypothesis.

## What I still don't know

- Exactly what `t7xx_cldma_reset` resets and what it doesn't. If it
  fully clears `tx_next`/`tr_done`, the plain-reprobe path SHOULD
  work, and the failure must be elsewhere. Reading t7xx_hif_cldma.c
  in detail would settle this. (Did not do this yet — Option B
  works regardless of this answer.)
- Why Lenovo's BIOS sometimes leaves the modem in a state where
  plain reprobe insufficient (likely platform-specific quirk that
  PLDR sidesteps).
- Whether Option C alone (CLDMA SW state reset) without PLDR would
  also fix it. Untested.
