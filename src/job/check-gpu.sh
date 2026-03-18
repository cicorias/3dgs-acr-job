#!/bin/bash
set -euo pipefail

echo "╔══════════════════════════════════════════════════════════╗"
echo "║              GPU Environment Check                      ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── nvidia-smi ────────────────────────────────────────────────────────────────
echo "GPU Hardware"
echo "────────────"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | \
    while IFS=, read -r name mem driver; do
      echo "  GPU: $name | $mem | driver $driver"
    done
  pass "nvidia-smi"
else
  fail "nvidia-smi not available"
fi
echo ""

# ── CUDA libraries ────────────────────────────────────────────────────────────
echo "CUDA Runtime"
echo "────────────"
if [ -d /usr/local/cuda ]; then
  CUDA_VER=$(cat /usr/local/cuda/version.json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['cuda']['version'])" 2>/dev/null || echo "unknown")
  pass "CUDA toolkit found (${CUDA_VER})"
else
  fail "CUDA toolkit not found at /usr/local/cuda"
fi

if ldconfig -p 2>/dev/null | grep -q libcudart; then
  pass "libcudart present"
else
  fail "libcudart not found"
fi
echo ""

# ── GPU compute test (pure Python + ctypes, no frameworks) ────────────────────
echo "GPU Compute Test"
echo "────────────────"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  python3 -c "
import ctypes, ctypes.util, sys

# Try to load the CUDA runtime
libname = ctypes.util.find_library('cudart')
if not libname:
    print('  Could not find libcudart')
    sys.exit(1)

cudart = ctypes.CDLL(libname)

# Get device count
count = ctypes.c_int(0)
rc = cudart.cudaGetDeviceCount(ctypes.byref(count))
if rc != 0 or count.value == 0:
    print(f'  No CUDA devices (rc={rc}, count={count.value})')
    sys.exit(1)

print(f'  CUDA devices: {count.value}')

# Allocate + free a small buffer on GPU as a smoke test
ptr = ctypes.c_void_p()
rc = cudart.cudaMalloc(ctypes.byref(ptr), ctypes.c_size_t(1024))
if rc != 0:
    print(f'  cudaMalloc failed (rc={rc})')
    sys.exit(1)
cudart.cudaFree(ptr)
print('  cudaMalloc/cudaFree: OK')
" 2>&1
  if [ $? -eq 0 ]; then
    pass "GPU compute smoke test"
  else
    fail "GPU compute smoke test"
  fi
else
  echo "  Skipped (no GPU)"
  fail "GPU compute smoke test (no GPU)"
fi
echo ""

# ── Environment info ──────────────────────────────────────────────────────────
echo "Environment"
echo "───────────"
echo "  Kernel : $(uname -r)"
echo "  Arch   : $(uname -m)"
echo "  Python : $(python3 --version 2>&1 | awk '{print $2}')"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ ENVIRONMENT CHECK FAILED"
  exit 1
else
  echo "  ✅ GPU ENVIRONMENT READY"
  exit 0
fi
