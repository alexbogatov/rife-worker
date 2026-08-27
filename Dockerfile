# 1. Lean Debian Python base
FROM python:3.10-slim-bullseye

# Prevent interactive prompts & python bytecode generation
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# 2. Install essential system dependencies (includes xz-utils for Node.js extraction)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ffmpeg \
    ca-certificates \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# 3. Install standalone lightweight Node.js (v20) directly to /usr/local
RUN curl -fsSL https://nodejs.org/dist/v20.11.1/node-v20.11.1-linux-x64.tar.xz | tar -xJf - -C /usr/local --strip-components=1 --no-same-owner \
    && npm install -g npm@latest

# 4. Install CUDA-enabled PyTorch & prune unused distributed libraries (~2.5 GB saved)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cu121 \
    && find /usr/local/lib/python3.10/site-packages/torch/lib/ \
       -name "libnccl*" -o \
       -name "libcufft*" -o \
       -name "libcurand*" -o \
       -name "libcusparse*" \
       -delete

# 5. Clone ComfyUI Core & only the required custom nodes for RIFE
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /ComfyUI \
    && pip install --no-cache-dir -r /ComfyUI/requirements.txt \
    && git clone --depth 1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation \
    && pip install --no-cache-dir -r /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/requirements.txt \
    && git clone --depth 1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git /ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite \
    && pip install --no-cache-dir -r /ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt \
    && find /root/.cache /tmp -mindepth 1 -delete

# 6. Bake RIFE v4.26 Model Weights (~22MB)
RUN mkdir -p /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife \
    && mkdir -p /ComfyUI/models/vfi/rife \
    && curl -L -f -o /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
       https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26.safetensors \
    && ln -s /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
       /ComfyUI/models/vfi/rife/rife_v4.26.safetensors

# 7. Setup Application & Production NPM dependencies
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy entrypoint and application files
COPY . .

# Fix Windows line breaks and set permissions
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]