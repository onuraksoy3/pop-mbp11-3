#!/bin/sh
# extras/facetimehd.sh — run with sudo. Installs the FaceTime HD camera driver (facetimehd, by patjak)
# and its firmware (extracted from Apple's driver) for 2013–2015 MacBooks on Ubuntu/Pop!_OS.
# Tries the facetimehd PPA first; falls back to building from GitHub for the running kernel.
set -e
export DEBIAN_FRONTEND=noninteractive
log() { echo "==> $*"; }
if ! command -v apt-get >/dev/null 2>&1; then echo "apt-based systems only" >&2; exit 2; fi
apt-get install -y -q software-properties-common curl git dkms >/dev/null 2>&1 || true

ok=0
if add-apt-repository -y ppa:greg-whiteley/facetimehd >/dev/null 2>&1 && apt-get update -q >/dev/null 2>&1; then
  if apt-get install -y -q facetimehd-dkms facetimehd-firmware >/dev/null 2>&1; then
    log "installed from PPA"; ok=1
  else
    log "PPA packages failed (often a kernel too new for the packaged driver) — building from source"
  fi
fi

if [ $ok = 0 ]; then
  apt-get install -y -q build-essential "linux-headers-$(uname -r)" >/dev/null 2>&1 || true
  rm -rf /usr/src/facetimehd-git && git clone -q https://github.com/patjak/facetimehd.git /usr/src/facetimehd-git
  ( cd /usr/src/facetimehd-git && make -s && make -s install && depmod -a )
  if [ ! -f /lib/firmware/facetimehd/firmware.bin ]; then
    ( cd /usr/src/facetimehd-git/firmware && make -s && make -s install )
  fi
  log "built from source for $(uname -r); rebuild after a kernel change: sudo extras/facetimehd.sh"
fi

echo facetimehd > /etc/modules-load.d/facetimehd.conf
modprobe -r bdc_pci 2>/dev/null || true
modprobe facetimehd 2>/dev/null || true
ls /dev/video* >/dev/null 2>&1 && log "camera device present" || log "driver installed; reboot if /dev/video0 is missing"
echo ok
