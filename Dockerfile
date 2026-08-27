# 1. Base Image (adjust tag as needed for your CUDA/PyTorch base or ComfyUI base)
FROM pytorch/pytorch:2.2.0-cuda12.1-cudnn8-runtime

# 2. Install essential system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# 3. Create model directories & download rife_v4.26 checkpoint
RUN mkdir -p /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife \
    && mkdir -p /ComfyUI/models/vfi/rife

RUN curl -L -f -o /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
    https://huggingface.co/Comfy-Org/frame_interpolation/resolve/main/frame_interpolation/rife_v4.26.safetensors

RUN ln -s /ComfyUI/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife_v4.26.safetensors \
    /ComfyUI/models/vfi/rife/rife_v4.26.safetensors

# 4. Copy project files & configure entrypoint
WORKDIR /app
COPY . .

# Fix potential Windows CRLF endings and set execution permissions
RUN sed -i 's/\r$//' /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
