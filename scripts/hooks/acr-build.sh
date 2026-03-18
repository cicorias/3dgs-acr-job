#!/usr/bin/env bash
# acr-build.sh — Build the job container image via ACR Tasks (remote build).
#
# Reads ACR coordinates from azd env, uploads the Docker context to ACR,
# and builds entirely in the cloud. No local Docker daemon required.
#
# Usage: ./scripts/hooks/acr-build.sh
#
# After a successful build the full image reference is written to
# the azd env var JOB_IMAGE so subsequent hooks / deploy steps can use it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Read ACR coordinates from azd env ────────────────────────────────────────
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
ACR_ENDPOINT=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>/dev/null || echo "")

if [[ -z "$ACR_NAME" || -z "$ACR_ENDPOINT" ]]; then
  echo "❌ AZURE_CONTAINER_REGISTRY_NAME / ENDPOINT not set in azd env."
  echo "   Run 'azd provision' first to create the infrastructure."
  exit 1
fi

# ── Build tag: short git SHA + epoch seconds for uniqueness ──────────────────
GIT_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
IMAGE_TAG="${GIT_SHA}-$(date +%s)"
IMAGE_REPO="3dgs-processor-job"

echo ""
echo "🐳 Building image via ACR Tasks (remote build)"
echo "   Registry : $ACR_NAME ($ACR_ENDPOINT)"
echo "   Image    : ${IMAGE_REPO}:${IMAGE_TAG}"
echo "   Context  : src/job/"
echo ""

# ── Run the remote build ─────────────────────────────────────────────────────
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_REPO}:${IMAGE_TAG}" \
  --image "${IMAGE_REPO}:latest" \
  --file src/job/Dockerfile \
  src/job/

FULL_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:${IMAGE_TAG}"
azd env set JOB_IMAGE "$FULL_IMAGE"

echo ""
echo "✅ Image built and pushed: $FULL_IMAGE"
echo "   Also tagged: ${ACR_ENDPOINT}/${IMAGE_REPO}:latest"
