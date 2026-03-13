#!/usr/bin/env bash
set -e

silent(){
"$@" > /dev/null 2>&1
}

echo "════════════════════════════════════"
echo "🖥️  WINDOWS 11 LTSB AUTO DEPLOY"
echo "════════════════════════════════════"

if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
echo "⚡ QEMU LLVM đã tồn tại"
export PATH="/opt/qemu-optimized/bin:$PATH"

else

echo "🚀 Build QEMU LLVM..."

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

silent sudo apt update
silent sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf

if [[ "$OS_ID" == "ubuntu" ]]; then
silent wget https://apt.llvm.org/llvm.sh
silent chmod +x llvm.sh
silent sudo ./llvm.sh 21
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

echo "🕧 Building QEMU..."

ninja -j"$(nproc)"
sudo ninja install

export PATH="/opt/qemu-optimized/bin:$PATH"

echo "🔥 QEMU LLVM build xong"

fi


echo "⬇ Download Windows 11 LTSB..."

WIN_NAME="Windows 11 LTSB"
WIN_URL="https://archive.org/download/win_20260312/win.img"

if [[ ! -f win.img ]]; then
silent aria2c -x16 -s16 --continue "$WIN_URL" -o win.img
fi

echo "🔎 Detect host resources..."

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

echo "🚀 Starting VM..."

qemu-system-x86_64 \
-machine q35,hpet=off \
-cpu "$cpu_model" \
-smp "$cpu_core" \
-m "${ram_size}G" \
-accel tcg,thread=multi,tb-size=3097152 \
-rtc base=localtime \
-bios /usr/share/qemu/OVMF.fd \
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
echo "🚀 WINDOWS VM STARTED"
echo "════════════════════════════════════"
echo "🪟 OS : Windows 11 LTSB"
echo "👤 User : Admin"
echo "🔑 Pass : Tam255Z"
echo "📡 RDP : YOUR_SERVER_IP:3389"
echo "════════════════════════════════════"
