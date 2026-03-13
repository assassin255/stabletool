#!/usr/bin/env bash
set -e

silent(){
"$@" > /dev/null 2>&1
}

install_packages_debian(){
  silent sudo apt update
  silent sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf
}

install_packages_fedora(){
  silent sudo dnf install -y wget gnupg2 gcc gcc-c++ make ninja-build git python3 python3-pip glib2-devel pixman-devel zlib-devel libslirp-devel pkgconf-pkg-config meson aria2 edk2-ovmf
  # python3-venv is not a separate package on Fedora; venv is included with python3
}

install_llvm_debian(){
  OS_ID="$1"
  OS_VER="$2"

  if [[ "$OS_ID" == "ubuntu" ]]; then
    silent wget -O /tmp/llvm.sh https://apt.llvm.org/llvm.sh
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
  silent sudo dnf install -y clang lld llvm llvm-devel
  export CC="clang"
  export CXX="clang++"
  export LD="lld"
}

find_ovmf(){
  # Try common OVMF paths across distros
  for p in \
    /usr/share/qemu/OVMF.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF.fd; do
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

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate
silent pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp

silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

mkdir /tmp/qemu-build
cd /tmp/qemu-build

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fomit-frame-pointer -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

../qemu-src/configure \
--prefix=/opt/qemu-optimized \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
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
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

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
silent aria2c -x16 -s16 --continue "$WIN_URL" -o win.img
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
