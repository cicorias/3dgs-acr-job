# Minimal GPU environment check for Azure Container Apps
#
# Validates: nvidia-smi, CUDA, PyTorch+CUDA, gsplat, ffmpeg, colmap
# No application code — just detection and exit.
#
# Build:  docker build -t 3dgs-gpu-check:latest .
# Run:    docker run --rm 3dgs-gpu-check:latest

ARG CUDA_VERSION=12.6.3
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

# NVIDIA env vars — enable GPU discovery when host has a GPU.
# On CPU-only hosts these are harmless; nvidia-smi simply won't find a device.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# Install runtime tools the 3DGS pipeline needs
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        ffmpeg \
        colmap \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install PyTorch (CUDA) + gsplat into a venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir \
        torch torchvision --index-url https://download.pytorch.org/whl/cu124 && \
    pip install --no-cache-dir gsplat numpy

# The check script
COPY check-gpu.sh /usr/local/bin/check-gpu.sh
RUN chmod +x /usr/local/bin/check-gpu.sh

ENTRYPOINT ["/usr/local/bin/check-gpu.sh"]

