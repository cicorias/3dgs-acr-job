#!/usr/bin/env bash
# verify-gpu.sh — Deploy and run a GPU verification job on Azure Container Apps
#
# This creates a lightweight Container Apps Job that runs nvidia-smi to confirm
# GPU access is working. Uses the serverless Consumption-GPU-NC8as-T4 profile.
#
# Usage:
#   ./scripts/verify-gpu.sh                           # standalone in swedencentral
#   ./scripts/verify-gpu.sh --location westus         # override region
#   ./scripts/verify-gpu.sh --existing                # use existing azd environment
#
# Supported T4 regions: swedencentral, eastus, westus, canadacentral, brazilsouth,
#   australiaeast, italynorth, francecentral, centralindia, japaneast,
#   northcentralus, southcentralus, southeastasia, southindia, westeurope,
#   westus2, westus3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

USE_EXISTING=false
GPU_LOCATION="swedencentral"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --existing) USE_EXISTING=true; shift ;;
    --location) GPU_LOCATION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Save any explicitly-set env vars before loading azd defaults
_EXPLICIT_RG="${AZURE_RESOURCE_GROUP:-}"
_EXPLICIT_ENV="${AZURE_CONTAINER_ENVIRONMENT_NAME:-}"

# Load azd environment values (may override env vars)
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

# Restore explicitly-set env vars (take precedence over azd)
if [[ -n "$_EXPLICIT_RG" ]]; then AZURE_RESOURCE_GROUP="$_EXPLICIT_RG"; fi
if [[ -n "$_EXPLICIT_ENV" ]]; then AZURE_CONTAINER_ENVIRONMENT_NAME="$_EXPLICIT_ENV"; fi

# Use nvidia/cuda image with nvidia-smi — runs and exits (job-compatible)
GPU_TEST_IMAGE="nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0"
GPU_PROFILE_NAME="Consumption-GPU-NC8as-T4"
GPU_JOB_NAME="gpu-verify-job"

if [[ "$USE_EXISTING" == "true" ]]; then
  : "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP not set. Run 'azd provision' with USE_GPU=true.}"
  : "${AZURE_CONTAINER_ENVIRONMENT_NAME:?ERROR: AZURE_CONTAINER_ENVIRONMENT_NAME not set.}"
  RG_NAME="$AZURE_RESOURCE_GROUP"
  ENV_NAME="$AZURE_CONTAINER_ENVIRONMENT_NAME"
  echo "╔══════════════════════════════════════════════╗"
  echo "║  GPU Verification — Existing Environment     ║"
  echo "╚══════════════════════════════════════════════╝"
else
  SUFFIX=$RANDOM
  RG_NAME="rg-gpu-verify-${SUFFIX}"
  ENV_NAME="cae-gpu-verify-${SUFFIX}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║  GPU Verification — Standalone Mode          ║"
  echo "╚══════════════════════════════════════════════╝"
fi

echo ""
echo "  Resource Group: $RG_NAME"
echo "  Location:       $GPU_LOCATION"
echo "  GPU Profile:    $GPU_PROFILE_NAME"
echo ""

# ── Create standalone resources via Bicep (handles GPU profile correctly) ─────
if [[ "$USE_EXISTING" != "true" ]]; then
  echo "🔧 Creating resource group..."
  az group create --name "$RG_NAME" --location "$GPU_LOCATION" --output none

  echo "🔧 Deploying Container Apps Environment with GPU profile via Bicep..."
  cat > /tmp/gpu-verify-env.bicep << 'BICEP'
param name string
param location string = resourceGroup().location

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${name}-log'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
      { name: 'Consumption-GPU-NC8as-T4', workloadProfileType: 'Consumption-GPU-NC8as-T4' }
    ]
  }
}

output envId string = env.id
output envName string = env.name
BICEP

  az deployment group create \
    --resource-group "$RG_NAME" \
    --template-file /tmp/gpu-verify-env.bicep \
    --parameters name="$ENV_NAME" location="$GPU_LOCATION" \
    --query "properties.provisioningState" \
    --output tsv
fi

# ── Verify GPU profile exists ─────────────────────────────────────────────────
echo "🔍 Verifying GPU workload profile..."
PROFILE_EXISTS=$(az containerapp env workload-profile list \
  --name "$ENV_NAME" \
  --resource-group "$RG_NAME" \
  --query "[?name=='$GPU_PROFILE_NAME'].name" \
  --output tsv 2>/dev/null || echo "")

if [[ -z "$PROFILE_EXISTS" ]]; then
  echo "❌ GPU workload profile $GPU_PROFILE_NAME not available in this environment."
  echo "   Ensure the region ($GPU_LOCATION) supports serverless T4 GPUs."
  exit 1
fi
echo "  ✅ $GPU_PROFILE_NAME is available"

# ── Create or reuse the GPU test job ──────────────────────────────────────────
JOB_EXISTS=$(az containerapp job show \
  --name "$GPU_JOB_NAME" \
  --resource-group "$RG_NAME" \
  --query "name" --output tsv 2>/dev/null || echo "")

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
else
  echo "  ♻️  Reusing existing job: $GPU_JOB_NAME"
fi

# ── Start and monitor the job ─────────────────────────────────────────────────
echo ""
echo "🚀 Starting GPU verification job..."
EXECUTION=$(az containerapp job start \
  --name "$GPU_JOB_NAME" \
  --resource-group "$RG_NAME" \
  --query "name" --output tsv)

echo "   Execution: $EXECUTION"
echo ""
echo "⏳ Waiting for execution to complete (up to 5 minutes)..."

STATUS="Unknown"
for i in $(seq 1 30); do
  sleep 10
  STATUS=$(az containerapp job execution show \
    --name "$GPU_JOB_NAME" \
    --resource-group "$RG_NAME" \
    --job-execution-name "$EXECUTION" \
    --query "properties.status" --output tsv 2>/dev/null || echo "Unknown")

  case "$STATUS" in
    Succeeded)
      echo ""
      echo "✅ GPU verification PASSED — NVIDIA T4 GPU is accessible!"
      break
      ;;
    Failed)
      echo ""
      echo "❌ GPU verification FAILED."
      echo "   Check GPU quota: https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade"
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
  echo "   az containerapp job execution show --name $GPU_JOB_NAME --resource-group $RG_NAME --job-execution-name $EXECUTION"
fi

echo ""
if [[ "$USE_EXISTING" != "true" ]]; then
  echo "🧹 To clean up standalone resources:"
  echo "   az group delete --name $RG_NAME --yes --no-wait"
fi
