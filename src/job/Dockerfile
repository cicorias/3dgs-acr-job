# 3DGS Processor — CUDA-enabled for Azure Container Apps Serverless GPU
#
# Based on the upstream Dockerfile from Azure-Samples/3DGS-accelerator
# with modifications for headless GPU (no OpenGL/X11) on Container Apps.
#
# Key changes from upstream:
#   - nvidia/cuda runtime base image (provides CUDA libs for gsplat)
#   - PyTorch with CUDA (cu124) instead of CPU-only
#   - COLMAP from apt (CPU SIFT) — works headless without OpenGL context
#   - NVIDIA env vars for Container Apps GPU discovery
#
# Build context: the 3DGS-accelerator source repo
#   git clone https://github.com/Azure-Samples/3DGS-accelerator.git
#   docker build -f /path/to/this/Dockerfile -t 3dgs-processor-gpu:latest .
#
# Build args:
#   CUDA_VERSION  — CUDA toolkit version (default: 12.6.3)

ARG CUDA_VERSION=12.6.3

# ============================================================================
# Stage 1: Rust build
# ============================================================================
FROM rust:1.93-bookworm AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY src ./src

RUN cargo build --release --locked && \
    strip target/release/3dgs-processor

# ============================================================================
# Stage 2: Python environment with CUDA PyTorch + gsplat
# ============================================================================
FROM python:3.12-slim-bookworm AS python-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# CUDA-enabled PyTorch for GPU training with gsplat
RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cu124 && \
    pip install --no-cache-dir \
    gsplat \
    numpy

# ============================================================================
# Stage 3: CUDA runtime with COLMAP + FFmpeg + Blobfuse2
# ============================================================================
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ARG CUDA_VERSION
ENV DEBIAN_FRONTEND=noninteractive
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

WORKDIR /app

RUN apt-get update && \
    ARCH=$(dpkg --print-architecture) && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-noble-prod noble main" | \
        tee /etc/apt/sources.list.d/microsoft.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        colmap \
        ffmpeg \
        python3 \
        python3-venv \
        libpython3.12 \
        fuse3 \
        libfuse3-3 && \
    if [ "$ARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends blobfuse2 && \
        blobfuse2 --version > /dev/null; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    ffmpeg -version > /dev/null && \
    colmap help > /dev/null 2>&1

# Wrap colmap to force CPU-based SIFT (apt COLMAP needs OpenGL for GPU SIFT,
# which is unavailable on serverless Container Apps).
RUN COLMAP_PATH=$(which colmap) && \
    mv "$COLMAP_PATH" "${COLMAP_PATH}.real" && \
    printf '#!/bin/bash\n\
REAL_COLMAP="$(dirname "$0")/colmap.real"\n\
if [ "${COLMAP_USE_GPU:-0}" = "0" ]; then\n\
  ARGS=()\n\
  SKIP_NEXT=false\n\
  for arg in "$@"; do\n\
    if [ "$SKIP_NEXT" = true ]; then SKIP_NEXT=false; continue; fi\n\
    case "$arg" in\n\
      --SiftExtraction.use_gpu|--SiftMatching.use_gpu) SKIP_NEXT=true; continue ;;\n\
      --SiftExtraction.use_gpu=*|--SiftMatching.use_gpu=*) continue ;;\n\
      *) ARGS+=("$arg") ;;\n\
    esac\n\
  done\n\
  case "${1:-}" in\n\
    feature_extractor)\n\
      exec "$REAL_COLMAP" "${ARGS[@]}" --SiftExtraction.use_gpu 0 ;;\n\
    exhaustive_matcher|sequential_matcher|vocab_tree_matcher|spatial_matcher|transitive_matcher)\n\
      exec "$REAL_COLMAP" "${ARGS[@]}" --SiftMatching.use_gpu 0 ;;\n\
    *)\n\
      exec "$REAL_COLMAP" "${ARGS[@]}" ;;\n\
  esac\n\
else\n\
  exec "$REAL_COLMAP" "$@"\n\
fi\n' > "$COLMAP_PATH" && \
    chmod +x "$COLMAP_PATH"

COPY --from=python-builder /opt/venv /opt/venv

RUN cd /opt/venv/bin && \
    rm -f python python3 python3.12 && \
    ln -s /usr/bin/python3.12 python3.12 && \
    ln -s python3.12 python3 && \
    ln -s python3 python && \
    /opt/venv/bin/python --version

COPY --from=builder /build/target/release/3dgs-processor /usr/local/bin/3dgs-processor

COPY scripts/gsplat_train.py /app/scripts/gsplat_train.py
COPY scripts/mount-azure.sh /usr/local/bin/mount-azure.sh
COPY config.example.yaml /config/config.example.yaml

RUN mkdir -p /config /tmp/3dgs-work /tmp/blobfuse-cache /tmp/blobfuse-configs && \
    chmod +x /usr/local/bin/mount-azure.sh /usr/local/bin/3dgs-processor

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LOG_LEVEL=info \
    TEMP_PATH=/tmp/3dgs-work \
    CONFIG_PATH=/config/config.yaml \
    UPLOAD_STABILITY_TIMEOUT_SECS=60 \
    MAX_RETRIES=3 \
    POLL_INTERVAL_SECS=10 \
    BACKEND=gsplat \
    GSPLAT_PYTHON=/opt/venv/bin/python \
    GSPLAT_BIN=/app/scripts/gsplat_train.py \
    RETENTION_DAYS=30 \
    QT_QPA_PLATFORM=offscreen \
    COLMAP_USE_GPU=0

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD pgrep -f 3dgs-processor || exit 1

ENTRYPOINT ["/usr/local/bin/3dgs-processor"]
