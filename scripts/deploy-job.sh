#!/usr/bin/env bash
# deploy-job.sh — Build the container image on ACR and deploy to the Container Apps Job.
#
# This replaces 'azd deploy' for this project. It:
#   1. Builds the Docker image via ACR Tasks (no local Docker required)
#   2. Deploys the image using 'azd deploy --from-package'
#
# Usage:
#   ./scripts/deploy-job.sh            # build + deploy
#   ./scripts/deploy-job.sh --skip-build   # deploy existing image (skip ACR build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
  esac
done

cd "$ROOT_DIR"

# ── Step 1: Build image on ACR ───────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  "$SCRIPT_DIR/hooks/acr-build.sh"
else
  echo "⏭️  Skipping ACR build (--skip-build)"
fi

# ── Step 2: Deploy via azd ──────────────────────────────────────────────────
JOB_IMAGE=$(azd env get-value JOB_IMAGE 2>/dev/null || echo "")
if [[ -z "$JOB_IMAGE" ]]; then
  echo "❌ JOB_IMAGE not set. Run without --skip-build first."
  exit 1
fi

echo ""
echo "🚀 Deploying image to Container Apps Job..."
echo "   Image: $JOB_IMAGE"
echo ""

azd deploy job --from-package "$JOB_IMAGE" --no-prompt

echo ""
echo "✅ Deploy complete."
