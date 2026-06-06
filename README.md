# RealESRGAN Auto

## Overview

RealESRGAN Auto is an automated video upscaling framework designed to simplify AI-powered video enhancement across NVIDIA, AMD, and Intel GPUs.

Supported backends:

- RealESRGAN (PyTorch CUDA)
- RealESRGAN NCNN Vulkan
- Real-CUGAN NCNN Vulkan

Key features:

- Automatic GPU detection
- Automatic backend selection
- Automatic model selection
- Multi-GPU support
- Automatic FPS detection
- Audio preservation
- Content-aware optimization
- Anime-specific enhancements
- Automatic dependency management
- Repair and validation modes

---

# Processing Workflow

Input Video
→ Frame Extraction
→ Content Selection
→ Backend Selection
→ Model Selection
→ GPU Distribution
→ Upscaling
→ Optional Sharpening
→ Video Reconstruction
→ Audio Merge
→ Final Output

---

# Supported GPU Types

## NVIDIA

Preferred backend:

- PyTorch CUDA

Examples:

- Tesla V100
- RTX 5000
- RTX 3090
- RTX 4090
- A100
- H100

## AMD

Preferred backend:

- NCNN Vulkan

Examples:

- RX 6800 XT
- RX 7800 XT
- RX 7900 XTX

## Intel

Preferred backend:

- NCNN Vulkan

Examples:

- Arc A770
- Arc A750
- Iris Xe

---

# Content Types

## Anime

Recommended for:

- Anime TV series
- Anime movies
- Japanese animation

Defaults:

- Model: realesr-animevideov3
- Outscale: 2x
- Sharpen: Medium

## Old Anime

Recommended for:

- DVD rips
- VHS captures
- 240p–480p anime

Defaults:

- Model: realesr-animevideov3
- Sharpen: Light

## Cartoons

Recommended for:

- Disney
- Cartoon Network
- Nickelodeon

Defaults:

- Model: realesr-animevideov3

## Live Action

Defaults:

- Model: RealESRGAN_x4plus

## Low Quality

Defaults:

- Reduced sharpening
- Conservative upscale settings

---

# Backend Decision Table

| GPU Type | Backend |
|-----------|----------|
| NVIDIA | PyTorch CUDA |
| AMD | NCNN Vulkan |
| Intel | NCNN Vulkan |
| CPU Only | NCNN Vulkan Fallback |

---

# Multi-GPU Support

Example:

GPU0 Tesla V100 32GB
GPU1 Tesla V100 32GB
GPU2 RTX 5000 16GB

Recommended:

GPU0 + GPU1

Reason:

- Highest VRAM
- Matching architecture
- Best throughput

---

# Installation

## Interactive

```bash
./setup_realesrgan_auto.sh --install --interactive
```

## Standard

```bash
./setup_realesrgan_auto.sh --install
```

## Repair

```bash
./setup_realesrgan_auto.sh --repair
```

## Uninstall

```bash
./setup_realesrgan_auto.sh --uninstall
```

---

# Usage Examples

## 360p Anime

```bash
./upscale_video_auto.sh \
  -i anime.mp4 \
  -o anime_upscaled.mkv \
  --content anime \
  --outscale 2 \
  --sharpen medium
```

## Old Anime DVD

```bash
./upscale_video_auto.sh \
  -i dvd.mkv \
  --content old-anime \
  --backend realcugan \
  --sharpen light
```

## Live Action

```bash
./upscale_video_auto.sh \
  -i movie.mkv \
  --content live
```

---

# Sharpening Guide

## Auto

Recommended default.

## Light

Use for:

- VHS
- Noisy sources
- Old DVDs

## Medium

Recommended for:

- 360p anime
- 480p anime

## Strong

Use only for:

- Extremely soft sources

Warning:

Strong sharpening may create halos around line art.

---

# Automatic Safety Checks

The scripts automatically:

- Validate command-line parameters
- Detect invalid backend selections
- Prevent unsafe cleanup operations
- Detect source resolution
- Detect FPS
- Detect GPU availability
- Validate CUDA and Vulkan availability
- Validate Python dependencies

---

# Dependency Management

Known-good package versions:

- torch 2.2.2
- torchvision 0.17.2
- torchaudio 2.2.2
- numpy 1.26.4
- opencv-python 4.8.1.78
- scipy 1.11.4
- scikit-image 0.21.0
- imageio 2.31.6
- tifffile 2023.7.10

---

# Troubleshooting

## NumPy Errors

Error:

A module compiled using NumPy 1.x cannot be run in NumPy 2.x

Fix:

```bash
./setup_realesrgan_auto.sh --repair
```

## CUDA Not Detected

```bash
nvidia-smi
```

```bash
python -c "import torch; print(torch.cuda.is_available())"
```

## Vulkan Not Detected

```bash
vulkaninfo --summary
```

## BasicSR Errors

Error:

functional_tensor missing

Run:

```bash
./setup_realesrgan_auto.sh --repair
```

---

# Hardware Recommendations

| GPU | Recommendation |
|------|---------------|
| V100 32GB | Best value/performance |
| RTX 5000 | Good secondary GPU |
| RTX 4090 | Excellent |
| A100 | Excellent |
| H100 | Excellent |

For mixed systems:

Preferred:

- V100 + V100

Supported:

- V100 + RTX 5000

---

# Roadmap

Planned features:

- Waifu2x support
- Video2X support
- Benchmark mode
- Dynamic GPU balancing
- Docker support
- Podman support
- REST API
- Web UI
- Distributed processing

---

# License

MIT License
