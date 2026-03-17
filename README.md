# 3DGS Processor — Azure Container Apps Job

Deploy the `3dgs-processor:latest` container to **Azure Container Apps Jobs** using the Azure Developer CLI (`azd`) and Bicep.

> **Source**: The container image is built from [Azure-Samples/3DGS-accelerator](https://github.com/Azure-Samples/3DGS-accelerator).

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Resource Group                                      │
│                                                      │
│  ┌──────────────┐   ┌──────────────────────────┐    │
│  │  ACR          │   │  Storage Account          │    │
│  │  (images)     │   │  ├── input/               │    │
│  │               │   │  ├── output/              │    │
│  └──────┬───────┘   │  ├── processed/           │    │
│         │            │  └── error/               │    │
│         │            └──────────┬───────────────┘    │
│         │                       │                     │
│         │  ┌────────────────┐   │                     │
│         │  │ Managed Identity│   │                     │
│         │  │  (RBAC: AcrPull │   │                     │
│         │  │  + BlobContrib) │   │                     │
│         │  └───────┬────────┘   │                     │
│         │          │             │                     │
│  ┌──────▼──────────▼─────────────▼──────────────┐    │
│  │  Container Apps Environment                    │    │
│  │  ┌──────────────────────────────────────────┐ │    │
│  │  │  Container Apps Job (Manual Trigger)      │ │    │
│  │  │  └── 3dgs-processor container             │ │    │
│  │  └──────────────────────────────────────────┘ │    │
│  └───────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- [Docker](https://docs.docker.com/get-docker/) with `3dgs-processor:latest` image available locally
- An Azure subscription with **Contributor** access to create resources

## Quick Start

```bash
# 1. Initialize the azd environment
azd init

# 2. Configure environment
azd env set AZURE_LOCATION eastus2
azd env set PROCESSOR_BACKEND mock        # mock (CPU) | gsplat | gaussian-splatting (GPU)

# 3. Provision infrastructure + deploy container image
azd up

# 4. (Privileged user) Assign RBAC roles to the Managed Identity
./scripts/assign-rbac.sh

# 5. Verify RBAC assignments
./scripts/verify-rbac.sh

# 6. Run a job
./scripts/run-job.sh
```

## Configuration

Set these via `azd env set <KEY> <VALUE>`:

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_LOCATION` | — | Azure region (e.g., `eastus2`) |
| `PROCESSOR_BACKEND` | `mock` | 3DGS backend: `mock`, `gsplat`, `gaussian-splatting` |
| `USE_GPU` | `false` | Enable GPU workload profile (dedicated NC24-A100) |
| `USE_STORAGE_KEYS` | `false` | Use storage account keys instead of RBAC |

## Workflows

### Scenario 1: Full Setup (Developer + Admin)

```bash
# Developer provisions and deploys
azd up

# Admin assigns RBAC (requires Owner or User Access Administrator)
./scripts/assign-rbac.sh

# Developer verifies and runs
./scripts/verify-rbac.sh
./scripts/run-job.sh --wait
```

### Scenario 2: Storage Keys Fallback (No RBAC needed)

```bash
# Provision with key-based storage
azd env set USE_STORAGE_KEYS true
azd up

# Or configure keys post-provision
./scripts/configure-storage-keys.sh

# Run the job
./scripts/run-job.sh
```

### Scenario 3: GPU-Enabled Processing

```bash
azd env set USE_GPU true
azd env set PROCESSOR_BACKEND gsplat
azd up
./scripts/assign-rbac.sh
./scripts/run-job.sh --wait --logs
```

### Scenario 4: Submit a Job (after azd up)

```bash
# Quick start — fire and forget
./scripts/run-job.sh

# Start and wait for completion
./scripts/run-job.sh --wait

# Start, wait, and show logs
./scripts/run-job.sh --logs
```

You can also use the Azure CLI directly:

```bash
az containerapp job start \
  --name <JOB_NAME> \
  --resource-group <AZURE_RESOURCE_GROUP>
```

### Scenario 5: Tear Down

```bash
# Remove RBAC first (if assigned)
./scripts/cleanup-rbac.sh

# Destroy all resources
azd down
```

## RBAC Management

RBAC role assignments are **intentionally separated** from `azd up`. In enterprise environments, developers typically lack permissions to assign roles.

### Roles Assigned

| Role | Scope | Purpose |
|------|-------|---------|
| `AcrPull` | Container Registry | MI pulls container images |
| `Storage Blob Data Contributor` | Storage Account | MI reads/writes blob data |

### Scripts

| Script | Who Runs It | Description |
|--------|-------------|-------------|
| `scripts/assign-rbac.sh` | Privileged user | Assigns RBAC roles to MI |
| `scripts/assign-rbac.sh --use-bicep` | Privileged user | Same, but via Bicep deployment |
| `scripts/verify-rbac.sh` | Anyone | Checks if RBAC roles are assigned |
| `scripts/cleanup-rbac.sh` | Privileged user | Removes RBAC role assignments |

### Preflight Check

The `preprovision` hook automatically runs `verify-rbac.sh` before each `azd provision`. This is non-blocking — it warns if RBAC is missing but does not prevent provisioning.

## Storage Account

The storage account is created with four blob containers:

| Container | Purpose |
|-----------|---------|
| `input` | Upload videos for processing |
| `output` | Processed 3DGS models (.ply, .splat) |
| `processed` | Archive of completed jobs |
| `error` | Quarantine for failed processing |

### RBAC Mode (Default)

The Managed Identity uses `DefaultAzureCredential` to access storage. The environment variable `AZURE_CLIENT_ID` is set to the MI's client ID.

### Key Mode (Fallback)

Run `./scripts/configure-storage-keys.sh` to retrieve the storage account key and configure it as a secret on the job. The connection string is passed via `AZURE_STORAGE_CONNECTION_STRING`.

## Project Structure

```
├── azure.yaml                          # azd project definition
├── infra/
│   ├── main.bicep                      # Main infrastructure (no RBAC)
│   ├── main.parameters.json            # azd env var bindings
│   ├── abbreviations.json              # Resource naming abbreviations
│   ├── modules/
│   │   ├── acr.bicep                   # Azure Container Registry
│   │   ├── storage.bicep               # Storage Account + blob containers
│   │   ├── container-apps-env.bicep    # Container Apps Environment
│   │   ├── container-apps-job.bicep    # Container Apps Job (Manual trigger)
│   │   ├── managed-identity.bicep      # User-Assigned Managed Identity
│   │   └── monitoring.bicep            # Log Analytics workspace
│   └── rbac/
│       ├── main.bicep                  # RBAC role assignments (separate)
│       └── main.parameters.json
├── scripts/
│   ├── assign-rbac.sh                  # Assign RBAC roles
│   ├── verify-rbac.sh                  # Verify RBAC roles (preflight)
│   ├── cleanup-rbac.sh                 # Remove RBAC roles
│   ├── run-job.sh                      # Submit a job execution
│   ├── configure-storage-keys.sh       # Fallback: storage keys
│   └── hooks/
│       └── preprovision.sh             # azd preprovision hook
├── src/job/
│   └── Dockerfile                      # References 3dgs-processor:latest
└── README.md
```

## Troubleshooting

### "RBAC roles missing" warning during azd up

This is expected on first run. After `azd up` completes, run `./scripts/assign-rbac.sh`.

### Job fails to pull image from ACR

Ensure the `AcrPull` role is assigned: `./scripts/verify-rbac.sh`

### Job can't access storage

Either assign RBAC (`./scripts/assign-rbac.sh`) or use key-based access (`./scripts/configure-storage-keys.sh`).

### GPU workload profile not available

GPU profiles (`NC24-A100`) are region-dependent. Check [Azure Container Apps GPU availability](https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-overview) and try a different region.

## License

See [Azure-Samples/3DGS-accelerator](https://github.com/Azure-Samples/3DGS-accelerator) for the source container license.
