#!/usr/bin/env bash
set -euo pipefail

# setup_realesrgan_auto.sh
# Ubuntu/Debian-focused installer/manager for:
# - PyTorch Real-ESRGAN on NVIDIA CUDA
# - Real-ESRGAN NCNN Vulkan on AMD/Intel/NVIDIA fallback
# - Real-CUGAN NCNN Vulkan
#
# Actions:
#   --install, --update, --repair, --status, --uninstall
#
# Safe defaults:
# - NVIDIA -> PyTorch CUDA
# - AMD/Intel -> NCNN Vulkan
# - Real-CUGAN can be installed with --backend realcugan

INSTALL_DIR="$HOME/realesrgan"
CONFIG_FILE=""
ACTION="install"
BACKEND="auto"
TORCH_BACKEND="auto"
REMOVE_PACKAGES=0
FORCE=0

PYTORCH_REPO="https://github.com/xinntao/Real-ESRGAN.git"
NCNN_REPO_API="https://api.github.com/repos/xinntao/Real-ESRGAN-ncnn-vulkan/releases/latest"
REALCUGAN_REPO_API="https://api.github.com/repos/nihui/realcugan-ncnn-vulkan/releases/latest"

GPU_TYPE="cpu"
GPU_COUNT=0
GPU_INFO=""
SELECTED_GPUS=""
TILE=1200
MODEL="realesr-animevideov3"
OUTSCALE=2
ENCODER="hevc_nvenc"
CQ=18
CONTAINER="mkv"
CONTENT_TYPE="anime"
INTERACTIVE=0
NCNN_BIN=""
REALCUGAN_BIN=""

usage() {
cat << EOF
Usage:
  ./setup_realesrgan_auto.sh [action] [options]

Actions:
  --install              Install everything, default
  --update               Update/reinstall selected backend
  --repair               Recreate Python venv / reinstall backend
  --status               Show installed status
  --uninstall            Remove install directory
  --remove-packages      With --uninstall, also remove optional packages
  --force                Skip uninstall confirmation

Options:
  --backend auto|pytorch|ncnn|realcugan
  --torch auto|cu121|cu118|cpu
  --install-dir PATH
  --interactive          Ask questions and select recommended defaults
  --content TYPE         anime|cartoon|live|old-anime|low-quality|restore
  -h, --help

Decision table:
  NVIDIA with nvidia-smi     -> PyTorch CUDA
  AMD / Intel with Vulkan    -> NCNN Vulkan
  Real-CUGAN requested       -> realcugan-ncnn-vulkan
  CPU / fallback             -> NCNN Vulkan fallback

Examples:
  ./setup_realesrgan_auto.sh --install
  ./setup_realesrgan_auto.sh --backend ncnn
  ./setup_realesrgan_auto.sh --backend realcugan
  ./setup_realesrgan_auto.sh --repair
  ./setup_realesrgan_auto.sh --status
  ./setup_realesrgan_auto.sh --uninstall
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) ACTION="install"; shift ;;
    --update) ACTION="update"; shift ;;
    --repair) ACTION="repair"; shift ;;
    --status) ACTION="status"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    --remove-packages) REMOVE_PACKAGES=1; shift ;;
    --force) FORCE=1; shift ;;
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --torch) TORCH_BACKEND="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --interactive) INTERACTIVE=1; shift ;;
    --content) CONTENT_TYPE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

CONFIG_FILE="$INSTALL_DIR/realesrgan_auto.conf"

log() { echo -e "\n==== $* ===="; }

install_os_packages() {
  log "Installing Ubuntu/Debian prerequisites"
  if ! command -v apt >/dev/null 2>&1; then
    echo "ERROR: This script currently supports Ubuntu/Debian apt-based systems."
    exit 1
  fi

  sudo apt update
  sudo apt install -y \
    git wget curl unzip ffmpeg \
    python3 python3-venv python3-pip \
    build-essential \
    libgl1 libglib2.0-0 \
    pciutils vulkan-tools
}

detect_gpu() {
  GPU_TYPE="cpu"
  GPU_COUNT=0
  GPU_INFO=""

  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    GPU_TYPE="nvidia"
    GPU_INFO="$(nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader,nounits)"
    GPU_COUNT="$(echo "$GPU_INFO" | sed '/^\s*$/d' | wc -l)"
    return
  fi

  if command -v lspci >/dev/null 2>&1 && lspci | grep -Ei "VGA|3D|Display" | grep -qi "AMD"; then
    GPU_TYPE="amd"
    GPU_INFO="$(lspci | grep -Ei "VGA|3D|Display" | grep -i "AMD")"
    GPU_COUNT="$(echo "$GPU_INFO" | sed '/^\s*$/d' | wc -l)"
    return
  fi

  if command -v lspci >/dev/null 2>&1 && lspci | grep -Ei "VGA|3D|Display" | grep -qi "Intel"; then
    GPU_TYPE="intel"
    GPU_INFO="$(lspci | grep -Ei "VGA|3D|Display" | grep -i "Intel")"
    GPU_COUNT="$(echo "$GPU_INFO" | sed '/^\s*$/d' | wc -l)"
    return
  fi
}

choose_backend() {
  log "Applying backend decision table"
  local requested="$BACKEND"

  case "$requested" in
    auto|"")
      case "$GPU_TYPE" in
        nvidia) BACKEND="pytorch" ;;
        amd|intel) BACKEND="ncnn" ;;
        *) BACKEND="ncnn" ;;
      esac
      ;;
    pytorch)
      if [[ "$GPU_TYPE" == "nvidia" ]]; then
        BACKEND="pytorch"
      else
        echo "Requested PyTorch CUDA, but no NVIDIA GPU was detected."
        echo "Auto-correcting to NCNN Vulkan."
        BACKEND="ncnn"
      fi
      ;;
    ncnn)
      BACKEND="ncnn"
      ;;
    realcugan)
      BACKEND="realcugan"
      ;;
    *)
      echo "Unknown backend requested: $requested"
      echo "Auto-correcting based on detected GPU."
      case "$GPU_TYPE" in
        nvidia) BACKEND="pytorch" ;;
        amd|intel) BACKEND="ncnn" ;;
        *) BACKEND="ncnn" ;;
      esac
      ;;
  esac

  echo "Requested backend: $requested"
  echo "Detected GPU type: $GPU_TYPE"
  echo "Selected backend:  $BACKEND"
}

choose_torch_backend() {
  [[ "$BACKEND" == "pytorch" ]] || return 0
  if [[ "$TORCH_BACKEND" == "auto" ]]; then
    TORCH_BACKEND="cu121"
  fi
  echo "Selected Torch backend: $TORCH_BACKEND"
}

rank_nvidia_gpus() {
  SELECTED_GPUS=""
  [[ "$GPU_TYPE" == "nvidia" ]] || return 0

  log "Ranking NVIDIA GPUs"
  # Prefer V100/A100/H100/L40/RTX 4090/3090/RTX/Quadro/Other by rough RealESRGAN usefulness.
  local ranked=""
  local patterns=("V100" "A100" "H100" "L40" "4090" "3090" "RTX" "Quadro" "P100")

  for pat in "${patterns[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local idx
      idx="$(echo "$line" | cut -d',' -f1 | xargs)"
      if [[ ",$ranked," != *",$idx,"* ]]; then
        ranked="${ranked:+$ranked,}$idx"
      fi
    done < <(echo "$GPU_INFO" | grep -i "$pat" || true)
  done

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local idx
    idx="$(echo "$line" | cut -d',' -f1 | xargs)"
    if [[ ",$ranked," != *",$idx,"* ]]; then
      ranked="${ranked:+$ranked,}$idx"
    fi
  done <<< "$GPU_INFO"

  # If multiple V100s exist, prefer only the V100 group by default.
  # This avoids mixing slower cards like RTX 5000 into a V100 batch unless the user overrides in upscale script.
  local v100_only
  v100_only="$(echo "$GPU_INFO" | grep -i "V100" | cut -d',' -f1 | xargs | tr ' ' ',' || true)"
  if [[ -n "$v100_only" ]]; then
    SELECTED_GPUS="$v100_only"
  else
    SELECTED_GPUS="$ranked"
  fi

  echo "Selected NVIDIA GPUs: $SELECTED_GPUS"
}


content_wizard() {
  [[ "$INTERACTIVE" -eq 1 ]] || return 0

  echo
  echo "Select content type:"
  echo "  1) Anime / animation video"
  echo "  2) Old anime / softer source"
  echo "  3) Cartoon / western animation"
  echo "  4) Live action / real video"
  echo "  5) Low-quality / noisy source"
  echo "  6) Restore only / avoid heavy upscale"
  read -r -p "Choose [1-6] default 1: " choice

  case "${choice:-1}" in
    1) CONTENT_TYPE="anime" ;;
    2) CONTENT_TYPE="old-anime" ;;
    3) CONTENT_TYPE="cartoon" ;;
    4) CONTENT_TYPE="live" ;;
    5) CONTENT_TYPE="low-quality" ;;
    6) CONTENT_TYPE="restore" ;;
    *) CONTENT_TYPE="anime" ;;
  esac
}

apply_content_defaults() {
  case "$CONTENT_TYPE" in
    anime)
      MODEL="realesr-animevideov3"
      OUTSCALE=2
      ;;
    old-anime)
      MODEL="realesr-animevideov3"
      OUTSCALE=2
      ;;
    cartoon)
      MODEL="realesr-animevideov3"
      OUTSCALE=2
      ;;
    live)
      MODEL="RealESRGAN_x4plus"
      OUTSCALE=2
      ;;
    low-quality)
      MODEL="realesr-animevideov3"
      OUTSCALE=1
      ;;
    restore)
      MODEL="realesr-animevideov3"
      OUTSCALE=1
      ;;
    *)
      MODEL="realesr-animevideov3"
      OUTSCALE=2
      ;;
  esac

  if [[ "$BACKEND" == "realcugan" ]]; then
    MODEL="realcugan"
    [[ "$OUTSCALE" -lt 2 ]] && OUTSCALE=2
  fi

  echo "Content type: $CONTENT_TYPE"
  echo "Recommended model: $MODEL"
  echo "Recommended outscale: $OUTSCALE"
}

choose_tile() {
  TILE=1200
  if [[ "$GPU_TYPE" == "nvidia" && -n "$GPU_INFO" ]]; then
    local max_vram
    max_vram="$(echo "$GPU_INFO" | awk -F',' '{print $3}' | xargs -n1 | sort -nr | head -1)"
    if [[ "${max_vram:-0}" -ge 30000 ]]; then TILE=0
    elif [[ "${max_vram:-0}" -ge 16000 ]]; then TILE=1200
    elif [[ "${max_vram:-0}" -ge 8000 ]]; then TILE=800
    else TILE=400
    fi
  fi
  echo "Selected tile: $TILE"
}

latest_release_zip() {
  local api="$1"
  local label="$2"
  local url
  url="$(curl -s "$api" | grep browser_download_url | grep -E "ubuntu.*zip|linux.*zip" | head -1 | cut -d '"' -f 4)"
  if [[ -z "$url" ]]; then
    url="$(curl -s "$api" | grep browser_download_url | grep ".zip" | head -1 | cut -d '"' -f 4)"
  fi
  if [[ -z "$url" ]]; then
    echo "ERROR: Could not find latest $label zip release."
    exit 1
  fi
  echo "$url"
}

install_pytorch_realesrgan() {
  log "Installing PyTorch Real-ESRGAN"
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [[ ! -d Real-ESRGAN ]]; then
    git clone "$PYTORCH_REPO"
  else
    (cd Real-ESRGAN && git pull)
  fi

  cd Real-ESRGAN
  python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip setuptools wheel

  case "$TORCH_BACKEND" in
    cu121)
      pip install torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 --index-url https://download.pytorch.org/whl/cu121
      ;;
    cu118)
      pip install torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2 --index-url https://download.pytorch.org/whl/cu118
      ;;
    cpu)
      pip install torch==2.1.2 torchvision==0.16.2 torchaudio==2.1.2
      ;;
    *)
      echo "ERROR: Unknown --torch value: $TORCH_BACKEND"
      exit 1
      ;;
  esac

  pip install -r requirements.txt
  pip install -e .

  # Known compatibility pins for this Real-ESRGAN/basicSR generation.
  pip uninstall -y numpy opencv-python || true
  pip install numpy==1.26.4 opencv-python==4.8.1.78

  local site_packages
  site_packages="$(python -c "import site; print(site.getsitepackages()[0])")"
  rm -rf "$site_packages"/-orch* "$site_packages"/~orch* || true

  python - << 'PY'
import torch
print("CUDA available:", torch.cuda.is_available())
print("GPU count:", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    print(i, torch.cuda.get_device_name(i))
PY
}

install_ncnn_realesrgan() {
  log "Installing Real-ESRGAN NCNN Vulkan"
  mkdir -p "$INSTALL_DIR/ncnn"
  cd "$INSTALL_DIR/ncnn"

  local url
  url="$(latest_release_zip "$NCNN_REPO_API" "Real-ESRGAN NCNN Vulkan")"
  echo "Downloading: $url"

  rm -f realesrgan-ncnn-vulkan.zip
  wget -O realesrgan-ncnn-vulkan.zip "$url"
  unzip -o realesrgan-ncnn-vulkan.zip

  NCNN_BIN="$(find "$INSTALL_DIR/ncnn" -type f -name "realesrgan-ncnn-vulkan" | head -1)"
  if [[ -z "$NCNN_BIN" ]]; then
    echo "ERROR: Could not find realesrgan-ncnn-vulkan binary."
    exit 1
  fi
  chmod +x "$NCNN_BIN"
  vulkaninfo --summary || true
}

install_realcugan() {
  log "Installing Real-CUGAN NCNN Vulkan"
  mkdir -p "$INSTALL_DIR/realcugan"
  cd "$INSTALL_DIR/realcugan"

  local url
  url="$(latest_release_zip "$REALCUGAN_REPO_API" "Real-CUGAN NCNN Vulkan")"
  echo "Downloading: $url"

  rm -f realcugan-ncnn-vulkan.zip
  wget -O realcugan-ncnn-vulkan.zip "$url"
  unzip -o realcugan-ncnn-vulkan.zip

  REALCUGAN_BIN="$(find "$INSTALL_DIR/realcugan" -type f -name "realcugan-ncnn-vulkan" | head -1)"
  if [[ -z "$REALCUGAN_BIN" ]]; then
    echo "ERROR: Could not find realcugan-ncnn-vulkan binary."
    exit 1
  fi
  chmod +x "$REALCUGAN_BIN"
  vulkaninfo --summary || true
}

write_config() {
  mkdir -p "$INSTALL_DIR"
  cat > "$CONFIG_FILE" << EOF
INSTALL_DIR="$INSTALL_DIR"
GPU_TYPE="$GPU_TYPE"
GPU_COUNT="$GPU_COUNT"
GPU_INFO="$(echo "$GPU_INFO" | tr '\n' ';')"
BACKEND="$BACKEND"
TORCH_BACKEND="$TORCH_BACKEND"
SELECTED_GPUS="$SELECTED_GPUS"
CONTENT_TYPE="$CONTENT_TYPE"
MODEL="$MODEL"
OUTSCALE="$OUTSCALE"
TILE="$TILE"
ENCODER="$ENCODER"
CQ="$CQ"
CONTAINER="$CONTAINER"
FRAME_FORMAT="png"
NCNN_BIN="$NCNN_BIN"
REALCUGAN_BIN="$REALCUGAN_BIN"
EOF
  echo "Config written to: $CONFIG_FILE"
}

print_summary() {
  log "RealESRGAN Auto Setup Summary"
  echo "Install dir:   $INSTALL_DIR"
  echo "GPU type:      $GPU_TYPE"
  echo "GPU count:     $GPU_COUNT"
  echo "GPU info:"
  echo "$GPU_INFO"
  echo
  echo "Backend:       $BACKEND"
  echo "Torch:         $TORCH_BACKEND"
  echo "Selected GPUs: $SELECTED_GPUS"
  echo "Content type:  $CONTENT_TYPE"
  echo "Model:         $MODEL"
  echo "Outscale:      $OUTSCALE"
  echo "Tile:          $TILE"
  echo "Config:        $CONFIG_FILE"
}

show_status() {
  log "Status"
  detect_gpu
  echo "Detected GPU type: $GPU_TYPE"
  echo "Detected GPU count: $GPU_COUNT"
  echo "$GPU_INFO"
  echo
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config:"
    cat "$CONFIG_FILE"
  else
    echo "No config found at $CONFIG_FILE"
  fi
  echo
  echo "Install directory:"
  ls -la "$INSTALL_DIR" 2>/dev/null || echo "Not installed."
}

uninstall_all() {
  log "Uninstall"
  echo "This will remove: $INSTALL_DIR"
  if [[ "$FORCE" -ne 1 ]]; then
    read -r -p "Continue? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
  fi

  rm -rf "$INSTALL_DIR"

  if [[ "$REMOVE_PACKAGES" -eq 1 ]]; then
    echo "Removing optional OS packages..."
    sudo apt remove -y vulkan-tools || true
    sudo apt autoremove -y || true
  fi
  echo "Uninstall complete."
}

do_install() {
  install_os_packages
  detect_gpu
  echo "Detected GPU type: $GPU_TYPE"
  echo "$GPU_INFO"
  choose_backend
  choose_torch_backend
  rank_nvidia_gpus
  choose_tile
  content_wizard
  apply_content_defaults

  case "$BACKEND" in
    pytorch) install_pytorch_realesrgan ;;
    ncnn) install_ncnn_realesrgan ;;
    realcugan) install_realcugan ;;
    *) echo "ERROR: Unknown backend: $BACKEND"; exit 1 ;;
  esac

  write_config
  print_summary
}

case "$ACTION" in
  install|update) do_install ;;
  repair)
    rm -rf "$INSTALL_DIR/Real-ESRGAN/venv" || true
    do_install
    ;;
  status) show_status ;;
  uninstall) uninstall_all ;;
  *) echo "ERROR: Unknown action: $ACTION"; exit 1 ;;
esac
