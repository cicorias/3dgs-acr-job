#!/usr/bin/env bash
# run-gsplat-check.sh — Build, deploy, and run the gsplat environment check
#                        on the existing Azure Container Apps Job.
#
# This script:
#   1. Builds the gsplat-check Docker image via ACR Tasks (remote build)
#   2. Updates the Container Apps Job to use the new image
#   3. Starts the job execution
#   4. Waits for completion and shows logs
#
# Usage:
#   ./scripts/run-gsplat-check.sh              # full cycle: build → deploy → run → logs
#   ./scripts/run-gsplat-check.sh --skip-build  # reuse existing image, just run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# ── Load azd environment ─────────────────────────────────────────────────────
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP not set. Run 'azd provision' first.}"
: "${JOB_NAME:?ERROR: JOB_NAME not set. Run 'azd provision' first.}"

ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
ACR_ENDPOINT=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>/dev/null || echo "")

if [[ -z "$ACR_NAME" || -z "$ACR_ENDPOINT" ]]; then
  echo "❌ AZURE_CONTAINER_REGISTRY_NAME / ENDPOINT not set."
  echo "   Run 'azd provision' first."
  exit 1
fi

IMAGE_REPO="gsplat-check"

# ── Step 1: Build image via ACR Tasks ─────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  GIT_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
  IMAGE_TAG="${GIT_SHA}-$(date +%s)"

  echo ""
  echo "🐳 Building gsplat-check image via ACR Tasks (remote build)"
  echo "   Registry : $ACR_NAME ($ACR_ENDPOINT)"
  echo "   Image    : ${IMAGE_REPO}:${IMAGE_TAG}"
  echo "   Context  : scripts/gsplat_check/"
  echo ""

  az acr build \
    --registry "$ACR_NAME" \
    --image "${IMAGE_REPO}:${IMAGE_TAG}" \
    --image "${IMAGE_REPO}:latest" \
    --file scripts/gsplat_check/Dockerfile \
    scripts/gsplat_check/

  FULL_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:${IMAGE_TAG}"
  echo ""
  echo "✅ Image built: $FULL_IMAGE"
else
  FULL_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:latest"
  echo "⏭️  Skipping build — using existing image: $FULL_IMAGE"
fi

# ── Step 2: Update the Container Apps Job with the new image ──────────────────
echo ""
echo "🔄 Updating Container Apps Job with gsplat-check image..."
echo "   Job   : $JOB_NAME"
echo "   Image : $FULL_IMAGE"

az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --image "$FULL_IMAGE" \
  --output none

echo "✅ Job updated."

# ── Step 3: Start the job execution ──────────────────────────────────────────
echo ""
echo "🚀 Starting gsplat-check job execution..."
EXECUTION=$(az containerapp job start \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "name" \
  --output tsv 2>/dev/null)

if [[ -z "$EXECUTION" ]]; then
  echo "❌ Failed to start job execution."
  exit 1
fi

echo "✅ Execution started: $EXECUTION"

# ── Step 4: Wait for completion ──────────────────────────────────────────────
echo ""
echo "⏳ Waiting for execution to complete..."

STATUS="Unknown"
for i in $(seq 1 40); do
  sleep 15
  STATUS=$(az containerapp job execution show \
    --name "$JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --job-execution-name "$EXECUTION" \
    --query "properties.status" \
    --output tsv 2>/dev/null || echo "Unknown")

  case "$STATUS" in
    Succeeded)
      echo "✅ Job execution completed successfully."
      break
      ;;
    Failed)
      echo "❌ Job execution failed."
      break
      ;;
    Running|Processing)
      printf "   Status: %-12s (check %d/40)\n" "$STATUS" "$i"
      ;;
    *)
      printf "   Status: %-12s (check %d/40)\n" "$STATUS" "$i"
      ;;
  esac
done

if [[ "$STATUS" != "Succeeded" && "$STATUS" != "Failed" ]]; then
  echo "⚠️  Timed out waiting (10 min). Check manually:"
  echo "   az containerapp job execution show --name $JOB_NAME --resource-group $AZURE_RESOURCE_GROUP --job-execution-name $EXECUTION"
fi

# ── Step 5: Show logs ────────────────────────────────────────────────────────
echo ""
echo "📋 Fetching execution logs..."
echo ""

# Retry log retrieval a few times (logs can lag behind completion)
for attempt in 1 2 3; do
  LOGS=$(az containerapp job logs show \
    --name "$JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --execution "$EXECUTION" \
    --container "main" \
    --follow false \
    2>/dev/null || echo "")

  if [[ -n "$LOGS" ]]; then
    echo "$LOGS"
    break
  fi

  if [[ $attempt -lt 3 ]]; then
    echo "   (Logs not yet available — retrying in 15s...)"
    sleep 15
  else
    echo "   (Logs not available yet. Retrieve manually:)"
    echo "   az containerapp job logs show --name $JOB_NAME --resource-group $AZURE_RESOURCE_GROUP --execution $EXECUTION --container main"
  fi
done
