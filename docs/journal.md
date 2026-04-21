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
