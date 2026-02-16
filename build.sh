#!/bin/bash
# Build the patched mtk_t7xx module
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/src"

echo "=== Building patched mtk_t7xx module ==="
echo "Kernel: $(uname -r)"
echo ""

make clean 2>/dev/null || true
make

echo ""
echo "=== Build successful ==="
echo "Module: $(ls -la mtk_t7xx.ko)"
echo ""
echo "Next: run 'sudo bash install.sh' to install with DKMS"
