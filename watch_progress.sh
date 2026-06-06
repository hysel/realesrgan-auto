#!/usr/bin/env bash
# =============================================================================
# Animation Upscaling Progress Watcher + Post-Processing Menu
# Watches realcugan-ncnn-vulkan or waifu2x-ncnn-vulkan progress,
# then offers post-processing options when done.
# =============================================================================

REFRESH_SECS=3

# ── Known paths (auto-detected from running process, fallback to these) ───────
DEFAULT_INPUT="$HOME/video_upscale/input_frames"
DEFAULT_OUTPUT="$HOME/video_upscale/output_frames_part0"
AUDIO_FILE="$HOME/video_upscale/original_audio.mka"
FINAL_DIR="$HOME/video_upscale"

# ── GPU to use for re-processing runs ────────────────────────────────────────
GPU_ID=2

# =============================================================================

START_TIME=$(date +%s)
BINARY_DIR="$HOME/realcugan/realcugan-ncnn-vulkan-20220728-ubuntu"
WAIFU2X_DIR="$HOME/waifu2x/waifu2x-ncnn-vulkan-20220728-ubuntu"

count_files() {
  local dir="$1"
  [ -d "$dir" ] && ls "$dir" 2>/dev/null | wc -l || echo 0
}

make_bar() {
  local pct="$1"
  local width=40
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local bar="" i
  for (( i=0; i<filled; i++ )); do bar="${bar}#"; done
  for (( i=0; i<empty;  i++ )); do bar="${bar}-"; done
  echo "$bar"
}

format_time() {
  local secs="$1"
  local h=$(( secs / 3600 ))
  local m=$(( (secs % 3600) / 60 ))
  local s=$(( secs % 60 ))
  if   [ "$h" -gt 0 ]; then printf "%dh %02dm %02ds" "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then printf "%dm %02ds" "$m" "$s"
  else                      printf "%ds" "$s"
  fi
}

detect_process() {
  # Detect running realcugan or waifu2x and extract -i / -o paths
  local cmd
  cmd=$(ps aux | grep -E "realcugan-ncnn-vulkan|waifu2x-ncnn-vulkan" \
        | grep -v grep | head -1)
  if [ -n "$cmd" ]; then
    INPUT_DIR=$(echo "$cmd"  | grep -oP '(?<=-i )\S+')
    OUTPUT_DIR=$(echo "$cmd" | grep -oP '(?<=-o )\S+')
  fi
}

detect_process
INPUT_DIR="${INPUT_DIR:-$DEFAULT_INPUT}"
OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT}"

# =============================================================================
# PROGRESS DISPLAY
# =============================================================================
show_progress() {
  local now=$1
  local elapsed=$(( now - START_TIME ))
  local total done pct bar

  total=$(count_files "$INPUT_DIR")
  done=$(count_files "$OUTPUT_DIR")

  echo "======================================================"
  echo "  Upscaling Progress              $(date '+%H:%M:%S')"
  echo "======================================================"
  echo ""
  echo "  Input :  $INPUT_DIR"
  echo "  Output:  $OUTPUT_DIR"
  echo ""

  if [ "$total" -eq 0 ]; then
    echo "  Waiting for input frames..."
    echo ""
    return 1
  fi

  pct=$(( done * 100 / total ))
  bar=$(make_bar "$pct")

  echo "  Frames:  $done / $total"
  echo "  [${bar}] ${pct}%"
  echo ""
  echo "  Elapsed: $(format_time $elapsed)"

  if [ "$done" -gt 10 ] && [ "$elapsed" -gt 0 ]; then
    local fpm=$(( done * 60 / elapsed ))
    local remaining=$(( total - done ))
    if [ "$fpm" -gt 0 ]; then
      local eta=$(( remaining * 60 / fpm ))
      echo "  Rate:    ${fpm} frames/min"
      echo "  ETA:     $(format_time $eta)"
    fi
  fi

  local running
  running=$(ps aux | grep -E "realcugan-ncnn-vulkan|waifu2x-ncnn-vulkan" \
            | grep -v grep | wc -l)
  echo ""
  [ "$running" -gt 0 ] && echo "  Status:  RUNNING" || echo "  Status:  PROCESS ENDED"

  [ "$done" -ge "$total" ] && return 0 || return 1
}

# =============================================================================
# POST-PROCESSING MENU
# =============================================================================

# ── Option 1: FFmpeg sharpening ───────────────────────────────────────────────
run_ffmpeg_sharpen() {
  echo ""
  echo "  FFmpeg Sharpening"
  echo "  -----------------"
  echo "  la = luma sharpening strength"
  echo "  Suggested values:"
  echo "    0.8 = subtle    1.2 = moderate (recommended)"
  echo "    1.8 = strong    2.5 = very aggressive"
  echo ""
  read -rp "  Enter sharpening strength [default: 1.2]: " la
  la="${la:-1.2}"

  local input_video
  echo ""
  echo "  Available videos in $FINAL_DIR:"
  ls "$FINAL_DIR"/*.mp4 2>/dev/null | xargs -I{} basename {}
  echo ""
  read -rp "  Enter video filename to sharpen (in $FINAL_DIR): " fname
  local input_video="$FINAL_DIR/$fname"

  if [ ! -f "$input_video" ]; then
    echo "  File not found: $input_video"
    return
  fi

  local out="$FINAL_DIR/sharpened_la${la}.mp4"
  echo ""
  echo "  Running: unsharp la=${la} on $fname"
  echo "  Output:  $out"
  echo ""

  ffmpeg -i "$input_video" \
    -vf "unsharp=lx=3:ly=3:la=${la}:cx=3:cy=3:ca=0.5" \
    -c:v libx264 -crf 16 -preset slow \
    -pix_fmt yuv420p \
    "$out" \
    && echo "" \
    && echo "  Done: $out" \
    || echo "  ffmpeg failed — check output above"
}

# ── Option 2: Re-run realcugan with conservative mode ─────────────────────────
run_realcugan_conservative() {
  local binary="$BINARY_DIR/realcugan-ncnn-vulkan"
  if [ ! -f "$binary" ]; then
    echo "  realcugan binary not found at: $binary"
    echo "  Edit BINARY_DIR at the top of this script."
    return
  fi

  echo ""
  echo "  realcugan Conservative Re-run"
  echo "  -----------------------------"
  echo "  Denoise levels:"
  echo "    -1 = none (what you ran before)"
  echo "     0 = conservative (recommended for animation)"
  echo "     1 = light    2 = medium    3 = heavy"
  echo ""
  read -rp "  Denoise level [default: 0]: " nlevel
  nlevel="${nlevel:-0}"

  local outdir="$HOME/video_upscale/output_conservative_n${nlevel}"
  mkdir -p "$outdir"

  echo ""
  echo "  Input:  $INPUT_DIR"
  echo "  Output: $outdir"
  echo "  Denoise: $nlevel  Scale: 2x  GPU: $GPU_ID"
  echo ""
  echo "  Starting realcugan... (run this script again in another terminal to watch progress)"
  echo ""

  # Update watched paths for progress display
  OUTPUT_DIR="$outdir"

  "$binary" \
    -i "$INPUT_DIR" \
    -o "$outdir" \
    -s 2 -n "$nlevel" -g "$GPU_ID" \
    && echo "" && echo "  realcugan finished: $outdir" \
    || echo "  realcugan failed — check output above"
}

# ── Option 3: Re-run realcugan with models-nose ───────────────────────────────
run_realcugan_nose() {
  local binary="$BINARY_DIR/realcugan-ncnn-vulkan"
  if [ ! -f "$binary" ]; then
    echo "  realcugan binary not found at: $binary"
    return
  fi

  local outdir="$HOME/video_upscale/output_nose"
  mkdir -p "$outdir"

  echo ""
  echo "  realcugan models-nose (no-denoise architecture)"
  echo "  ------------------------------------------------"
  echo "  Input:  $INPUT_DIR"
  echo "  Output: $outdir"
  echo "  GPU: $GPU_ID"
  echo ""

  OUTPUT_DIR="$outdir"

  "$binary" \
    -i "$INPUT_DIR" \
    -o "$outdir" \
    -s 2 -m models-nose -g "$GPU_ID" \
    && echo "" && echo "  Done: $outdir" \
    || echo "  realcugan failed"
}

# ── Option 4: Run waifu2x ─────────────────────────────────────────────────────
run_waifu2x() {
  local binary="$WAIFU2X_DIR/waifu2x-ncnn-vulkan"

  # Download if not present
  if [ ! -f "$binary" ]; then
    echo ""
    echo "  waifu2x not found — downloading..."
    mkdir -p "$HOME/waifu2x"
    wget -q --show-progress -O /tmp/waifu2x.zip \
      "https://github.com/nihui/waifu2x-ncnn-vulkan/releases/download/20220728/waifu2x-ncnn-vulkan-20220728-ubuntu.zip" \
      && unzip -q /tmp/waifu2x.zip -d "$HOME/waifu2x" \
      && chmod +x "$binary" \
      && echo "  waifu2x downloaded OK" \
      || { echo "  Download failed"; return; }
  fi

  echo ""
  echo "  waifu2x (purpose-built for animation)"
  echo "  --------------------------------------"
  echo "  Models:"
  echo "    1) models-cunet              (best quality, recommended)"
  echo "    2) models-upconv_7_anime_style_art_rgb  (faster)"
  echo "    3) models-upconv_7_photo     (photographic)"
  echo ""
  read -rp "  Choose model [default: 1]: " mchoice
  case "${mchoice:-1}" in
    2) MODEL="models-upconv_7_anime_style_art_rgb" ;;
    3) MODEL="models-upconv_7_photo" ;;
    *) MODEL="models-cunet" ;;
  esac

  echo ""
  echo "  Denoise levels:  -1=none  0=copy  1=light  2=medium  3=heavy"
  read -rp "  Denoise level [default: 1]: " nlevel
  nlevel="${nlevel:-1}"

  local outdir="$HOME/video_upscale/output_waifu2x_${MODEL##*_}"
  mkdir -p "$outdir"

  echo ""
  echo "  Input:  $INPUT_DIR"
  echo "  Output: $outdir"
  echo "  Model:  $MODEL   Denoise: $nlevel   GPU: $GPU_ID"
  echo ""

  OUTPUT_DIR="$outdir"

  "$binary" \
    -i "$INPUT_DIR" \
    -o "$outdir" \
    -s 2 -n "$nlevel" \
    -m "$MODEL" \
    -g "$GPU_ID" \
    && echo "" && echo "  waifu2x done: $outdir" \
    || echo "  waifu2x failed"
}

# ── Option 5: Reassemble video ────────────────────────────────────────────────
run_reassemble() {
  echo ""
  echo "  Reassemble Video"
  echo "  ----------------"
  echo ""
  echo "  Available output frame folders:"
  ls -d "$HOME/video_upscale"/output_frames* \
        "$HOME/video_upscale"/output_conservative* \
        "$HOME/video_upscale"/output_nose* \
        "$HOME/video_upscale"/output_waifu2x* \
        2>/dev/null | xargs -I{} basename {}
  echo ""
  read -rp "  Enter frame folder name (in $HOME/video_upscale): " fdir
  local frames_dir="$HOME/video_upscale/$fdir"

  if [ ! -d "$frames_dir" ]; then
    echo "  Directory not found: $frames_dir"
    return
  fi

  echo ""
  read -rp "  FPS [default: 25]: " fps
  fps="${fps:-25}"

  read -rp "  CRF quality 0-51, lower=better [default: 16]: " crf
  crf="${crf:-16}"

  # Detect frame filename pattern
  local first_frame
  first_frame=$(ls "$frames_dir" | head -1)
  local ext="${first_frame##*.}"
  local pattern

  # Check if filenames are zero-padded numbers
  if [[ "$first_frame" =~ ^[0-9]+\.$ext$ ]]; then
    local digits=${#first_frame}
    digits=$(( digits - ${#ext} - 1 ))
    pattern="%0${digits}d.${ext}"
  else
    # realcugan adds _realcugan suffix — use glob pattern
    pattern="*.${ext}"
    echo ""
    echo "  NOTE: frames don't follow a simple numbered pattern."
    echo "  FFmpeg needs sequential numbered files. Renaming frames..."
    local tmp="$frames_dir/_renamed"
    mkdir -p "$tmp"
    local n=1
    for f in $(ls "$frames_dir"/*."$ext" | sort); do
      printf -v newname "%08d.${ext}" "$n"
      cp "$f" "$tmp/$newname"
      (( n++ ))
    done
    frames_dir="$tmp"
    pattern="%08d.${ext}"
    echo "  Renamed $((n-1)) frames OK"
  fi

  local outfile="$FINAL_DIR/final_$(basename "$fdir")_${fps}fps.mp4"

  echo ""
  echo "  Frames:  $frames_dir/$pattern"
  echo "  Audio:   $AUDIO_FILE"
  echo "  Output:  $outfile"
  echo "  FPS: $fps   CRF: $crf"
  echo ""

  if [ -f "$AUDIO_FILE" ]; then
    ffmpeg -r "$fps" \
      -i "$frames_dir/$pattern" \
      -i "$AUDIO_FILE" \
      -c:v libx264 -crf "$crf" -preset slow \
      -pix_fmt yuv420p \
      -c:a copy \
      -map 0:v -map 1:a \
      "$outfile"
  else
    echo "  Audio file not found at $AUDIO_FILE — reassembling without audio"
    ffmpeg -r "$fps" \
      -i "$frames_dir/$pattern" \
      -c:v libx264 -crf "$crf" -preset slow \
      -pix_fmt yuv420p \
      "$outfile"
  fi

  echo ""
  [ -f "$outfile" ] \
    && echo "  Done: $outfile" \
    || echo "  ffmpeg failed — check output above"
}

# =============================================================================
# MAIN MENU (shown after upscaling finishes or if already done)
# =============================================================================
show_menu() {
  echo ""
  echo "======================================================"
  echo "  Post-Processing Menu"
  echo "======================================================"
  echo ""
  echo "  The upscaled frames are in:"
  echo "  $OUTPUT_DIR"
  echo ""
  echo "  What would you like to do?"
  echo ""
  echo "  1) Sharpen with FFmpeg          (quick, no re-processing)"
  echo "  2) Re-run realcugan             (conservative mode, less puffy)"
  echo "  3) Re-run realcugan             (models-nose, no-denoise architecture)"
  echo "  4) Run waifu2x                  (best for cel animation)"
  echo "  5) Reassemble video + audio     (make final .mp4)"
  echo "  6) Exit"
  echo ""
  read -rp "  Choice [1-6]: " choice

  case "$choice" in
    1) run_ffmpeg_sharpen ;;
    2) run_realcugan_conservative ;;
    3) run_realcugan_nose ;;
    4) run_waifu2x ;;
    5) run_reassemble ;;
    6) exit 0 ;;
    *) echo "  Invalid choice" ;;
  esac

  # Loop back to menu after action completes
  show_menu
}

# =============================================================================
# ENTRY POINT — watch progress, then show menu
# =============================================================================
while true; do
  clear
  NOW=$(date +%s)

  if show_progress "$NOW"; then
    # Finished
    echo ""
    echo "======================================================"
    echo "  Total time: $(format_time $(( NOW - START_TIME )))"
    echo "======================================================"
    show_menu
    break
  fi

  echo ""
  echo "======================================================"
  echo "  Refreshing every ${REFRESH_SECS}s  |  Ctrl+C to exit"
  echo "======================================================"

  sleep "$REFRESH_SECS"
done
