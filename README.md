# Stable Diffusion Multi-GPU Launcher

A production-ready shell script that installs, configures, and runs
[AUTOMATIC1111 Stable Diffusion WebUI](https://github.com/AUTOMATIC1111/stable-diffusion-webui)
across any combination of NVIDIA, AMD, and Intel GPUs in a single machine.

Each GPU gets its own independent WebUI instance with architecture-optimised
flags. A FastAPI smart router sits in front of all instances and routes each
generation request to the best available GPU based on resolution, free VRAM,
and queue depth.

The project also includes a full **video upscaling pipeline** for old and
low-resolution animation, with support for Real-ESRGAN, Real-CUGAN, and
waifu2x backends.

---

## Table of Contents

- [Features](#features)
- [Architecture](#architecture)
- [GPU Support](#gpu-support)
- [Mixed GPU Combinations](#mixed-gpu-combinations)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage — Stable Diffusion](#usage--stable-diffusion)
- [Smart Router](#smart-router)
- [Ports Reference](#ports-reference)
- [Configuration](#configuration)
- [Video Upscaling](#video-upscaling)
- [Progress Watcher](#progress-watcher)
- [Troubleshooting](#troubleshooting)
- [File Reference](#file-reference)
- [Contributing](#contributing)
- [License](#license)

---

## Features

### Stable Diffusion WebUI
- **Auto-detects all GPUs** — NVIDIA via `nvidia-smi`, AMD via `rocminfo`,
  Intel via `xpu-smi`, with strict `lspci` fallbacks that filter out server
  BMC chips (ASPEED) and non-GPU PCI devices
- **One WebUI instance per GPU** — full parallel throughput; three GPUs means
  three simultaneous independent generation queues
- **Architecture-aware launch flags** — V100 gets `--precision full --no-half`
  (FP16 is broken on Volta/Linux), RTX gets `--xformers`, Pascal gets safe
  defaults, AMD and Intel get stable FP32 mode
- **Pinned compatible torch versions** — resolves the
  `torchaudio X requires torch==Y but you have Z` conflict by installing
  torch, torchvision, and torchaudio as a verified matched set
- **Smart GPU router** — FastAPI proxy on port 8080 that inspects each
  generation request and routes to the optimal GPU
- **VRAM-aware routing** — queries `nvidia-smi` in real time before each
  request; GPUs without enough free VRAM are skipped
- **nginx integration** — optional reverse proxy on port 8888 with WebSocket
  support for SD live preview
- **Clean uninstall** — `--uninstall` removes everything with a confirmation
  prompt; drivers and system Python are never touched

### Video Upscaling
- **Multiple backends** — PyTorch Real-ESRGAN, NCNN Real-ESRGAN, Real-CUGAN,
  and waifu2x (best for cel animation)
- **Denoise before upscaling** — hqdn3d applied at source resolution for
  best noise removal; especially effective on 360p/480p sources
- **360p auto-detection** — automatically adjusts denoise strength, caps
  outscale at 2x, and recommends waifu2x cunet for low-res animation
- **Content-aware settings** — `--content old-anime` selects appropriate
  model, denoise strength, and sharpening automatically
- **Multi-GPU frame splitting** — splits frames across GPUs for parallel processing
- **Progress watcher** — real-time progress display with ETA, plus
  post-processing menu for sharpening, denoising, and reassembly

---

## Architecture

```
Browser / API Client
        |
   nginx :8888          (optional public-facing proxy)
        |
   Smart Router :8080   (GPU selection, VRAM check, queue depth)
        |
   +----+----+----+
   |         |         |
:7860     :7861     :7862
GPU 0     GPU 1     GPU 2
V100      RTX       V100
32GB     5000      32GB
          16GB
```

### Routing Logic

For every `POST /sdapi/v1/txt2img` or `POST /sdapi/v1/img2img` request:

1. Parse `width`, `height`, `batch_size` from the JSON body
2. Estimate VRAM needed: `4096 MB base + (width x height x batch x 4 bytes)`
3. Query `nvidia-smi` for real-time free VRAM on every NVIDIA GPU
4. Check liveness of all WebUI instances in parallel (2s timeout)
5. Filter out offline instances and GPUs with insufficient free VRAM
6. Score remaining candidates:
   - High-res bonus: prefer GPU with >= 20 GB for requests >= 1024px
   - Queue depth: fewer active requests is better
   - Free VRAM: more headroom is better
7. Forward the request to the winner; track queue depth with a counter

---

## GPU Support

### NVIDIA

| Architecture | GPUs | Compute | Precision | xformers | Notes |
|---|---|---|---|---|---|
| Blackwell | RTX 5xxx | 10.x | FP16 | Yes | Latest consumer gen |
| Hopper | H100 | 9.0 | FP16/FP8 | Yes | Datacenter |
| Ada Lovelace | RTX 4xxx | 8.9 | FP16/FP8 | Yes | Fastest consumer |
| Ampere | RTX 3xxx, A100, A10 | 8.x | FP16/BF16 | Yes | Best SDXL cards |
| Turing | RTX 2xxx, Quadro RTX, T4 | 7.5 | FP16 | Yes | xformers very effective |
| Volta | V100 | 7.0 | **FP32 forced** | No | FP16 broken on Linux |
| Pascal | GTX 10xx, P100, P40 | 6.x | FP16 | No | No xformers |
| Maxwell | GTX 9xx | 5.x | **FP32 forced** | No | Last resort |

> **Why is FP16 forced off for V100?**
> The NVIDIA V100 under Linux produces black or corrupted images when SD runs
> in FP16 mode. This is a driver-level issue, not a software bug. The script
> automatically applies `--precision full --no-half --no-half-vae` for any
> GPU with compute capability 7.0.

### AMD

| Architecture | GPUs | ROCm Support | Notes |
|---|---|---|---|
| RDNA3 | RX 7xxx | Excellent (ROCm 6.x) | Best AMD option |
| RDNA2 | RX 6xxx | Good (ROCm 5.x/6.x) | Stable |
| Vega20 | Radeon VII, MI50/60 | Fair | May need older ROCm |
| Vega10 | RX Vega | Limited | ROCm 5.x recommended |

### Intel

| GPU | IPEX Support | Notes |
|---|---|---|
| Arc A770 (16GB) | Good | Best Intel option for SD |
| Arc A750 (8GB) | Good | Solid for SD 1.5 |
| Arc A380 (6GB) | Fair | 512x512 only |
| Ponte Vecchio | Good | Datacenter, FP16 capable |
| Iris Xe (integrated) | Not supported | Cannot run SD inference |

### CPU Fallback

If no GPU is detected, the script falls back to CPU inference with
`--use-cpu all --precision full --no-half`. Expect 2-10 minutes per
512x512 image. Useful for testing only.

---

## Mixed GPU Combinations

| Combination | PyTorch Build | Behaviour |
|---|---|---|
| NVIDIA only | CUDA (`cuXXX`) | Full support, xformers where applicable |
| AMD only | ROCm (`rocmX.Y`) | Full ROCm support |
| Intel only | XPU (IPEX) | Full IPEX support |
| NVIDIA + AMD | CUDA | AMD launched with HIP env vars; suboptimal but functional |
| NVIDIA + Intel | CUDA | Intel falls back to CPU mode |
| AMD + Intel | ROCm | Intel falls back to CPU mode |
| All three | CUDA | AMD: HIP env vars; Intel: CPU fallback |

---

## Requirements

| Requirement | Details |
|---|---|
| OS | Ubuntu 20.04, 22.04, or 24.04 |
| Python | 3.10 recommended (auto-installed if missing) |
| NVIDIA | Driver >= 450; CUDA 11.7+ |
| AMD | ROCm 5.x or 6.x |
| Intel | oneAPI / Level Zero runtime |
| Sudo | Required for apt installs and nginx config |
| Disk | ~20 GB for WebUI + models |
| RAM | 16 GB minimum; 32 GB recommended |

---

## Installation

### Step 1 — Clone this repo

```bash
git clone https://github.com/YOUR_USERNAME/stable-diffusion-multigpu.git
cd stable-diffusion-multigpu
chmod +x run_stablediffusion.sh
chmod +x upscale_video_auto.sh
chmod +x watch_progress.sh
```

Both `run_stablediffusion.sh` and `router_template.py` must be in the same
directory. The launcher locates the router template by looking next to itself
at runtime.

### Step 2 — Run the installer

```bash
./run_stablediffusion.sh --install
```

The installer will:

1. Detect all GPUs (NVIDIA, AMD, Intel) and print a summary
2. Install apt system dependencies (`build-essential`, `libgl1`, `bc`, etc.)
3. Detect or install Python 3.10
4. Clone AUTOMATIC1111 WebUI to `~/stable-diffusion-webui`
5. Pre-clone required repositories (CodeFormer, BLIP, GFPGAN, k-diffusion)
6. Create a Python virtualenv with `setuptools==68.0.0` pinned
7. Install the correct PyTorch build for your GPU vendor and driver version
8. Install xformers (NVIDIA Turing+ only)
9. Install CLIP from OpenAI's GitHub source
10. Write and configure the smart router

### Step 3 — Add a model

```bash
cp your_model.safetensors ~/stable-diffusion-webui/models/Stable-diffusion/
```

### Step 4 — Launch

```bash
./run_stablediffusion.sh
```

Open your browser at **http://localhost:8888** (nginx) or
**http://localhost:8080** (smart router direct).

---

## Usage — Stable Diffusion

```
./run_stablediffusion.sh [OPTION]

  (no option)   Launch all GPU instances + smart router
  --install     Full first-time setup
  --update      Pull latest WebUI commits + reinstall Python deps
  --stop        Gracefully stop all instances and the router
  --diag        Show GPU hardware, PyTorch, and router health report
  --uninstall   Remove everything installed by this script (with confirmation)
  --help        Show usage
```

### Examples

```bash
# Check GPU detection and flags
./run_stablediffusion.sh --diag

# Pull latest WebUI and reinstall deps
./run_stablediffusion.sh --update

# Watch all GPU logs
tail -f ~/sd-logs/gpu*.log ~/sd-logs/router.log

# Check router fleet status
curl http://localhost:8080/router/status | python3 -m json.tool
```

---

## Smart Router

The smart router (`~/sd-router/router.py`) is generated from
`router_template.py` at install time with the GPU fleet JSON injected
automatically.

### Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/sdapi/v1/txt2img` | POST | Smart-routed text-to-image |
| `/sdapi/v1/img2img` | POST | Smart-routed image-to-image |
| `/router/status` | GET | Real-time fleet JSON |
| `/*` | ANY | Pass-through to first available instance |

### Routing Examples (V100 x2 + RTX 5000 setup)

| Request | Routed to | Reason |
|---|---|---|
| 512x512, SD 1.5 | RTX 5000 :7861 | Fastest with xformers + FP16 |
| 1024x1024, SDXL | V100 :7860 or :7862 | 32GB preferred for high-res |
| 2048x2048, SDXL | V100 only | RTX 5000 filtered (16GB < needed) |
| batch_size=4 | Least-queued V100 | Queue-depth tiebreaker |
| RTX 5000 busy | Next available V100 | Fallback to online GPU |

---

## Ports Reference

| Port | Service | Notes |
|---|---|---|
| 7860 | GPU 0 direct WebUI | Bypass router; use for testing |
| 7861 | GPU 1 direct WebUI | Bypass router |
| 7862 | GPU 2 direct WebUI | Bypass router |
| 8080 | Smart router | Use this for API calls |
| 8888 | nginx | Public-facing proxy to router |

---

## Configuration

Edit the top of `run_stablediffusion.sh`:

```bash
WEBUI_DIR="$HOME/stable-diffusion-webui"
VENV_DIR="$WEBUI_DIR/venv"
LOG_DIR="$HOME/sd-logs"
ROUTER_DIR="$HOME/sd-router"
BASE_PORT=7860          # GPU 0 port; increments per GPU
ROUTER_PORT=8080        # Smart router port
NGINX_PORT=8888         # nginx public port
```

---

## Video Upscaling

The `upscale_video_auto.sh` script provides a full video upscaling pipeline
optimised for old and low-resolution animation.

### Backends

| Backend | Best For | Notes |
|---|---|---|
| `pytorch` | Best quality | Needs CUDA venv, uses Real-ESRGAN |
| `ncnn` | Fast, any GPU | Real-ESRGAN NCNN Vulkan |
| `realcugan` | Animation | Real-CUGAN, good line preservation |
| `waifu2x` | Cel animation | Best for flat colors and hard edges |
| `auto` | Auto-detect | Picks first installed backend |

### Content Types

| Content | Denoise | Model | Notes |
|---|---|---|---|
| `anime` | mild | realesr-animevideov3 | Standard animation |
| `old-anime` | moderate | waifu2x cunet | 360p/480p cel animation |
| `cartoon` | mild | realesr-animevideov3 | Western animation |
| `live` | none | RealESRGAN_x4plus | Real-world footage |
| `low-quality` | strong | realesr-animevideov3 | Heavy noise/artifacts |
| `restore` | moderate | realesr-animevideov3 | Minimal upscale, cleanup focus |

### Denoise Levels

Denoise is applied **before upscaling** at source resolution — this is the key
difference from naive post-upscale denoising. At 360p, noise pixels are small
and distinct from real detail, making them much easier to remove cleanly.
After upscaling, the same noise becomes large blotchy patches that are much
harder to separate from genuine content.

| Level | hqdn3d filter | Use when |
|---|---|---|
| `none` | disabled | Clean source, HD resolution |
| `mild` | `2:1:3:2` | Light compression artifacts |
| `moderate` | `4:3:6:4` | Visible grain, 480p broadcast |
| `strong` | `6:5:9:6` | Heavy VHS grain |
| `vheavy` | `9:7:12:8` | Severe noise/dropout |
| `auto` | content-based | Recommended — set per content type |

### Sharpening

Applied **after upscaling** during final encode using FFmpeg `unsharp`:

| Level | Strength | Use when |
|---|---|---|
| `auto` | content-based | Recommended |
| `0.0` | disabled | Over-processed source |
| `0.8` | subtle | Old animation, avoid ringing |
| `1.0` | moderate | Standard animation |
| `1.2` | strong | Live action |

### Usage Examples

```bash
# Recommended for 360p old animation (auto-detects resolution)
./upscale_video_auto.sh \
  -i ~/video_upscale/input.mp4 \
  -o ~/video_upscale/output.mkv \
  --backend waifu2x \
  --content old-anime

# Explicit denoise and sharpen control
./upscale_video_auto.sh \
  -i input.mp4 \
  -o output.mkv \
  --backend waifu2x \
  --content old-anime \
  --denoise-strength moderate \
  --sharpen-strength 0.8

# Real-CUGAN with multiple GPUs
./upscale_video_auto.sh \
  -i input.mp4 \
  -o output.mkv \
  --backend realcugan \
  --gpus 0,1,2 \
  --content anime

# Resume an interrupted job
./upscale_video_auto.sh \
  -i input.mp4 \
  -o output.mkv \
  --resume

# Clean previous run and start fresh
./upscale_video_auto.sh \
  -i input.mp4 \
  -o output.mkv \
  --clean
```

### Full Option Reference

```
-i, --input FILE
-o, --output FILE
--config FILE
--workdir DIR                 Default: ~/video_upscale
--backend auto|pytorch|ncnn|realcugan|waifu2x
--gpus 0,1,2
--gpu-count N
--content anime|old-anime|cartoon|live|low-quality|restore
--model auto|realesr-animevideov3|RealESRGAN_x4plus_anime_6B|cunet|...
--outscale N                  Scale factor (default: 2; capped at 2 for 360p)
--tile N                      Tile size for VRAM management (default: 1200)
--frame-format png|jpg
--container mkv|mp4
--cq N                        Encode quality 0-51, lower=better (default: 18)
--denoise-strength none|mild|moderate|strong|vheavy|auto
--sharpen-strength FLOAT       e.g. 0.8 (or auto)
--clean                       Delete previous temp files for this run
--clean-all                   Delete all frames, audio, temp files
--delete-temp                 Remove temp files after successful output
--resume                      Skip already-completed steps
--force                       Skip cleanup confirmation prompts
--interactive                 Show content-type selection menu
```

---

## Progress Watcher

`watch_progress.sh` monitors a running upscale job and shows a post-processing
menu when it finishes.

```bash
./watch_progress.sh
```

While running, it displays:

```
======================================================
  Upscaling Progress            20:08:45
======================================================

  Input :  /home/user/video_upscale/input_frames
  Output:  /home/user/video_upscale/output_frames_part0

  Frames:  842 / 4787
  [#######---------------------------------] 17%

  Elapsed: 6m 32s
  Rate:    129 frames/min
  ETA:     26m 10s
======================================================
```

When the job finishes, it opens an interactive post-processing menu:

```
  1) Sharpen with FFmpeg          (quick, no re-processing)
  2) Re-run realcugan             (conservative mode, less puffy)
  3) Re-run realcugan             (models-nose, no-denoise architecture)
  4) Run waifu2x                  (best for cel animation)
  5) Reassemble video + audio     (make final .mp4)
  6) Exit
```

The watcher auto-detects the input/output folders by reading the running
process arguments, so it always watches the correct directories without
manual configuration.

---

## Troubleshooting

### `torchaudio requires torch==X but you have torch Y`

The script fixes this by installing torch, torchvision, and torchaudio as a
pinned matched set. If it recurs after a manual install:

```bash
./run_stablediffusion.sh --update
```

### Black or corrupted images on V100

V100 (compute 7.0) produces black images with FP16 on Linux. The script
automatically applies `--precision full --no-half --no-half-vae`. If launching
manually, always include these flags.

### `INTERACTIVE: unbound variable` in upscale_video_auto.sh

Fixed in v2.0 — `INTERACTIVE=0` is now set at the top of the script before
any function calls.

### `Failed to build clip` / `AttributeError: install_layout`

`setuptools >= 69` broke the `clip` PyPI package. Fixes applied by the script:
- setuptools pinned to `68.0.0`
- CLIP installed from OpenAI's GitHub source
- `--no-build-isolation` passed to use the pinned setuptools

### `bc: command not found`

```bash
sudo apt install -y bc
```

Installed automatically during `--install`.

### GPU detected as wrong vendor

The `lspci` fallback now filters out:
- NVIDIA chips on AMD-owned PCI bus segments
- ASPEED server BMC chips
- Non-GPU AMD devices (audio, USB, NVMe)

### `CUDA available: False` after install

| Driver | CUDA tag | torch |
|---|---|---|
| >= 560 | cu124 | 2.6.0 |
| >= 525 | cu121 | 2.5.1 |
| >= 520 | cu118 | 2.3.1 |
| >= 450 | cu117 | 2.0.1 |

```bash
./run_stablediffusion.sh --diag   # check detected tag
./run_stablediffusion.sh --update # reinstall correct version
```

### Video looks "puffy" after upscaling

For animation, avoid Real-ESRGAN x4plus and 4x-UltraSharp — they add
photographic texture to flat color fills. Use instead:

```bash
# waifu2x cunet — best for cel animation
./upscale_video_auto.sh -i input.mp4 -o output.mkv \
  --backend waifu2x --content old-anime

# Or apply FFmpeg sharpening to existing output
ffmpeg -i upscaled.mp4 \
  -vf "unsharp=lx=3:ly=3:la=1.2:cx=3:cy=3:ca=0.5" \
  -c:v libx264 -crf 16 sharpened.mp4
```

### Video has grain/noise after upscaling

Denoise before upscaling for best results:

```bash
./upscale_video_auto.sh -i input.mp4 -o output.mkv \
  --content old-anime \
  --denoise-strength moderate
```

Or apply hqdn3d to an existing video:

```bash
ffmpeg -i upscaled.mp4 \
  -vf "hqdn3d=4:3:6:4" \
  -c:v libx264 -crf 16 denoised.mp4
```

### AMD GPU not visible after ROCm install

```bash
sudo usermod -aG render,video $USER
# Log out and back in
rocminfo   # verify GPU appears
```

### nginx not accessible from outside VM

For a local VM, use SSH port forwarding (no firewall changes needed):

```bash
# Run on your local machine
ssh -L 8888:localhost:8888 user@VM_IP
# Then open http://localhost:8888
```

Or open the port in your VM software's NAT port forwarding settings.

---

## File Reference

```
stable-diffusion-multigpu/
├── run_stablediffusion.sh    # SD WebUI multi-GPU launcher (27 sections)
├── router_template.py        # FastAPI smart router template
├── upscale_video_auto.sh     # Video upscaling pipeline (v2.0)
├── watch_progress.sh         # Upscaling progress watcher + post-processing menu
├── README.md                 # This file
├── .gitignore                # Excludes generated dirs and venvs
└── LICENSE                   # MIT
```

Runtime directories (not tracked by git):

```
~/stable-diffusion-webui/     # AUTOMATIC1111 WebUI + models
~/sd-router/                  # Generated router.py + its venv
~/sd-logs/                    # gpu0.log, gpu1.log, router.log
~/video_upscale/              # Working directory for video upscaling
  input_frames/               # Extracted source frames
  output_frames_*/            # Upscaled frames per GPU/backend
  original_audio.mka          # Preserved audio track
  upscaled_video.*            # Intermediate encoded video
```

---

## Contributing

1. Test on Ubuntu 22.04 or 24.04 before submitting
2. Run `bash -n run_stablediffusion.sh` and `bash -n upscale_video_auto.sh`
3. Run `python3 -m py_compile router_template.py`
4. Keep bash comments in plain ASCII — Unicode chars cause `bash -n` errors
5. If adding a GPU architecture, update both `get_arch_label()` and
   `get_launch_flags()` in `run_stablediffusion.sh`

### Known Limitations

- Mixed NVIDIA + AMD requires CUDA PyTorch for both; pure ROCm needs a
  dedicated machine
- Intel IPEX support is still maturing; expect rough edges on non-Arc cards
- Smart router queue depth resets to 0 if the router process restarts
- waifu2x does not support outscale > 2 natively; use two 2x passes for 4x

---

## License

MIT License — see [LICENSE](LICENSE) for details.

Not affiliated with AUTOMATIC1111, Stability AI, NVIDIA, AMD, or Intel.
