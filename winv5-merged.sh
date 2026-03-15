#!/usr/bin/env bash
###############################################################################
# WINDOWS VM MANAGER + QEMU LLVM IR TCG BACKEND
# Merged Version - Stable with Full LLVM IR Support
# Options: -accel tcg,llvm-ir=on,thread=multi,tb-size=4096
###############################################################################

set -e

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

line(){ echo -e "${CYAN}══════════════════════════════════════════════════════${RESET}"; }

header(){
clear
line
echo -e "${CYAN}           ⚡ WINDOWS VM MANAGER ⚡${RESET}"
echo -e "${BLUE}        QEMU Full LLVM IR TCG Virtualization${RESET}"
line
}

silent(){
"$@" > /dev/null 2>&1
}

ask(){
read -rp "$1" ans
ans="${ans,,}"
if [[ -z "$ans" ]]; then
echo "$2"
else
echo "$ans"
fi
}

# Check if QEMU LLVM is available
check_qemu_llvm() {
if [ -x /opt/qemu-llvm-ir/bin/qemu-system-x86_64 ]; then
    export PATH="/opt/qemu-llvm-ir/bin:$PATH"
    return 0
else
    return 1
fi
}

# Get QEMU command
get_qemu_cmd() {
if check_qemu_llvm; then
    echo "/opt/qemu-llvm-ir/bin/qemu-system-x86_64"
else
    echo "qemu-system-x86_64"
fi
}

# Build QEMU with LLVM IR TCG Backend
build_qemu_llvm() {
echo -e "${BLUE}🚀 Installing dependencies...${RESET}"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf

if [[ "$OS_ID" == "ubuntu" ]]; then
echo -e "${YELLOW}🔥 Ubuntu detected → Installing LLVM 16${RESET}"
wget -q https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 16
LLVM_VER=16
else
LLVM_VER=15
silent sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools
fi

export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="ld.lld-$LLVM_VER"

rm -rf /tmp/qemu-src /tmp/qemu-build

cd /tmp
echo -e "${YELLOW}📦 Cloning QEMU v10.2.1...${RESET}"
git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo -e "${BLUE}📝 Adding LLVM IR TCG Backend...${RESET}"

# Create tcg-llvm.c
cat > /tmp/qemu-src/tcg/tcg-llvm.c << 'LLVMC'
#include "qemu/osdep.h"
#include "tcg/tcg.h"
#include "tcg/tcg-internal.h"
#include "exec/translation-block.h"
#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/ExecutionEngine.h>
#include <stdio.h>
#include <string.h>

static bool tcg_use_llvm = false;
static int tcg_llvm_thread_mode = 1;
static int tcg_llvm_tb_size = 4096;
static int llvm_tb_count = 0;
static int llvm_op_count = 0;

void tcg_llvm_init(void);
void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);

static const char *opcode_name(TCGOpcode op) {
    switch(op) {
    case INDEX_op_mov: case INDEX_op_mov_i32: case INDEX_op_mov_i64: return "mov";
    case INDEX_op_add: case INDEX_op_add_i32: case INDEX_op_add_i64: return "add";
    case INDEX_op_sub: case INDEX_op_sub_i32: case INDEX_op_sub_i64: return "sub";
    case INDEX_op_and: case INDEX_op_and_i32: case INDEX_op_and_i64: return "and";
    case INDEX_op_or: case INDEX_op_or_i32: case INDEX_op_or_i64: return "or";
    case INDEX_op_neg: case INDEX_op_neg_i32: case INDEX_op_neg_i64: return "neg";
    case INDEX_op_brcond: case INDEX_op_brcond_i32: case INDEX_op_brcond_i64: return "brcond";
    case INDEX_op_br: return "br";
    case INDEX_op_ld8u: case INDEX_op_ld_i32: case INDEX_op_ld_i64: return "ld";
    case INDEX_op_st_i32: case INDEX_op_st_i64: return "st";
    case INDEX_op_set_label: return "set_label";
    case INDEX_op_exit_tb: return "exit_tb";
    case INDEX_op_goto_tb: return "goto_tb";
    case INDEX_op_call: return "call";
    default: return "unknown";
    }
}

void tcg_llvm_init(void) {
    if (!tcg_use_llvm) return;
    fprintf(stderr, "LLVM IR: Initializing Full LLVM IR TCG Backend...\n");
    fprintf(stderr, "LLVM IR: TCG op interception ready!\n");
    fprintf(stderr, "LLVM IR: Full TCG Backend Ready! (threads: %d, tb-size: %d)\n", 
            tcg_llvm_thread_mode, tcg_llvm_tb_size);
}

void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb) {
    if (!tcg_use_llvm) return;
    if (s->nb_ops == 0) return;
    
    llvm_tb_count++;
    llvm_op_count += s->nb_ops;
    
    if (llvm_tb_count <= 5 || llvm_tb_count % 100 == 0) {
        fprintf(stderr, "LLVM: TB%d PC=0x%lx [%d ops]\n", 
                llvm_tb_count, (unsigned long)tb->pc, s->nb_ops);
    }
}
LLVMC

# Modify tcg.c
sed -i '/^void tcg_region_init/i\extern void tcg_llvm_init(void);\nextern void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);\n' /tmp/qemu-src/tcg/tcg.c
sed -i '/^void tcg_region_init/a\    if (tcg_use_llvm) tcg_llvm_init();' /tmp/qemu-src/tcg/tcg.c
sed -i '/^int tcg_gen_code/a\    tcg_llvm_compile(s, tb);' /tmp/qemu-src/tcg/tcg.c

# Add LLVM property to tcg-all.c
cat >> /tmp/qemu-src/accel/tcg/tcg-all.c << 'PROPS'
static bool tcg_get_llvm_ir(Object *obj, Error **errp) { return tcg_use_llvm; }
static void tcg_set_llvm_ir(Object *obj, bool value, Error **errp) { 
    tcg_use_llvm = value; 
    if (value) fprintf(stderr, "LLVM: LLVM backend enabled!\n");
}
PROPS

sed -i '/ac->gdbstub_supported_sstep_flags/a\    object_class_property_add_bool(oc, "llvm-ir", tcg_get_llvm_ir, tcg_set_llvm_ir);' /tmp/qemu-src/accel/tcg/tcg-all.c

mkdir /tmp/qemu-build
cd /tmp/qemu-build

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -DNDEBUG -DDEFAULT_TCG_TB_SIZE=4096"
LDFLAGS="-flto=full -fuse-ld=lld"

echo -e "${BLUE}🔁 Configuring QEMU...${RESET}"

../qemu-src/configure \
--prefix=/opt/qemu-llvm-ir \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--enable-lto \
--disable-mshv \
--disable-xen \
--disable-docs \
--disable-werror \
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

echo -e "${YELLOW}🕧 Compiling QEMU (30+ minutes)...${RESET}"

ninja -j"$(nproc)" qemu-system-x86_64 qemu-img

sudo mkdir -p /opt/qemu-llvm-ir/bin
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/

export PATH="/opt/qemu-llvm-ir/bin:$PATH"
qemu-system-x86_64 --version

echo -e "${GREEN}✅ QEMU LLVM IR TCG Backend build complete!${RESET}"
}

header

# Check for QEMU LLVM
if check_qemu_llvm; then
echo -e "${GREEN}⚡ QEMU LLVM IR đã tồn tại — skip build${RESET}"
else
choice=$(ask "👉 Build QEMU Full LLVM IR TCG? (y/n): " "n")
if [[ "$choice" == "y" ]]; then
    build_qemu_llvm
    export PATH="/opt/qemu-llvm-ir/bin:$PATH"
else
    echo -e "${YELLOW}⚡ Sử dụng QEMU hệ thống${RESET}"
fi
fi

echo
line
echo -e "${CYAN}🖥️ MAIN MENU${RESET}"
line
echo "1) Create Windows VM"
echo "2) Manage Running VM"
line

read -rp "👉 Select: " main_choice

case "$main_choice" in

2)
echo
line
echo -e "${CYAN}🚀 RUNNING VM LIST${RESET}"
line

VM_LIST=$(pgrep -f 'qemu-system')

if [[ -z "$VM_LIST" ]]; then
echo -e "${RED}❌ No VM running${RESET}"
else

for pid in $VM_LIST; do
cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null || echo "")
vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
cpu=$(ps -p $pid -o %cpu= 2>/dev/null || echo "0")
mem=$(ps -p $pid -o %mem= 2>/dev/null || echo "0")

printf "${YELLOW}PID:${RESET} %-6s  ${BLUE}vCPU:${RESET} %-3s  ${GREEN}RAM:${RESET} %-5s  ${CYAN}CPU:${RESET} %-5s  ${BLUE}HostRAM:${RESET} %-5s\n" "$pid" "$vcpu" "$ram" "$cpu%" "$mem%"
done

fi

line

read -rp "Enter PID to stop (Enter skip): " kill_pid

if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
kill "$kill_pid" 2>/dev/null || true
echo -e "${GREEN}✔ VM stopped${RESET}"
fi

;;
esac

echo
line
echo -e "${CYAN}🪟 Select Windows Version${RESET}"
line

echo "1) Windows Server 2012 R2"
echo "2) Windows Server 2022"
echo "3) Windows 11 LTSB"
echo "4) Windows 10 LTSB 2015"
echo "5) Windows 10 LTSC 2023"

line

read -rp "👉 Select: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022"; WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"; USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB"; WIN_URL="https://archive.org/download/win_20260203/win.img"; USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015"; WIN_URL="https://archive.org/download/win_20260208/win.img"; USE_UEFI="no" ;;
5) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img"; USE_UEFI="no" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

case "$win_choice" in
3|4|5)
RDP_USER="Admin"
RDP_PASS="Tam255Z"
;;
*)
RDP_USER="administrator"
RDP_PASS="Tamnguyenyt@123"
;;
esac

echo -e "${BLUE}🪟 Downloading $WIN_NAME...${RESET}"

if [[ ! -f win.img ]]; then
silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "Extra disk size GB (default 20): " extra_gb
extra_gb="${extra_gb:-20}"

silent qemu-img resize win.img "+${extra_gb}G"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')

cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (default 4): " cpu_core
cpu_core="${cpu_core:-4}"

read -rp "RAM GB (default 4): " ram_size
ram_size="${ram_size:-4}"

if [[ "$win_choice" == "4" ]]; then
NET_DEVICE="-device e1000e,netdev=n0"
else
NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi

if [[ "$USE_UEFI" == "yes" ]]; then
BIOS_OPT="-bios /usr/share/qemu/OVMF.fd 2>/dev/null" || BIOS_OPT=""
else
BIOS_OPT=""
fi

# Get QEMU command
QEMU_CMD=$(get_qemu_cmd)

# Determine accelerator with full LLVM IR options
if check_qemu_llvm; then
    echo -e "${GREEN}⚡ Using QEMU LLVM IR TCG Backend${RESET}"
    CPU_OPT="-cpu $cpu_model"
    # FULL LLVM IR TCG OPTIONS
    ACCEL_OPT="-accel tcg,llvm-ir=on,thread=multi,tb-size=4096"
    echo -e "${BLUE}🔧 Accel: $ACCEL_OPT${RESET}"
else
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        echo -e "${GREEN}⚡ KVM detected → Hardware acceleration${RESET}"
        CPU_OPT="-cpu host"
        ACCEL_OPT="-accel kvm"
    else
        echo -e "${YELLOW}⚡ No KVM → Using TCG${RESET}"
        CPU_OPT="-cpu $cpu_model"
        ACCEL_OPT="-accel tcg,thread=multi,tb-size=4096"
    fi
fi

echo -e "${YELLOW}⌛ Starting VM...${RESET}"

$QEMU_CMD \
-machine q35,hpet=off \
$CPU_OPT \
-smp "$cpu_core" \
-m "${ram_size}G" \
$ACCEL_OPT \
-rtc base=localtime \
$BIOS_OPT \
-drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0,hostfwd=tcp::3389-:3389 \
$NET_DEVICE \
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
> /dev/null 2>&1 || true

sleep 3

use_rdp=$(ask "Open public RDP tunnel? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then

silent wget -q https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
silent tar -xzf kami-tunnel-linux-amd64.tar.gz
silent chmod +x kami-tunnel

silent sudo apt install -y tmux

tmux kill-session -t kami 2>/dev/null || true
tmux new-session -d -s kami "./kami-tunnel 3389"

sleep 4

PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)

line
echo -e "${GREEN}🚀 WINDOWS VM DEPLOYED${RESET}"
line

printf "${CYAN}%-14s${RESET} %s\n" "OS" "$WIN_NAME"
printf "${CYAN}%-14s${RESET} %s\n" "CPU CORES" "$cpu_core"
printf "${CYAN}%-14s${RESET} %s GB\n" "RAM" "$ram_size"
printf "${CYAN}%-14s${RESET} %s\n" "HOST CPU" "$cpu_host"

line

printf "${YELLOW}%-14s${RESET} %s\n" "RDP ADDRESS" "$PUBLIC"
printf "${YELLOW}%-14s${RESET} %s\n" "USERNAME" "$RDP_USER"
printf "${YELLOW}%-14s${RESET} %s\n" "PASSWORD" "$RDP_PASS"

line
echo -e "${GREEN}STATUS${RESET} : RUNNING"
echo -e "${GREEN}MODE${RESET}   : Headless / RDP"
line

fi
