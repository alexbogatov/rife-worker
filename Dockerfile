# 1. Lean Debian Python base
FROM python:3.10-slim-bullseye

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# 2. Install essential system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ffmpeg \
    ca-certificates \
    build-essential \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# 3. Install official Node.js (v20) via NodeSource cleanly
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 4. Install CUDA-enabled PyTorch & prune unused distributed libraries (~2.5 GB saved)
RUN pip install --no-cache-dir --upgrade pip setuptools wheel \
    && pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cu121 \
    && find /usr/local/lib/python3.10/site-packages/torch/lib/ \
       -name "libnccl*" -o \
       -name "libcufft*" -o \
       -name "libcurand*" -o \
       -name "libcusparse*" \
       -delete

# 5. Clone ComfyUI Core and install dependencies
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI \
    && pip install --no-cache-dir --prefer-binary -r /ComfyUI/requirements.txt

# 6. Pre-install all Video & Interpolation Python dependencies explicitly
RUN pip install --no-cache-dir --prefer-binary \
    opencv-python-headless \
    imageio-ffmpeg \
    moviepy \
    einops \
    scipy \
    timm \
    kornia \
    av

# 7. Clone Custom Nodes cleanly
RUN git clone --depth 1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation
RUN git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite
RUN rm -rf /root/.cache /tmp/* /var/tmp/*

# 8. Bake RIFE v4.26 Model Weights (~22MB)
RUN mkdir -p /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife \
    && mkdir -p /ComfyUI/models/vfi/rife \
    && curl -L -f -o /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
       https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26.safetensors \
    && ln -s /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
       /ComfyUI/models/vfi/rife/rife_v4.26.safetensors

# 9. Setup Application & Install Dependencies
WORKDIR /app

# Install standard production dependencies explicitly to bypass lockfile/cache errors
RUN npm init -y && npm install --no-audit --no-fund \
    dotenv \
    ws \
    @aws-sdk/client-s3

# Copy application files
COPY . .

# Fix Windows line breaks and set permissions
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]