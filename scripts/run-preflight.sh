#!/usr/bin/env bash
# run-preflight.sh — Build and run the 3DGS preflight GPU check on Container Apps
#
# Clones the 3DGS-accelerator repo, builds Dockerfile.preflight, pushes to ACR,
# creates a Container Apps Job on the GPU profile, and runs it.
#
# Usage:
#   ./scripts/run-preflight.sh                        # basic GPU detection
#   ./scripts/run-preflight.sh --expect gsplat        # assert gsplat backend works
#   ./scripts/run-preflight.sh --skip-build           # reuse existing image
#   ./scripts/run-preflight.sh --cleanup              # remove preflight job + image
#
# Prerequisites:
#   - azd environment provisioned with USE_GPU=true
#   - Docker available locally for image build
#   - az CLI authenticated
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

EXPECT_BACKEND=""
SKIP_BUILD=false
CLEANUP=false
SOURCE_REPO="https://github.com/Azure-Samples/3DGS-accelerator.git"
PREFLIGHT_IMAGE_NAME="3dgs-preflight"
PREFLIGHT_JOB_NAME="preflight-check"
GPU_PROFILE_NAME="Consumption-GPU-NC8as-T4"
BUILD_DIR="/tmp/3dgs-preflight-build"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expect) EXPECT_BACKEND="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --cleanup) CLEANUP=true; shift ;;
    --repo) SOURCE_REPO="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${AZURE_CONTAINER_REGISTRY_NAME:?ERROR: AZURE_CONTAINER_REGISTRY_NAME not set. Run 'azd provision' first.}"
: "${AZURE_CONTAINER_REGISTRY_ENDPOINT:?ERROR: AZURE_CONTAINER_REGISTRY_ENDPOINT not set.}"
: "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP not set.}"
: "${AZURE_CONTAINER_ENVIRONMENT_NAME:?ERROR: AZURE_CONTAINER_ENVIRONMENT_NAME not set.}"

FULL_IMAGE="${AZURE_CONTAINER_REGISTRY_ENDPOINT}/${PREFLIGHT_IMAGE_NAME}:latest"

# ── Cleanup mode ──────────────────────────────────────────────────────────────
if [[ "$CLEANUP" == "true" ]]; then
  echo "🧹 Cleaning up preflight resources..."
  az containerapp job delete \
    --name "$PREFLIGHT_JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --yes --output none 2>/dev/null && echo "  ✅ Job deleted" || echo "  (job not found)"
  az acr repository delete \
    --name "$AZURE_CONTAINER_REGISTRY_NAME" \
    --repository "$PREFLIGHT_IMAGE_NAME" \
    --yes 2>/dev/null && echo "  ✅ Image deleted from ACR" || echo "  (image not found)"
  rm -rf "$BUILD_DIR" && echo "  ✅ Build directory cleaned"
  echo "Done."
  exit 0
fi

echo "╔══════════════════════════════════════════════╗"
echo "║  3DGS Preflight GPU Check                    ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "  ACR:          $AZURE_CONTAINER_REGISTRY_ENDPOINT"
echo "  GPU Profile:  $GPU_PROFILE_NAME"
if [[ -n "$EXPECT_BACKEND" ]]; then
  echo "  Expect:       --expect $EXPECT_BACKEND"
fi
echo ""

# ── Step 1: Build the preflight image ─────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  echo "🔧 Step 1: Building preflight image..."
  echo ""

  if [[ -d "$BUILD_DIR/.git" ]]; then
    echo "  ♻️  Reusing existing clone at $BUILD_DIR"
    cd "$BUILD_DIR" && git pull --quiet 2>/dev/null || true
  else
    echo "  📥 Cloning $SOURCE_REPO..."
    rm -rf "$BUILD_DIR"
    git clone --depth 1 "$SOURCE_REPO" "$BUILD_DIR" 2>&1 | tail -1
  fi

  cd "$BUILD_DIR"

  echo "  🐳 Building Docker image..."
  docker build -f Dockerfile.preflight -t "${PREFLIGHT_IMAGE_NAME}:latest" . 2>&1 | tail -5
  echo ""

  # ── Step 2: Push to ACR ───────────────────────────────────────────────────
  echo "🔧 Step 2: Pushing image to ACR..."
  az acr login --name "$AZURE_CONTAINER_REGISTRY_NAME" --output none 2>&1
  docker tag "${PREFLIGHT_IMAGE_NAME}:latest" "$FULL_IMAGE"
  docker push "$FULL_IMAGE" 2>&1 | tail -3
  echo "  ✅ Pushed: $FULL_IMAGE"
  echo ""
else
  echo "⏭️  Skipping build (--skip-build)"
  echo ""
fi

# ── Step 3: Create or update the preflight job ────────────────────────────────
echo "🔧 Step 3: Creating preflight job on GPU profile..."

# Build command args for the job
CMD_ARGS=""
if [[ -n "$EXPECT_BACKEND" ]]; then
  CMD_ARGS="--expect $EXPECT_BACKEND"
fi

# Check if job already exists
JOB_EXISTS=$(az containerapp job show \
  --name "$PREFLIGHT_JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "name" --output tsv 2>/dev/null || echo "")

MI_ID="${MANAGED_IDENTITY_RESOURCE_ID:-}"

if [[ -z "$JOB_EXISTS" ]]; then
  # Determine registry identity args
  REGISTRY_ARGS=""
  if [[ -n "$MI_ID" ]]; then
    REGISTRY_ARGS="--registry-identity $MI_ID"
  fi

  az containerapp job create \
    --name "$PREFLIGHT_JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --environment "$AZURE_CONTAINER_ENVIRONMENT_NAME" \
    --image "$FULL_IMAGE" \
    --cpu 8.0 \
    --memory 56.0Gi \
    --workload-profile-name "$GPU_PROFILE_NAME" \
    --trigger-type Manual \
    --replica-timeout 300 \
    --replica-retry-limit 0 \
    --registry-server "$AZURE_CONTAINER_REGISTRY_ENDPOINT" \
    $REGISTRY_ARGS \
    --env-vars "NVIDIA_VISIBLE_DEVICES=all" "NVIDIA_DRIVER_CAPABILITIES=compute,utility" "QT_QPA_PLATFORM=offscreen" \
    --output none 2>&1
  echo "  ✅ Job created: $PREFLIGHT_JOB_NAME"
else
  echo "  ♻️  Job already exists, reusing"
  az containerapp job update \
    --name "$PREFLIGHT_JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --image "$FULL_IMAGE" \
    --output none 2>&1
  echo "  ✅ Job image updated"
fi
echo ""

# ── Step 4: Start the preflight job ───────────────────────────────────────────
echo "🚀 Step 4: Starting preflight job..."
EXECUTION=$(az containerapp job start \
  --name "$PREFLIGHT_JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "name" --output tsv)

echo "  Execution: $EXECUTION"
echo ""

# ── Step 5: Wait for result ───────────────────────────────────────────────────
echo "⏳ Waiting for preflight to complete (up to 5 minutes)..."

STATUS="Unknown"
for i in $(seq 1 30); do
  sleep 10
  STATUS=$(az containerapp job execution show \
    --name "$PREFLIGHT_JOB_NAME" \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --job-execution-name "$EXECUTION" \
    --query "properties.status" --output tsv 2>/dev/null || echo "Unknown")

  case "$STATUS" in
    Succeeded)
      echo ""
      echo "✅ Preflight PASSED"
      break
      ;;
    Failed)
      echo ""
      echo "❌ Preflight FAILED"
      break
      ;;
    *)
      printf "   Status: %-12s (check %d/30)\n" "$STATUS" "$i"
      ;;
  esac
done

if [[ "$STATUS" != "Succeeded" && "$STATUS" != "Failed" ]]; then
  echo ""
  echo "⚠️  Timed out waiting. Check manually:"
  echo "   az containerapp job execution show --name $PREFLIGHT_JOB_NAME --resource-group $AZURE_RESOURCE_GROUP --job-execution-name $EXECUTION"
fi

# ── Step 6: Fetch logs ────────────────────────────────────────────────────────
echo ""
echo "📋 Fetching preflight logs..."

# Wait for logs to propagate to Log Analytics
sleep 30

WORKSPACE_ID=$(az monitor log-analytics workspace list \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].customerId" --output tsv 2>/dev/null || echo "")

if [[ -n "$WORKSPACE_ID" ]]; then
  LOGS=$(az rest --method post \
    --url "https://api.loganalytics.io/v1/workspaces/${WORKSPACE_ID}/query" \
    --headers "Content-Type=application/json" \
    --body "{\"query\":\"ContainerAppConsoleLogs_CL | where ContainerGroupName_s contains '${EXECUTION}' | project Log_s | order by TimeGenerated asc | take 200\"}" \
    --resource "https://api.loganalytics.io" 2>/dev/null || echo "")

  if [[ -n "$LOGS" ]]; then
    echo "$LOGS" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    rows = data.get('tables', [{}])[0].get('rows', [])
    if rows:
        for r in rows:
            print(r[0])
    else:
        print('(logs not yet available — check again in 1-2 minutes)')
except:
    print('(could not parse log response)')
" 2>/dev/null
  else
    echo "  (logs not yet available — check again in 1-2 minutes)"
    echo "  Query manually with:"
    echo "  az rest --method post --url 'https://api.loganalytics.io/v1/workspaces/${WORKSPACE_ID}/query' \\"
    echo "    --headers 'Content-Type=application/json' \\"
    echo "    --body '{\"query\":\"ContainerAppConsoleLogs_CL | where ContainerGroupName_s contains \\\"${EXECUTION}\\\" | project Log_s | order by TimeGenerated asc\"}' \\"
    echo "    --resource 'https://api.loganalytics.io'"
  fi
else
  echo "  (Log Analytics workspace not found)"
fi

echo ""
if [[ "$STATUS" == "Succeeded" ]]; then
  echo "🎉 GPU environment is ready for 3DGS processing."
elif [[ "$STATUS" == "Failed" ]]; then
  echo "⚠️  GPU preflight failed. Check logs above for details."
  echo "   The container image may need remediation — see docs/container-image-remediation.md"
  exit 1
fi
