# Minimal GPU environment check for Azure Container Apps
#
# Validates: nvidia-smi, CUDA libraries, basic GPU compute
# No application code or ML frameworks — just shell + lightweight Python.
#
# Build:  docker build --build-arg CUDA_VERSION=12.6.3 -t gpu-check:latest .
# Run:    docker run --rm --gpus all gpu-check:latest

ARG CUDA_VERSION=12.6.3
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive

# NVIDIA env vars — enable GPU discovery when host has a GPU.
# On CPU-only hosts these are harmless; nvidia-smi simply won't find a device.
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY check-gpu.sh /usr/local/bin/check-gpu.sh
RUN chmod +x /usr/local/bin/check-gpu.sh

ENTRYPOINT ["/usr/local/bin/check-gpu.sh"]
