# GPU Environment Check — Azure Container Apps Job

Run a lightweight GPU validation job on **Azure Container Apps** using `azd` and Bicep.

The container image is self-contained — just `nvidia/cuda` base + shell scripts + Python stdlib.
No ML frameworks, no external repos. Checks nvidia-smi, CUDA libraries, and runs a
`cudaMalloc`/`cudaFree` smoke test via Python ctypes.

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
│  │  │  └── gpu-check container                  │ │    │
│  │  └──────────────────────────────────────────┘ │    │
│  └───────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)
- [Azure CLI (`az`)](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- An Azure subscription with **Contributor** access to create resources

> **Note:** Docker is _not_ required locally. Container images are built remotely
> via [ACR Tasks](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-tasks-overview)
> — no local Docker daemon, build, or push needed.

## Quick Start

```bash
# 1. Initialize the azd environment
azd init

# 2. Configure environment
azd env set AZURE_LOCATION swedencentral
azd env set USE_GPU true

# 3. Provision infrastructure (also builds the image on ACR)
azd provision

# 4. (Privileged user) Assign RBAC roles to the Managed Identity
./scripts/assign-rbac.sh

# 5. Verify RBAC assignments
./scripts/verify-rbac.sh

# 6. Run the GPU check job
./scripts/run-job.sh --logs
```

### Deploying Code Changes

After the initial `azd provision`, use the deploy script to rebuild and
redeploy whenever your Dockerfile or application code changes:

```bash
./scripts/deploy-job.sh
```

This script:
1. Builds the image remotely via ACR Tasks (`az acr build`)
2. Deploys it via `azd deploy job --from-package`

> **Why not plain `azd deploy`?** — `azd deploy` with `host: containerapp`
> attempts a local Docker pull/push cycle. Since the CUDA base image is
> multi-GB, we bypass that entirely with `--from-package` which sends
> the image reference directly to Container Apps.

## Configuration

Set these via `azd env set <KEY> <VALUE>`:

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_LOCATION` | — | Azure region (e.g., `swedencentral`) |
| `USE_GPU` | `false` | Enable GPU workload profile |
| `USE_STORAGE_KEYS` | `false` | Use storage account keys instead of RBAC |

## Workflows

### Scenario 1: Full Setup (Developer + Admin)

```bash
# Developer provisions infra + builds image on ACR
azd provision

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
azd provision

# Or configure keys post-provision
./scripts/configure-storage-keys.sh

# Run the job
./scripts/run-job.sh
```

### Scenario 3: GPU-Enabled Check

```bash
azd env set USE_GPU true
azd env set AZURE_LOCATION swedencentral
azd provision
./scripts/assign-rbac.sh
./scripts/run-job.sh --logs
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

### Scenario 5: Redeploy After Code Changes

```bash
# Rebuild on ACR + update the Container Apps Job
./scripts/deploy-job.sh

# Or deploy an existing image (skip the ACR build)
./scripts/deploy-job.sh --skip-build
```

### Scenario 6: Build Image Manually via ACR

If you need to rebuild the image without deploying:

```bash
az acr build \
  --registry <ACR_NAME> \
  --image 3dgs-processor-job:latest \
  --file src/job/Dockerfile \
  src/job/
```

### Scenario 7: Tear Down

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
| `input` | Upload data for processing |
| `output` | Job output |
| `processed` | Archive of completed jobs |
| `error` | Quarantine for failed processing |

### RBAC Mode (Default)

The Managed Identity uses `DefaultAzureCredential` to access storage. The environment variable `AZURE_CLIENT_ID` is set to the MI's client ID.

### Key Mode (Fallback)

Run `./scripts/configure-storage-keys.sh` to retrieve the storage account key and configure it as a secret on the job. The connection string is passed via `AZURE_STORAGE_CONNECTION_STRING`.

## Container Image

The job image is built from `src/job/Dockerfile`. It is minimal:

- **Base:** `nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04`
- **Added:** `python3` (stdlib only — no pip, no frameworks)
- **Entrypoint:** `check-gpu.sh` — validates nvidia-smi, CUDA libs, and runs a `cudaMalloc`/`cudaFree` smoke test

No external repositories are cloned. No ML frameworks are installed.

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `scripts/deploy-job.sh` | Build image on ACR + deploy to Container Apps Job |
| `scripts/assign-rbac.sh` | Assign RBAC roles (AcrPull + Blob Contributor) to MI |
| `scripts/verify-rbac.sh` | Verify RBAC roles are assigned |
| `scripts/cleanup-rbac.sh` | Remove RBAC role assignments |
| `scripts/run-job.sh` | Start a Container Apps Job execution |
| `scripts/configure-storage-keys.sh` | Fallback: configure storage account keys on the job |
| `scripts/hooks/preprovision.sh` | azd preprovision hook (captures deployer ID, runs RBAC check) |
| `scripts/hooks/postprovision.sh` | azd postprovision hook (ACR build + update job) |
| `scripts/hooks/acr-build.sh` | Shared: builds image via ACR Tasks, sets JOB_IMAGE in azd env |
| `scripts/verify-gpu.sh` | Standalone GPU verification (creates its own ACA environment) |
| `scripts/run-preflight.sh` | ⚠️ Legacy — clones external repo for preflight (deprecated) |

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
│   ├── deploy-job.sh                   # Build on ACR + deploy (replaces azd deploy)
│   ├── assign-rbac.sh                  # Assign RBAC roles
│   ├── verify-rbac.sh                  # Verify RBAC roles (preflight)
│   ├── cleanup-rbac.sh                 # Remove RBAC roles
│   ├── run-job.sh                      # Submit a job execution
│   ├── configure-storage-keys.sh       # Fallback: storage keys
│   ├── verify-gpu.sh                   # Standalone GPU verification
│   ├── run-preflight.sh                # ⚠️ Legacy preflight (external repo)
│   └── hooks/
│       ├── preprovision.sh             # azd preprovision hook
│       ├── postprovision.sh            # azd postprovision hook (ACR build)
│       └── acr-build.sh                # Shared ACR Tasks build logic
├── src/job/
│   ├── Dockerfile                      # Minimal CUDA + python3 image
│   └── check-gpu.sh                    # GPU environment check script
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

GPU profiles are region-dependent. Check [Azure Container Apps GPU availability](https://learn.microsoft.com/en-us/azure/container-apps/workload-profiles-overview) and try a different region (e.g., `swedencentral`).

## License

[MIT](LICENSE)
