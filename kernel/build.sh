#!/bin/bash
# kernel/build.sh — reproduce the 7.0.11-mbp packages (or build a newer kernel) on Pop!_OS / Ubuntu.
#   ./build.sh [kernel-version]      default: 7.0.11
# Result: ./out/linux-image-<ver>-mbp_*.deb and linux-headers-<ver>-mbp_*.deb. Takes 2–4 h on the MacBook;
# ~40 min on a fast machine. Cross-compiling from Apple Silicon works with CROSS_COMPILE=x86_64-linux-gnu-.
set -euo pipefail
VER=${1:-7.0.11}
MAJOR=${VER%%.*}
PATCHES_REPO="https://github.com/IgorChicherin/reclocked.git"
PATCHES_BRANCH="patch/linux-6.18.54-kernel"
HERE=$(cd "$(dirname "$0")" && pwd); WORK="$HERE/work"; OUT="$HERE/out"; mkdir -p "$WORK" "$OUT"
sudo apt-get install -y -q build-essential libncurses-dev bison flex libssl-dev libelf-dev libdw-dev bc dwarves rsync cpio kmod zstd debhelper dh-python gawk git wget >/dev/null
cd "$WORK"
[ -d reclocked ] || git clone -q --depth 1 -b "$PATCHES_BRANCH" "$PATCHES_REPO" reclocked
[ -f "linux-$VER.tar.xz" ] || wget -q "https://cdn.kernel.org/pub/linux/kernel/v$MAJOR.x/linux-$VER.tar.xz"
rm -rf "linux-$VER"; tar xf "linux-$VER.tar.xz"; cd "linux-$VER"
for p in ../reclocked/patches/kernel/00{02..17}-*.patch; do
  echo "== $(basename "$p")"; patch -p1 -s --no-backup-if-mismatch < "$p" || { echo "patch failed — this series targets 6.18/7.0; port it for $VER"; exit 1; }
done
cp "/boot/config-$(uname -r)" .config
make olddefconfig >/dev/null
scripts/config --set-str LOCALVERSION "-mbp" --disable LOCALVERSION_AUTO \
  --disable SYSTEM_TRUSTED_KEYS --disable SYSTEM_REVOCATION_KEYS \
  --disable DEBUG_INFO --enable DEBUG_INFO_NONE --disable DEBUG_INFO_BTF
make olddefconfig >/dev/null
grep -E '^CONFIG_(VGA_SWITCHEROO|APPLE_GMUX|DRM_NOUVEAU|SENSORS_APPLESMC)=' .config
# Compile first (resumable), then package without the clean that bindeb-pkg would otherwise do.
make -j"$(nproc)"
make -j"$(nproc)" bindeb-pkg DPKG_FLAGS=-nc
mv ../linux-image-"$VER"-mbp_*.deb ../linux-headers-"$VER"-mbp_*.deb "$OUT"/ 2>/dev/null || true
rm -f ../linux-image-"$VER"-mbp-dbg_*.deb ../linux-libc-dev_*.deb
ls -la "$OUT"
