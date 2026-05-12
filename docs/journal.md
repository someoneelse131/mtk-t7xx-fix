# mtk_t7xx_fix — Engineering Journal

Reverse-chronological log of what was broken, what was done, and why.
New entries at the top. For line-level details see `git log` / commit
messages; this journal exists so a reader (human or future AI session)
can catch up on context without re-reading each commit.

Standard entry layout:

- **Date & version** (if bumped)
- **Symptom** — what the user saw
- **Hergang** — what actually happened, reconstructed from logs
- **Root cause** — why it happened
- **Fix** — what changed, with commit reference
- **Verification** — what evidence proves the fix works

Hardware baseline for every entry: ThinkPad X1 Carbon Gen 11,
Fibocom FM350-GL (`14c3:4d75`), Fedora 43, kernel 6.18.x,
systemd 258.x, `iommu=pt` in kernel cmdline. Sleep behaviour is
suspend-then-hibernate on lid-close (KDE + logind drop-in).

---

## 2026-05-05 — Always-PLDR on `.restore` (Option B, v1.2.0)

**Symptom.** After STH cycles that fully transition to S4, the
post-resume `mtk_t7xx` plain-reprobe path sometimes leaves the modem
in a state where the MD handshake reports success
(`md_pm_state=MTK_PM_RESUMED`, `mode=T7XX_READY`, `init_done`
signalled) but every MBIM transaction times out. ModemManager hits
`transaction_timed_out`, SIGABRTs, respawns ~36 s later, crashes the
same way, repeats until reboot. WiFi etc. fine — only mobile data.

**Hergang (Boot -1, 2026-05-05).** STH cycle 3 transitioned to S4 at
07:51:23. S4 wake at 08:01:38 (10 min in S4) → `atr=0x7f`, plain
reprobe path. Driver logs the smoking-gun
`mtk_t7xx 0000:08:00.0: CLDMA1 queue 0 is not empty`. NO subsequent
`[PM] Resume: handshake path` ever appears. From 08:02:59 onward MM
SIGABRTs every ~36 s (8 crashes total) until user issued a clean
`systemctl shutdown` at 08:07:50. Same crash signature already seen
on 2026-05-02 (8 SIGABRTs after 5h21m S4) and 2026-05-04 (1 SIGABRT
at end of boot -2).

**Root cause.** The HS1/HS2 handshake uses MHCCIF (register-based
interrupts), not CLDMA. So the handshake completes cleanly while the
driver's in-memory CLDMA ring SW state (`tx_next`, `tr_done`,
pending GPDs) is whatever was restored from the hibernate image —
stale relative to the firmware's hardware queue pointers, which are
fresh from cold boot. `t7xx_cldma_txq_empty_hndl` in
`src/t7xx_hif_cldma.c` reads `REG_CLDMA_UL_CURRENT_ADDRL_0`,
compares to the GPD it expects to be "current", and bails when they
disagree — that's the `CLDMA1 queue 0 is not empty` warning. After
that point every TX/RX is desynchronised. Race / timing, not a
duration threshold (16 h S4 worked, 10 min S4 failed in the same
week).

**Why a `md_pm_state` watchdog (Option A) was rejected.** The
handshake completes via MHCCIF and `md_pm_state` reaches
`MTK_PM_RESUMED` even when CLDMA is broken, so a
"watch pm_state, escalate if stuck" watchdog never fires. To catch
this it would need CLDMA-level health probing — nearly as complex
as the deeper fix and still has corner cases.

**Fix.** Force a chip-level PLDR on every `.restore`. PLDR runs
ACPI `MRST._RST` which resets the firmware AND the subsequent
`t7xx_pci_reprobe(boot=true)` rebuilds CLDMA SW state from scratch,
so hardware and SW agree. Scoped to `.restore` only — `.resume`,
`.thaw`, `.runtime_resume` keep their existing fast plain-reprobe
behavior. Safe in `.restore` because `pm_suspend_target_state ==
PM_SUSPEND_ON` (we're past `hibernation_exit`), so the April-16
NVMe-wedge scenario that 5305cb5 was protecting against does not
apply.

`t7xx_pci_pm_restore` now:

1. `cancel_delayed_work_sync(&deferred_pldr_work)` at top — every
   other PM entry already does this; `.restore` was the only
   omission.
2. Bumps `md_pm_state` from `≤MTK_PM_INIT` to `MTK_PM_SUSPENDED`
   (preserved from previous behavior, harmless before PLDR).
3. Caps at `MAX_RESUME_REPROBE_ATTEMPTS = 3` — counts attempts,
   gives up after 3, `complete_all(&init_done)` so
   `.prepare` doesn't block 20 s and trigger the
   suspend-retry loop (the e22d499 / April-9 regression).
4. `t7xx_reset_device(t7xx_dev, PLDR)`. On failure same
   `complete_all(&init_done)` unblock so suspend can still proceed
   with a dead modem.
5. Counter zeroed only on success — same convention as
   `t7xx_deferred_pldr_worker`.

**Trade-off.** ~5–10 s extra latency on every hibernate-resume
(PLDR is just an ACPI call + reprobe), on top of the existing
35 s post-resume MM-restart delay the user already sees. Acceptable
in exchange for catching every CLDMA-ring-desync incident.

**Verification.** Build clean against kernel 6.19.14 out-of-tree.
Runtime verification by user across multiple S4 cycles (2026-05-05
through 2026-05-12): every post-S4 resume now recovers mobile data
without modem death. Notable observations:

- `[PM] Restore: forcing PLDR (attempt 1/3)` appears once per S4 wake
- No `CLDMA1 queue 0 is not empty` warnings anymore
- No ModemManager SIGABRT loops after S4 resume
- Time-to-mobile-data after S4 is noticeably longer than after plain
  s2idle wake (PLDR + full reprobe + post-resume MM-restart timer
  stack up) — known cost of the always-PLDR policy; future work to
  consider tightening the post-resume MM-restart delay on the
  `.restore` path specifically.

Declared stable as **v1.2.0** on 2026-05-12.

Full root-cause investigation in
`docs/superpowers/2026-05-05-investigation.md` (parallel agent
review producing the reviewed code sketch this commit applied).

---

## 2026-04-28 — `keepalive_s2idle` option for fast s2idle wake (lands in v1.2.0)

**Symptom (none — feature, not bug).** After every lid-open the user
waits 45–66 s before mobile data is back. Profile of three consecutive
s2idle cycles (Boot 0, 16:33 / 16:49 / 17:00):

| Δt from suspend exit | Event |
|---|---|
| +0 s  | `PM: suspend exit` |
| +3 s  | `Deferred PLDR: running now, attempt 1/3` |
| +5 s  | `PM configuration timed out — continuing without full PM support` |
| +19 s | `PORT_ENUM already pending after reprobe` |
| +25–30 s | repeated `Packet drop on channel 0x1004 / 0x1012, port not found` |
| +35 s | `99-modem-fix.sh` timer fires, `systemctl restart ModemManager` |
| +45–66 s | `[modem0] simple connect started` |

So the **kernel-side** PLDR + port-reprobe burns ~25 s every wake even
though the modem firmware was perfectly fine before suspend, and the
**hook delay** adds another 10 s of slack on top.

**Hergang.** Lid-close on this hardware is always
suspend-then-hibernate (KDE + logind drop-in, `HibernateDelaySec=10min`).
For the common case where the user reopens the lid within those 10 min
the system never reaches hibernate — it only did s2idle. Yet the driver
still ran a full firmware-suspend handshake on the way in
(`H2D_CH_SUSPEND_REQ`), and on resume the firmware came back in L3/INIT
and triggered the deferred-PLDR path — even though no real reset was
needed, the firmware had simply been running normally the whole time.

**Root cause.** Two compounding issues:

1. The driver suspends the modem firmware on every s2idle entry even
   though `t7xx_pci_pm_suspend_noirq` already keeps the PCIe device in
   D0 (the firmware "cannot survive D3hot or D3cold" per the existing
   comment). The full handshake is only required when the firmware is
   actually about to lose power — i.e. hibernate.
2. The sleep hook waits a worst-case 35 s before restarting MM, so even
   if the kernel side got faster the user would still wait.

**Fix.** New module parameter `keepalive_s2idle` (default off):

- `t7xx_pci_pm_suspend()` early-returns 0 when both
  `keepalive_s2idle=Y` *and* `pm_suspend_target_state == PM_SUSPEND_TO_IDLE`.
  Hibernate (`.freeze`) sees `pm_suspend_target_state == PM_SUSPEND_ON`
  and falls through to the full handshake — firmware loses power across
  S4 regardless, so this is mandatory.
- A `suspend_skipped` flag on `t7xx_pci_dev` lets `t7xx_pci_pm_resume`
  and `t7xx_pci_pm_resume_noirq` short-circuit symmetrically (no MSI-X
  toggling, no body work). Modem stayed online → nothing to recover.
- `99-modem-fix.sh` greps the kernel log for the driver's
  `keepalive_s2idle: skipping firmware suspend` banner in the last 30 s.
  When seen, the post-resume MM-restart delay drops from 35 s to 3 s
  (modem is registered, MBIM endpoint live; MM only needs to reopen
  its session). Without the banner — i.e. real hibernate resume or
  keepalive disabled — the original 35 s delay applies.

The `pre/STH` MM-stop is unconditional even with keepalive: an STH
cycle may still transition to actual hibernate, in which case the
freeze callback runs the full handshake and we want MM out of the way
to avoid the libmbim transaction-timeout SIGABRT (the 09:36 / 09:37
incidents from 2026-04-17).

**Reinstall opt-in.** `reinstall.sh` now prompts (or accepts
`--keepalive` / `--no-keepalive`). The choice is persisted via
`/etc/modprobe.d/mtk-t7xx-keepalive.conf`. Re-running the installer
defaults to whatever was previously chosen, so the prompt is
idempotent.

**Trade-off.** Keepalive costs ~100 mW idle (≈0.03 % of the ~57 Wh
battery per 10 min lid-closed) for a ~40 s reduction in resume
latency. Hibernate behaviour is identical in both modes — firmware is
power-cycled across S4 regardless.

**Risks to watch in early use.**

1. Modem firmware potentially wedging if it sits idle for the full
   10 min s2idle window without IRQ servicing. Frozen userspace can't
   poll, but the firmware itself keeps running — buffer pressure
   should be near zero on an idle data session.
2. PCIe ASPM stays in its normal-runtime state instead of being
   toggled via `DISABLE_ASPM_LOWPWR` around the suspend handshake. The
   skip path doesn't touch ASPM at all, which matches the
   "running normally" baseline.
3. MBIM session is held by the modem's own firmware across s2idle —
   if it disagrees with MM's view after wake, MM will reopen on its
   3 s scheduled restart anyway.

**Verification plan.** Manual cycles before any further work:

- `modprobe -r mtk_t7xx && modprobe mtk_t7xx keepalive_s2idle=1`
- Lid close 30 s, lid open → confirm `mmcli -m 0` answers immediately
  and `journalctl -k -b` shows `keepalive_s2idle: skipping firmware suspend`
- Lid close 5 min, lid open → same
- Lid close 9 min (just under STH transition), lid open → same
- Lid close >10 min so STH actually hibernates → confirm full PLDR
  path runs as before, MM restart at 35 s

---

## 2026-04-21 — Deferred PLDR actually runs (v1.1.3)

**Symptom.** User noticed "mobile data geht nicht mehr" during a work
session. Did a reboot to recover, wasn't sure afterwards whether the
system would have self-recovered or whether the reboot was actually
needed. Same pattern as previous weeks: each fix seemed to reveal a
new edge case, "drehen uns im Kreis".

**Hergang (reconstructed from Boot -1, 2026-04-21 06:15 → 07:38).**

| Time | Event |
|---|---|
| 06:16:06 | Mobile data up after cold boot (IP 10.57.125.89), user working |
| 06:54:47 | Lid close → STH; modem-fix stops MM; system enters s2idle |
| 07:02:54 | Wake from s2idle (8 min nap, before hibernate delay). Kernel: `[PM] Resume: L3/INIT + link up during system sleep (target=1), deferring PLDR reset` |
| 07:03:35 | `modem-fix` 35 s timer fires, restarts MM |
| 07:03:38 | Every port write returns `-5 EIO`: `Failed to send skb`, `Write error on AT port`, `Write error on MBIM port`. Modem is dead. |
| 07:04:23 | MM gives up: `Failed to find primary AT port`. Modem not registered. |
| 07:04:23 – 07:33:35 | ~30 min of dead mobile data, no further probe attempts. |
| 07:33:35 | User connects to WiFi (wlp0s20f3 DHCP 10.206.250.121) — fell back to WiFi because mobile data was broken. |
| 07:38:46 | User clicks KDE "Herunterfahren" → clean poweroff at 07:38:53. |
| 07:57:43 | Cold power-on. Modem chip reset by power cycle; mobile data works again from Boot 0. |

So: **user rebooted, system did not self-recover. The reboot was actually
needed.** The 19-minute gap between shutdown and next boot confirms a full
cold power cycle (not a warm reboot) — and only cold power reset the modem
chip.

**Root cause.** commit `5305cb5` (2026-04-17) introduced a branch in
`__t7xx_pci_pm_resume` (src/t7xx_pci.c:640) that detects "L3/INIT +
PCIe link still up + `pm_suspend_target_state != PM_SUSPEND_ON`" and
defers the PLDR reset to avoid wedging NVMe during hibernate entry.
The branch's comment claimed "the next resume after the full system
wake will find `pm_suspend_target_state == PM_SUSPEND_ON` again and
run PLDR normally" — that assumption holds **only** when STH
continues into hibernate (then `.restore` runs the normal L3/INIT
reprobe). For the s2idle-wake-to-fully-awake path (user wakes before
hibernate delay), no further `.resume` callback ever fires. The
"defer" becomes "abandon". Modem stays in L3/INIT, MBIM/AT EIO on
every write, MM gives up, modem is dead until cold power cycle.

**Fix.** One `struct delayed_work deferred_pldr_work` in the driver.

- `src/t7xx_pci.h`: add `workqueue.h` include + field in `t7xx_pci_dev`
- `src/t7xx_pci.c`: add `t7xx_deferred_pldr_worker()`. When the defer
  branch fires, it schedules the worker with a 3 s initial delay.
  The worker:
  - rechecks `pm_suspend_target_state` (reschedules in 2 s if system
    re-entered sleep → preserves the NVMe-wedge guarantee of 5305cb5)
  - bails if another resume already recovered the modem
  - takes a `pm_runtime_get_sync` ref (PLDR on a runtime-suspended
    device is undefined — config-space PM mismatch)
  - bails if PCIe link dropped since defer (delegates to normal
    resume path, which handles `atr == 0x7f` cleanly)
  - respects `MAX_RESUME_REPROBE_ATTEMPTS`, zeros on success
  - `complete_all(&init_done)` on terminal failure so the next
    `.prepare`'s 20 s wait doesn't stall
- **Cancellation sites (5)**: `.prepare`, `__t7xx_pci_pm_resume`,
  `__t7xx_pci_pm_suspend`, `.shutdown`, `.remove`. `.suspend`/`.freeze`/
  `.poweroff`/`.runtime_suspend` all route through
  `__t7xx_pci_pm_suspend` (verified via `dev_pm_ops` at line 914).
  `.thaw`/`.restore`/`.runtime_resume` route through
  `__t7xx_pci_pm_resume`. Uses `cancel_delayed_work_sync` — worker
  holds no lock any caller holds; bounded wait ≤ `T7XX_INIT_TIMEOUT`
  (20 s), well under systemd's 45 s ceiling.

Also bumped in the same release:

- `ModemManager` `TimeoutStopSec` 5 s → 10 s. Every single
  `stop-sigterm timed out` event since April fires at exactly
  T+5.000 s — systemd-timeout-driven, not MM's natural completion.
  10 s gives libmbim more headroom for in-flight transactions; still
  35 s below the original 45 s shutdown-hang threshold. If 10 s turns
  out to still be too tight, bump further in a follow-up (downside is
  just the same SIGABRT log, no functional impact).
- `reinstall.sh -y / --yes` flag — skips both interactive prompts
  (iommu=pt warning + reboot confirmation). Flag is forwarded
  through the sudo re-exec, so `bash reinstall.sh -y` works
  end-to-end. Reason: user does installs themselves (Claude Code
  cannot sudo) and wants them scriptable.

**Verification.** Plan was written per the superpowers `writing-plans`
skill and reviewed by two parallel verification agents:

- Round 1: driver-code agent found 6 real issues (missing
  `pm_runtime_get_sync`, missing counter reset on success, missing
  `.prepare` cancel, include hygiene, etc.). Log-pattern agent
  approved with 1 non-blocking note (MM SIGABRT, addressed in
  Task 6).
- Round 2 (after revision): both agents **APPROVE**, no new issues.

Commits: `43de8f0` (driver), `537a7f0` (installer + version),
`6c57398` (plan doc at `docs/superpowers/plans/2026-04-21-deferred-pldr-followup.md`).

**Post-install test plan for user:** trigger STH, wake from s2idle
before the hibernate delay, then check
`journalctl -b -k | grep 'Deferred PLDR'` — should see
`running now, attempt 1/3` followed by the usual `handshake path`
recovery sequence. Mobile data should be back within ~10 s of wake,
not dead until reboot.

---

## 2026-04-18 — Shutdown hang on poweroff (22bf201)

**Symptom.** Poweroff/reboot occasionally stalled silently for minutes
(empty pstore), eventually required hard reset.

**Root cause.** `t7xx_pci_shutdown()` unconditionally ran the full PM
handshake. If the modem's SAP side was desynchronised, the handshake
waited forever on a half-dead modem inside `device_shutdown()` —
observed 2026-04-18 00:28.

**Fix.** Force `mode = T7XX_UNKNOWN` in `t7xx_pci_shutdown` when
`system_state ∈ {POWER_OFF, RESTART, HALT}`. This makes
`__t7xx_pci_pm_suspend` take its "modem not ready, skipping PM
handshake" early-return, and `t7xx_md_exit` skips `FSM_CMD_PRE_STOP`.
Only local cleanup (CLDMA stop with 1 s poll, port-proxy uninit,
kthread_stop) runs — no modem-side I/O. Mirrors the defer-approach
of `5305cb5`.

**Verification.** Today's clean 07:38:53 poweroff reached
`systemd-poweroff.service` / `Reached target poweroff.target`
without hangs.

---

## 2026-04-17 — Two hibernate-resume fixes (5305cb5, 8f7fc91)

**5305cb5 — Defer PLDR during system sleep.**
The hibernate entry path was wedging NVMe I/O indefinitely after
"hibernation entry" (observed 2026-04-16 21:29, machine stayed at
full power until battery drained, hard reset). Root cause: PLDR
(ACPI `MRST._RST`) pulls the PCIe root complex transiently; running
it from `.resume` while the kernel is already proceeding to
hibernate() / sync_filesystems_hibernate() collides. Fix: when the
L3/INIT branch fires and `pm_suspend_target_state != PM_SUSPEND_ON`,
set `mode = T7XX_UNKNOWN` and return without reset. **(NB: this fix
itself caused the bug fixed on 2026-04-21 — see above.)**

**8f7fc91 — Preserve user session on hibernate resume.**
SDDM sleep hook was unconditionally restarting SDDM on
`post/hibernate`, creating a duplicate user Plasma session that
fought the existing one over DRM master (blackscreen + mouse after
password, hard reset required, observed 2026-04-17 09:36). Fix:
sleep hook now detects a healthy user Wayland session (live
`kwin_wayland`) and leaves SDDM stopped in that case; only restarts
SDDM if no user session survived. Also proactively calls
`loginctl lock-session` on all user Wayland sessions before
hibernate.

---

## 2026-04-16 — L1 PM thrashing + init_done completion (af09618, e22d499)

**af09618.** Autosuspend delay raised from 2 s to 15 s to stop
runtime-PM churn during light mobile traffic (every small packet was
triggering a full suspend/resume round).

**e22d499.** On reprobe failure, `init_done` completion was left
reset, which made every subsequent `.prepare` block 20 s and return
`-EBUSY`, triggering a systemd suspend-retry loop that eventually
froze the machine (observed April 9, hard reset required). Fix:
`complete_all(&init_done)` on the failed-reprobe exit so pm_prepare
unblocks and the system can still sleep even with a dead modem.

---

## 2026-04-13 — s2idle-only wake MBIM restart (3e7d6ce)

Sleep hook was only restarting MM after hibernate legs, not after
s2idle-only wakes. But MM's MBIM session went stale even across pure
s2idle (handle still valid from MM's POV, but the kernel's
wwan0mbim0 state had been reset). Result: MM looped
"Operation aborted" forever. Fix: restart MM after every
`post/suspend` event, not only `post/hibernate`. Delay differs:
3 s for post/suspend (light), 35 s for post/hibernate (covers
mtk_t7xx reprobe window).

---

## 2026-04-12 — Dead modem on L3/INIT with PCIe link up (2802798)

Root of the whole PLDR chain. When the modem firmware reboots during
s2idle, the driver sees `prev_state == L3/INIT` but the PCIe link
stays up (atr != 0x7f). A plain pcie_reinit doesn't reset firmware —
ACPI `MRST._RST` (PLDR) is the only recovery path. Added the
`t7xx_reset_device(PLDR)` call on the "link up" branch of the
L3/INIT resume handler.

---

## 2026-04-08 — Reprobe loop cap + suspend block (e7b9ba3)

After a failed reprobe, the driver's retry logic would keep
reprobing indefinitely on every resume, and meanwhile suspend was
unblocked — leading to a reprobe/suspend-loop that eventually
corrupted memory and GP-faulted. Fix: cap `resume_reprobe_count` at
`MAX_RESUME_REPROBE_ATTEMPTS = 3`; block suspend via init_done until
reprobe completes; on giving up, explicitly complete init_done so
suspend can proceed (paired with e22d499).

---

## 2026-03-17 / 2026-03-24 — Hibernate resume race (54a9fea, 0120b2a)

Two separate sleep-hook race issues across two weekends.
Documentation-only at this level — the mechanics are in the commit
messages; both were addressed by migrating the sleep hook from
background subshells to `systemd-run --on-active` timers (cleaner
cancellation semantics), plus `.restore` bumping `md_pm_state` from
stuck `INIT` to `SUSPENDED` so `__t7xx_pci_pm_resume` actually
re-reads the hardware registers instead of short-circuiting.

---

## 2026-03-11 — Suspend loop after reprobe (f32f75c)

`reinit_completion(&init_done)` was missing in `t7xx_pci_pm_reinit`,
so a second suspend right after a reprobe found init_done already
signalled and skipped the wait. Fix: re-init the completion on every
reprobe round.

---

## 2026-03-02 to 2026-03-09 — Stable run + SAP reprobe regression

**c52a9aa (03-02).** Shutdown hang fixed by stopping the TX thread
in `t7xx_pci_shutdown` (pre-cursor to 22bf201).

**70ed722 (03-06).** Dead-modem-after-sleep fix via reprobe on SAP
resume timeout.

**6835c5a (03-09).** Above reprobe fix regressed normal L1/L2
resumes (rfkill-blocked modem, etc.) into infinite reprobe — capped
to "only when modem actually rebooted" (`prev_state == INIT`).

---

## 2026-02-25 to 2026-02-28 — Foundational fixes (pre-1.0)

- `1bee2e8` — modem dying after s2idle (original sleep-hook)
- `6518469` — NULL `port->thread` on `kthread_run` failure
- `a674ea1` — sleep hook uses `systemd-run` instead of background
  subshell
- `fd7c5d0` — SELinux restorecon for sleep hook
- `be86ac0` — stress test suite added
- Multiple README / install-script polish commits

For exhaustive details pre-March, see `git log --reverse`. The base
of the project (`3f74ab9`, 2026-02-16) covered the original nine
issues enumerated in README.md.

---

## Template for future entries

```
## YYYY-MM-DD — Short title (vX.Y.Z if bumped)

**Symptom.** What the user observed.

**Hergang.** Timeline from logs.

**Root cause.** Why it happened.

**Fix.** What changed, with commit ref.

**Verification.** Evidence.
```
