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
