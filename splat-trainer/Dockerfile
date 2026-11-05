# Gaussian Splat Training Worker
# Based on nerfstudio with gsplat and DN-Splatter depth supervision
# Requires NVIDIA GPU with CUDA support

FROM nvidia/cuda:12.1.1-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV CUDA_HOME=/usr/local/cuda

# Install system dependencies
RUN apt-get update && apt-get install -y \
    python3.10 \
    python3-pip \
    python3-dev \
    git \
    wget \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    && rm -rf /var/lib/apt/lists/*

# Set up Python
RUN ln -s /usr/bin/python3.10 /usr/bin/python && \
    python -m pip install --upgrade pip setuptools wheel

# Install PyTorch with CUDA 12.1 support
RUN pip install torch==2.1.0 torchvision==0.16.0 --index-url https://download.pytorch.org/whl/cu121

# Install nerfstudio and gsplat
RUN pip install nerfstudio gsplat

# Install additional dependencies for depth supervision and compression
RUN pip install \
    opencv-python-headless \
    Pillow \
    numpy \
    scipy \
    open3d \
    plyfile \
    tyro \
    rich \
    tensorboard

# Install SPZ compression library (Niantic)
RUN pip install git+https://github.com/nianticlabs/spz.git

# Install tiny-cuda-nn for instant-ngp style hash encoding (optional, for speed)
RUN pip install git+https://github.com/NVlabs/tiny-cuda-nn/#subdirectory=bindings/torch

WORKDIR /workspace

# Copy training scripts
COPY train.py /workspace/
COPY compress.py /workspace/
COPY config.yml /workspace/

# Environment variables for optimal training
ENV TCNN_CUDA_ARCHITECTURES=80;86;89;90
ENV TORCH_CUDA_ARCH_LIST="8.0;8.6;8.9;9.0"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import torch; assert torch.cuda.is_available()" || exit 1

CMD ["python", "train.py"]
