# gsplat environment check — runs on Azure Container Apps GPU job
#
# Uses a PyTorch base image with CUDA + devel tools (nvcc needed for gsplat
# CUDA kernel compilation).  Dependencies installed via pip from pyproject.toml.
#
# Build:  docker build -t gsplat-check:latest .
# Run:    docker run --rm --gpus all gsplat-check:latest

FROM pytorch/pytorch:2.10.0-cuda12.6-cudnn9-devel

ENV DEBIAN_FRONTEND=noninteractive

# NVIDIA env vars — enable GPU discovery in Container Apps
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

WORKDIR /app

# Install dependencies via pip (no uv required)
COPY pyproject.toml ./
RUN pip install --no-cache-dir --break-system-packages .

COPY main.py ./

ENTRYPOINT ["python", "main.py"]
