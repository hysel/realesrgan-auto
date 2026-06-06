#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="$HOME/realesrgan/realesrgan_auto.conf"
INPUT=""
OUTPUT=""
WORKDIR="$HOME/video_upscale"
BACKEND="auto"
CONTENT="anime"
MODEL="auto"
OUTSCALE=""
TILE=""
FRAME_FORMAT="png"
CONTAINER="mp4"
CQ="18"
GPUS=""
GPU_COUNT=""
CLEAN=0
CLEAN_ALL=0
DELETE_TEMP=0
RESUME=0
FORCE=0
INTERACTIVE=0
SHARPEN="auto"
SHARPEN_AMOUNT="auto"
INSTALL_DIR="$HOME/realesrgan"
SELECTED_GPUS=""
NCNN_BIN=""
REALCUGAN_BIN=""

usage() {
cat <<USAGE
Usage:
  ./upscale_video_auto.sh -i input.mp4 [options]

Options:
  -i, --input FILE                 Input video
  -o, --output FILE                Output video
  --backend auto|pytorch|ncnn|realcugan
  --content anime|old-anime|cartoon|live|low-quality|restore
  --model auto|realesr-animevideov3|RealESRGAN_x4plus|RealESRGAN_x4plus_anime_6B
  --outscale N                     Default: content-based, usually 2
  --tile N                         Default: config or 1200
  --gpus 0,1                       NVIDIA GPU list for PyTorch backend
  --gpu-count N                    Limit number of GPUs from selected list
  --workdir DIR                    Default: ~/video_upscale
  --frame-format png|jpg           Default: png
  --container mp4|mkv              Default: mp4
  --cq N                           Encoder quality, default: 18
  --sharpen auto|off|light|medium|strong
  --sharpen-amount FILTER          Custom ffmpeg unsharp filter
  --clean                          Remove previous temp output folders
  --clean-all                      Remove all temp frames/audio first
  --delete-temp                    Delete temp files after success
  --resume                         Reuse existing frames if present
  --force                          Skip cleanup prompts
  --interactive                    Ask for content type
  -h, --help

360p anime example:
  ./upscale_video_auto.sh -i input.mp4 -o output.mp4 --backend auto --content anime --outscale 2 --sharpen medium
USAGE
}

safe_var_defaults() {
  CONFIG_FILE="${CONFIG_FILE:-$HOME/realesrgan/realesrgan_auto.conf}"
  INPUT="${INPUT:-}"
  OUTPUT="${OUTPUT:-}"
  WORKDIR="${WORKDIR:-$HOME/video_upscale}"
  BACKEND="${BACKEND:-auto}"
  CONTENT="${CONTENT:-anime}"
  MODEL="${MODEL:-auto}"
  OUTSCALE="${OUTSCALE:-}"
  TILE="${TILE:-}"
  FRAME_FORMAT="${FRAME_FORMAT:-png}"
  CONTAINER="${CONTAINER:-mp4}"
  CQ="${CQ:-18}"
  GPUS="${GPUS:-}"
  GPU_COUNT="${GPU_COUNT:-}"
  CLEAN="${CLEAN:-0}"
  CLEAN_ALL="${CLEAN_ALL:-0}"
  DELETE_TEMP="${DELETE_TEMP:-0}"
  RESUME="${RESUME:-0}"
  FORCE="${FORCE:-0}"
  INTERACTIVE="${INTERACTIVE:-0}"
  SHARPEN="${SHARPEN:-auto}"
  SHARPEN_AMOUNT="${SHARPEN_AMOUNT:-auto}"
  INSTALL_DIR="${INSTALL_DIR:-$HOME/realesrgan}"
  SELECTED_GPUS="${SELECTED_GPUS:-}"
  NCNN_BIN="${NCNN_BIN:-}"
  REALCUGAN_BIN="${REALCUGAN_BIN:-}"
}

validate_options() {
  case "$BACKEND" in auto|pytorch|ncnn|realcugan) ;; *) echo "ERROR: invalid --backend $BACKEND"; exit 1 ;; esac
  case "$CONTENT" in anime|old-anime|cartoon|live|low-quality|restore) ;; *) echo "ERROR: invalid --content $CONTENT"; exit 1 ;; esac
  case "$FRAME_FORMAT" in png|jpg|jpeg) ;; *) echo "ERROR: invalid --frame-format $FRAME_FORMAT"; exit 1 ;; esac
  case "$CONTAINER" in mp4|mkv) ;; *) echo "ERROR: invalid --container $CONTAINER"; exit 1 ;; esac
  case "$SHARPEN" in auto|off|light|medium|strong) ;; *) echo "ERROR: invalid --sharpen $SHARPEN"; exit 1 ;; esac
  [[ -z "$OUTSCALE" || "$OUTSCALE" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: --outscale must be numeric"; exit 1; }
  [[ -z "$TILE" || "$TILE" =~ ^[0-9]+$ ]] || { echo "ERROR: --tile must be a whole number"; exit 1; }
}

safe_cleanup_guard() {
  [[ -n "${WORKDIR:-}" && "$WORKDIR" != "/" && "$WORKDIR" != "$HOME" ]] || {
    echo "ERROR: unsafe WORKDIR for cleanup: '$WORKDIR'"; exit 1;
  }
}

confirm_delete() {
  [[ "$FORCE" -eq 1 ]] && return 0
  echo "Cleanup requested in: $WORKDIR"
  read -r -p "Continue deleting temp files? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
}

content_wizard() {
  [[ "${INTERACTIVE:-0}" -eq 1 ]] || return 0
  echo "Select content type:"
  echo "  1) Anime / animation video"
  echo "  2) Old anime / soft source"
  echo "  3) Cartoon / western animation"
  echo "  4) Live action"
  echo "  5) Low-quality / noisy source"
  echo "  6) Restore only / avoid heavy upscale"
  read -r -p "Choose [1-6] default 1: " choice
  case "${choice:-1}" in
    1) CONTENT="anime" ;; 2) CONTENT="old-anime" ;; 3) CONTENT="cartoon" ;;
    4) CONTENT="live" ;; 5) CONTENT="low-quality" ;; 6) CONTENT="restore" ;;
    *) CONTENT="anime" ;;
  esac
}

resolve_backend_auto() {
  [[ "$BACKEND" == "auto" ]] || return 0
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    BACKEND="pytorch"
    echo "Auto backend selected: pytorch — NVIDIA CUDA detected."
  elif command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary >/dev/null 2>&1; then
    BACKEND="ncnn"
    echo "Auto backend selected: ncnn — Vulkan detected."
  else
    BACKEND="ncnn"
    echo "Auto backend selected: ncnn fallback — Vulkan/CUDA may need troubleshooting."
  fi
}

apply_content_defaults() {
  if [[ "$MODEL" == "auto" ]]; then
    case "$CONTENT" in
      live) MODEL="RealESRGAN_x4plus" ;;
      *) MODEL="realesr-animevideov3" ;;
    esac
  fi
  if [[ -z "$OUTSCALE" ]]; then
    case "$CONTENT" in low-quality|restore) OUTSCALE="1" ;; *) OUTSCALE="2" ;; esac
  fi
  if [[ -z "$TILE" ]]; then TILE="1200"; fi
  if [[ "$BACKEND" == "realcugan" ]]; then
    MODEL="realcugan"
    [[ "$OUTSCALE" < "2" ]] && OUTSCALE="2"
  fi
}

detect_source_info() {
  FPS="$(ffprobe -v 0 -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT")"
  SRC_WIDTH="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$INPUT" | head -1)"
  SRC_HEIGHT="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$INPUT" | head -1)"
  FPS="${FPS:-25}"
  SRC_WIDTH="${SRC_WIDTH:-0}"
  SRC_HEIGHT="${SRC_HEIGHT:-0}"
}

choose_sharpen_filter() {
  SHARPEN_FILTER=""
  if [[ "$SHARPEN" == "off" ]]; then echo "Sharpening disabled."; return 0; fi
  if [[ "$SHARPEN_AMOUNT" != "auto" ]]; then SHARPEN_FILTER="$SHARPEN_AMOUNT"; echo "Custom sharpening: $SHARPEN_FILTER"; return 0; fi
  local mode="$SHARPEN"
  if [[ "$mode" == "auto" ]]; then
    if [[ "$SRC_HEIGHT" -le 480 && "$CONTENT" =~ ^(anime|old-anime|cartoon)$ ]]; then mode="medium"
    elif [[ "$CONTENT" =~ ^(low-quality|restore)$ ]]; then mode="light"
    else mode="off"; fi
  fi
  case "$mode" in
    light) SHARPEN_FILTER="unsharp=5:5:0.45:3:3:0.20" ;;
    medium) SHARPEN_FILTER="unsharp=5:5:0.75:3:3:0.30" ;;
    strong) SHARPEN_FILTER="unsharp=7:7:1.00:5:5:0.45" ;;
  esac
  [[ -n "$SHARPEN_FILTER" ]] && echo "Sharpening enabled: $mode ($SHARPEN_FILTER)" || echo "Sharpening disabled."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) INPUT="${2:-}"; shift 2 ;;
    -o|--output) OUTPUT="${2:-}"; shift 2 ;;
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --workdir) WORKDIR="${2:-}"; shift 2 ;;
    --backend) BACKEND="${2:-auto}"; shift 2 ;;
    --content) CONTENT="${2:-anime}"; shift 2 ;;
    --model) MODEL="${2:-auto}"; shift 2 ;;
    --outscale) OUTSCALE="${2:-}"; shift 2 ;;
    --tile) TILE="${2:-}"; shift 2 ;;
    --gpus) GPUS="${2:-}"; shift 2 ;;
    --gpu-count) GPU_COUNT="${2:-}"; shift 2 ;;
    --frame-format) FRAME_FORMAT="${2:-png}"; shift 2 ;;
    --container) CONTAINER="${2:-mp4}"; shift 2 ;;
    --cq) CQ="${2:-18}"; shift 2 ;;
    --sharpen) SHARPEN="${2:-auto}"; shift 2 ;;
    --sharpen-amount) SHARPEN_AMOUNT="${2:-auto}"; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    --clean-all) CLEAN_ALL=1; shift ;;
    --delete-temp) DELETE_TEMP=1; shift ;;
    --resume) RESUME=1; shift ;;
    --force) FORCE=1; shift ;;
    --interactive) INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

safe_var_defaults
if [[ -f "$CONFIG_FILE" ]]; then source "$CONFIG_FILE"; fi
safe_var_defaults
validate_options
[[ -n "$INPUT" ]] || { echo "ERROR: --input is required"; usage; exit 1; }
[[ -f "$INPUT" ]] || { echo "ERROR: input not found: $INPUT"; exit 1; }

content_wizard
resolve_backend_auto
apply_content_defaults
detect_source_info
choose_sharpen_filter

if [[ -z "$OUTPUT" ]]; then
  stem="$(basename "$INPUT")"; stem="${stem%.*}"
  OUTPUT="$WORKDIR/${stem}_upscaled.${CONTAINER}"
fi

cat <<INFO
Input:      $INPUT
Output:     $OUTPUT
FPS:        $FPS
Resolution: ${SRC_WIDTH}x${SRC_HEIGHT}
Backend:    $BACKEND
Content:    $CONTENT
Model:      $MODEL
Outscale:   $OUTSCALE
Tile:       $TILE
Workdir:    $WORKDIR
INFO

mkdir -p "$WORKDIR/input_frames" "$WORKDIR/output_frames_final" "$WORKDIR/logs"

if [[ "$RESUME" -eq 1 ]]; then CLEAN=0; CLEAN_ALL=0; fi
if [[ "$CLEAN_ALL" -eq 1 ]]; then
  safe_cleanup_guard; confirm_delete
  rm -rf "$WORKDIR"/input_frames/* "$WORKDIR"/input_frames_part* "$WORKDIR"/output_frames_part* "$WORKDIR"/output_frames_final/*
  rm -f "$WORKDIR"/original_audio.* "$WORKDIR"/upscaled_video.*
elif [[ "$CLEAN" -eq 1 ]]; then
  safe_cleanup_guard; confirm_delete
  rm -rf "$WORKDIR"/input_frames_part* "$WORKDIR"/output_frames_part* "$WORKDIR"/output_frames_final/*
  rm -f "$WORKDIR"/upscaled_video.*
fi

if [[ "$RESUME" -eq 0 || ! -f "$WORKDIR/original_audio.mka" ]]; then
  ffmpeg -y -i "$INPUT" -vn -acodec copy "$WORKDIR/original_audio.mka" || true
fi
if [[ "$RESUME" -eq 0 || -z "$(find "$WORKDIR/input_frames" -type f -name "*.${FRAME_FORMAT}" 2>/dev/null | head -1)" ]]; then
  ffmpeg -y -i "$INPUT" "$WORKDIR/input_frames/%08d.${FRAME_FORMAT}"
fi

if [[ "$BACKEND" == "pytorch" ]]; then
  [[ -n "$GPUS" ]] || GPUS="${SELECTED_GPUS:-0}"
  if [[ -n "$GPU_COUNT" ]]; then GPUS="$(echo "$GPUS" | tr ',' '\n' | head -n "$GPU_COUNT" | paste -sd, -)"; fi
  IFS=',' read -r -a GPU_ARRAY <<< "$GPUS"
  parts="${#GPU_ARRAY[@]}"
  echo "Splitting frames across $parts GPU process(es): ${GPU_ARRAY[*]}"
  for ((p=0; p<parts; p++)); do rm -rf "$WORKDIR/input_frames_part$p" "$WORKDIR/output_frames_part$p"; mkdir -p "$WORKDIR/input_frames_part$p" "$WORKDIR/output_frames_part$p"; done
  i=0
  while IFS= read -r f; do p=$(( i % parts )); cp "$f" "$WORKDIR/input_frames_part$p/"; i=$((i+1)); done < <(find "$WORKDIR/input_frames" -maxdepth 1 -type f -name "*.${FRAME_FORMAT}" | sort)
  cd "$INSTALL_DIR/Real-ESRGAN"
  source venv/bin/activate
  PIDS=(); part=0
  for gpu in "${GPU_ARRAY[@]}"; do
    CUDA_VISIBLE_DEVICES="$gpu" python inference_realesrgan.py -n "$MODEL" -i "$WORKDIR/input_frames_part$part" -o "$WORKDIR/output_frames_part$part" --outscale "$OUTSCALE" --tile "$TILE" &
    PIDS+=("$!"); part=$((part+1))
  done
  for pid in "${PIDS[@]}"; do wait "$pid"; done
elif [[ "$BACKEND" == "ncnn" ]]; then
  mkdir -p "$WORKDIR/output_frames_part0"
  NCNN_BIN="${NCNN_BIN:-$(find "$INSTALL_DIR/ncnn" -type f -name realesrgan-ncnn-vulkan | head -1)}"
  [[ -x "$NCNN_BIN" ]] || { echo "ERROR: NCNN binary not found. Run setup."; exit 1; }
  "$NCNN_BIN" -i "$WORKDIR/input_frames" -o "$WORKDIR/output_frames_part0" -n "$MODEL" -s "$OUTSCALE"
elif [[ "$BACKEND" == "realcugan" ]]; then
  mkdir -p "$WORKDIR/output_frames_part0"
  REALCUGAN_BIN="${REALCUGAN_BIN:-$(find "$INSTALL_DIR/realcugan" -type f -name realcugan-ncnn-vulkan | head -1)}"
  [[ -x "$REALCUGAN_BIN" ]] || { echo "ERROR: Real-CUGAN binary not found. Run setup."; exit 1; }
  "$REALCUGAN_BIN" -i "$WORKDIR/input_frames" -o "$WORKDIR/output_frames_part0" -s "$OUTSCALE" -n -1
fi

rm -rf "$WORKDIR/output_frames_final"/*
find "$WORKDIR" -maxdepth 1 -type d -name "output_frames_part*" | sort | while read -r d; do cp "$d"/* "$WORKDIR/output_frames_final/" 2>/dev/null || true; done

# Detect output naming pattern.
PATTERN="%08d_out.${FRAME_FORMAT}"
if ! ls "$WORKDIR/output_frames_final"/*_out."$FRAME_FORMAT" >/dev/null 2>&1; then
  PATTERN="%08d.${FRAME_FORMAT}"
fi
upscaled_video="$WORKDIR/upscaled_video.${CONTAINER}"

if [[ -n "$SHARPEN_FILTER" ]]; then
  ffmpeg -y -framerate "$FPS" -i "$WORKDIR/output_frames_final/$PATTERN" -vf "$SHARPEN_FILTER" -c:v hevc_nvenc -preset p7 -profile:v main10 -pix_fmt p010le -rc vbr -cq "$CQ" -b:v 0 "$upscaled_video"
else
  ffmpeg -y -framerate "$FPS" -i "$WORKDIR/output_frames_final/$PATTERN" -c:v hevc_nvenc -preset p7 -profile:v main10 -pix_fmt p010le -rc vbr -cq "$CQ" -b:v 0 "$upscaled_video"
fi

if [[ -f "$WORKDIR/original_audio.mka" ]]; then
  ffmpeg -y -i "$upscaled_video" -i "$WORKDIR/original_audio.mka" -map 0:v:0 -map 1:a? -c:v copy -c:a copy "$OUTPUT"
else
  cp "$upscaled_video" "$OUTPUT"
fi

echo "Final output: $OUTPUT"

if [[ "$DELETE_TEMP" -eq 1 ]]; then
  safe_cleanup_guard
  rm -rf "$WORKDIR/input_frames" "$WORKDIR"/input_frames_part* "$WORKDIR"/output_frames_part* "$WORKDIR/output_frames_final"
  rm -f "$WORKDIR"/original_audio.* "$WORKDIR"/upscaled_video.*
fi
