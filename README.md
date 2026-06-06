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
