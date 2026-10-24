#!/bin/bash
# tools/make-bundle.sh — build pop-mbp11-3-bundle.tar.gz for installing without a network (no Wi-Fi driver yet).
# Run as your normal user on any Pop!_OS 24.04 machine with internet (sudo is used only to install build tools):
#   tools/make-bundle.sh [--kernel-dir D] [--out DIR] [--dgpu-ref R | --from-main]
# Contents: install.sh, verify.sh, uninstall.sh, lib/, dgpu/ (pop-mbp11-3-dgpu at its newest vX.Y.Z tag, or R),
# debs/kernel/ (7.0.11-7), debs/apt/ (broadcom-sta-dkms, refind, build tools and the rest of their dependency
# closure, indexed as a local apt repository), debs/keyd/ (keyd built into a .deb), src/ (reclocked and gpu-switch
# sources, at the URLs the dGPU installer uses).
# Clover and Clover Dock are not included: they are built from source and need the network.
# On the target:  tar xzf pop-mbp11-3-bundle.tar.gz && cd pop-mbp11-3-bundle && sudo ./install.sh --offline .
set -euo pipefail

REPO="onuraksoy3/pop-mbp11-3"
KEYD_REPO="https://github.com/rvaiya/keyd"
KEYD_TAG="v2.6.0"
# Everything install.sh may apt-get in offline mode, plus what the kernel packages depend on.
APT_PKGS="broadcom-sta-dkms dkms refind efibootmgr git curl switcheroo-control mesa-utils libglib2.0-bin
  build-essential whiptail initramfs-tools kmod linux-base"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

KERNEL_DIR=""; OUT=$PWD; DGPU_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel-dir) KERNEL_DIR=$(realpath "$2"); shift ;;
    --out) OUT=$(realpath "$2"); shift ;;
    --dgpu-ref) DGPU_ARG=$2; shift ;;
    --from-main) [ -n "$DGPU_ARG" ] || DGPU_ARG=main ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done
[ "$(id -u)" != 0 ] || die "run as your normal user (apt-get download does not need root)"
. /etc/os-release
[ "${ID:-}" = pop ] && [ "${VERSION_ID:-}" = 24.04 ] || die "build the bundle on Pop!_OS 24.04 so the packages match"

TOP=$(cd "$(dirname "$0")/.." && pwd)
# One source of truth: the dGPU version is picked like install.sh picks it (lib/refs.sh); the kernel version and the
# reclocked and gpu-switch sources come from that dGPU installer.
. "$TOP/lib/refs.sh"
conf() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$2" | head -1; }
DGPU_REPO=$(conf DGPU_REPO "$TOP/install.sh")
read -r DGPU_TAG DGPU_REV _ <<<"$(resolve "$DGPU_REPO" "$DGPU_ARG")" || true
[ -n "${DGPU_REV:-}" ] || die "could not resolve $DGPU_REPO${DGPU_ARG:+ $DGPU_ARG}"
WORK=$(mktemp -d /tmp/mbp-bundle.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
B="$WORK/pop-mbp11-3-bundle"
mkdir -p "$B/debs/kernel" "$B/debs/apt" "$B/debs/keyd" "$B/src"

missing=""
for p in build-essential git apt-utils dpkg-dev curl; do
  [ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] || missing="$missing $p"
done
[ -z "$missing" ] || { log "installing build tools:$missing"; sudo apt-get install -y -q $missing; }

log "scripts"
cp -r "$TOP/install.sh" "$TOP/verify.sh" "$TOP/uninstall.sh" "$TOP/lib" "$B/"

log "pop-mbp11-3-dgpu $DGPU_TAG ($DGPU_REV)"
mkdir -p "$B/dgpu"
curl -fsSL "https://github.com/$DGPU_REPO/archive/$DGPU_REV.tar.gz" | tar xz -C "$B/dgpu" --strip-components=1
echo "$DGPU_REV" > "$B/dgpu/.rev"; echo "$DGPU_TAG" > "$B/dgpu/.tag"
RELEASE_TAG=$(conf RELEASE_TAG "$B/dgpu/install.sh"); KVER=$(conf KVER "$B/dgpu/install.sh")
KPKG=$(conf KPKG "$B/dgpu/install.sh")
[ -n "$KPKG" ] || die "pop-mbp11-3-dgpu $DGPU_TAG has no KPKG; it is older than v0.1.3"
RECLOCKED_REPO=$(conf RECLOCKED_REPO "$B/dgpu/install.sh"); RECLOCKED_BRANCH=$(conf RECLOCKED_BRANCH "$B/dgpu/install.sh")
GPU_SWITCH_REPO=$(conf GPU_SWITCH_REPO "$B/dgpu/install.sh")

log "kernel $KVER $KPKG"
for f in "linux-image-${KVER}_${KPKG}_amd64.deb" "linux-headers-${KVER}_${KPKG}_amd64.deb"; do
  if [ -n "$KERNEL_DIR" ]; then cp "$KERNEL_DIR/$f" "$B/debs/kernel/" || die "$f not in $KERNEL_DIR"
  else curl -fL --progress-bar "https://github.com/$DGPU_REPO/releases/download/$RELEASE_TAG/$f" -o "$B/debs/kernel/$f"
  fi
done

log "apt packages and their dependencies"
# The full closure, minus packages every Pop!_OS install has (Essential or Priority required/important):
# the target may lack anything else, and apt there only takes what it needs from the local repository.
# shellcheck disable=SC2086
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances \
  $APT_PKGS 2>/dev/null | grep -v '^ ' | sed 's/^<\(.*\)>$/\1/' | sort -u > "$WORK/closure"
xargs apt-cache show --no-all-versions < "$WORK/closure" 2>/dev/null | python3 -I -c '
import sys
for stanza in sys.stdin.read().split("\n\n"):
    f = dict(l.split(": ", 1) for l in stanza.splitlines() if ": " in l and not l.startswith(" "))
    if "Package" in f and f.get("Essential") != "yes" and f.get("Priority") not in ("required", "important"):
        print(f["Package"])' | sort -u > "$WORK/download"
( cd "$B/debs/apt" && xargs apt-get download -q < "$WORK/download" >/dev/null ) || die "apt-get download failed"
( cd "$B/debs/apt" && apt-ftparchive packages . > Packages 2>/dev/null )
log "$(ls "$B/debs/apt"/*.deb | wc -l) packages, $(du -sh "$B/debs/apt" | cut -f1)"

log "keyd $KEYD_TAG → .deb"
git clone -q --depth 1 -b "$KEYD_TAG" "$KEYD_REPO" "$WORK/keyd"
make -s -C "$WORK/keyd" PREFIX=/usr >/dev/null
P="$WORK/keyd-pkg"
make -s -C "$WORK/keyd" PREFIX=/usr DESTDIR="$P" FORCE_SYSTEMD=1 install >/dev/null 2>&1 \
  || [ -x "$P/usr/bin/keyd" ] || die "keyd install into the package tree failed"
mkdir -p "$P/DEBIAN"
cat > "$P/DEBIAN/control" <<EOF
Package: keyd
Version: ${KEYD_TAG#v}-0popmbp1
Architecture: amd64
Maintainer: pop-mbp11-3 <https://github.com/$REPO>
Depends: libc6
Section: utils
Priority: optional
Homepage: $KEYD_REPO
Description: key remapping daemon (built by pop-mbp11-3 tools/make-bundle.sh)
EOF
cat > "$P/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
systemd-sysusers keyd.conf 2>/dev/null || getent group keyd >/dev/null || groupadd keyd
systemctl daemon-reload || true
systemctl enable --now keyd || true
EOF
cat > "$P/DEBIAN/prerm" <<'EOF'
#!/bin/sh
systemctl disable --now keyd 2>/dev/null || true
EOF
chmod 755 "$P/DEBIAN/postinst" "$P/DEBIAN/prerm"
dpkg-deb --root-owner-group -b "$P" "$B/debs/keyd/keyd_${KEYD_TAG#v}-0popmbp1_amd64.deb" >/dev/null

log "reclocked and gpu-switch sources"
git clone -q --depth 1 -b "$RECLOCKED_BRANCH" "$RECLOCKED_REPO" "$WORK/reclocked"
git -C "$WORK/reclocked" archive --prefix=reclocked/ HEAD | gzip > "$B/src/reclocked.tar.gz"
git clone -q --depth 1 "$GPU_SWITCH_REPO" "$WORK/gpu-switch"
install -m755 "$WORK/gpu-switch/gpu-switch" "$B/src/gpu-switch"

tar czf "$OUT/pop-mbp11-3-bundle.tar.gz" -C "$WORK" pop-mbp11-3-bundle
log "$OUT/pop-mbp11-3-bundle.tar.gz ($(du -h "$OUT/pop-mbp11-3-bundle.tar.gz" | cut -f1))"
echo "Attach it to a release:  gh release upload <tag> $OUT/pop-mbp11-3-bundle.tar.gz -R $REPO"
