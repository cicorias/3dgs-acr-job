#!/usr/bin/env bash
# verify-gpu.sh — Deploy and run a GPU verification job on Azure Container Apps
#
# This creates a lightweight Container Apps Job that runs nvidia-smi to confirm
# GPU access is working. Uses the serverless Consumption-GPU-NC8as-T4 profile.
#
# Usage:
#   ./scripts/verify-gpu.sh              # run against existing azd environment
#   ./scripts/verify-gpu.sh --standalone # create a standalone test environment
#
# The --standalone flag creates a fresh resource group + environment for testing.
# Without it, the script uses the existing azd environment (must have GPU enabled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STANDALONE=false
if [[ "${1:-}" == "--standalone" ]]; then
  STANDALONE=true
fi

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

GPU_TEST_IMAGE="mcr.microsoft.com/k8se/gpu-quickstart:latest"
GPU_PROFILE_NAME="NC8as-T4"
GPU_PROFILE_TYPE="Consumption-GPU-NC8as-T4"
GPU_JOB_NAME="gpu-verify-job"
# T4 supported region
GPU_LOCATION="${AZURE_LOCATION:-swedencentral}"

if [[ "$STANDALONE" == "true" ]]; then
  RG_NAME="rg-gpu-verify-${RANDOM}"
  ENV_NAME="cae-gpu-verify"

  echo "╔══════════════════════════════════════════════╗"
  echo "║  GPU Verification — Standalone Mode          ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "  Resource Group: $RG_NAME"
  echo "  Location:       $GPU_LOCATION"
  echo ""

  echo "🔧 Creating resource group..."
  az group create \
    --name "$RG_NAME" \
    --location "$GPU_LOCATION" \
    --output none

  echo "🔧 Creating Container Apps environment..."
  az containerapp env create \
    --name "$ENV_NAME" \
    --resource-group "$RG_NAME" \
    --location "$GPU_LOCATION" \
    --output none

  echo "🔧 Adding GPU workload profile ($GPU_PROFILE_TYPE)..."
  az containerapp env workload-profile add \
    --name "$ENV_NAME" \
    --resource-group "$RG_NAME" \
    --workload-profile-name "$GPU_PROFILE_NAME" \
    --workload-profile-type "$GPU_PROFILE_TYPE"

  echo "🔧 Creating GPU verification job..."
  az containerapp job create \
    --name "$GPU_JOB_NAME" \
    --resource-group "$RG_NAME" \
    --environment "$ENV_NAME" \
    --image "$GPU_TEST_IMAGE" \
    --cpu 8.0 \
    --memory 56.0Gi \
    --workload-profile-name "$GPU_PROFILE_NAME" \
    --trigger-type Manual \
    --replica-timeout 300 \
    --replica-retry-limit 0 \
    --output none

else
  # Use existing azd environment
  : "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP is not set. Run 'azd provision' with USE_GPU=true first.}"
  : "${AZURE_CONTAINER_ENVIRONMENT_NAME:?ERROR: AZURE_CONTAINER_ENVIRONMENT_NAME is not set.}"

  RG_NAME="$AZURE_RESOURCE_GROUP"
  ENV_NAME="$AZURE_CONTAINER_ENVIRONMENT_NAME"

  echo "╔══════════════════════════════════════════════╗"
  echo "║  GPU Verification — Existing Environment     ║"
  echo "╚══════════════════════════════════════════════╝"
  echo ""
  echo "  Resource Group: $RG_NAME"
  echo "  Environment:    $ENV_NAME"
  echo ""

  # Check if GPU profile exists
  PROFILE_EXISTS=$(az containerapp env workload-profile list \
    --name "$ENV_NAME" \
    --resource-group "$RG_NAME" \
    --query "[?name=='$GPU_PROFILE_NAME'].name" \
    --output tsv 2>/dev/null || echo "")

  if [[ -z "$PROFILE_EXISTS" ]]; then
    echo "⚠️  GPU workload profile not found. Adding $GPU_PROFILE_TYPE..."
    az containerapp env workload-profile add \
      --name "$ENV_NAME" \
      --resource-group "$RG_NAME" \
      --workload-profile-name "$GPU_PROFILE_NAME" \
      --workload-profile-type "$GPU_PROFILE_TYPE"
  fi

  # Check if test job already exists
  JOB_EXISTS=$(az containerapp job show \
    --name "$GPU_JOB_NAME" \
    --resource-group "$RG_NAME" \
    --query "name" \
    --output tsv 2>/dev/null || echo "")

  if [[ -z "$JOB_EXISTS" ]]; then
    echo "🔧 Creating GPU verification job..."
    az containerapp job create \
      --name "$GPU_JOB_NAME" \
      --resource-group "$RG_NAME" \
      --environment "$ENV_NAME" \
      --image "$GPU_TEST_IMAGE" \
      --cpu 8.0 \
      --memory 56.0Gi \
      --workload-profile-name "$GPU_PROFILE_NAME" \
      --trigger-type Manual \
      --replica-timeout 300 \
      --replica-retry-limit 0 \
      --output none
  fi
fi

echo ""
echo "🚀 Starting GPU verification job..."
EXECUTION=$(az containerapp job start \
  --name "$GPU_JOB_NAME" \
  --resource-group "$RG_NAME" \
  --query "name" \
  --output tsv)

echo "   Execution: $EXECUTION"
echo ""
echo "⏳ Waiting for execution to complete (up to 5 minutes)..."

for i in $(seq 1 30); do
  sleep 10
  STATUS=$(az containerapp job execution show \
    --name "$GPU_JOB_NAME" \
    --resource-group "$RG_NAME" \
    --job-execution-name "$EXECUTION" \
    --query "properties.status" \
    --output tsv 2>/dev/null || echo "Unknown")

  case "$STATUS" in
    Succeeded)
      echo ""
      echo "✅ GPU verification PASSED — NVIDIA GPU is accessible!"
      echo ""
      echo "📋 Fetching nvidia-smi output from logs..."
      # Allow a few seconds for logs to propagate
      sleep 5
      az containerapp job logs show \
        --name "$GPU_JOB_NAME" \
        --resource-group "$RG_NAME" \
        --execution "$EXECUTION" \
        --container "$GPU_JOB_NAME" \
        2>/dev/null || echo "   (Logs may take a minute to appear in Log Analytics)"
      break
      ;;
    Failed)
      echo ""
      echo "❌ GPU verification FAILED."
      echo "   Check if the region ($GPU_LOCATION) supports serverless GPUs."
      echo "   Check GPU quota: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade"
      break
      ;;
    *)
      printf "   Status: %-12s (check %d/30)\r" "$STATUS" "$i"
      ;;
  esac
done

if [[ "$STATUS" != "Succeeded" && "$STATUS" != "Failed" ]]; then
  echo ""
  echo "⚠️  Timed out waiting for execution. Check status manually:"
  echo "   az containerapp job execution show --name $GPU_JOB_NAME --resource-group $RG_NAME --job-execution-name $EXECUTION"
fi

echo ""
if [[ "$STANDALONE" == "true" ]]; then
  echo "🧹 To clean up standalone resources:"
  echo "   az group delete --name $RG_NAME --yes --no-wait"
fi
