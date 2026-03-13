#!/usr/bin/env bash
set -e

silent(){
"$@" > /dev/null 2>&1
}

# Download helper: uses aria2c if available, falls back to curl then wget
download(){
  local url="$1"
  local out="$2"
  if command -v aria2c &>/dev/null; then
    aria2c -x16 -s16 --continue --file-allocation=none "$url" -o "$out"
  elif command -v curl &>/dev/null; then
    curl -L -C - -o "$out" "$url"
  elif command -v wget &>/dev/null; then
    wget -c -O "$out" "$url"
  else
    echo "ERROR: No download tool available (need aria2c, curl, or wget)"
    exit 1
  fi
}

install_packages_debian(){
  silent sudo apt update
  silent sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf
}

install_packages_fedora(){
  # Install what's available from repos (skip curl - curl-minimal already provides it)
  silent sudo dnf install -y --skip-broken gcc gcc-c++ make ninja-build git python3 python3-pip \
    glib2-devel pixman-devel zlib-devel pkgconf-pkg-config

  # meson/ninja might need pip install if not in repos
  if ! command -v meson &>/dev/null; then
    silent pip3 install --user meson
  fi

  # libslirp-devel: build from source if not in repos
  if ! rpm -q libslirp-devel &>/dev/null 2>&1; then
    if ! dnf install -y libslirp-devel 2>/dev/null; then
      echo "Building libslirp from source..."
      install_libslirp_from_source
    fi
  fi

  # OVMF: download if not in repos
  if ! rpm -q edk2-ovmf &>/dev/null 2>&1; then
    if ! dnf install -y edk2-ovmf 2>/dev/null; then
      download_ovmf
    fi
  fi
}

install_libslirp_from_source(){
  local build_dir="/tmp/libslirp-build"
  rm -rf "$build_dir"
  git clone --depth 1 https://gitlab.freedesktop.org/slirp/libslirp.git "$build_dir"
  cd "$build_dir"
  meson setup builddir --prefix=/usr --default-library=both
  ninja -C builddir
  # Use sudo with preserved PATH so meson is found
  sudo env "PATH=$PATH" "PYTHONPATH=$(python3 -c 'import site; print(site.getusersitepackages())')" \
    meson install -C builddir --no-rebuild
  sudo ldconfig
  cd -
}

download_ovmf(){
  echo "Downloading OVMF firmware..."
  sudo mkdir -p /usr/share/OVMF
  if [[ ! -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
    sudo curl -L -o /usr/share/OVMF/OVMF_CODE.fd \
      "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF_CODE.fd"
  fi
}

install_llvm_debian(){
  OS_ID="$1"
  OS_VER="$2"

  if [[ "$OS_ID" == "ubuntu" ]]; then
    silent curl -L -o /tmp/llvm.sh https://apt.llvm.org/llvm.sh
    silent chmod +x /tmp/llvm.sh
    silent sudo /tmp/llvm.sh 21
    LLVM_VER=21
  else
    if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
      LLVM_VER=19
    else
      LLVM_VER=15
    fi
    silent sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools
  fi

  export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
  export CC="clang-$LLVM_VER"
  export CXX="clang++-$LLVM_VER"
  export LD="lld-$LLVM_VER"
}

install_llvm_fedora(){
  silent sudo dnf install -y clang lld llvm llvm-devel || true
  # If clang not available from repos, try what we have (gcc fallback)
  if command -v clang &>/dev/null; then
    export CC="clang"
    export CXX="clang++"
    export LD="lld"
  else
    echo "LLVM/clang not available, using GCC"
    export CC="gcc"
    export CXX="g++"
    export LD="ld"
  fi
}

find_ovmf(){
  for p in \
    /usr/share/qemu/OVMF.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF.fd \
    /opt/qemu-optimized/share/qemu/edk2-x86_64-code.fd; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return
    fi
  done
  echo ""
}

echo "════════════════════════════════════"
echo "WINDOWS 11 LTSB AUTO DEPLOY"
echo "════════════════════════════════════"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_ID_LIKE="$(. /etc/os-release && echo "${ID_LIKE:-}")"
OS_VER="$(. /etc/os-release && echo "${VERSION_ID:-}")"

# Determine package manager family
PKG_FAMILY=""
if command -v apt-get &>/dev/null; then
  PKG_FAMILY="debian"
elif command -v dnf &>/dev/null; then
  PKG_FAMILY="fedora"
elif command -v yum &>/dev/null; then
  PKG_FAMILY="fedora"
else
  echo "ERROR: Unsupported package manager. Need apt or dnf/yum."
  exit 1
fi

echo "Detected: $OS_ID ($PKG_FAMILY family)"

if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
echo "QEMU LLVM already exists"
export PATH="/opt/qemu-optimized/bin:$PATH"

else

echo "Building QEMU LLVM..."

if [[ "$PKG_FAMILY" == "debian" ]]; then
  install_packages_debian
  install_llvm_debian "$OS_ID" "$OS_VER"
else
  install_packages_fedora
  install_llvm_fedora
fi

# Ensure meson and ninja are available via pip if needed
if ! command -v meson &>/dev/null || ! command -v ninja &>/dev/null; then
  python3 -m pip install --user meson ninja 2>/dev/null || \
  pip3 install --user meson ninja 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"
fi

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate
silent pip install --upgrade pip tomli packaging meson ninja

rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp

silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

mkdir /tmp/qemu-build
cd /tmp/qemu-build

# Adjust CFLAGS based on compiler
if [[ "$CC" == *clang* ]]; then
  EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fomit-frame-pointer -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
  EXTRA_LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"
else
  # GCC-compatible flags
  EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=auto -ffast-math -fomit-frame-pointer -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
  EXTRA_LDFLAGS="-flto=auto -Wl,--gc-sections -Wl,-O3"
fi

# Check if slirp is available
SLIRP_OPT="--enable-slirp"
if ! pkg-config --exists slirp 2>/dev/null; then
  echo "WARNING: libslirp not found, disabling slirp (using user-mode networking may not work)"
  SLIRP_OPT="--disable-slirp"
fi

../qemu-src/configure \
--prefix=/opt/qemu-optimized \
--target-list=x86_64-softmmu \
--enable-tcg \
$SLIRP_OPT \
--enable-lto \
--enable-coroutine-pool \
--disable-kvm \
--disable-xen \
--disable-gtk \
--disable-sdl \
--disable-spice \
--disable-vnc \
--disable-plugins \
--disable-debug-info \
--disable-docs \
--disable-werror \
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$EXTRA_LDFLAGS"

echo "Building QEMU..."

ninja -j"$(nproc)"
sudo ninja install

export PATH="/opt/qemu-optimized/bin:$PATH"

echo "QEMU LLVM build complete"

fi


echo "Downloading Windows 11 LTSB..."

WIN_NAME="Windows 11 LTSB"
WIN_URL="https://archive.org/download/win_20260312/win.img"

if [[ ! -f win.img ]]; then
download "$WIN_URL" win.img
fi

echo "Detecting host resources..."

cpu_core=$(nproc)

host_ram=$(free -g | awk '/Mem:/ {print $2}')
ram_size=$((host_ram/2))

disk_host=$(df --output=size -BG / | tail -1 | tr -dc '0-9')
extra_gb=$((disk_host/2))

echo "CPU : $cpu_core"
echo "RAM : ${ram_size}G"
echo "DISK ADD : ${extra_gb}G"

silent qemu-img resize win.img "+${extra_gb}G"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')

cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

OVMF_PATH=$(find_ovmf)
if [[ -z "$OVMF_PATH" ]]; then
  echo "ERROR: OVMF firmware not found. Install ovmf/edk2-ovmf package."
  exit 1
fi

echo "Starting VM..."
echo "Using OVMF: $OVMF_PATH"

qemu-system-x86_64 \
-machine q35,hpet=off \
-cpu "$cpu_model" \
-smp "$cpu_core" \
-m "${ram_size}G" \
-accel tcg,thread=multi,tb-size=3097152 \
-rtc base=localtime \
-bios "$OVMF_PATH" \
-drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0,hostfwd=tcp::3389-:3389 \
-device virtio-net-pci,netdev=n0 \
-device virtio-mouse-pci \
-device virtio-keyboard-pci \
-nodefaults \
-global ICH9-LPC.disable_s3=1 \
-global ICH9-LPC.disable_s4=1 \
-smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
-global kvm-pit.lost_tick_policy=discard \
-no-user-config \
-display none \
-vga virtio \
-daemonize \
> /dev/null 2>&1

echo ""
echo "════════════════════════════════════"
echo "WINDOWS VM STARTED"
echo "════════════════════════════════════"
echo "OS   : Windows 11 LTSB"
echo "User : Admin"
echo "Pass : Tam255Z"
echo "RDP  : YOUR_SERVER_IP:3389"
echo "════════════════════════════════════"
