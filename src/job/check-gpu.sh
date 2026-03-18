#!/bin/bash
set -euo pipefail

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           3DGS GPU Environment Check                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✅ $label"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $label"
    FAIL=$((FAIL + 1))
  fi
}

# ── nvidia-smi ────────────────────────────────────────────────────────────────
echo "GPU Hardware"
echo "────────────"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | \
    while IFS=, read -r name mem driver; do
      echo "  ✅ GPU: $name ($mem, driver $driver)"
    done
  PASS=$((PASS + 1))
else
  echo "  ❌ No GPU detected (nvidia-smi not available)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── PyTorch CUDA ──────────────────────────────────────────────────────────────
echo "PyTorch + CUDA"
echo "──────────────"
python3 -c "
import torch
print(f'  PyTorch version : {torch.__version__}')
print(f'  CUDA compiled   : {torch.version.cuda}')
print(f'  CUDA available  : {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'  CUDA device     : {torch.cuda.get_device_name(0)}')
    print(f'  CUDA devices    : {torch.cuda.device_count()}')
    print(f'  cuDNN version   : {torch.backends.cudnn.version()}')
    # Quick GPU compute test
    a = torch.rand(512, 512, device='cuda')
    b = torch.rand(512, 512, device='cuda')
    c = torch.mm(a, b)
    print(f'  GPU matmul test : PASS ({c.shape})')
else:
    print('  ⚠️  No CUDA device — running CPU-only')
" 2>&1
if python3 -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
fi
echo ""

# ── gsplat ────────────────────────────────────────────────────────────────────
echo "gsplat (3DGS training backend)"
echo "──────────────────────────────"
if python3 -c "import gsplat; print(f'  gsplat version  : {gsplat.__version__}')" 2>&1; then
  PASS=$((PASS + 1))
else
  echo "  ❌ gsplat not importable"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── External tools ────────────────────────────────────────────────────────────
echo "External Tools"
echo "──────────────"
check "ffmpeg"  ffmpeg -version
check "colmap"  colmap help
check "python3" python3 --version
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo "  ❌ ENVIRONMENT CHECK FAILED"
  exit 1
else
  echo "  ✅ ENVIRONMENT READY FOR 3DGS PROCESSING"
  exit 0
fi
