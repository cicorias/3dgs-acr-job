# GPU Workload Profile Discovery

This document captures the discovery process for determining which Azure regions
support serverless GPU workload profiles in Azure Container Apps.

## Context

During deployment of the 3DGS processor, we needed to verify NVIDIA GPU
availability for the `Consumption-GPU-NC8as-T4` (T4) serverless workload profile.
The initial deployment used `eastus2`, which **does not** support serverless GPU
profiles. We discovered `swedencentral` does.

## Discovery Commands

### 1. List supported workload profiles per region

The key command is `az containerapp env workload-profile list-supported`, which
shows which workload profile types are available in a given Azure region.

**East US 2 — no GPU profiles:**

```bash
$ az containerapp env workload-profile list-supported --location eastus2 -o table

Location    Name
----------  -----------
eastus2     D4
eastus2     D8
eastus2     D16
eastus2     D32
eastus2     E4
eastus2     E8
eastus2     E16
eastus2     E32
eastus2     Consumption
```

> ⚠️ No `Consumption-GPU-*` profiles listed — `eastus2` does not support
> serverless GPUs.

**Sweden Central — GPU profiles available:**

```bash
$ az containerapp env workload-profile list-supported --location swedencentral -o table

Location       Name
-------------  -------------------------
swedencentral  D4
swedencentral  D8
swedencentral  D16
swedencentral  D32
swedencentral  E4
swedencentral  E8
swedencentral  E16
swedencentral  E32
swedencentral  Consumption
swedencentral  Flex
swedencentral  Consumption-GPU-NC24-A100
swedencentral  Consumption-GPU-NC8as-T4
```

> ✅ Both `Consumption-GPU-NC8as-T4` (T4) and `Consumption-GPU-NC24-A100` (A100)
> are available.

### 2. Check multiple regions quickly

To find which regions support T4, run against each candidate:

```bash
for region in eastus eastus2 westus swedencentral canadacentral brazilsouth; do
  echo "=== $region ==="
  az containerapp env workload-profile list-supported \
    --location "$region" \
    --query "[?contains(name, 'GPU')].name" \
    -o tsv 2>/dev/null || echo "(none)"
done
```

Example output:

```
=== eastus ===
Consumption-GPU-NC24-A100
Consumption-GPU-NC8as-T4
=== eastus2 ===
(none)
=== westus ===
Consumption-GPU-NC24-A100
Consumption-GPU-NC8as-T4
=== swedencentral ===
Consumption-GPU-NC24-A100
Consumption-GPU-NC8as-T4
=== canadacentral ===
Consumption-GPU-NC24-A100
Consumption-GPU-NC8as-T4
=== brazilsouth ===
Consumption-GPU-NC24-A100
Consumption-GPU-NC8as-T4
```

### 3. Verify a profile can't be added post-creation via CLI

We attempted to add the GPU profile to an existing environment using:

```bash
$ az containerapp env workload-profile add \
    --name cae-gpu-verify \
    --resource-group rg-gpu-verify \
    --workload-profile-name Consumption-GPU-NC8as-T4 \
    --workload-profile-type Consumption-GPU-NC8as-T4

(WorkloadProfileInvalidType) Workload profile type 'CONSUMPTION_GPU_NC8AS_T4' is invalid.
```

> ⚠️ The `workload-profile add` CLI command does **not** support consumption GPU
> profile types. Serverless GPU profiles must be defined at environment creation
> time — either via **Bicep** (in `workloadProfiles` array) or during initial
> `az containerapp env create`.

### 4. Correct approach: define GPU profile in Bicep

The working approach is to include the GPU profile in the `workloadProfiles`
property at environment creation time:

```bicep
resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  properties: {
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
      { name: 'Consumption-GPU-NC8as-T4', workloadProfileType: 'Consumption-GPU-NC8as-T4' }
    ]
  }
}
```

> For serverless consumption GPU profiles, the **name** and **workloadProfileType**
> are identical (e.g., `Consumption-GPU-NC8as-T4`).

## Available GPU Profile Types

| Profile Name | GPU | VRAM | Use Case |
|---|---|---|---|
| `Consumption-GPU-NC8as-T4` | NVIDIA T4 | 16 GB GDDR6 | Inference, light training |
| `Consumption-GPU-NC24-A100` | NVIDIA A100 | 80 GB HBM2e | Training, large models |

## Supported Regions (as of March 2026)

| Region | A100 | T4 |
|---|---|---|
| Australia East | Yes | Yes |
| Brazil South | Yes | Yes |
| Canada Central | Yes | Yes |
| Central India | No | Yes |
| East US | Yes | Yes |
| **East US 2** | **No** | **No** |
| France Central | No | Yes |
| Italy North | Yes | Yes |
| Japan East | No | Yes |
| North Central US | No | Yes |
| South Central US | No | Yes |
| South East Asia | No | Yes |
| South India | No | Yes |
| Sweden Central | Yes | Yes |
| West Europe | No | Yes |
| West US | Yes | Yes |
| West US 2 | No | Yes |
| West US 3 | Yes | Yes |

> **Key finding:** `eastus2` is not in the supported regions list. Always verify
> with `az containerapp env workload-profile list-supported --location <region>`
> before deploying GPU workloads.

## Resource Sizing for GPU Profiles

| Profile | vCPU | Memory | GPU |
|---|---|---|---|
| `Consumption-GPU-NC8as-T4` | 8 | 56 GiB | 1× T4 |
| `Consumption-GPU-NC24-A100` | 24 | 220 GiB | 1× A100 |

When creating a job or app on a GPU profile, the resource requests must match
the profile's allocation:

```bash
az containerapp job create \
  --cpu 8.0 \
  --memory 56.0Gi \
  --workload-profile-name Consumption-GPU-NC8as-T4
```
