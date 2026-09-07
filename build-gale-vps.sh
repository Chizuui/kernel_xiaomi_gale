#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out-vps}"
CLANG_DIR="${CLANG_DIR:-$ROOT_DIR/aosp-20}"
CLANG_REVISION="${CLANG_REVISION:-clang-r547379}"
RESUKISU_REF="${RESUKISU_REF:-main}"
CONFIG_NAME="${CONFIG_NAME:-gale_defconfig}"
JOBS="${JOBS:-$(nproc)}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
PACKAGE="${PACKAGE:-1}"
ANYKERNEL_DIR="${ANYKERNEL_DIR:-$ROOT_DIR/AnyKernel3}"
ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/Chizuui/AnyKernel3.git}"
ANYKERNEL_BRANCH="${ANYKERNEL_BRANCH:-priestess}"

CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/llvm-r547379-release/${CLANG_REVISION}.tar.gz"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cd "$ROOT_DIR"

if [[ "$(uname -s)" != Linux ]]; then
  die "Script ini untuk VPS Linux/Ubuntu."
fi

if [[ "$INSTALL_DEPS" == 1 ]]; then
  log "Install build dependencies"
  if [[ $EUID -eq 0 ]]; then
    APT=(apt-get)
  elif command -v sudo >/dev/null 2>&1; then
    APT=(sudo apt-get)
  else
    die "Butuh root atau sudo untuk install dependency. Set INSTALL_DEPS=0 jika semuanya sudah tersedia."
  fi

  "${APT[@]}" update
  "${APT[@]}" install -y \
    bc bison build-essential curl flex git libelf-dev libncurses-dev \
    libssl-dev python3 rsync unzip xz-utils zip zstd \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi \
    binutils-aarch64-linux-gnu binutils-arm-linux-gnueabi
fi

command -v make >/dev/null || die "make tidak ditemukan."
command -v curl >/dev/null || die "curl tidak ditemukan."
command -v tar >/dev/null || die "tar tidak ditemukan."

log "Download/cache AOSP Clang ${CLANG_REVISION}"
mkdir -p "$CLANG_DIR"
if [[ ! -x "$CLANG_DIR/bin/clang" ]]; then
  tmp_archive="$(mktemp --suffix=.tar.gz)"
  trap 'rm -f "$tmp_archive"' EXIT
  curl --fail --location --retry 5 --retry-delay 5 \
    --output "$tmp_archive" "$CLANG_URL"
  tar -xzf "$tmp_archive" -C "$CLANG_DIR"
  rm -f "$tmp_archive"
fi

export PATH="$CLANG_DIR/bin:$PATH"
command -v clang >/dev/null || die "clang tidak ditemukan setelah setup toolchain."
command -v ld.lld >/dev/null || die "ld.lld tidak ditemukan setelah setup toolchain."

log "Setup ReSukiSU"
if [[ ! -d KernelSU || ! -e drivers/kernelsu ]]; then
  curl -LSs \
    "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" \
    | bash -s "$RESUKISU_REF"
fi

[[ -d KernelSU ]] || die "KernelSU tidak tersedia."
[[ -e drivers/kernelsu ]] || die "drivers/kernelsu tidak tersedia."

log "Validate Gale hooks and NoMount"
[[ -f "fs/nomount/nomount.c" ]] || die "fs/nomount/nomount.c tidak ditemukan. Gunakan branch CIP135 + NoMount."
[[ -f "fs/nomount/Kconfig" ]] || die "fs/nomount/Kconfig tidak ditemukan."
grep -q '^source "fs/nomount/Kconfig"$' fs/Kconfig || die "fs/Kconfig belum memasukkan NoMount."
grep -q '^obj-\$(CONFIG_NOMOUNT)' fs/Makefile || die "fs/Makefile belum memasukkan NoMount."

for check in \
  'drivers/input/input.c:ksu_handle_input_handle_event' \
  'fs/exec.c:ksu_handle_execveat' \
  'fs/open.c:ksu_handle_faccessat' \
  'fs/read_write.c:ksu_handle_sys_read' \
  'fs/stat.c:ksu_handle_stat' \
  'kernel/reboot.c:ksu_handle_sys_reboot' \
  'kernel/sys.c:ksu_handle_setresuid'; do
  file="${check%%:*}"
  symbol="${check#*:}"
  grep -q "$symbol" "$file" || die "Manual hook $symbol tidak ditemukan di $file."
done

log "Generate ${CONFIG_NAME}"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

make -s O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC=clang LD=ld.lld CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- "$CONFIG_NAME"

grep -q '^CONFIG_KSU=y$' "$OUT_DIR/.config" || die "CONFIG_KSU tidak aktif."
grep -q '^CONFIG_KSU_MANUAL_HOOK=y$' "$OUT_DIR/.config" || die "CONFIG_KSU_MANUAL_HOOK tidak aktif."
grep -q '^CONFIG_NOMOUNT=y$' "$OUT_DIR/.config" || die "CONFIG_NOMOUNT tidak aktif."

log "Build kernel with ${JOBS} jobs"
make -j"$JOBS" O="$OUT_DIR" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm STRIP=llvm-strip \
  OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump READELF=llvm-readelf \
  HOSTCC=clang HOSTCXX=clang++ HOSTAR=llvm-ar HOSTLD=ld.lld \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- 2>&1 | tee "$OUT_DIR/compile.log"

if [[ "$PACKAGE" == 1 ]]; then
  log "Package AnyKernel3"
  if [[ ! -d "$ANYKERNEL_DIR" ]]; then
    git clone --depth=1 --branch "$ANYKERNEL_BRANCH" "$ANYKERNEL_REPO" "$ANYKERNEL_DIR"
  fi

  image="$(find "$OUT_DIR" -type f -name Image.gz -print -quit)"
  dtb="$(find "$OUT_DIR" -type f -name mt6768.dtb -print -quit)"
  [[ -f "$image" ]] || die "Image.gz tidak ditemukan."
  [[ -f "$dtb" ]] || die "mt6768.dtb tidak ditemukan."

  cp -f "$image" "$ANYKERNEL_DIR/Image.gz"
  cp -f "$dtb" "$ANYKERNEL_DIR/dtb"

  kernel_name="$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "arch/arm64/configs/$CONFIG_NAME" | sed 's/^-//')"
  kernel_name="${kernel_name:-Gale-CIP135}"
  zip_name="${kernel_name}-$(date -u +%Y%m%d-%H%M).zip"
  (cd "$ANYKERNEL_DIR" && zip -r9 "$ROOT_DIR/$zip_name" . -x '.git/*' '.git' 'builds/*' 'builds' '*.zip' '*/*.zip' >/dev/null)
  sha256sum "$ROOT_DIR/$zip_name"
  printf '\nBuilt package: %s\n' "$ROOT_DIR/$zip_name"
fi

log "Build complete"
printf 'Kernel: %s\n' "$ROOT_DIR/$OUT_DIR/Image.gz"
printf 'Config: %s\n' "$OUT_DIR/.config"
