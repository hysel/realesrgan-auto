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
REQUESTED_BACKEND="auto"
TORCH_BACKEND="auto"
REMOVE_PACKAGES=0
FORCE=0
VERBOSE=0
QUIET=0

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
  --verbose              Show extra decision/debug information
  --quiet                Reduce console output

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
    --verbose) VERBOSE=1; shift ;;
    --quiet) QUIET=1; shift ;;
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


explain() {
  [[ "$QUIET" -eq 1 ]] && return 0
  echo "$@"
}

print_section() {
  [[ "$QUIET" -eq 1 ]] && return 0
  echo
  echo "===================================================="
  echo "$1"
  echo "===================================================="
}

print_detected_environment() {
  print_section "Detected Environment"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    echo "OS:"
    echo "  ${PRETTY_NAME:-Unknown}"
  fi

  echo
  echo "GPU Type:"
  echo "  $GPU_TYPE"
  echo
  echo "GPU Count:"
  echo "  $GPU_COUNT"
  echo
  echo "GPU Info:"
  if [[ -n "$GPU_INFO" ]]; then
    echo "$GPU_INFO" | sed 's/^/  /'
  else
    echo "  No GPU information available"
  fi
}

print_backend_decision() {
  print_section "Backend Selection"

  echo "Requested backend:"
  echo "  $REQUESTED_BACKEND"
  echo
  echo "Selected backend:"
  echo "  $BACKEND"
  echo

  case "$BACKEND" in
    pytorch)
      echo "Why:"
      echo "  NVIDIA GPU support was detected through nvidia-smi."
      echo "  PyTorch CUDA is usually the fastest and most flexible backend for NVIDIA GPUs."
      echo "  AMD and Intel backends are skipped because CUDA is preferred when available."
      ;;
    ncnn)
      echo "Why:"
      echo "  AMD, Intel, or non-CUDA hardware was detected."
      echo "  NCNN Vulkan is the safest cross-vendor backend for AMD, Intel, and NVIDIA fallback use."
      ;;
    realcugan)
      echo "Why:"
      echo "  Real-CUGAN was explicitly selected."
      echo "  This uses the Real-CUGAN NCNN Vulkan backend and is useful for anime sources where RealESRGAN looks too soft, puffy, or smudged."
      ;;
  esac
}

print_torch_decision() {
  [[ "$BACKEND" == "pytorch" ]] || return 0

  print_section "PyTorch Version Selection"

  echo "Selected Torch backend:"
  echo "  $TORCH_BACKEND"
  echo
  echo "Selected package versions:"
  echo "  torch       2.2.2"
  echo "  torchvision 0.17.2"
  echo "  torchaudio  2.2.2"
  echo
  echo "Why:"
  echo "  The older torch 2.1.2 package is no longer available from the CUDA 12.1 wheel index on some systems."
  echo "  torch 2.2.2 + torchvision 0.17.2 is available from the cu121 index and keeps compatibility with this RealESRGAN/basicSR setup."
  echo "  NumPy is pinned to 1.26.4 to avoid NumPy 2.x binary compatibility issues."
  echo "  OpenCV is pinned to 4.8.1.78 to stay compatible with NumPy 1.26.4."
}

print_gpu_decision() {
  [[ "$GPU_TYPE" == "nvidia" ]] || return 0

  print_section "NVIDIA GPU Selection"

  echo "Ranking rule:"
  echo "  Prefer high-memory datacenter GPUs first, then RTX/Quadro cards, then other NVIDIA GPUs."
  echo
  echo "Selected GPUs:"
  if [[ -n "$SELECTED_GPUS" ]]; then
    echo "  $SELECTED_GPUS"
  else
    echo "  None selected"
  fi
  echo
  echo "Why:"
  echo "  Matching GPUs with similar performance usually gives better multi-GPU frame processing."
  echo "  On a mixed V100 + RTX 5000 system, the V100s are preferred first."
  echo "  You can override this later in upscale_video_auto.sh with --gpus 0,1,2."
}

print_tile_decision() {
  print_section "Tile Selection"

  echo "Selected tile:"
  echo "  $TILE"
  echo
  echo "Why:"
  if [[ "$TILE" == "0" ]]; then
    echo "  The largest detected NVIDIA GPU has about 30GB+ VRAM."
    echo "  tile=0 allows full-frame processing and usually gives better performance when memory is sufficient."
  else
    echo "  Tile size was selected based on available VRAM."
    echo "  Smaller GPUs use smaller tiles to reduce out-of-memory risk."
  fi
}

print_content_decision() {
  print_section "Content / Model Selection"

  echo "Content type:"
  echo "  $CONTENT_TYPE"
  echo
  echo "Selected model:"
  echo "  $MODEL"
  echo
  echo "Selected outscale:"
  echo "  $OUTSCALE"
  echo
  echo "Why:"
  case "$CONTENT_TYPE" in
    anime|old-anime|cartoon)
      echo "  realesr-animevideov3 is the safer default for anime and animation video."
      echo "  It is generally less overprocessed than RealESRGAN_x4plus_anime_6B."
      ;;
    live)
      echo "  RealESRGAN_x4plus is better suited for real-world/live-action footage."
      ;;
    low-quality|restore)
      echo "  Lower outscale is used to avoid exaggerating compression artifacts or noisy details."
      ;;
    *)
      echo "  Defaulting to anime video settings."
      ;;
  esac
}

print_installation_plan() {
  print_section "Installation Plan"

  echo "Will install/configure:"
  echo "  OS packages: git, curl, wget, unzip, ffmpeg, python3-venv, vulkan-tools, build tools"
  echo "  Backend:     $BACKEND"
  echo "  Install dir: $INSTALL_DIR"
  echo "  Config file: $CONFIG_FILE"

  if [[ "$BACKEND" == "pytorch" ]]; then
    echo "  Python venv: $INSTALL_DIR/Real-ESRGAN/venv"
    echo "  PyTorch:     torch 2.2.2 / torchvision 0.17.2 / torchaudio 2.2.2"
    echo "  NumPy:       1.26.4"
    echo "  OpenCV:      4.8.1.78"
  elif [[ "$BACKEND" == "ncnn" ]]; then
    echo "  NCNN Vulkan: latest Linux/Ubuntu release from GitHub"
  elif [[ "$BACKEND" == "realcugan" ]]; then
    echo "  Real-CUGAN:  latest Linux/Ubuntu NCNN Vulkan release from GitHub"
  fi
}

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

  echo "Requested backend: $REQUESTED_BACKEND"
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


run_pip_with_log() {
  local log_file="$1"
  shift
  set +e
  "$@" 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e
  analyze_pip_log "$log_file"
  return "$rc"
}

analyze_pip_log() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 0

  if grep -qi "dependency resolver does not currently take into account" "$log_file"; then
    echo
    echo "Dependency warning detected."
    echo "Reason: pip found installed packages with conflicting version requirements."
    echo "Action: The script will apply known compatibility pins for RealESRGAN."
  fi

  if grep -qi "requires numpy>=2" "$log_file"; then
    echo
    echo "NumPy 2.x dependency conflict detected."
    echo "Reason: A package wants NumPy 2.x, but this RealESRGAN/PyTorch stack uses NumPy 1.26.4 for compatibility."
    echo "Action: Pinning known packages to NumPy-1.x-compatible versions."
    pip install --upgrade --force-reinstall \
      numpy==1.26.4 \
      opencv-python==4.8.1.78 \
      scipy==1.11.4 \
      scikit-image==0.21.0 \
      imageio==2.31.6 \
      tifffile==2023.7.10
  fi

  if grep -qi "No matching distribution found for torch==2.1.2" "$log_file"; then
    echo
    echo "Old Torch pin unavailable."
    echo "Action: Switching to torch 2.2.2 / torchvision 0.17.2 / torchaudio 2.2.2."
    TORCH_VERSION="2.2.2"
    TORCHVISION_VERSION="0.17.2"
    TORCHAUDIO_VERSION="2.2.2"
  fi

  if grep -qi "No matching distribution found" "$log_file"; then
    echo
    echo "A package version could not be found."
    echo "Tip: This can happen with unsupported Python versions or unavailable wheel indexes."
    echo "Recommended Python: 3.10 or 3.11."
  fi

  if grep -qi "ResolutionImpossible" "$log_file"; then
    echo
    echo "pip dependency resolution failed."
    echo "Action: Try --repair, which recreates the venv and installs the known-good pins."
  fi
}

apply_realesrgan_compatibility_pins() {
  echo
  echo "Applying RealESRGAN compatibility pins..."
  echo "Why:"
  echo "  - NumPy 2.x can break older compiled modules."
  echo "  - Newer opencv-python releases may require NumPy 2.x."
  echo "  - Newer tifffile/scikit-image stacks may pull NumPy 2.x."
  echo "  - These pins keep the RealESRGAN/basicSR/PyTorch stack stable."

  pip install --upgrade --force-reinstall \
    numpy==1.26.4 \
    opencv-python==4.8.1.78 \
    scipy==1.11.4 \
    scikit-image==0.21.0 \
    imageio==2.31.6 \
    tifffile==2023.7.10
}

patch_basicsr_functional_tensor_if_needed() {
  echo
  echo "Checking BasicSR / torchvision functional_tensor compatibility..."

  set +e
  python - << 'PY'
try:
    import torchvision.transforms.functional_tensor
    print("functional_tensor import OK")
    raise SystemExit(0)
except Exception:
    raise SystemExit(1)
PY
  local rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    echo "functional_tensor import is missing."
    echo "Action: Applying compatibility patch to BasicSR degradations.py if needed."

    local degradations
    degradations="$(python - << 'PY'
import site, glob
paths = []
for sp in site.getsitepackages():
    paths += glob.glob(sp + "/basicsr/data/degradations.py")
print(paths[0] if paths else "")
PY
)"
    if [[ -n "$degradations" && -f "$degradations" ]]; then
      cp "$degradations" "$degradations.bak" || true
      sed -i 's/from torchvision.transforms.functional_tensor import rgb_to_grayscale/from torchvision.transforms.functional import rgb_to_grayscale/g' "$degradations"
      echo "Patched: $degradations"
    else
      echo "WARNING: Could not find BasicSR degradations.py to patch."
    fi
  fi
}

validate_python_environment() {
  echo
  echo "Validating Python environment..."

  python - << 'PY'
import sys
print("Python:", sys.version)
if sys.version_info < (3,10):
    raise SystemExit("ERROR: Python 3.10+ is recommended.")
PY

  python - << 'PY'
import numpy, cv2, torch
print("numpy:", numpy.__version__)
print("opencv:", cv2.__version__)
print("torch:", torch.__version__)
print("torch cuda available:", torch.cuda.is_available())
print("torch cuda version:", torch.version.cuda)
if torch.cuda.is_available():
    for i in range(torch.cuda.device_count()):
        print(i, torch.cuda.get_device_name(i))
PY
}

diagnose_common_runtime_errors() {
  echo
  echo "Runtime diagnostic checks..."

  set +e
  python - << 'PY'
errors = []

try:
    import torch
except Exception as e:
    errors.append(("torch-import", str(e)))

try:
    import torchvision
except Exception as e:
    errors.append(("torchvision-import", str(e)))

try:
    import cv2
except Exception as e:
    errors.append(("opencv-import", str(e)))

try:
    import basicsr
except Exception as e:
    errors.append(("basicsr-import", str(e)))

for name, msg in errors:
    print(f"CHECK_FAILED:{name}:{msg}")

if not errors:
    print("Core Python imports OK")
PY
  set -e
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

  echo "Installing PyTorch packages selected by the decision engine..."
  echo "Reason: torch 2.2.2 is available on the cu121/cu118 indexes where torch 2.1.2 may not be."

  case "$TORCH_BACKEND" in
    cu121)
      run_pip_with_log /tmp/realesrgan_torch_install.log pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu121
      ;;
    cu118)
      run_pip_with_log /tmp/realesrgan_torch_install.log pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2 --index-url https://download.pytorch.org/whl/cu118
      ;;
    cpu)
      run_pip_with_log /tmp/realesrgan_torch_install.log pip install torch==2.2.2 torchvision==0.17.2 torchaudio==2.2.2
      ;;
    *)
      echo "ERROR: Unknown --torch value: $TORCH_BACKEND"
      exit 1
      ;;
  esac

  run_pip_with_log /tmp/realesrgan_requirements_install.log pip install -r requirements.txt
  run_pip_with_log /tmp/realesrgan_editable_install.log pip install -e .

  # Known compatibility pins for this Real-ESRGAN/basicSR generation.
  pip uninstall -y numpy opencv-python scipy scikit-image imageio tifffile || true
  apply_realesrgan_compatibility_pins
  patch_basicsr_functional_tensor_if_needed
  diagnose_common_runtime_errors

  local site_packages
  site_packages="$(python -c "import site; print(site.getsitepackages()[0])")"
  rm -rf "$site_packages"/-orch* "$site_packages"/~orch* || true

  validate_python_environment
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

  print_detected_environment
  print_backend_decision
  print_torch_decision
  print_gpu_decision
  print_tile_decision
  print_content_decision
  print_installation_plan

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
