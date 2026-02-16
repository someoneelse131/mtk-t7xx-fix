#!/bin/bash
# Verify modem is working after patched module installation
set -e

echo "=== Fibocom FM350 Modem Verification ==="
echo ""

echo "--- Kernel ---"
uname -r
echo ""

echo "--- Module loaded ---"
if lsmod | grep -q mtk_t7xx; then
    lsmod | grep mtk_t7xx
    echo ""
    echo "--- Module info ---"
    modinfo mtk_t7xx | head -5
else
    echo "WARNING: mtk_t7xx module is NOT loaded"
fi
echo ""

echo "--- DKMS status ---"
dkms status mtk_t7xx 2>/dev/null || echo "DKMS not available or module not installed via DKMS"
echo ""

echo "--- dmesg (t7xx) ---"
sudo dmesg | grep -i t7xx | tail -15 || echo "No t7xx messages found"
echo ""

echo "--- WWAN devices ---"
ls -la /dev/wwan* 2>/dev/null || echo "No /dev/wwan* devices found"
echo ""

echo "--- ModemManager ---"
if command -v mmcli &>/dev/null; then
    mmcli -L 2>/dev/null || echo "No modems detected by ModemManager"
else
    echo "mmcli not found (install ModemManager)"
fi
echo ""

echo "--- PCI device ---"
lspci | grep -i "fibocom\|mediatek\|t7xx\|cellular\|wwan" || echo "No WWAN PCI device found"
echo ""

echo "=== Done ==="
