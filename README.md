# RealESRGAN Automation Package

Files:
- setup_realesrgan_auto.sh
- upscale_video_auto.sh
- realesrgan_auto.conf

This package is a starter template based on the design discussed in chat.

## Safety checks and sharpening

`upscale_video_auto.sh` now defines all variables before use to prevent `set -u` / unbound variable errors. It also validates backend, content type, frame format, sharpening mode, outscale, and tile values.

For 360p anime, start with:

```bash
./upscale_video_auto.sh \
  -i ~/video_upscale/input.mp4 \
  -o ~/video_upscale/test.mp4 \
  --backend auto \
  --content anime \
  --outscale 2 \
  --sharpen medium
```

Sharpening options:

- `--sharpen off`
- `--sharpen light`
- `--sharpen medium` — recommended first test for 360p anime
- `--sharpen strong`
- `--sharpen auto`

If you see halos around lines, use `--sharpen light` instead of `medium`.
