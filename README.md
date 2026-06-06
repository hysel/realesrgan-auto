# RealESRGAN Auto Package

## Files

- `setup_realesrgan_auto.sh` — installer/manager.
- `upscale_video_auto.sh` — video upscale workflow.
- `realesrgan_auto.conf` — generated config.

## Install

```bash
chmod +x setup_realesrgan_auto.sh upscale_video_auto.sh
./setup_realesrgan_auto.sh --install
```

## Check status

```bash
./setup_realesrgan_auto.sh --status
```

## Install Real-CUGAN

```bash
./setup_realesrgan_auto.sh --backend realcugan
```

## Upscale video

```bash
./upscale_video_auto.sh --input input.mkv --clean
```

## Use 2 GPUs

```bash
./upscale_video_auto.sh --input input.mkv --gpus 0,1 --clean
```

## Use Real-CUGAN

```bash
./upscale_video_auto.sh --input input.mkv --backend realcugan --outscale 2 --clean
```

## Cleanup modes

- `--clean`: deletes previous split/output temp folders.
- `--clean-all`: deletes all extracted frames/audio/temp output first.
- `--delete-temp`: deletes temp files after successful output.
- `--resume`: keeps existing files and continues.

## Uninstall

```bash
./setup_realesrgan_auto.sh --uninstall
```

With optional OS package removal:

```bash
./setup_realesrgan_auto.sh --uninstall --remove-packages
```

## Review notes

This package is Ubuntu/Debian focused. NVIDIA defaults to PyTorch CUDA. AMD/Intel default to NCNN Vulkan. The upscale script auto-detects FPS and restores original audio.


## Interactive Content Type Wizard

Both scripts support an interactive mode that asks what kind of source video you are working with.

```bash
./setup_realesrgan_auto.sh --install --interactive
```

or during upscaling:

```bash
./upscale_video_auto.sh --input input.mkv --interactive
```

The wizard asks for the content type and automatically recommends the correct model and scale.

| Content Type | Recommended Backend | Recommended Model | Outscale | Notes |
|---|---|---|---|---|
| Anime / animation | NVIDIA: PyTorch, AMD/Intel: NCNN | `realesr-animevideov3` | 2 | Best default for most anime video |
| Old anime / soft source | NVIDIA: PyTorch, AMD/Intel: NCNN | `realesr-animevideov3` | 2 | Less aggressive than `RealESRGAN_x4plus_anime_6B` |
| Cartoon / western animation | NVIDIA: PyTorch, AMD/Intel: NCNN | `realesr-animevideov3` | 2 | Good for clean line art |
| Live action / real video | NVIDIA: PyTorch, AMD/Intel: NCNN | `RealESRGAN_x4plus` | 2 | Better for real-world footage |
| Low-quality / noisy source | NVIDIA: PyTorch, AMD/Intel: NCNN | `realesr-animevideov3` | 1 | Avoids overprocessing |
| Restore only | NVIDIA: PyTorch, AMD/Intel: NCNN | `realesr-animevideov3` | 1 | Enhancement without heavy resizing |
| Real-CUGAN mode | Real-CUGAN NCNN Vulkan | Real-CUGAN internal model | 2 | Useful when RealESRGAN looks puffy/smudged |

## Non-Interactive Content Selection

You can skip the wizard and specify the content type directly:

```bash
./upscale_video_auto.sh \
  --input anime.mkv \
  --content anime
```

Other options:

```bash
--content old-anime
--content cartoon
--content live
--content low-quality
--content restore
```

Example for live action:

```bash
./upscale_video_auto.sh \
  --input movie.mkv \
  --content live \
  --delete-temp
```

Example for a low-quality anime source:

```bash
./upscale_video_auto.sh \
  --input old_anime.mkv \
  --content low-quality \
  --delete-temp
```

## Backend and Content Type Logic

The scripts make two separate decisions:

1. **Hardware/backend decision**
   - NVIDIA -> PyTorch CUDA
   - AMD -> NCNN Vulkan
   - Intel -> NCNN Vulkan
   - Real-CUGAN requested -> Real-CUGAN NCNN Vulkan

2. **Content/model decision**
   - Anime/cartoon -> `realesr-animevideov3`
   - Live action -> `RealESRGAN_x4plus`
   - Low-quality/restore -> gentler settings using lower outscale

This prevents the user from needing to know CUDA, Vulkan, PyTorch, or model details.


## Decision Report and Version Selection

The setup script prints a decision report before installation. It explains:

- Detected OS
- Detected GPU type and count
- Backend selection
- PyTorch version selection
- GPU ranking
- Tile selection
- Content/model selection
- Installation plan

Example:

```text
Backend Selection
Selected backend:
  pytorch

Why:
  NVIDIA GPU support was detected through nvidia-smi.
  PyTorch CUDA is usually the fastest backend for NVIDIA GPUs.
```

### PyTorch Version

The installer now uses:

```text
torch       2.2.2
torchvision 0.17.2
torchaudio  2.2.2
```

for CUDA 12.1 and CUDA 11.8 installs.

This replaces the older `torch 2.1.2` pin because some PyTorch CUDA indexes no longer provide that package. The script also explains this decision during installation.

### Verbosity Options

Normal output:

```bash
./setup_realesrgan_auto.sh --install
```

Extra details:

```bash
./setup_realesrgan_auto.sh --install --verbose
```

Reduced output:

```bash
./setup_realesrgan_auto.sh --install --quiet
```


## Dependency Error Handling

The setup script includes a dependency-health layer that looks for common Python and GPU setup problems and explains what it is doing.

### Handled Scenarios

| Scenario | What the Script Does |
|---|---|
| `torch==2.1.2` not found | Uses `torch==2.2.2`, `torchvision==0.17.2`, `torchaudio==2.2.2` |
| NumPy 2.x binary warning | Pins `numpy==1.26.4` |
| OpenCV requires NumPy 2.x | Pins `opencv-python==4.8.1.78` |
| `tifffile requires numpy>=2.1` | Pins `tifffile==2023.7.10` |
| `scikit-image` / image stack conflicts | Pins `scikit-image==0.21.0`, `imageio==2.31.6`, `scipy==1.11.4` |
| `torchvision.transforms.functional_tensor` missing | Patches BasicSR import to use `torchvision.transforms.functional` |
| Broken Torch install leftovers | Removes invalid `-orch` / `~orch` package folders |
| CUDA not visible to PyTorch | Prints CUDA diagnostics and detected GPU list |
| Vulkan unavailable | Prints `vulkaninfo --summary` output for NCNN/Real-CUGAN installs |

### Known-Good Python Package Pins

For the PyTorch RealESRGAN backend, the script uses:

```text
torch==2.2.2
torchvision==0.17.2
torchaudio==2.2.2
numpy==1.26.4
opencv-python==4.8.1.78
scipy==1.11.4
scikit-image==0.21.0
imageio==2.31.6
tifffile==2023.7.10
```

### Repair Mode

If the environment gets into a bad state, run:

```bash
./setup_realesrgan_auto.sh --repair
```

Repair mode removes the Python virtual environment and rebuilds it using the known-good dependency pins.
