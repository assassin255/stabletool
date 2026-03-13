#!/usr/bin/env bash
set -e

IMG_URL="https://archive.org/download/win_20260312/win.img"
IMG_FILE="win.img"

echo "⚡ AUTO WINDOWS VM DEPLOYER (LLVM OPTIMIZED)"

if [ ! -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then

echo "🚀 Building QEMU LLVM optimized..."

sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf

LLVM_VER=19

sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools

export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate

pip install --upgrade pip tomli packaging > /dev/null

rm -rf /tmp/qemu-src /tmp/qemu-build

cd /tmp
git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

mkdir /tmp/qemu-build
cd /tmp/qemu-build

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fomit-frame-pointer -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=4097152"

LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

../qemu-src/configure \
--prefix=/opt/qemu-optimized \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--enable-lto \
--enable-coroutine-pool \
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

ninja -j$(nproc) qemu-system-x86_64 qemu-img

sudo mkdir -p /opt/qemu-optimized/bin
sudo cp qemu-system-x86_64 /opt/qemu-optimized/bin/
sudo cp qemu-img /opt/qemu-optimized/bin/

sudo mkdir -p /opt/qemu-optimized/share/qemu
sudo cp -r /tmp/qemu-src/pc-bios/* /opt/qemu-optimized/share/qemu/

export PATH="/opt/qemu-optimized/bin:$PATH"

echo "🔥 QEMU LLVM build complete"

else

export PATH="/opt/qemu-optimized/bin:$PATH"
echo "⚡ Using existing LLVM optimized QEMU"

fi


echo "🔍 Detecting host resources..."

CPU_CORES=$(nproc)

HOST_RAM=$(free -g | awk '/Mem:/ {print $2}')
RAM_VM=$((HOST_RAM/2))
[ "$RAM_VM" -lt 2 ] && RAM_VM=2

echo "CPU: $CPU_CORES"
echo "VM RAM: $RAM_VM GB"


CPU_NAME=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs)

if echo "$CPU_NAME" | grep -qi "unknown"; then
CPU_OPT="-cpu EPYC"
else
CPU_OPT="-cpu max"
fi


if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
echo "⚡ KVM detected → hardware acceleration"
ACCEL_OPT="-accel kvm"
else
echo "⚡ No KVM → using optimized TCG"
ACCEL_OPT="-accel tcg,thread=multi,tb-size=4097152"
fi


if [[ ! -f "$IMG_FILE" ]]; then
echo "⬇ Downloading Windows image..."
aria2c -x16 -s16 --continue "$IMG_URL" -o "$IMG_FILE"
fi


echo "💾 Expanding disk +20GB..."
qemu-img resize "$IMG_FILE" +20G > /dev/null


echo "🚀 Starting VM..."

qemu-system-x86_64 \
-L /opt/qemu-optimized/share/qemu \
-machine q35,hpet=off \
$CPU_OPT \
-smp "$CPU_CORES" \
-m "${RAM_VM}G" \
$ACCEL_OPT \
-rtc base=localtime \
-drive file=$IMG_FILE,if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0 \
-device virtio-net-pci,netdev=n0 \
-nodefaults \
-global ICH9-LPC.disable_s3=1 \
-global ICH9-LPC.disable_s4=1 \
-display none \
-vga virtio \
-daemonize

sleep 3

echo
echo "══════════════════════════════════"
echo "🚀 WINDOWS VM STARTED"
echo "══════════════════════════════════"
echo "Connect using Tailscale IP"
echo "USER: Admin"
echo "PASS: Tam255Z"
echo "══════════════════════════════════"
