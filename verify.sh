#!/bin/bash
# Verify that the patched mtk_t7xx module and all system-level fixes
# are correctly installed and the modem is operational.
#
# Usage:  bash verify.sh
# No root required (dmesg falls back gracefully if restricted).

echo "=== Fibocom FM350-GL Modem Verification ==="
echo ""

# --- Kernel ---
echo "--- Kernel ---"
echo "  $(uname -r)"
echo ""

# --- Module ---
echo "--- Module ---"
if grep -q '^mtk_t7xx ' /proc/modules 2>/dev/null; then
    echo "  Status:   loaded"
    mod_path=$(modinfo -F filename mtk_t7xx 2>/dev/null) || true
    mod_vermagic=$(modinfo -F vermagic mtk_t7xx 2>/dev/null) || true
    mod_ver=$(echo "$mod_vermagic" | awk '{print $1}')
    echo "  Path:     $mod_path"
    echo "  Vermagic: $mod_vermagic"

    # Check if loaded from DKMS (patched) or in-tree (unpatched)
    if echo "$mod_path" | grep -qE 'updates|extra'; then
        echo "  Source:   DKMS (patched)"
    else
        echo "  Source:   in-tree (UNPATCHED — fixes not active!)"
    fi

    # Check module matches running kernel
    if [ "$mod_ver" = "$(uname -r)" ]; then
        echo "  Match:    module matches running kernel"
    else
        echo "  WARNING:  module built for $mod_ver but running $(uname -r)"
    fi
else
    echo "  WARNING: mtk_t7xx module is NOT loaded"
fi
echo ""

# --- DKMS ---
echo "--- DKMS ---"
dkms_out=$(dkms status mtk_t7xx 2>/dev/null) || true
if [ -n "$dkms_out" ]; then
    echo "$dkms_out" | while IFS= read -r line; do echo "  $line"; done
else
    echo "  Not installed via DKMS"
fi
echo ""

# --- PCI device ---
echo "--- PCI device ---"
pci_out=$(lspci -d 14c3:4d75 2>/dev/null) || true
if [ -n "$pci_out" ]; then
    echo "  $pci_out"
else
    echo "  WARNING: Fibocom FM350 (14c3:4d75) not found on PCI bus"
fi
echo ""

# --- WWAN devices ---
echo "--- WWAN devices ---"
if ls /dev/wwan* >/dev/null 2>&1; then
    ls /dev/wwan* 2>/dev/null | while IFS= read -r dev; do echo "  $dev"; done
else
    echo "  WARNING: No /dev/wwan* devices found"
fi
echo ""

# --- ModemManager ---
echo "--- ModemManager ---"
if command -v mmcli &>/dev/null; then
    mm_out=$(mmcli -L 2>/dev/null) || true
    if echo "$mm_out" | grep -q '/Modem/'; then
        echo "  $mm_out"
        modem_idx=$(echo "$mm_out" | grep -oP '/Modem/\K[0-9]+' | head -1)
        if [ -n "$modem_idx" ]; then
            mm_info=$(mmcli -m "$modem_idx" 2>/dev/null) || true
            state=$(echo "$mm_info" | grep -oP 'state:\s*\x27\K[^\x27]+' || echo "unknown")
            echo "  State:  $state"
        fi
    else
        echo "  WARNING: No modems detected"
    fi
else
    echo "  WARNING: mmcli not found (install ModemManager)"
fi
echo ""

# --- System-level fixes ---
echo "--- System-level fixes ---"

# FCC unlock
if [ -x "/usr/lib64/ModemManager/fcc-unlock.d/14c3:4d75" ] || \
   [ -x "/usr/lib/ModemManager/fcc-unlock.d/14c3:4d75" ]; then
    echo "  FCC unlock:       installed"
else
    echo "  FCC unlock:       MISSING"
fi

# Sleep hook
hook="/usr/lib/systemd/system-sleep/99-modem-fix.sh"
if [ -x "$hook" ]; then
    if grep -q 'systemd-run' "$hook" 2>/dev/null; then
        echo "  Sleep hook:       installed (systemd-run)"
    else
        echo "  Sleep hook:       installed (WARNING: old subshell version)"
    fi
else
    echo "  Sleep hook:       MISSING"
fi

# MM quick-stop dropin
if [ -f "/etc/systemd/system/ModemManager.service.d/quick-stop.conf" ]; then
    echo "  MM quick-stop:    installed"
else
    echo "  MM quick-stop:    MISSING"
fi

# Fibocom services
fibo_ok=true
for svc in fibo_helper fibo_flash fwswitch lenovo-cfgservice; do
    svc_state=$(systemctl is-enabled "${svc}.service" 2>/dev/null) || true
    if [ "$svc_state" = "enabled" ]; then
        echo "  Fibocom services: WARNING — $svc is enabled"
        fibo_ok=false
    fi
done
if $fibo_ok; then
    echo "  Fibocom services: all disabled"
fi

# iommu=pt
if grep -q 'iommu=pt' /proc/cmdline; then
    echo "  iommu=pt:         present in cmdline"
else
    echo "  iommu=pt:         MISSING from cmdline"
fi
echo ""

# --- Kernel log (t7xx) ---
echo "--- dmesg (last 15 t7xx messages) ---"
dmesg_out=$(dmesg 2>/dev/null) || true
if [ -n "$dmesg_out" ]; then
    t7xx_msgs=$(echo "$dmesg_out" | grep -i t7xx | tail -15)
    if [ -n "$t7xx_msgs" ]; then
        echo "$t7xx_msgs" | while IFS= read -r line; do echo "  $line"; done
    else
        echo "  No t7xx messages found"
    fi
else
    echo "  dmesg not accessible (try: sudo bash verify.sh)"
fi
echo ""

echo "=== Done ==="
