# Fix Fibocom FM350 (mtk_t7xx) on Fedora

Patches the `mtk_t7xx` kernel driver so the Fibocom FM350-GL (MediaTek T700, PCI ID `14c3:4d75`) WWAN modem actually works on Fedora (kernels 6.17+).

Tested on Lenovo ThinkPad X1 Carbon Gen 11, Fedora 43, kernel 6.18.

Related Fedora discussion: [Issue activating mobile internet modem on a Lenovo ThinkPad X1 Yoga Gen 8](https://discussion.fedoraproject.org/t/issue-activating-mobile-internet-modem-on-a-lenovo-thinkpad-x1-yoga-gen-8/170623)

## The problem

On Fedora 43 the in-tree `mtk_t7xx` driver fails to initialize the modem. Eight separate issues stack up:

1. **PM timeout treated as fatal** -- the modem's PCIe power-management status register never becomes ready. The driver aborts instead of continuing without PM.
2. **NULL pointer crash (double-uninit)** -- the error-recovery path calls `kthread_stop()` twice on the same thread without NULLing the pointer.
3. **NULL pointer crash (kthread_run failure)** -- if `kthread_run()` fails, the thread pointer is left as `ERR_PTR`, so `kthread_stop()` dereferences garbage.
4. **FCC unlock broken** -- Lenovo's unlock binary segfaults, and ModemManager's built-in unlock script silently fails because `xxd` isn't installed.
5. **Lenovo services hijack the modem** -- `fibo_helper` / `fibo_flash` / `fwswitch` / `lenovo-cfgservice` force the modem into fastboot mode ~15 s after it connects.
6. **Shutdown hangs for hours** -- `t7xx_pci_shutdown()` only runs the suspend path, which leaves the TX thread alive. When the modem is unresponsive, the thread polls forever and blocks poweroff.
7. **s2idle sleep kills the connection** -- after resume the modem's MBIM session is stale but ModemManager doesn't know, so it loops "Operation aborted" forever.
8. **Dead modem after sleep** -- the modem firmware sometimes reboots during s2idle. The ATR register retains a stale valid value, so the driver skips reprobing and attempts a normal handshake resume. The SAP channel times out but the driver continues anyway, leaving the modem in a zombie state where all communication fails.

The same hardware works fine on Ubuntu (kernel 6.14) because it uses IOMMU passthrough and doesn't ship the Lenovo services.

All eight issues are fixed by this project -- six driver patches (across three source files), plus system-level fixes handled by the install script.

## Quick start

```bash
# 1. Install build dependencies
sudo dnf install kernel-devel-$(uname -r) kernel-headers gcc make dkms vim-common

# 2. Add IOMMU passthrough (required for the modem's DMA)
sudo grubby --update-kernel=ALL --args="iommu=pt"

# 3. Clone this repo
git clone https://github.com/someoneelse131/mtk-t7xx-fix.git
cd mtk-t7xx-fix

# 4. Build, install, and reboot (one command does everything)
bash reinstall.sh
```

The script will build the module as your user, then `sudo` for the install step. After install it reboots automatically (Ctrl+C to cancel).

## After reboot

```bash
# Check everything is working
bash verify.sh

# Modem state should be "registered" with power "on"
mmcli -m 0

# WWAN interface should be listed
nmcli device status
```

## Connect mobile data

```bash
# Create a connection (replace APN with your carrier's)
nmcli connection add type gsm ifname wwan0mbim0 con-name "Mobile" apn internet

# Connect
nmcli connection up "Mobile"
```

Replace `internet` with your carrier's APN.

## After a kernel update

DKMS rebuilds the module automatically for new kernels. If the modem stops working after an update:

```bash
cd mtk-t7xx-fix
bash reinstall.sh
```

## What `reinstall.sh` does

All of this is idempotent -- safe to run repeatedly.

1. Checks for `kernel-devel` headers and warns if `iommu=pt` is missing
2. Builds the patched module from source
3. Installs via DKMS (survives kernel updates)
4. Installs ModemManager's AT-based FCC unlock script (replaces the crashing Lenovo binary)
5. Installs `xxd` if missing (needed by the FCC unlock script)
6. Disables Lenovo Fibocom services that force the modem into fastboot
7. Adds a systemd drop-in to cap ModemManager's stop timeout at 5 s (it hangs for 45 s otherwise)
8. Installs a systemd sleep hook to restart ModemManager after resume (fixes stale MBIM session)
9. Rebuilds initramfs and reboots

## Other scripts

| Script | Purpose |
|---|---|
| `verify.sh` | Check module, dmesg, devices, ModemManager status |
| `uninstall.sh` | Remove patched module and restore the in-tree version |

## Uninstall

```bash
sudo bash uninstall.sh
sudo grubby --update-kernel=ALL --remove-args="iommu=pt"
sudo reboot
```

## Troubleshooting

**Modem not detected after reboot:**
```bash
dkms status                 # patched module installed?
lsmod | grep t7xx           # module loaded?
sudo dmesg | grep -i t7xx   # driver errors?
```

**Modem shows `disabled` / `power state: low`:**

FCC unlock didn't run. Check:
```bash
ls -la /usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75   # script installed?
which xxd                                                 # xxd available?
```
If either is missing, re-run `bash reinstall.sh`.

**`mmcli -m 0 --enable` gives "Invalid transition":**
```bash
sudo systemctl restart ModemManager
sleep 15
mmcli -m 0
```

**Modem connects then drops after ~15 seconds:**

Lenovo services are forcing the modem into fastboot:
```bash
journalctl -b | grep fastboot_switching
# If you see "t7xx_mode, command: fastboot_switching":
sudo systemctl disable --now fibo_helper.service fibo_flash.service fwswitch.service lenovo-cfgservice.service
sudo reboot
```

**Modem not working after sleep/resume:**

ModemManager should restart automatically after resume. If it doesn't:
```bash
sudo systemctl restart ModemManager
sleep 15
mmcli -m 0
```
If the modem is gone from PCI entirely, a full reboot is needed.

**Connection fails with "service option not subscribed":**

Wrong APN. Check your carrier and update:
```bash
nmcli connection modify "Mobile" gsm.apn "your.carrier.apn"
nmcli connection up "Mobile"
```

## Applies to

Tested on a ThinkPad X1 Carbon Gen 11 with Fibocom FM350-GL, Fedora 43, kernel 6.18. Should also work on:

- Other Lenovo laptops with the Fibocom FM350-GL (PCI `14c3:4d75`) -- T14s Gen 4, etc.
- Dell DW5933e (PCI `14c0:4d75`) -- same MediaTek T700 chip, already in the driver's PCI ID table
- Fedora 42 with kernel 6.17+ (untested)
- Likely any distro that uses strict IOMMU by default

## Technical details

The patched driver source lives in `src/`. Key changes:

| File | Fix |
|---|---|
| `t7xx_pci.c` | PM timeout made non-fatal (warn + continue), poll timeout increased to 500 ms, D3cold disabled, suspend_noirq/resume_noirq keep the device in D0 with a reprobe fallback on handshake failure |
| `t7xx_pci.c` | SAP resume timeout triggers full reprobe instead of continuing with a dead modem |
| `t7xx_pci.c` | Shutdown calls `t7xx_md_exit()` after suspend to stop the TX thread and prevent the poweroff hang |
| `t7xx_port_ctrl_msg.c` | NULL `port->thread` after `kthread_stop()` (prevents double-uninit crash) |
| `t7xx_port_ctrl_msg.c` | NULL `port->thread` on `kthread_run()` failure (prevents ERR_PTR dereference) |
| `t7xx_state_monitor.c` | Device-stage timeout increased to 60 s |
