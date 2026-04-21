# Uninstall Guide — mtk_t7xx_fix

Complete, standalone guide to undo everything this project installed.
Written to be self-sufficient: you should not need any other context
than this file plus a shell on the target machine.

**Target reader:** you (or a future AI session) starting cold with only
this repository and a running Fedora system.

---

## What this project installed

Before uninstalling, know what's on the system. The install
(`reinstall.sh`) put the following in place:

| Item | Path | Purpose |
|---|---|---|
| Patched `mtk_t7xx` kernel module | `/var/lib/dkms/mtk_t7xx/<ver>/` + `/usr/src/mtk_t7xx-<ver>/` | DKMS-built patched driver; loaded automatically by kernel via depmod priority (extra/ > kernel/). Current versions: 1.1.2 or 1.1.3. |
| FCC unlock script | `/usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75` | Replacement for Lenovo's segfaulting binary — AT-based, from ModemManager's own share dir. |
| `xxd` binary | `/usr/bin/xxd` (via `vim-common` package) | Required by the FCC unlock script. May be shared with other tools — we do NOT remove the package. |
| Modem sleep hook | `/usr/lib/systemd/system-sleep/99-modem-fix.sh` | Stops MM before hibernate/STH, restarts on resume. |
| SDDM sleep hook (optional) | `/usr/lib/systemd/system-sleep/50-sddm-displays.sh` | Only created if `/usr/local/bin/generate-sddm-display-config` exists on the host. Regenerates SDDM display config on wake. Contains marker `"Prevent SDDM's KWin from crashing on hibernate resume"` — `uninstall.sh` only removes if the marker is present (protects any pre-existing file with the same name). |
| ModemManager drop-in | `/etc/systemd/system/ModemManager.service.d/quick-stop.conf` | Caps MM's `TimeoutStopSec` at 10 s (was 5 s in 1.1.2, 10 s in 1.1.3). |
| Fibocom services disabled | `fibo_helper.service`, `fibo_flash.service`, `fwswitch.service`, `lenovo-cfgservice.service` | Lenovo services that hijack the modem into fastboot ~15 s after connect. Disabled but not uninstalled. |
| `iommu=pt` kernel cmdline arg | `grubby` / `/proc/cmdline` | Required for the modem's DMA pattern on Fedora. Optional to remove. |
| Module blacklist (legacy) | `/etc/modprobe.d/blacklist-mtk-t7xx.conf` | Historical artifact; should not exist on fresh installs but cleaned up if present. |

Full reasoning for each item lives in `docs/journal.md`. One-line
summary: every item exists because removing it breaks the modem in a
specific, documented way.

---

## Before you uninstall: what will be WORSE after uninstall

Be explicit about this. The unpatched in-tree driver has real bugs
that this project fixed. After uninstall:

- **Fibocom services stay disabled** (by design). Re-enabling them
  with the in-tree driver triggers a kernel NULL-pointer panic on the
  fastboot_switching path — bootloop territory. `uninstall.sh` does
  NOT re-enable them. If you re-enable manually (see below), expect
  bootloops.
- **Mobile data after resume will degrade**: the in-tree driver does
  not have the L3/INIT reprobe, the PLDR deferral, or the deferred-PLDR
  follow-up — so the scenarios fixed in v1.0.x through v1.1.3 can
  recur. Cold reboot becomes a normal recovery tool again.
- **Shutdown may hang**: the TX-thread-stop fix (`c52a9aa`) and the
  skip-handshake-on-poweroff fix (`22bf201`) go away. Silent
  multi-minute poweroff stalls can recur.
- **FCC unlock may fail**: the in-tree driver still looks for the
  Lenovo `DPR_Fcc_unlock_service` binary which segfaults. Modem will
  stay in `disabled` / `power state: low`.

If none of that sounds good but you still want to uninstall (e.g. to
reinstall cleanly, or to try a different upstream kernel), you can
`reinstall.sh` right after — no need to stay uninstalled.

---

## The one-shot path (preferred)

```bash
cd /path/to/mtk-t7xx-fix
sudo bash uninstall.sh
```

Or non-interactive (skip every prompt — will reboot automatically):

```bash
sudo bash uninstall.sh -y
```

What the script does, in order:

1. **Confirm** (unless `-y`).
2. **Remove every installed DKMS version** of `mtk_t7xx` — enumerates
   `dkms status` and `/usr/src/mtk_t7xx-*` so an upgrade history of
   multiple versions (e.g. 1.1.2 plus 1.1.3) all get torn down.
3. **Clean root-owned build artifacts** from the project's `src/` dir
   (`.cmd`, `.o`, `.ko`, `Module.symvers`, etc.).
4. **Remove the module blacklist** if present (legacy path).
5. **Remove the modem sleep hook** (`99-modem-fix.sh`).
6. **Remove the SDDM sleep hook** (`50-sddm-displays.sh`) if it
   contains our marker comment — otherwise left alone so we don't
   nuke a user-owned file with the same name.
7. **Remove the FCC unlock script** from both `lib64` (Fedora) and
   `lib` (Debian/Arch) paths.
8. **Remove the ModemManager drop-in** and `systemctl daemon-reload`.
9. **Print a NOTE** about Fibocom services still being disabled, with
   the exact command to re-enable.
10. **Offer to remove `iommu=pt`** if it's currently in the cmdline.
11. **Rebuild initramfs** via `dracut --force` (Fedora) or
    `update-initramfs -u` (Debian).
12. **Offer to reboot**.

After reboot the in-tree `mtk_t7xx` loads from `kernel/drivers/net/wwan/`
instead of the DKMS `extra/` path.

---

## Verification after reboot

Confirm the uninstall took effect:

```bash
# Should show NO patched module (or only the in-tree one in kernel/)
modinfo mtk_t7xx 2>/dev/null | grep -E '^(filename|version|srcversion)'
#   expected: filename: .../kernel/drivers/net/wwan/t7xx/mtk_t7xx.ko.xz
#   NOT:      filename: .../extra/mtk_t7xx.ko.xz

# Should be empty
dkms status | grep mtk_t7xx

# Should not exist
ls /usr/src/mtk_t7xx-*        2>/dev/null
ls /usr/lib/systemd/system-sleep/99-modem-fix.sh 2>/dev/null
ls /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75 2>/dev/null
ls /etc/systemd/system/ModemManager.service.d/quick-stop.conf 2>/dev/null
# (each `ls` should report "No such file or directory")

# Fibocom services — should be disabled (masked OK too)
systemctl is-enabled fibo_helper.service fibo_flash.service \
                     fwswitch.service lenovo-cfgservice.service

# iommu=pt — may or may not still be there depending on your answer
grep -o 'iommu=pt' /proc/cmdline || echo "iommu=pt not set"
```

---

## Manual fallback (if `uninstall.sh` fails or is unavailable)

If the script is broken or you don't have the repo anymore, here is
every manual command to do what the script does. Run as root.

```bash
# 1. Remove every DKMS version
for v in $(dkms status 2>/dev/null | awk -F'[/,: ]+' '$1=="mtk_t7xx" {print $2}' | sort -u); do
    dkms remove "mtk_t7xx/$v" --all 2>/dev/null
done
# 2. Remove DKMS source trees
rm -rf /usr/src/mtk_t7xx-*
# 3. Remove legacy blacklist
rm -f /etc/modprobe.d/blacklist-mtk-t7xx.conf
# 4. Remove our sleep hooks
rm -f /usr/lib/systemd/system-sleep/99-modem-fix.sh
# Only remove the SDDM hook if it's ours (marker comment):
if grep -q "Prevent SDDM's KWin from crashing on hibernate resume" \
          /usr/lib/systemd/system-sleep/50-sddm-displays.sh 2>/dev/null; then
    rm /usr/lib/systemd/system-sleep/50-sddm-displays.sh
fi
# 5. Remove FCC unlock scripts (both common paths)
rm -f /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75
rm -f /usr/lib/ModemManager/fcc-unlock.d/14c3:4d75
# 6. Remove the MM drop-in
rm -f /etc/systemd/system/ModemManager.service.d/quick-stop.conf
rmdir /etc/systemd/system/ModemManager.service.d 2>/dev/null
systemctl daemon-reload
# 7. Optional: remove iommu=pt
grubby --update-kernel=ALL --remove-args="iommu=pt"
# 8. Rebuild initramfs
dracut --force
# 9. Reboot
reboot
```

---

## Re-enabling Fibocom services (DO NOT unless you understand the risk)

The script intentionally does NOT re-enable these. If you genuinely
want them back (e.g. you moved to Windows dual-boot logic that
depends on them), the command is:

```bash
sudo systemctl enable --now fibo_helper.service fibo_flash.service \
                            fwswitch.service lenovo-cfgservice.service
```

**Warning:** with the unpatched in-tree `mtk_t7xx`, the Lenovo
`fibo_helper` service can push the modem into `fastboot_switching`
which exercises a NULL-pointer path in the unpatched driver, causing
a kernel panic. Symptom: bootloop. Recovery: boot the rescue entry,
`systemctl disable` the services from there, reboot.

---

## Re-adding `iommu=pt` if you removed it and regret it

If you removed `iommu=pt` and later want it back (e.g. reinstalling
this project):

```bash
sudo grubby --update-kernel=ALL --args="iommu=pt"
sudo dracut --force
sudo reboot
```

Confirm after reboot:

```bash
grep -o 'iommu=pt' /proc/cmdline    # should print: iommu=pt
```

See `docs/journal.md` or the README's IOMMU explanation for why this
flag is needed.

---

## Alternative: uninstall without reboot (advanced)

You can remove the files without rebooting. The running kernel will
continue using the already-loaded DKMS module until unload. A full
runtime teardown looks like:

```bash
# Stop userspace consumers
sudo systemctl stop NetworkManager ModemManager

# The t7xx firmware cannot recover from driver unbind — a reboot is
# the only way to return to the in-tree module's behaviour.
# This is documented in the project notes (see docs/journal.md
# "modem firmware cannot recover from driver unbind").
#
# Do not run `echo 0 > /sys/bus/pci/devices/.../remove` or
# `modprobe -r mtk_t7xx` — either will brick the modem until cold
# reboot.
```

**So**: in practice, always reboot after uninstall. There is no
clean in-place switch from the DKMS module back to the in-tree one
without reloading both, which the firmware does not survive.

---

## Complete reset (nuclear option)

If the system is in a weird state (mixed versions, failed DKMS builds,
half-applied blacklists), do this:

```bash
# Remove absolutely everything related to mtk_t7xx in userspace config
sudo bash -c '
    dkms status 2>/dev/null | awk -F"[/,: ]+" "\$1==\"mtk_t7xx\" {print \$2}" | \
        while read v; do dkms remove "mtk_t7xx/$v" --all 2>/dev/null; done
    rm -rf /usr/src/mtk_t7xx-*
    rm -f /etc/modprobe.d/blacklist-mtk-t7xx.conf
    rm -f /etc/modprobe.d/*mtk_t7xx*.conf
    rm -f /usr/lib/systemd/system-sleep/99-modem-fix.sh
    rm -f /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75
    rm -f /usr/lib/ModemManager/fcc-unlock.d/14c3:4d75
    rm -f /etc/systemd/system/ModemManager.service.d/quick-stop.conf
    rmdir /etc/systemd/system/ModemManager.service.d 2>/dev/null
    systemctl daemon-reload
    dracut --force
'
sudo reboot
```

After reboot the machine is back to stock-Fedora + disabled Fibocom
services. `iommu=pt` remains unless you remove it separately (it's
safe to leave set).

---

## Troubleshooting

**`dkms remove` fails with "module not in tree":**
That's fine — it just means DKMS already lost track of it. Remove
`/usr/src/mtk_t7xx-*` manually and continue.

**`modinfo mtk_t7xx` still shows `extra/` path after reboot:**
The initramfs was not rebuilt, or a module from the old initramfs
was reloaded. Run:

```bash
sudo dracut --force
sudo reboot
```

If still stuck, verify no stray `.ko` files remain:

```bash
find /lib/modules/$(uname -r) -name 'mtk_t7xx*'
```

Delete any that are in `/extra/` or `/updates/` paths.

**Kernel panic on boot after uninstall:**
Almost certainly a Fibocom service got re-enabled. Boot into the
rescue/recovery entry from GRUB, then:

```bash
systemctl disable fibo_helper.service fibo_flash.service \
                  fwswitch.service lenovo-cfgservice.service
reboot
```

**ModemManager stops working entirely:**
Check if our drop-in left an empty config dir:

```bash
ls /etc/systemd/system/ModemManager.service.d/
# If empty, remove:
sudo rmdir /etc/systemd/system/ModemManager.service.d
sudo systemctl daemon-reload
sudo systemctl restart ModemManager
```

**Want to reinstall after uninstall:**

```bash
cd /path/to/mtk-t7xx-fix
bash reinstall.sh -y
```

---

## Quick reference

| Action | Command |
|---|---|
| Full uninstall, interactive | `sudo bash uninstall.sh` |
| Full uninstall, auto-reboot | `sudo bash uninstall.sh -y` |
| Remove `iommu=pt` afterwards | `sudo grubby --update-kernel=ALL --remove-args="iommu=pt" && sudo dracut --force && sudo reboot` |
| Reinstall after uninstall | `bash reinstall.sh -y` |
| Re-enable Fibocom (risky) | `sudo systemctl enable --now fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service` |
| Nuclear reset | see "Complete reset" section above |
