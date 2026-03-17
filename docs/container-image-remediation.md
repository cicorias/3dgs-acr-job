# Remediation: 3DGS Processor Container Image for Azure Container Apps GPU

## Problem Statement

The `3dgs-processor:latest` container image (from
[Azure-Samples/3DGS-accelerator](https://github.com/Azure-Samples/3DGS-accelerator))
fails at the COLMAP reconstruction step when running on Azure Container Apps
serverless GPU (Consumption-GPU-NC8as-T4):

```
F20260317 20:23:53.395457 209 opengl_utils.cc:54] Check failed: context_.create()
```

**Root cause**: Two issues in the current `Dockerfile`:

1. **COLMAP is installed from Ubuntu's `apt` repo** — this is a CPU-only build
   compiled with OpenGL/Qt/GLX dependencies. It requires an X11 display server
   or GLX context, neither of which exists on serverless Container Apps.

2. **PyTorch is installed CPU-only** — the Python stage uses
   `--index-url https://download.pytorch.org/whl/cpu`, so gsplat cannot use
   CUDA even when a GPU is available.

## Environment Context

Azure Container Apps serverless GPU (T4) provides:

- **NVIDIA Driver**: ~550.x (pre-installed by Azure, not in the container)
- **CUDA**: 12.x (available via driver, container needs matching CUDA toolkit)
- **GPU**: Tesla T4, 16 GB VRAM, Turing architecture
- **No X11/GLX**: No display server, no window manager, no OpenGL via GLX
- **No `nvidia-container-toolkit` hooks**: Unlike Docker with `--gpus all`,
  Container Apps exposes the GPU directly — the container must have the right
  libraries

## Remediation Steps

### Step 1: Use NVIDIA CUDA Base Image

Replace the runtime stage base image from `ubuntu:24.04` to an NVIDIA CUDA
runtime image. This provides the CUDA toolkit and runtime libraries.

**Current** (line in Dockerfile):
```dockerfile
FROM ubuntu:24.04
```

**Change to**:
```dockerfile
FROM nvidia/cuda:12.4.1-runtime-ubuntu24.04
```

> Use `-runtime-` (not `-devel-`) to keep image size down. The CUDA toolkit
> headers are only needed at build time.

### Step 2: Build COLMAP from Source with CUDA, No OpenGL

The `apt`-installed COLMAP requires OpenGL. Replace it with a COLMAP build
stage that compiles with CUDA enabled and OpenGL/GUI disabled.

**Add a new build stage** before the final runtime stage:

```dockerfile
# ============================================================================
# Stage 2b: Build COLMAP from source (CUDA, no OpenGL/GUI)
# ============================================================================
FROM nvidia/cuda:12.4.1-devel-ubuntu24.04 AS colmap-builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential \
    libboost-program-options-dev libboost-graph-dev \
    libboost-system-dev libeigen3-dev \
    libgoogle-glog-dev libgtest-dev \
    libsqlite3-dev libceres-dev \
    libflann-dev libfreeimage-dev \
    libsuitesparse-dev libmetis-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch 3.11.1 \
    https://github.com/colmap/colmap.git /colmap

WORKDIR /colmap

RUN cmake -B build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDA_ENABLED=ON \
      -DGUI_ENABLED=OFF \
      -DOPENGL_ENABLED=OFF \
      -DCMAKE_CUDA_ARCHITECTURES="75" \
    && cmake --build build --config Release \
    && cmake --install build --prefix /colmap-install
```

> **`CMAKE_CUDA_ARCHITECTURES="75"`** targets the T4 (Turing SM 7.5). Add
> `"75;80;86;89;90"` for multi-GPU support (A100=80, RTX 3090=86, RTX 4090=89,
> H100=90).

**In the final runtime stage**, replace the `apt` COLMAP install:

```dockerfile
# Remove this line:
#   colmap \

# Add this instead:
COPY --from=colmap-builder /colmap-install /usr/local
```

### Step 3: Install PyTorch with CUDA Support

The gsplat backend requires CUDA-enabled PyTorch to use the GPU for 3DGS
training.

**Current** (in `python-builder` stage):
```dockerfile
RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cpu
```

**Change to**:
```dockerfile
RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cu124
```

> `cu124` matches CUDA 12.4 from the base image. Check
> [PyTorch wheel index](https://download.pytorch.org/whl/) for the latest
> compatible version.

### Step 4: Add NVIDIA Runtime Environment Variables

Add these to the Dockerfile's `ENV` block to ensure the container can discover
the GPU drivers provided by Azure:

```dockerfile
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    QT_QPA_PLATFORM=offscreen
```

> `compute,utility` is sufficient since we disabled OpenGL. If COLMAP is built
> with EGL support (`-DEGL_ENABLED=ON`), add `graphics` to the capabilities.

### Step 5: Remove Blobfuse2 Dependency for Container Apps

Azure Container Apps does not support FUSE mounts (no `/dev/fuse`, no
`CAP_SYS_ADMIN`). The container already supports batch mode with Azure Blob
Storage SDK, which is the correct approach.

The blobfuse2 install can remain for VM/AKS deployments, but it will never
work on Container Apps. Consider making it conditional:

```dockerfile
# Only install blobfuse2 on platforms that support FUSE
# Container Apps users should use RUN_MODE=batch instead
RUN if [ "$ARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends blobfuse2 || true; \
    fi
```

### Step 6: Update Rust Source for Batch Mode COLMAP Flags

In the Rust source code, when running COLMAP in batch mode, pass
`--SiftExtraction.use_gpu 1` explicitly (since the from-source build won't
default to GPU SIFT without an OpenGL context check):

**File to modify**: `src/reconstruction/colmap.rs` (or equivalent)

When constructing the COLMAP feature_extractor command, ensure these flags
are passed:

```
colmap feature_extractor \
  --SiftExtraction.use_gpu 1 \
  --SiftExtraction.gpu_index 0 \
  --database_path <db> \
  --image_path <images>
```

This ensures CUDA-based SIFT extraction is used instead of CPU fallback.

## Complete Dockerfile Diff Summary

```
 # Stage 2: Python environment
-RUN pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
+RUN pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124

+# Stage 2b: COLMAP from source (NEW STAGE)
+FROM nvidia/cuda:12.4.1-devel-ubuntu24.04 AS colmap-builder
+# ... (build COLMAP with -DCUDA_ENABLED=ON -DGUI_ENABLED=OFF -DOPENGL_ENABLED=OFF)

 # Stage 3: Runtime
-FROM ubuntu:24.04
+FROM nvidia/cuda:12.4.1-runtime-ubuntu24.04

 RUN apt-get install -y --no-install-recommends \
-    colmap \
     ffmpeg \
     python3 \
     ...

+COPY --from=colmap-builder /colmap-install /usr/local

+ENV NVIDIA_VISIBLE_DEVICES=all \
+    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
+    QT_QPA_PLATFORM=offscreen
```

## Verification Plan

After rebuilding the image:

1. **Local GPU test** (if NVIDIA GPU available):
   ```bash
   docker run --gpus all -e INPUT_PATH=/data/input -e OUTPUT_PATH=/data/output \
     -e PROCESSED_PATH=/data/processed -e ERROR_PATH=/data/error \
     -e BACKEND=gsplat 3dgs-processor:latest
   ```

2. **Container Apps GPU test**:
   ```bash
   # Push new image, start batch job
   azd deploy
   ./scripts/run-job.sh --wait --logs
   ```

3. **Expected log output on success**:
   ```
   INFO  Batch mode: using Azure Blob Storage SDK (no FUSE mounts)
   INFO  Step 2: Extracting frames from videos
   INFO  Step 5: Running reconstruction
   INFO  Running COLMAP feature extraction         # ← uses CUDA SIFT
   INFO  Running COLMAP exhaustive matcher          # ← uses CUDA matcher
   INFO  COLMAP reconstruction complete points=XXXX
   INFO  Step 6: Training 3DGS model
   INFO  Using gsplat backend with CUDA             # ← GPU training
   INFO  Training iteration 1000/30000 loss=X.XXX
   ...
   INFO  Step 7: Exporting outputs
   INFO  Batch job completed successfully
   ```

## Image Size Impact

| Component | Current | After Change |
|---|---|---|
| Base image | ubuntu:24.04 (~78MB) | nvidia/cuda:12.4.1-runtime (~3.6GB) |
| COLMAP | apt install (~50MB) | From source (~200MB) |
| PyTorch | CPU (~800MB) | CUDA (~2.5GB) |
| **Total** | **~1.7GB** | **~6.5GB** |

The image will be significantly larger due to CUDA libraries. This is expected
for GPU workloads. Consider multi-stage builds to minimize unnecessary
build-time artifacts.

## Alternative: CPU-Only COLMAP with GPU gsplat

If the larger image size is a concern, a middle-ground approach is:

1. Keep COLMAP from `apt` but force CPU SIFT: `--SiftExtraction.use_gpu 0`
2. Only install CUDA PyTorch for the gsplat training stage
3. Use `nvidia/cuda:12.4.1-runtime` as base (needed for PyTorch CUDA)

This trades COLMAP performance (CPU SIFT is ~5x slower) for smaller image
size and simpler builds.

```dockerfile
FROM nvidia/cuda:12.4.1-runtime-ubuntu24.04

# Keep apt COLMAP (CPU-only is fine, just skip GPU SIFT)
RUN apt-get install -y colmap ffmpeg python3 ...

# Set env to force CPU-based feature extraction
ENV COLMAP_USE_GPU=0
```

The Rust code would need to respect `COLMAP_USE_GPU=0` and pass
`--SiftExtraction.use_gpu 0` to COLMAP commands.

## References

- [COLMAP Build Documentation](https://colmap.github.io/install.html)
- [COLMAP CMake Configuration](https://deepwiki.com/colmap/colmap/11.1-cmake-build-configuration)
- [COLMAP Headless Docker Issue #570](https://github.com/colmap/colmap/issues/570)
- [Azure Container Apps Serverless GPUs](https://learn.microsoft.com/en-us/azure/container-apps/gpu-serverless-overview)
- [PyTorch CUDA Wheels](https://download.pytorch.org/whl/)
- [NVIDIA CUDA Docker Images](https://hub.docker.com/r/nvidia/cuda)
