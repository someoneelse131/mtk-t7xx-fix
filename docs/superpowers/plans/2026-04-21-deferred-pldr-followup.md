# Deferred PLDR Follow-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the dead-modem-after-s2idle-wake bug by guaranteeing that a deferred PLDR reset actually runs, instead of being silently abandoned when the system does not continue into hibernate.

**Architecture:** Add one `struct delayed_work` to the driver. When the resume path decides to defer PLDR (because running it mid-suspend would wedge NVMe), it schedules the work. The worker re-checks system state and either executes PLDR or reschedules itself until the system is stably awake. Every resume and suspend callback cancels any pending work before it re-evaluates state, so a normal recovery path supersedes a pending deferred reset without racing.

**Tech Stack:** Linux kernel module (out-of-tree DKMS), C. Existing infrastructure in `t7xx_pci.c`: `t7xx_reset_device()`, `struct t7xx_pci_dev`, `MAX_RESUME_REPROBE_ATTEMPTS`, `pm_suspend_target_state`.

---

## Root-cause summary (for reviewer context)

Commit `5305cb5` (Fix hibernate hang: defer PLDR reset during system sleep) introduced a branch in `__t7xx_pci_pm_resume` at `src/t7xx_pci.c:640-647`:

```c
if (atr_reg_val != 0x0000007f &&
    pm_suspend_target_state != PM_SUSPEND_ON) {
    dev_warn(&pdev->dev,
             "[PM] Resume: L3/INIT + link up during system sleep (target=%d), deferring PLDR reset\n",
             pm_suspend_target_state);
    t7xx_mode_update(t7xx_dev, T7XX_UNKNOWN);
    return 0;
}
```

The branch's comment claims:

> The next resume after the full system wake will find `pm_suspend_target_state == PM_SUSPEND_ON` again and run PLDR normally.

This is true **only if** the STH cycle continues into a real hibernate leg (then `.restore` triggers the normal L3/INIT reprobe). If the user wakes the machine from s2idle *before* hibernate timeout, no further resume callback ever fires — the deferred reset is abandoned and the modem stays dead until cold power-cycle.

Observed today, Boot 1: 07:02:54 defer → 07:03:38 MM restart → EIO on every port write → 07:04:23 MM gave up → 55 min of dead mobile data until user rebooted at 07:38.

---

## File structure

| File | Responsibility |
|---|---|
| `src/t7xx_pci.h` | Add `struct delayed_work deferred_pldr_work` to `struct t7xx_pci_dev`. |
| `src/t7xx_pci.c` | Add worker function `t7xx_deferred_pldr_worker()`. Init/schedule/cancel it at 5 call sites. |
| `dkms.conf` | Bump `PACKAGE_VERSION` from `1.1.2` to `1.1.3`. |
| `reinstall.sh` | Bump `MODULE_VERSION` from `1.1.2` to `1.1.3`, raise `ModemManager` `TimeoutStopSec` from 5 to 10 (Task 6). |

No other files touched. No sleep-hook change in the .sh body. No driver-external state.

## Revision notes (post-review round 1)

This plan was reviewed by two parallel audit agents. Round-1 findings addressed in this revision:

- **Agent A (driver-code):** reset `resume_reprobe_count=0` on worker PLDR success (race with main path's zeroing at line 775); add `pm_runtime_get_sync`/`put` in worker (avoid PLDR on runtime-suspended device); add explicit `<linux/workqueue.h>` include in `.c`; cancel also in `.prepare` for earlier-than-suspend inhibit. Deadlock concern on `cancel_delayed_work_sync`: analyzed and discounted — the worker takes no lock that any cancel caller holds; the bounded wait (≤ `T7XX_INIT_TIMEOUT`s = 20s) is acceptable in a PM path where systemd already permits 45s.
- **Agent B (log-pattern):** approved. Uncovered: recurring MM SIGABRT on pre-hibernate stop (daily since Apr 01) — addressed by Task 6 as a sleep-hook timeout bump (separate, small, independent of the driver fix).

---

## Task 1: Add delayed_work field to t7xx_pci_dev

**Files:**
- Modify: `src/t7xx_pci.h:20-25` (add `workqueue.h` include)
- Modify: `src/t7xx_pci.h:74-99` (add field to struct)

- [ ] **Step 1: Add include**

At `src/t7xx_pci.h:20-25`, the existing include block is:

```c
#include <linux/completion.h>
#include <linux/irqreturn.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/spinlock.h>
#include <linux/types.h>
```

Add `workqueue.h`, keeping alphabetical order:

```c
#include <linux/completion.h>
#include <linux/irqreturn.h>
#include <linux/mutex.h>
#include <linux/pci.h>
#include <linux/spinlock.h>
#include <linux/types.h>
#include <linux/workqueue.h>
```

- [ ] **Step 2: Add field to struct t7xx_pci_dev**

In `src/t7xx_pci.h`, locate `struct t7xx_pci_dev { ... };` (currently ending at line 99). Add a new member just before the `mode` field on line 97, keeping the struct's existing grouping (the comment block "Low Power Items" is the natural home):

```c
	unsigned int		resume_reprobe_count;
	struct completion	sleep_lock_acquire;
	struct delayed_work	deferred_pldr_work;
```

And add a kerneldoc line to the struct's `/* struct t7xx_pci_dev ... */` header block (line 56 onward) so the field is documented alongside the others:

```
 * @deferred_pldr_work: worker that runs a deferred PLDR reset after resume
 *                     completes (covers the s2idle-wake path where no further
 *                     resume callback would otherwise occur)
```

- [ ] **Step 3: Compile-check the header**

Run:

```bash
cd /home/kirby/projects/mtk_t7xx_fix/src
make -C /lib/modules/$(uname -r)/build M=$PWD modules 2>&1 | head -40
```

Expected: compile proceeds past the header (errors at this point would be about `deferred_pldr_work` being referenced from nowhere, which is fine — we add references in later tasks). If you see a header-syntax error, fix it before moving on.

- [ ] **Step 4: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.h
git commit -m "t7xx: add deferred_pldr_work field to pci_dev struct

Prep for guaranteeing the deferred PLDR reset actually runs. No
functional change yet — the field is unused."
```

---

## Task 2: Implement the worker function

**Files:**
- Modify: `src/t7xx_pci.c` — add worker + constants above `t7xx_pci_pm_init` (line 228)

- [ ] **Step 1: Add explicit include and delay constants**

In `src/t7xx_pci.c`, the include block at lines 19-37 already lists `<linux/pm_runtime.h>` and `<linux/suspend.h>`. Add `<linux/workqueue.h>` explicitly (do not rely on transitive include per kernel style):

```c
#include <linux/suspend.h>
#include <linux/workqueue.h>
```

At the constants block around line 52-58 (just before `MAX_RESUME_REPROBE_ATTEMPTS`), append:

```c
#define MAX_RESUME_REPROBE_ATTEMPTS	3
#define DEFERRED_PLDR_DELAY_MS		3000
#define DEFERRED_PLDR_RETRY_MS		2000
```

Rationale (for commit message — do not write these as comments):
- 3000 ms initial delay — long enough for the kernel PM machinery to return to `PM_SUSPEND_ON` after s2idle wake (empirically ~100-500 ms on the target laptop, 3 s leaves generous headroom)
- 2000 ms retry delay — the worker fired too early (system still sleeping), wait and re-check

- [ ] **Step 2: Add the worker function**

Insert the worker function **above** `static int t7xx_pci_pm_init(...)` at line 228. The full function:

```c
static void t7xx_deferred_pldr_worker(struct work_struct *work)
{
	struct t7xx_pci_dev *t7xx_dev =
		container_of(to_delayed_work(work), struct t7xx_pci_dev,
			     deferred_pldr_work);
	struct pci_dev *pdev = t7xx_dev->pdev;
	u32 atr_reg_val;
	int ret;

	/* If the system re-entered suspend (STH → hibernate leg, or a
	 * fresh user-triggered suspend landed on top of our wake), defer
	 * again.  Running PLDR mid-suspend pulls ACPI MRST._RST and wedges
	 * the PCIe root complex, which is exactly the hazard 5305cb5
	 * was avoiding in the first place.
	 */
	if (pm_suspend_target_state != PM_SUSPEND_ON) {
		dev_info(&pdev->dev,
			 "[PM] Deferred PLDR: system sleeping (target=%d), rescheduling\n",
			 pm_suspend_target_state);
		schedule_delayed_work(&t7xx_dev->deferred_pldr_work,
				      msecs_to_jiffies(DEFERRED_PLDR_RETRY_MS));
		return;
	}

	/* If another resume path already recovered the modem (hibernate
	 * .restore, or a second user-suspend/resume round that took the
	 * reprobe branch), do not PLDR a working modem.
	 */
	if (READ_ONCE(t7xx_dev->mode) != T7XX_UNKNOWN) {
		dev_info(&pdev->dev,
			 "[PM] Deferred PLDR: mode already %u, skipping\n",
			 READ_ONCE(t7xx_dev->mode));
		return;
	}

	/* Take a runtime-PM reference before touching hardware.  Between
	 * the defer (modem in L3/INIT, mode=UNKNOWN) and this worker,
	 * runtime-PM may have decided to autosuspend the device.  PLDR on
	 * a runtime-suspended PCI device is undefined (config space PM
	 * mismatch).  pm_runtime_get_sync wakes the device if needed, and
	 * we release the ref after PLDR completes.
	 *
	 * Bail if we cannot acquire the ref — runtime-resume failure
	 * means the device is in a state where PLDR would make things
	 * worse.  Let the next system-resume callback deal with it.
	 */
	ret = pm_runtime_get_sync(&pdev->dev);
	if (ret < 0) {
		dev_warn(&pdev->dev,
			 "[PM] Deferred PLDR: pm_runtime_get_sync failed (%d), aborting\n",
			 ret);
		pm_runtime_put_noidle(&pdev->dev);
		complete_all(&t7xx_dev->init_done);
		return;
	}

	/* If the PCIe link dropped since the deferral (atr reads 0x7f),
	 * this is now the L3 "clean" path where a plain pcie_reinit would
	 * work.  Leaving it to the next resume callback keeps the retry
	 * accounting honest and avoids a needless PLDR.
	 */
	atr_reg_val = ioread32(IREG_BASE(t7xx_dev) +
			       ATR_PCIE_WIN0_T0_ATR_PARAM_SRC_ADDR);
	if (atr_reg_val == 0x0000007f) {
		dev_info(&pdev->dev,
			 "[PM] Deferred PLDR: link down since defer, leaving to resume path\n");
		pm_runtime_put(&pdev->dev);
		return;
	}

	if (t7xx_dev->resume_reprobe_count >= MAX_RESUME_REPROBE_ATTEMPTS) {
		dev_err(&pdev->dev,
			"[PM] Deferred PLDR: modem dead after %u attempts, giving up\n",
			MAX_RESUME_REPROBE_ATTEMPTS);
		complete_all(&t7xx_dev->init_done);
		pm_runtime_put(&pdev->dev);
		return;
	}

	t7xx_dev->resume_reprobe_count++;
	dev_info(&pdev->dev,
		 "[PM] Deferred PLDR: running now, attempt %u/%u\n",
		 t7xx_dev->resume_reprobe_count, MAX_RESUME_REPROBE_ATTEMPTS);

	ret = t7xx_reset_device(t7xx_dev, PLDR);
	if (ret) {
		dev_err(&pdev->dev,
			"[PM] Deferred PLDR failed: %d, unblocking suspend path\n",
			ret);
		complete_all(&t7xx_dev->init_done);
	} else {
		/* Mirror the zero-on-success convention of the main
		 * resume path at __t7xx_pci_pm_resume line 775.  Without
		 * this, a subsequent L3/INIT resume would see a stale
		 * non-zero count and prematurely hit the MAX cap.
		 */
		t7xx_dev->resume_reprobe_count = 0;
	}

	pm_runtime_put(&pdev->dev);
}
```

- [ ] **Step 3: Compile-check**

Run:

```bash
cd /home/kirby/projects/mtk_t7xx_fix/src
make -C /lib/modules/$(uname -r)/build M=$PWD modules 2>&1 | tail -20
```

Expected: module builds. If not, fix compile errors before moving on. The worker is not yet wired into any call site, so there may be an "unused function" warning — acceptable, clears in Task 3.

- [ ] **Step 4: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.c
git commit -m "t7xx: add deferred PLDR worker function

New worker that re-evaluates system state and executes the deferred
PLDR reset when the system is stably awake.  Not yet invoked by any
call site — next commit wires it in."
```

---

## Task 3: Init the work and schedule it from the defer branch

**Files:**
- Modify: `src/t7xx_pci.c:228-254` (`t7xx_pci_pm_init`)
- Modify: `src/t7xx_pci.c:640-647` (defer branch in `__t7xx_pci_pm_resume`)

- [ ] **Step 1: Init the work item in t7xx_pci_pm_init**

In `src/t7xx_pci.c`, `t7xx_pci_pm_init` currently starts at line 228. Right after `atomic_set(&t7xx_dev->md_pm_state, MTK_PM_INIT);` (line 238), add:

```c
	atomic_set(&t7xx_dev->md_pm_state, MTK_PM_INIT);

	INIT_DELAYED_WORK(&t7xx_dev->deferred_pldr_work,
			  t7xx_deferred_pldr_worker);
```

- [ ] **Step 2: Schedule the work in the defer branch**

In `src/t7xx_pci.c`, replace the defer branch at lines 640-647:

```c
			if (atr_reg_val != 0x0000007f &&
			    pm_suspend_target_state != PM_SUSPEND_ON) {
				dev_warn(&pdev->dev,
					 "[PM] Resume: L3/INIT + link up during system sleep (target=%d), deferring PLDR reset\n",
					 pm_suspend_target_state);
				t7xx_mode_update(t7xx_dev, T7XX_UNKNOWN);
				return 0;
			}
```

with:

```c
			if (atr_reg_val != 0x0000007f &&
			    pm_suspend_target_state != PM_SUSPEND_ON) {
				dev_warn(&pdev->dev,
					 "[PM] Resume: L3/INIT + link up during system sleep (target=%d), deferring PLDR reset\n",
					 pm_suspend_target_state);
				t7xx_mode_update(t7xx_dev, T7XX_UNKNOWN);
				/* Schedule the reset for after PM machinery
				 * returns to PM_SUSPEND_ON.  The worker
				 * reschedules itself if the system is still
				 * sleeping (STH hibernate leg) and bails if a
				 * normal resume path recovers the modem first.
				 */
				schedule_delayed_work(&t7xx_dev->deferred_pldr_work,
						      msecs_to_jiffies(DEFERRED_PLDR_DELAY_MS));
				return 0;
			}
```

- [ ] **Step 3: Compile-check**

Run:

```bash
cd /home/kirby/projects/mtk_t7xx_fix/src
make -C /lib/modules/$(uname -r)/build M=$PWD modules 2>&1 | tail -10
```

Expected: clean build, no "unused function" warning. If you see "deferred_pldr_work used before init" or similar, re-order `INIT_DELAYED_WORK` before any code path that can call `schedule_delayed_work` on it. (In the current driver, `t7xx_pci_pm_init` runs inside `t7xx_pci_probe` before any resume path can be taken, so this is safe.)

- [ ] **Step 4: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.c
git commit -m "t7xx: wire deferred PLDR worker into resume defer branch

The defer branch at t7xx_pci.c:640 now schedules the worker instead
of leaving mode=T7XX_UNKNOWN with no follow-up.  The worker executes
the actual PLDR reset once the system is stably awake — closes the
hole where an s2idle wake with no subsequent hibernate leg left the
modem dead until reboot."
```

---

## Task 4: Cancel pending work at every superseding transition

**Files:**
- Modify: `src/t7xx_pci.c:853-865` (`t7xx_pci_pm_prepare`)
- Modify: `src/t7xx_pci.c:581-593` (top of `__t7xx_pci_pm_resume`)
- Modify: `src/t7xx_pci.c:422-434` (top of `__t7xx_pci_pm_suspend`)
- Modify: `src/t7xx_pci.c:818-851` (`t7xx_pci_shutdown`)
- Modify: `src/t7xx_pci.c:1106-1125` (`t7xx_pci_remove`)

The worker must be cancelled whenever another code path is about to act on the modem. Five sites. `.prepare` is added as the earliest-fire PM hook so the cancel happens before `.suspend`/`.freeze`/`.poweroff` — narrows the race window where the worker could fire between `.prepare` and `.suspend` of a second PM cycle that started within the `DEFERRED_PLDR_DELAY_MS` window.

- [ ] **Step 0: Cancel at top of t7xx_pci_pm_prepare**

`t7xx_pci_pm_prepare` currently spans lines 853-865. Its body starts at:

```c
static int t7xx_pci_pm_prepare(struct device *dev)
{
	struct pci_dev *pdev = to_pci_dev(dev);
	struct t7xx_pci_dev *t7xx_dev;

	t7xx_dev = pci_get_drvdata(pdev);
	if (!wait_for_completion_timeout(&t7xx_dev->init_done, T7XX_INIT_TIMEOUT * HZ)) {
```

Add the cancel after `pci_get_drvdata` and before the `wait_for_completion_timeout` call:

```c
	t7xx_dev = pci_get_drvdata(pdev);

	/* .prepare is the earliest PM callback — cancel any pending
	 * deferred PLDR before waiting on init_done.  Otherwise a
	 * worker scheduled at T=0 might fire between our .prepare and
	 * .suspend (both are separate callbacks), making PLDR race with
	 * the suspend freezer.
	 */
	cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

	if (!wait_for_completion_timeout(&t7xx_dev->init_done, T7XX_INIT_TIMEOUT * HZ)) {
```

- [ ] **Step 1: Cancel at top of __t7xx_pci_pm_resume**

`__t7xx_pci_pm_resume` currently starts at line 581. Immediately after `t7xx_dev = pci_get_drvdata(pdev);` on line 588, before the `md_pm_state <= MTK_PM_INIT` check, add:

```c
	t7xx_dev = pci_get_drvdata(pdev);

	/* A new resume callback supersedes any pending deferred PLDR.
	 * Cancel it before re-evaluating state so the worker cannot run
	 * concurrently with this callback's reprobe.
	 */
	cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

	if (atomic_read(&t7xx_dev->md_pm_state) <= MTK_PM_INIT) {
```

- [ ] **Step 2: Cancel at top of __t7xx_pci_pm_suspend**

`__t7xx_pci_pm_suspend` currently starts at line 422. Immediately after `t7xx_dev = pci_get_drvdata(pdev);` on line 429, before the `md_pm_state <= MTK_PM_INIT` check, add:

```c
	t7xx_dev = pci_get_drvdata(pdev);

	/* Do not let a deferred PLDR fire while we are trying to
	 * suspend.  cancel_delayed_work_sync waits for an in-flight
	 * worker to finish — this is acceptable here because the
	 * workqueue is frozen during suspend anyway, and any in-flight
	 * PLDR must complete before we can safely save PCI state.
	 */
	cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

	if (atomic_read(&t7xx_dev->md_pm_state) <= MTK_PM_INIT ||
```

- [ ] **Step 3: Cancel in t7xx_pci_shutdown**

`t7xx_pci_shutdown` currently spans lines 818-851. Its body starts at line 820 with `struct t7xx_pci_dev *t7xx_dev = pci_get_drvdata(pdev);`. Right after that declaration, add the cancel before the big `system_state` comment block:

```c
	struct t7xx_pci_dev *t7xx_dev = pci_get_drvdata(pdev);

	cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

	/* At real system poweroff/reboot the modem loses power shortly and
```

- [ ] **Step 4: Cancel in t7xx_pci_remove**

`t7xx_pci_remove` currently starts at line 1106. Right after `t7xx_dev = pci_get_drvdata(pdev);` on line 1111, before the `sysfs_remove_group` call, add:

```c
	t7xx_dev = pci_get_drvdata(pdev);

	cancel_delayed_work_sync(&t7xx_dev->deferred_pldr_work);

	sysfs_remove_group(&t7xx_dev->pdev->dev.kobj,
			   &t7xx_attribute_group);
```

- [ ] **Step 5: Compile-check**

Run:

```bash
cd /home/kirby/projects/mtk_t7xx_fix/src
make -C /lib/modules/$(uname -r)/build M=$PWD modules 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 6: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add src/t7xx_pci.c
git commit -m "t7xx: cancel deferred PLDR on suspend/resume/shutdown/remove

Every code path that either supersedes the deferred reset (a new
resume callback, or suspend starting again) or tears down the device
(shutdown, remove) must cancel the pending work.  Uses
cancel_delayed_work_sync so any in-flight PLDR completes before the
caller proceeds — safe because all four call sites are sleepable
contexts and the PLDR itself is bounded (~100 ms ACPI MRST._RST +
reprobe ≤ T7XX_INIT_TIMEOUT)."
```

---

## Task 5: Bump module version and rebuild

**Files:**
- Modify: `dkms.conf`
- Modify: `reinstall.sh:10`

- [ ] **Step 1: Bump dkms.conf version**

Read `dkms.conf` first to see the exact line. Change `PACKAGE_VERSION="1.1.2"` to `PACKAGE_VERSION="1.1.3"`.

- [ ] **Step 2: Bump reinstall.sh MODULE_VERSION**

In `reinstall.sh`, line 10 reads `MODULE_VERSION="1.1.2"`. Change to `MODULE_VERSION="1.1.3"`.

- [ ] **Step 3: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add dkms.conf reinstall.sh
git commit -m "Bump to 1.1.3 for deferred PLDR follow-up fix"
```

- [ ] **Step 4: Run reinstall**

Print to the user:

```
Ready to install. Run:
  cd /home/kirby/projects/mtk_t7xx_fix
  bash reinstall.sh
Answer 'y' when prompted to reboot.
```

Wait for user confirmation that reinstall completed.

---

## Task 6: Raise ModemManager stop timeout (address recurring SIGABRT)

**Files:**
- Modify: `reinstall.sh:106-113` (`quick-stop.conf` drop-in content)

**Why this is in the same plan:** log audit (Agent B) identified ~daily SIGABRT of ModemManager on pre-hibernate stop since April 01. Root cause: current `TimeoutStopSec=5` drop-in is too aggressive when MM is mid-MBIM-transaction against a dead modem (example today 11:17:25). Doubling to 10 s still beats the original 45 s default (which was the shutdown-hang we fixed), while allowing enough time for libmbim to abort cleanly before systemd kills MM.

- [ ] **Step 1: Update the drop-in content**

In `reinstall.sh`, locate the block starting at line ~106:

```bash
MM_DROPIN="${MM_DROPIN_DIR}/quick-stop.conf"
mkdir -p "$MM_DROPIN_DIR"
cat > "$MM_DROPIN" <<'EOF'
[Service]
TimeoutStopSec=5
EOF
```

Change `TimeoutStopSec=5` to `TimeoutStopSec=10`. Also update the preceding comment (line 104-105) from "Cap ... at 5 seconds" to "Cap ... at 10 seconds".

- [ ] **Step 2: Commit**

```bash
cd /home/kirby/projects/mtk_t7xx_fix
git add reinstall.sh
git commit -m "Raise ModemManager TimeoutStopSec from 5 to 10

The 5 s cap was chosen to beat the default 45 s shutdown hang but is
too short when MM is mid-MBIM transaction against a recovering modem.
Daily SIGABRT since April (see journalctl: 'ModemManager.service:
Killing process ... with signal SIGABRT'). 10 s gives libmbim enough
time to abort the transaction cleanly while still beating shutdown
timeouts."
```

---

## Task 7: Verification

This is a kernel driver; verification is real-hardware testing. Do not skip.

- [ ] **Step 1: Load check after reboot**

```bash
uname -r
lsmod | grep mtk_t7xx
modinfo mtk_t7xx | grep -E '^(version|srcversion|filename)'
journalctl -b -k | grep 'mtk_t7xx.*0000:08:00.0' | head -10
nmcli -t -f TYPE,STATE device | grep gsm
```

Expected:
- `mtk_t7xx` loaded from `extra/` path (DKMS)
- kernel log shows driver init without errors
- `gsm:connected`

- [ ] **Step 2: Data plane check**

```bash
timeout 5 ping -c 3 -I wwan0 1.1.1.1
```

Expected: 0 % loss.

- [ ] **Step 3: Exercise the s2idle-wake path (the bug's repro)**

Trigger suspend-then-hibernate, then wake from s2idle **before** the hibernate delay so no hibernate leg runs:

```bash
systemctl suspend-then-hibernate
# Close lid or let the machine sleep ~30 seconds, then open lid / press a key
# to wake BEFORE systemd hibernates (default delay is 2h, so this is easy)
```

After wake, wait 5 seconds, then:

```bash
journalctl -b -k --since '1 minute ago' | grep -E 'mtk_t7xx|Deferred PLDR'
nmcli -t -f TYPE,STATE device | grep gsm
timeout 5 ping -c 3 -I wwan0 1.1.1.1
```

**Expected log sequence (the successful fix):**
```
[PM] Resume: prev_state=2 atr=0x... pci_state=0
[PM] Resume: L3/INIT + link up during system sleep (target=1), deferring PLDR reset
[PM] Deferred PLDR: running now, attempt 1/3
[PM] Resume: handshake path
```

**Expected nmcli:** `gsm:connected` within ≤ 10 s of wake.
**Expected ping:** 0 % loss.

If instead the old bug reproduces (no `Deferred PLDR: running now` line ever appears, modem stays dead, MM logs `Write error on MBIM port, -5`), the fix did not trigger — stop and investigate.

- [ ] **Step 4: Full STH cycle check (regression for the 5305cb5 case)**

Force a full suspend-then-hibernate that completes the hibernate leg. Either wait out the default delay or reduce `HibernateDelaySec`:

```bash
sudo systemctl edit --drop-in=short-hib-test systemd-logind.service  # no, wrong target
# Instead write:
sudo tee /etc/systemd/sleep.conf.d/short-hib-test.conf <<EOF
[Sleep]
HibernateDelaySec=60
EOF
sudo systemctl suspend-then-hibernate
# Leave the machine for ~90 seconds so it finishes the hibernate leg, then resume.
```

After wake from hibernate, check:

```bash
journalctl -b -k --since '5 minutes ago' | grep -E 'mtk_t7xx|Deferred PLDR'
nmcli -t -f TYPE,STATE device | grep gsm
```

**Expected:** the intermediate s2idle-wake may log "deferring PLDR reset" and schedule the worker; the subsequent `.suspend` (hibernate leg) cancels it (you should see no `Deferred PLDR: running now`); the hibernate-resume takes the normal `reprobe attempt 1/3` path and recovers.

**Expected:** `gsm:connected` and ping works. No double-PLDR, no wedged NVMe.

Clean up the test drop-in:

```bash
sudo rm /etc/systemd/sleep.conf.d/short-hib-test.conf
```

- [ ] **Step 5: Stress test**

Run the project's own stress test for at least 20 minutes:

```bash
sudo bash /home/kirby/projects/mtk_t7xx_fix/stresstest.sh --duration=1200
```

Expected: exit 0, no `Write error on ... port, -5`, no `Failed to find primary AT port`, no MM SIGABRT.

- [ ] **Step 6: Commit verification log**

If all steps pass, no further action. The git history already contains the fix commits.

---

## Self-review checklist (executed before handoff to agents)

1. **Spec coverage** — the spec has one goal: make the deferred reset actually run. Task 3 schedules the work. Task 4 prevents races. Both cover the goal.
2. **Placeholder scan** — no "TBD", no "add error handling". All code blocks are complete.
3. **Type consistency** — `deferred_pldr_work` (field), `t7xx_deferred_pldr_worker` (function), `DEFERRED_PLDR_DELAY_MS`/`DEFERRED_PLDR_RETRY_MS` (constants) — names used consistently across tasks. `struct delayed_work` / `INIT_DELAYED_WORK` / `schedule_delayed_work` / `cancel_delayed_work_sync` / `to_delayed_work` — all standard kernel delayed-work idioms, names match.
4. **Compatibility with prior fixes** — does not modify the conditions that 15 prior commits tuned: still respects `pm_suspend_target_state != PM_SUSPEND_ON`, still respects `MAX_RESUME_REPROBE_ATTEMPTS`, still calls `complete_all(&init_done)` on terminal failure (per e22d499), still runs `t7xx_reset_device(PLDR)` — the same function `.restore` uses.
