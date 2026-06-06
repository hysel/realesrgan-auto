#!/usr/bin/env bash
set -euo pipefail
# upscale_video_auto.sh v2.0
# Supports:
# - PyTorch Real-ESRGAN
# - Real-ESRGAN NCNN Vulkan
# - Real-CUGAN NCNN Vulkan
# - waifu2x NCNN Vulkan  (NEW)
#
# New in v2.0:
# - Denoise pass BEFORE upscaling (better results, especially for 360p sources)
# - 360p source detection with auto-adjusted settings
# - waifu2x backend with model selection
# - hqdn3d denoise + unsharp integrated into final encode
# - Content-aware denoise strength selection
# - INTERACTIVE default fixed (no more unbound variable)

CONFIG_FILE="$HOME/realesrgan/realesrgan_auto.conf"
CLI_INPUT=""
CLI_OUTPUT=""
CLI_WORKDIR=""
CLI_BACKEND=""
CLI_GPUS=""
CLI_GPU_COUNT=""
CLI_CONTENT=""
CLI_MODEL=""
CLI_OUTSCALE=""
CLI_TILE=""
CLI_FRAME_FORMAT=""
CLI_CONTAINER=""
CLI_CQ=""
CLI_DENOISE_STRENGTH=""
CLI_SHARPEN_STRENGTH=""
CLEAN=0
CLEAN_ALL=0
DELETE_TEMP=0
RESUME=0
FORCE=0
INTERACTIVE=0     # FIXED: always default here, before any function calls

usage() {
cat << EOF
Usage:
  ./upscale_video_auto.sh --input video.mkv [options]

Required:
  -i, --input FILE

Options:
  -o, --output FILE
  --config FILE
  --workdir DIR
  --backend auto|pytorch|ncnn|realcugan|waifu2x
  --gpus 0,1
  --gpu-count N
  --interactive
  --content anime|old-anime|cartoon|live|low-quality|restore
  --model auto|realesr-animevideov3|RealESRGAN_x4plus_anime_6B|RealESRGAN_x4plus
  --outscale N
  --tile N
  --frame-format png|jpg
  --container mkv|mp4
  --cq N
  --denoise-strength none|mild|moderate|strong|vheavy
                        Denoise pass applied BEFORE upscaling (default: auto)
  --sharpen-strength FLOAT
                        Unsharp strength added during encode (default: auto)
  --clean               Delete previous output/temp folders for this run
  --clean-all           Delete all extracted frames/audio/temp files first
  --delete-temp         Delete temporary files after successful output
  --resume              Keep existing files and continue
  --force               Skip cleanup prompts
  -h, --help

Backends:
  pytorch    PyTorch Real-ESRGAN (best quality, needs CUDA venv)
  ncnn       Real-ESRGAN NCNN Vulkan (fast, any GPU)
  realcugan  Real-CUGAN NCNN Vulkan (good for animation)
  waifu2x    waifu2x NCNN Vulkan (best for cel animation, NEW)
  auto       Auto-detect installed backend

Content types:
  anime        Standard anime/animation
  old-anime    Old cel animation (360p/480p, VHS/broadcast source) -- enables denoise
  cartoon      Western animation
  live         Live action / real footage
  low-quality  Heavy noise/artifacts -- enables strong denoise
  restore      Minimal upscale, focus on cleanup

Examples:
  ./upscale_video_auto.sh -i input.mkv --content old-anime
  ./upscale_video_auto.sh -i input.mkv --backend waifu2x --content old-anime
  ./upscale_video_auto.sh -i input.mkv --gpus 0,1 --model realesr-animevideov3
  ./upscale_video_auto.sh -i input.mkv --backend realcugan --outscale 2
  ./upscale_video_auto.sh -i input.mkv --denoise-strength moderate --sharpen-strength 1.0
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)            CLI_INPUT="${2:-}";            shift 2 ;;
    -o|--output)           CLI_OUTPUT="${2:-}";           shift 2 ;;
    --config)              CONFIG_FILE="${2:-}";          shift 2 ;;
    --workdir)             CLI_WORKDIR="${2:-}";          shift 2 ;;
    --backend)             CLI_BACKEND="${2:-}";          shift 2 ;;
    --gpus)                CLI_GPUS="${2:-}";             shift 2 ;;
    --gpu-count)           CLI_GPU_COUNT="${2:-}";        shift 2 ;;
    --content)             CLI_CONTENT="${2:-}";          shift 2 ;;
    --model)               CLI_MODEL="${2:-}";            shift 2 ;;
    --outscale)            CLI_OUTSCALE="${2:-}";         shift 2 ;;
    --tile)                CLI_TILE="${2:-}";             shift 2 ;;
    --frame-format)        CLI_FRAME_FORMAT="${2:-}";     shift 2 ;;
    --container)           CLI_CONTAINER="${2:-}";        shift 2 ;;
    --cq)                  CLI_CQ="${2:-}";               shift 2 ;;
    --denoise-strength)    CLI_DENOISE_STRENGTH="${2:-}"; shift 2 ;;
    --sharpen-strength)    CLI_SHARPEN_STRENGTH="${2:-}"; shift 2 ;;
    --clean)               CLEAN=1;                       shift ;;
    --clean-all)           CLEAN_ALL=1;                   shift ;;
    --delete-temp)         DELETE_TEMP=1;                 shift ;;
    --resume)              RESUME=1;                      shift ;;
    --force)               FORCE=1;                       shift ;;
    --interactive)         INTERACTIVE=1;                 shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Defaults (before config) ──────────────────────────────────────────────────
INSTALL_DIR="$HOME/realesrgan"
BACKEND="auto"
SELECTED_GPUS=""
MODEL="auto"
OUTSCALE="2"
TILE="1200"
CONTAINER="mkv"
CQ="18"
FRAME_FORMAT="png"
NCNN_BIN=""
REALCUGAN_BIN=""
WAIFU2X_BIN=""
WORKDIR="$HOME/video_upscale"
CONTENT="anime"
DENOISE_STRENGTH="auto"   # none|mild|moderate|strong|vheavy|auto
SHARPEN_STRENGTH="auto"   # float or auto

# ── Load config ───────────────────────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ── CLI overrides config ──────────────────────────────────────────────────────
INPUT="${CLI_INPUT}"
OUTPUT="${CLI_OUTPUT}"
[[ -n "$CLI_WORKDIR" ]]          && WORKDIR="$CLI_WORKDIR"
[[ -n "$CLI_BACKEND" ]]          && BACKEND="$CLI_BACKEND"
[[ -n "$CLI_GPUS" ]]             && SELECTED_GPUS="$CLI_GPUS"
[[ -n "$CLI_CONTENT" ]]          && CONTENT="$CLI_CONTENT"
[[ -n "$CLI_MODEL" ]]            && MODEL="$CLI_MODEL"
[[ -n "$CLI_OUTSCALE" ]]         && OUTSCALE="$CLI_OUTSCALE"
[[ -n "$CLI_TILE" ]]             && TILE="$CLI_TILE"
[[ -n "$CLI_FRAME_FORMAT" ]]     && FRAME_FORMAT="$CLI_FRAME_FORMAT"
[[ -n "$CLI_CONTAINER" ]]        && CONTAINER="$CLI_CONTAINER"
[[ -n "$CLI_CQ" ]]               && CQ="$CLI_CQ"
[[ -n "$CLI_DENOISE_STRENGTH" ]] && DENOISE_STRENGTH="$CLI_DENOISE_STRENGTH"
[[ -n "$CLI_SHARPEN_STRENGTH" ]] && SHARPEN_STRENGTH="$CLI_SHARPEN_STRENGTH"

[[ -n "$INPUT" ]] || { echo "ERROR: --input is required"; usage; exit 1; }
[[ -f "$INPUT" ]] || { echo "ERROR: input not found: $INPUT"; exit 1; }

# ── Backend resolution ────────────────────────────────────────────────────────
resolve_backend_auto() {
  [[ "$BACKEND" != "auto" ]] && return
  if   [[ -d "$INSTALL_DIR/Real-ESRGAN" ]];   then BACKEND="pytorch"
  elif [[ -n "$NCNN_BIN" || -d "$INSTALL_DIR/ncnn" ]]; then BACKEND="ncnn"
  elif [[ -n "$REALCUGAN_BIN" || -d "$INSTALL_DIR/realcugan" ]]; then BACKEND="realcugan"
  elif [[ -n "$WAIFU2X_BIN"   || -d "$INSTALL_DIR/waifu2x"   ]]; then BACKEND="waifu2x"
  else echo "ERROR: Could not resolve backend=auto. Run setup first."; exit 1
  fi
}
resolve_backend_auto

# ── Source resolution detection ───────────────────────────────────────────────
# Reads actual video dimensions and adjusts settings for low-res sources.
# 360p sources benefit from:
#   - denoise BEFORE upscaling (noise pixels are small and easy to remove)
#   - conservative outscale (2x is usually best; 4x introduces artifacts)
#   - waifu2x cunet model (handles flat animation colors best at low res)

SOURCE_HEIGHT=0
SOURCE_WIDTH=0

detect_source_resolution() {
  SOURCE_WIDTH=$(ffprobe -v quiet -select_streams v:0 \
    -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null || echo 0)
  SOURCE_HEIGHT=$(ffprobe -v quiet -select_streams v:0 \
    -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$INPUT" 2>/dev/null || echo 0)
  echo "Source resolution: ${SOURCE_WIDTH}x${SOURCE_HEIGHT}"
}

apply_resolution_adjustments() {
  # For 360p and below: auto-enable denoise and recommend waifu2x
  if [[ "$SOURCE_HEIGHT" -le 360 && "$SOURCE_HEIGHT" -gt 0 ]]; then
    echo "Detected low-resolution source (<= 360p) — applying optimised settings"

    # Auto-set denoise if not explicitly set by user
    if [[ "$DENOISE_STRENGTH" == "auto" ]]; then
      case "$CONTENT" in
        old-anime|low-quality) DENOISE_STRENGTH="moderate" ;;
        anime|cartoon)         DENOISE_STRENGTH="mild" ;;
        *)                     DENOISE_STRENGTH="mild" ;;
      esac
      echo "  Auto denoise strength: $DENOISE_STRENGTH (before upscaling)"
    fi

    # Recommend waifu2x cunet for animation at this resolution
    if [[ "$BACKEND" == "auto" || "$BACKEND" == "waifu2x" ]] && \
       [[ "$CONTENT" == "anime" || "$CONTENT" == "old-anime" || "$CONTENT" == "cartoon" ]]; then
      echo "  Tip: --backend waifu2x --model cunet gives best results for 360p animation"
    fi

    # Cap outscale at 2 for very low res — 4x on 360p often looks worse
    if [[ "$OUTSCALE" -gt 2 ]] && [[ "$CONTENT" != "live" ]]; then
      echo "  Capping outscale at 2x for 360p source (use --outscale 4 to override)"
      OUTSCALE=2
    fi
  fi

  # For 480p: mild denoise auto-enabled for old-anime
  if [[ "$SOURCE_HEIGHT" -le 480 && "$SOURCE_HEIGHT" -gt 360 ]]; then
    if [[ "$DENOISE_STRENGTH" == "auto" && "$CONTENT" == "old-anime" ]]; then
      DENOISE_STRENGTH="mild"
      echo "  Auto denoise strength: mild (480p old-anime source)"
    fi
  fi

  # For HD sources: denoise off by default unless explicitly set
  if [[ "$SOURCE_HEIGHT" -gt 480 && "$DENOISE_STRENGTH" == "auto" ]]; then
    DENOISE_STRENGTH="none"
  fi
}

# ── hqdn3d filter string from strength level ──────────────────────────────────
# Applied BEFORE upscaling for best results.
# Denoising at source resolution removes noise when pixels are small and
# distinct — the upscaler then works on clean data instead of upscaling noise.
#
# hqdn3d=luma_spatial:chroma_spatial:luma_temporal:chroma_temporal
# Temporal values handle flicker between frames (important for old animation).

get_denoise_filter() {
  local strength="$1"
  case "$strength" in
    none)   echo "" ;;
    mild)   echo "hqdn3d=2:1:3:2" ;;
    moderate) echo "hqdn3d=4:3:6:4" ;;
    strong) echo "hqdn3d=6:5:9:6" ;;
    vheavy) echo "hqdn3d=9:7:12:8" ;;
    auto)   echo "" ;;  # should have been resolved by now
    *)      echo "hqdn3d=4:3:6:4" ;;  # safe default
  esac
}

# ── Unsharp filter string from strength ───────────────────────────────────────
# Applied AFTER upscaling during final encode.
# For animation: keep chroma (ca) lower than luma (la) to avoid color bleeding.

get_sharpen_filter() {
  local strength="$1"
  # If auto, pick based on content
  if [[ "$strength" == "auto" ]]; then
    case "$CONTENT" in
      old-anime|cartoon) strength="0.8" ;;
      anime)             strength="1.0" ;;
      live)              strength="1.2" ;;
      low-quality)       strength="0.6" ;;
      restore)           strength="0.0" ;;
      *)                 strength="0.8" ;;
    esac
  fi
  # strength=0 means skip sharpening
  if [[ "$strength" == "0" || "$strength" == "0.0" ]]; then
    echo ""
  else
    echo "unsharp=lx=3:ly=3:la=${strength}:cx=3:cy=3:ca=$(echo "$strength * 0.4" | bc -l | xargs printf "%.1f")"
  fi
}

# ── Content wizard (interactive mode) ────────────────────────────────────────
content_wizard() {
  [[ "$INTERACTIVE" -eq 1 ]] || return 0
  echo
  echo "Select content type:"
  echo "  1) Anime / animation video"
  echo "  2) Old anime / softer source (enables denoise)"
  echo "  3) Cartoon / western animation"
  echo "  4) Live action / real video"
  echo "  5) Low-quality / noisy source (enables strong denoise)"
  echo "  6) Restore only / avoid heavy upscale"
  read -r -p "Choose [1-6] default 1: " choice
  case "${choice:-1}" in
    1) CONTENT="anime" ;;
    2) CONTENT="old-anime" ;;
    3) CONTENT="cartoon" ;;
    4) CONTENT="live" ;;
    5) CONTENT="low-quality" ;;
    6) CONTENT="restore" ;;
    *) CONTENT="anime" ;;
  esac
}

# ── Content-based defaults ────────────────────────────────────────────────────
apply_content_defaults() {
  if [[ "$MODEL" == "auto" ]]; then
    case "$CONTENT" in
      anime|old-anime|cartoon) MODEL="realesr-animevideov3" ;;
      live)                    MODEL="RealESRGAN_x4plus" ;;
      low-quality|restore)     MODEL="realesr-animevideov3" ;;
      *)                       MODEL="realesr-animevideov3" ;;
    esac
  fi

  if [[ -z "$OUTSCALE" || "$OUTSCALE" == "2" ]]; then
    case "$CONTENT" in
      low-quality|restore) OUTSCALE=1 ;;
      *) OUTSCALE=2 ;;
    esac
  fi

  if [[ "$BACKEND" == "realcugan" ]]; then
    MODEL="realcugan"
    [[ "$OUTSCALE" -lt 2 ]] && OUTSCALE=2
  fi

  # waifu2x model selection based on content
  if [[ "$BACKEND" == "waifu2x" ]]; then
    if [[ "$MODEL" == "auto" || "$MODEL" == "realesr-animevideov3" ]]; then
      case "$CONTENT" in
        old-anime|anime|cartoon) MODEL="cunet" ;;
        live)                    MODEL="upconv_7_photo" ;;
        *)                       MODEL="cunet" ;;
      esac
    fi
  fi
}

content_wizard
apply_content_defaults

# ── Detect source resolution and adjust settings ──────────────────────────────
detect_source_resolution
apply_resolution_adjustments

# ── Output path ───────────────────────────────────────────────────────────────
if [[ -z "$OUTPUT" ]]; then
  stem="$(basename "$INPUT")"
  stem="${stem%.*}"
  OUTPUT="$WORKDIR/${stem}_upscaled.${CONTAINER}"
fi

FPS="$(ffprobe -v 0 -select_streams v:0 \
  -show_entries stream=r_frame_rate \
  -of default=noprint_wrappers=1:nokey=1 "$INPUT")"
[[ -n "$FPS" ]] || { echo "ERROR: Could not detect frame rate."; exit 1; }

echo "------------------------------------------------------------"
echo "Input:            $INPUT"
echo "Output:           $OUTPUT"
echo "Source res:       ${SOURCE_WIDTH}x${SOURCE_HEIGHT}"
echo "FPS:              $FPS"
echo "Backend:          $BACKEND"
echo "Model:            $MODEL"
echo "Outscale:         $OUTSCALE"
echo "Tile:             $TILE"
echo "Frame format:     $FRAME_FORMAT"
echo "Workdir:          $WORKDIR"
echo "Denoise (pre):    $DENOISE_STRENGTH"
echo "Sharpen (post):   $SHARPEN_STRENGTH"
echo "------------------------------------------------------------"

mkdir -p "$WORKDIR"/{input_frames,output_frames_final,logs}
mkdir -p "$(dirname "$OUTPUT")"

[[ "$RESUME" -eq 1 ]] && { CLEAN=0; CLEAN_ALL=0; }

confirm_delete() {
  [[ "$FORCE" -eq 1 ]] && return 0
  echo "Cleanup requested in: $WORKDIR"
  read -r -p "Continue deleting temp files? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
}

if [[ "$CLEAN_ALL" -eq 1 ]]; then
  confirm_delete
  rm -rf "$WORKDIR"/input_frames/* "$WORKDIR"/input_frames_part* \
         "$WORKDIR"/input_frames_denoised \
         "$WORKDIR"/output_frames_part* "$WORKDIR"/output_frames_final/* \
         "$WORKDIR"/original_audio.* "$WORKDIR"/upscaled_video.*
elif [[ "$CLEAN" -eq 1 ]]; then
  confirm_delete
  rm -rf "$WORKDIR"/input_frames_part* \
         "$WORKDIR"/input_frames_denoised \
         "$WORKDIR"/output_frames_part* "$WORKDIR"/output_frames_final/* \
         "$WORKDIR"/upscaled_video.*
fi

# ── Extract audio ─────────────────────────────────────────────────────────────
echo "Extracting audio..."
if [[ "$RESUME" -eq 0 || ! -f "$WORKDIR/original_audio.mka" ]]; then
  ffmpeg -y -i "$INPUT" -vn -acodec copy "$WORKDIR/original_audio.mka" 2>/dev/null || true
fi

# ── Extract frames ────────────────────────────────────────────────────────────
# If denoise is enabled, apply hqdn3d DURING frame extraction.
# This is the key improvement: denoise at source resolution before upscaling.
# Denoising 360p frames is far more effective than denoising 720p upscaled frames
# because noise pixels are smaller and easier to separate from real detail.

DENOISE_FILTER="$(get_denoise_filter "$DENOISE_STRENGTH")"
UPSCALE_INPUT_DIR="$WORKDIR/input_frames"

echo "Extracting frames..."
if [[ "$RESUME" -eq 0 || -z "$(find "$WORKDIR/input_frames" -type f -name "*.${FRAME_FORMAT}" 2>/dev/null | head -1)" ]]; then
  if [[ -n "$DENOISE_FILTER" ]]; then
    echo "  Applying denoise filter BEFORE upscaling: $DENOISE_FILTER"
    echo "  (Denoising at ${SOURCE_WIDTH}x${SOURCE_HEIGHT} for best results)"
    ffmpeg -y -i "$INPUT" \
      -vf "$DENOISE_FILTER" \
      "$WORKDIR/input_frames/%08d.${FRAME_FORMAT}"
  else
    ffmpeg -y -i "$INPUT" \
      "$WORKDIR/input_frames/%08d.${FRAME_FORMAT}"
  fi
fi

echo "Frames extracted: $(find "$WORKDIR/input_frames" -name "*.${FRAME_FORMAT}" | wc -l)"

# ── GPU array preparation ─────────────────────────────────────────────────────
prepare_gpu_array() {
  local gpus="$SELECTED_GPUS"
  [[ -z "$gpus" && "$BACKEND" == "pytorch" ]] && gpus="0"
  if [[ -n "$CLI_GPU_COUNT" && -n "$gpus" ]]; then
    gpus="$(echo "$gpus" | tr ',' '\n' | head -n "$CLI_GPU_COUNT" | paste -sd, -)"
  fi
  IFS=',' read -r -a GPU_ARRAY <<< "$gpus"
  [[ "$BACKEND" == "pytorch" && "${#GPU_ARRAY[@]}" -eq 0 ]] && GPU_ARRAY=("0")
}

split_frames_by_range() {
  echo "Splitting frames by ranges..."
  local parts="${#GPU_ARRAY[@]}"
  [[ "$parts" -gt 0 ]] || parts=1
  mapfile -t FRAMES < <(find "$WORKDIR/input_frames" -maxdepth 1 \
    -type f -name "*.${FRAME_FORMAT}" | sort)
  local total="${#FRAMES[@]}"
  [[ "$total" -gt 0 ]] || { echo "ERROR: no frames found"; exit 1; }
  for ((p=0; p<parts; p++)); do
    rm -rf "$WORKDIR/input_frames_part$p" "$WORKDIR/output_frames_part$p"
    mkdir -p "$WORKDIR/input_frames_part$p" "$WORKDIR/output_frames_part$p"
  done
  local chunk=$(( (total + parts - 1) / parts ))
  for ((p=0; p<parts; p++)); do
    local start=$(( p * chunk ))
    local end=$(( start + chunk ))
    (( end > total )) && end="$total"
    for ((i=start; i<end; i++)); do
      cp "${FRAMES[$i]}" "$WORKDIR/input_frames_part$p/"
    done
    echo "  Part $p: $(( end - start )) frames"
  done
}

prepare_gpu_array
echo "Selected GPUs: ${GPU_ARRAY[*]:-vulkan/default}"

# ── Upscaling ─────────────────────────────────────────────────────────────────
if [[ "$BACKEND" == "pytorch" ]]; then
  split_frames_by_range
  cd "$INSTALL_DIR/Real-ESRGAN"
  source venv/bin/activate
  PIDS=()
  part=0
  for gpu in "${GPU_ARRAY[@]}"; do
    echo "Starting PyTorch RealESRGAN on GPU $gpu part $part"
    CUDA_VISIBLE_DEVICES="$gpu" python inference_realesrgan.py \
      -n "$MODEL" \
      -i "$WORKDIR/input_frames_part$part" \
      -o "$WORKDIR/output_frames_part$part" \
      --outscale "$OUTSCALE" \
      --tile "$TILE" \
      --fp32 &        # --fp32 for V100 compatibility
    PIDS+=("$!")
    part=$(( part + 1 ))
  done
  for pid in "${PIDS[@]}"; do wait "$pid"; done

elif [[ "$BACKEND" == "ncnn" ]]; then
  mkdir -p "$WORKDIR/output_frames_part0"
  if [[ -z "$NCNN_BIN" ]]; then
    NCNN_BIN="$(find "$INSTALL_DIR/ncnn" -type f -name realesrgan-ncnn-vulkan | head -1)"
  fi
  [[ -x "$NCNN_BIN" ]] || { echo "ERROR: NCNN binary not found. Run setup."; exit 1; }
  "$NCNN_BIN" \
    -i "$WORKDIR/input_frames" \
    -o "$WORKDIR/output_frames_part0" \
    -n "$MODEL" -s "$OUTSCALE"

elif [[ "$BACKEND" == "realcugan" ]]; then
  mkdir -p "$WORKDIR/output_frames_part0"
  if [[ -z "$REALCUGAN_BIN" ]]; then
    REALCUGAN_BIN="$(find "$INSTALL_DIR/realcugan" -type f \
      -name realcugan-ncnn-vulkan | head -1)"
  fi
  [[ -x "$REALCUGAN_BIN" ]] || { echo "ERROR: Real-CUGAN binary not found. Run setup."; exit 1; }

  # Map denoise strength to realcugan -n level
  # realcugan: -1=none 0=conservative 1=light 2=medium 3=heavy
  case "$DENOISE_STRENGTH" in
    none)     CUGAN_N="-1" ;;
    mild)     CUGAN_N="0"  ;;
    moderate) CUGAN_N="1"  ;;
    strong)   CUGAN_N="2"  ;;
    vheavy)   CUGAN_N="3"  ;;
    *)        CUGAN_N="0"  ;;
  esac

  # For realcugan, denoise is handled by the -n flag at upscale time
  # rather than a pre-pass (it's built into the model)
  "$REALCUGAN_BIN" \
    -i "$WORKDIR/input_frames" \
    -o "$WORKDIR/output_frames_part0" \
    -s "$OUTSCALE" \
    -n "$CUGAN_N" \
    ${SELECTED_GPUS:+-g "$SELECTED_GPUS"}

elif [[ "$BACKEND" == "waifu2x" ]]; then
  # ── waifu2x backend ────────────────────────────────────────────────────────
  # Purpose-built for cel animation. Preserves flat color fills and hard edges
  # far better than Real-ESRGAN or Real-CUGAN for traditional animation.
  #
  # Models:
  #   cunet                          Best quality, recommended for old animation
  #   upconv_7_anime_style_art_rgb   Faster, good for clean anime
  #   upconv_7_photo                 Photographic content
  #
  # Denoise levels: -1=none 0=copy 1=light 2=medium 3=heavy

  mkdir -p "$WORKDIR/output_frames_part0"

  if [[ -z "$WAIFU2X_BIN" ]]; then
    WAIFU2X_BIN="$(find "$INSTALL_DIR/waifu2x" -type f \
      -name waifu2x-ncnn-vulkan 2>/dev/null | head -1)"
  fi

  # Auto-download if not found
  if [[ ! -x "$WAIFU2X_BIN" ]]; then
    echo "waifu2x binary not found — downloading..."
    mkdir -p "$INSTALL_DIR/waifu2x"
    wget -q --show-progress -O /tmp/waifu2x.zip \
      "https://github.com/nihui/waifu2x-ncnn-vulkan/releases/download/20220728/waifu2x-ncnn-vulkan-20220728-ubuntu.zip" \
      && unzip -q /tmp/waifu2x.zip -d "$INSTALL_DIR/waifu2x" \
      || { echo "ERROR: waifu2x download failed"; exit 1; }
    WAIFU2X_BIN="$(find "$INSTALL_DIR/waifu2x" -type f \
      -name waifu2x-ncnn-vulkan | head -1)"
    chmod +x "$WAIFU2X_BIN"
    echo "waifu2x downloaded OK"
  fi

  [[ -x "$WAIFU2X_BIN" ]] || { echo "ERROR: waifu2x binary not found."; exit 1; }

  # Map model name: cunet -> models-cunet etc.
  case "$MODEL" in
    cunet)  W2X_MODEL="models-cunet" ;;
    photo)  W2X_MODEL="models-upconv_7_photo" ;;
    anime)  W2X_MODEL="models-upconv_7_anime_style_art_rgb" ;;
    models-*)  W2X_MODEL="$MODEL" ;;  # allow passing full model name
    *)      W2X_MODEL="models-cunet" ;;
  esac

  # Map denoise strength to waifu2x -n level
  case "$DENOISE_STRENGTH" in
    none)     W2X_N="-1" ;;
    mild)     W2X_N="1"  ;;
    moderate) W2X_N="2"  ;;
    strong)   W2X_N="3"  ;;
    vheavy)   W2X_N="3"  ;;
    *)        W2X_N="1"  ;;
  esac

  GPU_FLAG=""
  [[ -n "$SELECTED_GPUS" ]] && GPU_FLAG="-g $SELECTED_GPUS"

  echo "Running waifu2x: model=$W2X_MODEL scale=${OUTSCALE}x denoise=$W2X_N"
  # shellcheck disable=SC2086
  "$WAIFU2X_BIN" \
    -i "$WORKDIR/input_frames" \
    -o "$WORKDIR/output_frames_part0" \
    -s "$OUTSCALE" \
    -n "$W2X_N" \
    -m "$W2X_MODEL" \
    $GPU_FLAG

else
  echo "ERROR: Unknown backend: $BACKEND"
  exit 1
fi

# ── Merge output frame parts ──────────────────────────────────────────────────
echo "Merging output frames..."
rm -rf "$WORKDIR/output_frames_final"/*
find "$WORKDIR" -maxdepth 1 -type d -name "output_frames_part*" | sort | \
  while read -r d; do
    cp "$d"/* "$WORKDIR/output_frames_final/" 2>/dev/null || true
  done

echo "Merged: $(find "$WORKDIR/output_frames_final" -name "*.${FRAME_FORMAT}" | wc -l) frames"

# ── Detect output frame pattern ───────────────────────────────────────────────
INPUT_PATTERN=""
if ls "$WORKDIR"/output_frames_final/*_out."$FRAME_FORMAT" >/dev/null 2>&1; then
  INPUT_PATTERN="$WORKDIR/output_frames_final/%08d_out.${FRAME_FORMAT}"
elif ls "$WORKDIR"/output_frames_final/*."$FRAME_FORMAT" >/dev/null 2>&1; then
  INPUT_PATTERN="$WORKDIR/output_frames_final/%08d.${FRAME_FORMAT}"
else
  echo "ERROR: No output frames found in $WORKDIR/output_frames_final"
  exit 1
fi
echo "Frame pattern: $INPUT_PATTERN"

# ── Build post-processing filter chain ───────────────────────────────────────
# Sharpening is applied AFTER upscaling during encode.
# For animation: keep values conservative to avoid sharpening compression
# artifacts or ringing around lines.

SHARPEN_FILTER="$(get_sharpen_filter "$SHARPEN_STRENGTH")"
VF_CHAIN=""
if [[ -n "$SHARPEN_FILTER" ]]; then
  VF_CHAIN="$SHARPEN_FILTER"
  echo "Post-encode sharpening: $SHARPEN_FILTER"
fi

# ── Encode upscaled video ─────────────────────────────────────────────────────
echo "Encoding video..."
upscaled_video="$WORKDIR/upscaled_video.${CONTAINER}"

FFMPEG_VF_ARGS=()
[[ -n "$VF_CHAIN" ]] && FFMPEG_VF_ARGS=(-vf "$VF_CHAIN")

ffmpeg -y \
  -framerate "$FPS" \
  -i "$INPUT_PATTERN" \
  "${FFMPEG_VF_ARGS[@]}" \
  -c:v hevc_nvenc \
  -preset p7 \
  -profile:v main10 \
  -pix_fmt p010le \
  -rc vbr \
  -cq "$CQ" \
  -b:v 0 \
  "$upscaled_video"

# ── Mux audio ─────────────────────────────────────────────────────────────────
echo "Adding original audio..."
if [[ -f "$WORKDIR/original_audio.mka" ]]; then
  ffmpeg -y \
    -i "$upscaled_video" \
    -i "$WORKDIR/original_audio.mka" \
    -map 0:v:0 -map 1:a? \
    -c:v copy -c:a copy \
    "$OUTPUT"
else
  echo "No audio found — copying video only"
  cp "$upscaled_video" "$OUTPUT"
fi

echo "------------------------------------------------------------"
echo "Final output: $OUTPUT"
echo "------------------------------------------------------------"

# ── Cleanup ───────────────────────────────────────────────────────────────────
if [[ "$DELETE_TEMP" -eq 1 ]]; then
  echo "Deleting temp files..."
  rm -rf "$WORKDIR"/input_frames \
         "$WORKDIR"/input_frames_part* \
         "$WORKDIR"/input_frames_denoised \
         "$WORKDIR"/output_frames_part* \
         "$WORKDIR"/output_frames_final
  rm -f  "$WORKDIR"/original_audio.* \
         "$WORKDIR"/upscaled_video.*
fi
