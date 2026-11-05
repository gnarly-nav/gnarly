# Dockerfile for gnarly textured mesh worker
# Builds a container with mvs-texturing (Waechter et al. 2014) to texture ARKit scene reconstruction meshes
# from captured keyframe photos with poses/intrinsics/depth.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libeigen3-dev \
    libpng-dev \
    libjpeg-dev \
    libtiff-dev \
    libgtest-dev \
    libtbb-dev \
    wget \
    unzip \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies for pipeline scripts
RUN pip3 install --no-cache-dir \
    numpy \
    Pillow \
    pygltflib

# Build mvs-texturing from source
WORKDIR /opt
RUN git clone https://github.com/nmoehrle/mvs-texturing.git && \
    cd mvs-texturing && \
    git checkout 7fa9e9cfd8e8a3eeade2f7a3f3f9ae4ff15c806f && \
    mkdir build && cd build && \
    cmake .. -DCMAKE_BUILD_TYPE=Release && \
    make -j$(nproc) && \
    cp apps/texrecon/texrecon /usr/local/bin/

# Copy pipeline scripts
WORKDIR /app
COPY pipeline/ /app/

# Default command runs the texturing pipeline
ENTRYPOINT ["python3", "/app/texture_zone.py"]
