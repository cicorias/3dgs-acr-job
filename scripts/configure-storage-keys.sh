#!/usr/bin/env bash
# configure-storage-keys.sh — Fallback: configure the job with storage account keys
# Use this when RBAC cannot be assigned (developer lacks permissions).
#
# This retrieves the storage account key, builds a connection string,
# and updates the Container Apps Job to use it.
#
# Usage:
#   ./scripts/configure-storage-keys.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${JOB_NAME:?ERROR: JOB_NAME is not set. Run 'azd provision' first.}"
: "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP is not set.}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?ERROR: AZURE_STORAGE_ACCOUNT_NAME is not set.}"

echo "🔑 Configuring storage account keys for job: $JOB_NAME"
echo ""

# Retrieve the primary storage account key
echo "  → Retrieving storage account key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "[0].value" \
  --output tsv)

if [[ -z "$STORAGE_KEY" ]]; then
  echo "❌ Failed to retrieve storage account key."
  exit 1
fi

# Build the connection string
CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=${AZURE_STORAGE_ACCOUNT_NAME};AccountKey=${STORAGE_KEY};EndpointSuffix=core.windows.net"

echo "  → Updating job secrets..."
az containerapp job secret set \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --secrets "storage-connection-string=$CONNECTION_STRING" \
  --output none

echo "  → Updating job environment variables..."
az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --set-env-vars "AZURE_STORAGE_CONNECTION_STRING=secretref:storage-connection-string" \
  --output none

echo ""
echo "✅ Storage account keys configured on job."
echo "   The job will use the connection string for storage access."
echo ""
echo "⚠️  Note: If you rotate storage keys, re-run this script to update the job."
