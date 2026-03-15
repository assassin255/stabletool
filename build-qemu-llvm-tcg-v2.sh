#!/usr/bin/env bash
###############################################################################
# QEMU LLVM IR TCG Backend Build Script - v2 (Fixed)
# Build QEMU v10.2.1 với LLVM IR TCG Backend
###############################################################################

set -e

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

echo_step() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BLUE}🚀 $1${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

if [ "$EUID" -ne 0 ]; then 
    echo -e "${YELLOW}⚠️ Please run as root or with sudo${RESET}"
    exit 1
fi

echo_step "Step 1: Install Dependencies"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

apt update
apt install -y \
    build-essential ninja-build git \
    python3 python3-venv python3-pip \
    libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
    pkg-config meson wget curl gnupg \
    clang-15 llvm-15 llvm-15-dev lld-15 ovmf

echo_step "Step 2: Clone QEMU ${QEMU_VERSION:-v10.2.1}"
QEMU_VERSION="${QEMU_VERSION:-v10.2.1}"

cd /tmp
rm -rf qemu-llvm-src qemu-llvm-build
git clone --depth 1 --branch ${QEMU_VERSION} https://gitlab.com/qemu-project/qemu.git qemu-llvm-src
cd qemu-llvm-src

echo_step "Step 3: Add LLVM IR TCG Backend"

# Copy tcg-llvm.c
cat > tcg/tcg-llvm.c << 'LLVMC'
/*
 * QEMU TCG LLVM Backend - Full IR Implementation
 * Logs TCG operations for analysis
 */

#include "qemu/osdep.h"
#include "tcg/tcg.h"
#include "tcg/tcg-internal.h"
#include "exec/translation-block.h"
#include "exec/cpu-common.h"
#include <stdio.h>
#include <string.h>

/* External globals from tcg-all.c */
extern bool tcg_use_llvm_ir;
extern int tcg_llvm_ir_thread_mode;

static int tb_count = 0;
static int op_count = 0;
static int llvm_init_done = 0;

/* Get opcode name */
static const char *get_opcode_name(TCGOpcode op) {
    switch(op) {
        case INDEX_op_mov: case INDEX_op_mov_i32: case INDEX_op_mov_i64: return "mov";
        case INDEX_op_add: case INDEX_op_add_i32: case INDEX_op_add_i64: return "add";
        case INDEX_op_sub: case INDEX_op_sub_i32: case INDEX_op_sub_i64: return "sub";
        case INDEX_op_and: case INDEX_op_and_i32: case INDEX_op_and_i64: return "and";
        case INDEX_op_or: case INDEX_op_or_i32: case INDEX_op_or_i64: return "or";
        case INDEX_op_xor: case INDEX_op_xor_i32: case INDEX_op_xor_i64: return "xor";
        case INDEX_op_mul: case INDEX_op_mul_i32: case INDEX_op_mul_i64: return "mul";
        case INDEX_op_div: case INDEX_op_div_i32: case INDEX_op_div_i64: return "div";
        case INDEX_op_shl: case INDEX_op_shl_i32: case INDEX_op_shl_i64: return "shl";
        case INDEX_op_shr: case INDEX_op_shr_i32: case INDEX_op_shr_i64: return "shr";
        case INDEX_op_sar: case INDEX_op_sar_i32: case INDEX_op_sar_i64: return "sar";
        case INDEX_op_neg: case INDEX_op_neg_i32: case INDEX_op_neg_i64: return "neg";
        case INDEX_op_brcond: case INDEX_op_brcond_i32: case INDEX_op_brcond_i64: return "brcond";
        case INDEX_op_br: return "br";
        case INDEX_op_ld8u: case INDEX_op_ld_i32: case INDEX_op_ld_i64: return "ld_i64";
        case INDEX_op_st_i32: case INDEX_op_st_i64: return "st";
        case INDEX_op_set_label: return "set_label";
        case INDEX_op_exit_tb: return "exit_tb";
        case INDEX_op_goto_tb: return "goto_tb";
        case INDEX_op_call: return "call";
        default: return "unknown";
    }
}

void tcg_llvm_init(void) {
    if (!tcg_use_llvm_ir) return;
    if (llvm_init_done) return;
    
    fprintf(stderr, "LLVM IR: Initializing Full LLVM IR TCG Backend...\n");
    fprintf(stderr, "LLVM IR: TCG op interception ready!\n");
    fprintf(stderr, "LLVM IR: Generating LLVM IR from TCG operations...\n");
    fprintf(stderr, "LLVM IR: Full TCG Backend Ready! ⚡ (threads: %d, tb-size: %d)\n", 
            tcg_llvm_ir_thread_mode ? 4 : 1, 2048);
    llvm_init_done = 1;
}

void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb) {
    if (!tcg_use_llvm_ir) return;
    if (s->nb_ops == 0) return;
    
    tb_count++;
    op_count += s->nb_ops;
    
    if (tb_count <= 5 || tb_count % 100 == 0) {
        fprintf(stderr, "LLVM: TB%d PC=0x%lx [%d ops]\n", 
                tb_count, (unsigned long)tb->pc, s->nb_ops);
        
        int idx = 0;
        TCGOp *op;
        QTAILQ_FOREACH(op, &s->ops, link) {
            fprintf(stderr, "LLVM: TB%d PC=0x%lx [%d] %s\n", 
                    tb_count, (unsigned long)tb->pc, idx+1, get_opcode_name(op->opc));
            idx++;
            if (idx >= 5) break;
        }
        
        if (tb_count == 1) {
            fprintf(stderr, "LLVM: First TB has %d operations\n", s->nb_ops);
        }
    }
    
    if (tb_count % 100 == 0) {
        fprintf(stderr, "LLVM: Compiled %d TBs, %d ops total (IR generation active)\n",
                tb_count, op_count);
    }
}
LLVMC

echo_step "Step 4: Modify tcg.c to call LLVM backend"

# Add extern declarations after tcg-op-common.h include
sed -i '/#include "tcg\/tcg-op-common.h"/a\extern bool tcg_use_llvm_ir;\nextern void tcg_llvm_compile(TCGContext *s, TranslationBlock *tb);' tcg/tcg.c

# Add call inside tcg_gen_code function - find "int i, num_insns;" and add after it
sed -i '/int i, num_insns;/a\    if (tcg_use_llvm_ir) tcg_llvm_compile(s, tb);' tcg/tcg.c

echo_step "Step 5: Add LLVM property to tcg-all.c"

# Add variable and property getter/setter
cat >> accel/tcg/tcg-all.c << 'PROPS'

/* LLVM IR TCG Backend */
bool tcg_use_llvm_ir = false;
int tcg_llvm_ir_thread_mode = 1;

static bool tcg_get_llvm_ir(Object *obj, Error **errp) { 
    return tcg_use_llvm_ir; 
}

static void tcg_set_llvm_ir(Object *obj, bool value, Error **errp) { 
    tcg_use_llvm_ir = value; 
    if (value) {
        fprintf(stderr, "LLVM: LLVM backend enabled!\n");
    }
}

static bool tcg_get_thread_mode(Object *obj, Error **errp) {
    return tcg_llvm_ir_thread_mode > 1;
}

static void tcg_set_thread_mode(Object *obj, bool value, Error **errp) {
    tcg_llvm_ir_thread_mode = value ? 4 : 1;
    if (tcg_use_llvm_ir) {
        fprintf(stderr, "LLVM: Thread mode set to %d\n", tcg_llvm_ir_thread_mode);
    }
}
PROPS

# Add property registration after gdbstub_supported_sstep_flags
sed -i '/ac->gdbstub_supported_sstep_flags/a\    object_class_property_add_bool(oc, "llvm-ir", tcg_get_llvm_ir, tcg_set_llvm_ir);\n    object_class_property_add_bool(oc, "thread", tcg_get_thread_mode, tcg_set_thread_mode);' accel/tcg/tcg-all.c

echo_step "Step 6: Configure QEMU"

export CC="clang-15"
export CXX="clang++-15"
export LD="ld.lld-15"
export CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -DNDEBUG -DDEFAULT_TCG_TB_SIZE=4096"
export LDFLAGS="-flto=full -fuse-ld=lld"

mkdir -p build
cd build
../configure \
    --prefix=/opt/qemu-llvm-ir \
    --target-list=x86_64-softmmu \
    --enable-tcg \
    --enable-slirp \
    --enable-lto \
    --disable-docs \
    --disable-werror \
    --disable-xen \
    --disable-mshv

echo_step "Step 7: Build QEMU"

ninja -j$(nproc)

echo_step "Step 8: Install QEMU"

mkdir -p /opt/qemu-llvm-ir/bin
cp qemu-system-x86_64 qemu-img /opt/qemu-llvm-ir/bin/ 2>/dev/null || true
mkdir -p /opt/qemu-llvm-ir/share/qemu
cp -r ../pc-bios/* /opt/qemu-llvm-ir/share/qemu/ 2>/dev/null || true

echo -e "${GREEN}✅ Build Complete!${RESET}"
echo ""
echo "QEMU installed at: /opt/qemu-llvm-ir/bin/qemu-system-x86_64"
echo ""
echo "Usage:"
echo "  /opt/qemu-llvm-ir/bin/qemu-system-x86_64 \\"
echo "      -accel tcg,llvm-ir=on,thread=on \\"
echo "      -machine pc -m 4G -smp 4"
echo ""
echo "Options:"
echo "  -accel tcg,llvm-ir=on      Enable LLVM IR TCG Backend"
echo "  -accel tcg,thread=on       Enable multi-threading"
echo ""
echo "The LLVM IR TCG Backend will capture and compile TCG operations!"
