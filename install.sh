#!/bin/bash
# pop-mbp11-3-dgpu — guided setup for the 15" MacBook Pro (Late 2013 / Mid 2014, MacBookPro11,3: Intel Iris
# Pro + NVIDIA GT 750M) on Pop!_OS 24.04 with COSMIC: macOS-style GPU switching, Wi-Fi, patched kernel, Clover.
#
#   curl -fsSL https://raw.githubusercontent.com/onuraksoy3/pop-mbp11-3-dgpu/main/install.sh | sudo bash
#
# With no flags this opens a TUI: detection summary, phase checklist, then a list of everything it will write.
# Phases (each is checked first and skipped when already done; --all runs them in this order):
#   wifi         broadcom-sta-dkms (wl driver for the BCM4360)
#   intel-boot   rEFInd with the macOS spoof, gpu-switch -i (Intel is the boot GPU), COSMIC on Intel,
#                dgpu-off.service for the stock kernel, an rEFInd entry for OpenCore if macOS is found
#   kernel       7.0.11-mbp (vanilla 7.0.11 + gmux/nouveau power-cycle patches + TB runtime PM), its own
#                systemd-boot entry with nouveau.runpm=1, rEFInd fallback to the stock kernel
#   reclocked    pstate governor + fans for the GT 750M, service gated to the -mbp kernel
#   keyd         key remapping daemon (needed by Clover)
#   clover       Clover applet (Mac-style keys and trackpad on COSMIC), built for your user
#   clover-dock  Clover Dock (app list with hover previews), built for your user
#
# Flags:  --all           run every phase, no questions
#         --phases a,b,c  run these phases, no questions
#         --max-0f        let reclocked use pstate 0f (Apple's factory memory clock; small lock-up risk)
#         --no-kernel     skip kernel and reclocked; alone: intel-boot only (dGPU off at boot)
#         --kernel-dir D  use the kernel .deb files from directory D instead of downloading
#         --offline D     install from an unpacked pop-mbp11-3-bundle (tools/make-bundle.sh) instead of the network
#         --dry-run       show what would be written and stop
#         --allow-11-2    allow a MacBookPro11,2 (no dGPU: wifi, kernel, keyd, clover, clover-dock only)
#   --max-0f / --no-kernel / --kernel-dir on their own keep the v0.1 behaviour: intel-boot, kernel, reclocked.
#
# Log: /var/log/pop-mbp11-3-install.log. Undo: uninstall.sh. Verify after reboot: verify.sh.
set -euo pipefail

REPO="onuraksoy3/pop-mbp11-3-dgpu"
REF=${MBP_REF:-main}
RELEASE_TAG="kernel-7.0.11-mbp"
KVER="7.0.11-mbp"
KPKG="7.0.11-7"
RECLOCKED_REPO="https://github.com/IgorChicherin/reclocked.git"
RECLOCKED_BRANCH="patch/linux-6.18.54-kernel"
GPU_SWITCH_REPO="https://github.com/0xbb/gpu-switch"
KEYD_REPO="https://github.com/rvaiya/keyd"
KEYD_TAG="v2.6.0"
CLOVER_REPO="onuraksoy3/cosmic-ext-applet-clover"
CLOVER_DOCK_REPO="onuraksoy3/cosmic-ext-applet-clover-dock"
LOG=/var/log/pop-mbp11-3-install.log
SHARE=/usr/local/share/pop-mbp11-3
LAUNCHER=/usr/share/applications/pop-mbp11-3-setup.desktop
GPU_PREFS=/sys/firmware/efi/efivars/gpu-power-prefs-fa4ce28d-b62f-4c99-9cc3-6815686e30f9
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
APFS_TYPE=7c3457ef-0000-11aa-aa11-00306543ecac
ALL_PHASES="wifi intel-boot kernel reclocked keyd clover clover-dock"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ bootstrap
# Piped through curl there is no script directory: fetch the repo at $REF and run the copy, on the terminal.
HERE=""
[ -z "${BASH_SOURCE[0]:-}" ] || HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)
if [ ! -f "$HERE/files/dgpu-off.service" ]; then
  [ -z "${MBP_BOOTSTRAPPED:-}" ] || die "bootstrap failed: files/ missing in $HERE"
  BOOT=$(mktemp -d /tmp/pop-mbp11-3.XXXXXX)
  curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar xz -C "$BOOT" --strip-components=1 \
    || die "could not download $REPO@$REF (no network? see the README: \"No Wi-Fi on first boot?\")"
  export MBP_BOOTSTRAPPED=1
  if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then exec bash "$BOOT/install.sh" "$@" </dev/tty; fi
  exec bash "$BOOT/install.sh" "$@"
fi

MAX_0F=0; NO_KERNEL=0; KERNEL_DIR=""; OFFLINE=""; DRY_RUN=0; ALLOW_11_2=0; PHASES=""; LEGACY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max-0f) MAX_0F=1; LEGACY=1 ;;
    --no-kernel) NO_KERNEL=1; LEGACY=1 ;;
    --kernel-dir) KERNEL_DIR=$(realpath "${2:?--kernel-dir needs a directory}"); LEGACY=1; shift ;;
    --all) PHASES=$ALL_PHASES ;;
    --phases) PHASES=${2:?--phases needs a list}; PHASES=${PHASES//,/ }; shift ;;
    --offline) OFFLINE=$(realpath "${2:?--offline needs a directory}"); shift ;;
    --dry-run) DRY_RUN=1 ;;
    --allow-11-2) ALLOW_11_2=1 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (see --help)" ;;
  esac
  shift
done
for p in $PHASES; do case " $ALL_PHASES " in *" $p "*) ;; *) die "unknown phase: $p (phases: $ALL_PHASES)" ;; esac; done
if [ -z "$PHASES" ] && [ "$LEGACY" = 1 ]; then
  PHASES="intel-boot kernel reclocked"
fi
if [ "$NO_KERNEL" = 1 ]; then PHASES=$(tr ' ' '\n' <<<"$PHASES" | { grep -vx 'kernel\|reclocked' || true; } | paste -sd' ' -); fi
BATCH=0; { [ -n "$PHASES" ] || [ "$LEGACY" = 1 ]; } && BATCH=1
if [ -n "$OFFLINE" ]; then
  [ -d "$OFFLINE/debs" ] || die "$OFFLINE does not look like an unpacked bundle (no debs/)"
  [ -n "$KERNEL_DIR" ] || KERNEL_DIR="$OFFLINE/debs/kernel"
fi
# A kernel directory may hold a self-built package (kernel/build.sh): take its version from the .deb.
KIMG=""; KHDR=""
if [ -n "$KERNEL_DIR" ]; then
  KIMG=$(ls "$KERNEL_DIR"/linux-image-"$KVER"_*.deb 2>/dev/null | sort -V | tail -1)
  KHDR=$(ls "$KERNEL_DIR"/linux-headers-"$KVER"_*.deb 2>/dev/null | sort -V | tail -1)
  [ -n "$KIMG" ] && [ -n "$KHDR" ] || die "no linux-image/linux-headers-$KVER .deb in $KERNEL_DIR"
  KPKG=$(dpkg-deb -f "$KIMG" Version)
fi

IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1
[ "$IS_ROOT" = 1 ] || [ "$DRY_RUN" = 1 ] || die "run as root (sudo), or add --dry-run to look without changing anything"
if [ "$BATCH" = 0 ] && ! [ -t 0 ]; then
  die "no terminal for the TUI; pass --all or --phases for a non-interactive run"
fi
WORK=$(mktemp -d /tmp/mbp-dgpu.XXXXXX)
trap 'rm -rf "$WORK"; [ -z "${MBP_BOOTSTRAPPED:-}" ] || rm -rf "$HERE"' EXIT

# ------------------------------------------------------------------ detection
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)
case "$PRODUCT" in
  MacBookPro11,3) HAS_DGPU=1 ;;
  MacBookPro11,2) [ "$ALLOW_11_2" = 1 ] || die "this is a MacBookPro11,2 (no NVIDIA GPU); re-run with --allow-11-2 for the phases that apply"
                  HAS_DGPU=0 ;;
  *) die "this installer is for the MacBookPro11,3 (15\" Late 2013 / Mid 2014) only; this machine reports '${PRODUCT:-unknown}'" ;;
esac
. /etc/os-release
[ "${ID:-}" = pop ] && [ "${VERSION_ID:-}" = 24.04 ] || die "this is for Pop!_OS 24.04 (found: ${PRETTY_NAME:-unknown})"

pci_vendor() { cat "/sys/bus/pci/devices/0000:$1/vendor" 2>/dev/null || true; }
[ "$(pci_vendor 00:02.0)" = 0x8086 ] || die "no Intel GPU at PCI 00:02.0 (found vendor '$(pci_vendor 00:02.0)')"
pci_name() { lspci -s "$1" 2>/dev/null | cut -d: -f3- | sed 's/^ //'; }
IGPU_NAME=$(pci_name 00:02.0)
if [ "$HAS_DGPU" = 1 ]; then
  [ "$(pci_vendor 01:00.0)" = 0x10de ] || die "no NVIDIA GPU at PCI 01:00.0 (found vendor '$(pci_vendor 01:00.0)')"
  DGPU_NAME=$(pci_name 01:00.0)
else
  DGPU_NAME="none (MacBookPro11,2)"
fi

ESP=$(findmnt -no TARGET /boot/efi 2>/dev/null || true)
[ -n "$ESP" ] || die "/boot/efi is not mounted (is this a UEFI Pop!_OS install?)"
ESP_DEV=$(findmnt -no SOURCE "$ESP")
ROOT_UUID=$(findmnt -no UUID /)
ROOT_DEV=$(findmnt -no SOURCE /)
[ -n "$ROOT_UUID" ] || die "could not read the UUID of the root filesystem"
POP_DIR=$(ls -d "$ESP"/EFI/Pop_OS-* 2>/dev/null | head -1 || true)
if [ -z "$POP_DIR" ] && [ "$IS_ROOT" = 1 ]; then
  die "no EFI/Pop_OS-* directory on $ESP_DEV (is this a systemd-boot Pop install?)"
fi
POP_REL=${POP_DIR#"$ESP"}
CUR_KERNEL=$(uname -r)

# macOS: look for OpenCore (EFI/OC) or Apple's firmware folder (EFI/APPLE) on every EFI system partition.
OC_DEV=""; OC_PARTUUID=""; APPLE_DEV=""; MACOS_SCAN=1
mkdir -p "$WORK/mnt"
while read -r dev ptype; do
  [ "$ptype" = "$ESP_TYPE" ] || continue
  mnt=$(findmnt -no TARGET "$dev" 2>/dev/null | head -1 || true)
  if [ -z "$mnt" ]; then
    [ "$IS_ROOT" = 1 ] || { MACOS_SCAN=0; continue; }
    mnt="$WORK/mnt/$(basename "$dev")"; mkdir -p "$mnt"
    mount -o ro "$dev" "$mnt" 2>/dev/null || continue
  fi
  if [ -r "$mnt/EFI" ]; then
    if [ -z "$OC_DEV" ] && [ -f "$mnt/EFI/OC/OpenCore.efi" ]; then
      OC_DEV=$dev; OC_PARTUUID=$(lsblk -no PARTUUID "$dev")
    fi
    [ -n "$APPLE_DEV" ] || { [ -d "$mnt/EFI/APPLE" ] && APPLE_DEV=$dev; } || true
  else
    MACOS_SCAN=0
  fi
  [ "${mnt#"$WORK"}" = "$mnt" ] || umount "$mnt"
done < <(lsblk -rno PATH,PARTTYPE)
HAS_APFS=0; lsblk -rno PARTTYPE | grep -qx "$APFS_TYPE" && HAS_APFS=1
if [ -n "$OC_DEV" ]; then MACOS="yes — OpenCore on $OC_DEV (rEFInd entry will be added)"
elif [ "$MACOS_SCAN" = 0 ]; then MACOS="$([ "$HAS_APFS" = 1 ] && echo "APFS found; ")OpenCore unknown (scanning ESPs needs root)"
elif [ -n "$APPLE_DEV" ] || [ "$HAS_APFS" = 1 ]; then MACOS="yes — native boot (${APPLE_DEV:-APFS}); rEFInd finds it, no entry needed"
else MACOS="no"
fi

# The desktop user Clover is built for.
TARGET_USER=${SUDO_USER:-}
[ -n "$TARGET_USER" ] || { [ -n "${PKEXEC_UID:-}" ] && TARGET_USER=$(id -nu "$PKEXEC_UID"); } || true
[ -n "$TARGET_USER" ] || { [ "$IS_ROOT" = 0 ] && TARGET_USER=$(id -nu); } || true
[ "$TARGET_USER" = root ] && TARGET_USER=""
TARGET_HOME=""; [ -n "$TARGET_USER" ] && TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

# ------------------------------------------------------------------ state checks
pkg_installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]; }
gpu_prefs_intel() { [ -r "$GPU_PREFS" ] && [ "$(od -An -tx1 -j4 -N1 "$GPU_PREFS" | tr -d ' ')" = 01 ]; }
oc_block_present() { grep -q '^# pop-mbp11-3 begin' "$ESP/EFI/refind/refind.conf" 2>/dev/null; }
boost_current() { sed -n '/^\[profile default\]/,/^$/ s/^boost-pstate = //p' /etc/reclocked.conf 2>/dev/null | head -1; }
keyd_from_apt() { [ -z "$OFFLINE" ] && apt-cache policy keyd 2>/dev/null | grep -q 'Candidate: [0-9]'; }
user_has() { [ -n "$TARGET_HOME" ] && { [ -x "$TARGET_HOME/.local/bin/$1" ] || [ -x "/usr/bin/$1" ]; }; }

# 0f boost: --max-0f turns it on; otherwise an existing config keeps its setting and a new one starts off.
WANT_BOOST=-1; [ "$MAX_0F" = 1 ] && WANT_BOOST=0f
[ "$MAX_0F" = 0 ] && [ "$(boost_current)" = 0f ] && WANT_BOOST=0f

done_wifi() { pkg_installed broadcom-sta-dkms; }
done_intel-boot() {
  [ -f "$ESP/EFI/refind/refind_x64.efi" ] && grep -q '^spoof_osx_version' "$ESP/EFI/refind/refind.conf" 2>/dev/null &&
    gpu_prefs_intel && grep -q '^COSMIC_RENDER_DEVICE=' /etc/environment && grep -q '^WGPU_POWER_PREF=' /etc/environment &&
    systemctl -q is-enabled dgpu-off.service 2>/dev/null && { [ -z "$OC_DEV" ] || oc_block_present; }
}
done_kernel() {
  [ "$(dpkg-query -W -f='${Version}' "linux-image-$KVER" 2>/dev/null)" = "$KPKG" ] &&
    [ -f "$ESP/loader/entries/Pop_OS-mbp.conf" ] && cmp -s "/boot/vmlinuz-$KVER" "$POP_DIR/vmlinuz-mbp.efi" &&
    grep -q '^default Pop_OS-mbp.conf' "$ESP/loader/loader.conf" 2>/dev/null
}
done_reclocked() {
  [ -x /usr/local/bin/reclocked ] && [ -x /usr/local/bin/reclockctl ] && [ -f /etc/reclocked.conf ] &&
    systemctl -q is-enabled reclocked.service 2>/dev/null && [ "$(boost_current)" = "$WANT_BOOST" ]
}
done_keyd() { command -v keyd >/dev/null && systemctl -q is-enabled keyd 2>/dev/null; }
done_clover() { user_has clover-applet; }
done_clover-dock() { user_has clover-dock; }

# Why a phase cannot run here (empty: it can).
unavailable() {
  case "$1" in
    intel-boot|reclocked) [ "$HAS_DGPU" = 1 ] || echo "no dGPU on the MacBookPro11,2" ;;
    clover|clover-dock)
      if [ -n "$OFFLINE" ]; then echo "needs the network (built from source); run again once Wi-Fi works"
      elif [ -z "$TARGET_USER" ]; then echo "no desktop user: run with sudo from your own account"; fi ;;
  esac
}
status() {
  local why; why=$(unavailable "$1")
  if [ -n "$why" ]; then echo "n/a: $why"; elif "done_$1"; then echo installed; else echo "not installed"; fi
}

# ------------------------------------------------------------------ plan (what each phase writes)
plan_wifi() {
  echo "  package  broadcom-sta-dkms + dkms (wl driver for the BCM4360, built for every installed kernel)"
}
plan_intel-boot() {
  echo "  package  refind efibootmgr git curl switcheroo-control mesa-utils libglib2.0-bin (those missing)"
  [ -f "$ESP/EFI/refind/refind_x64.efi" ] || echo "  file     $ESP/EFI/refind/ (refind-install)"
  echo "  file     $ESP/EFI/refind/refind.conf: spoof_osx_version 10.9"
  if [ -n "$OC_DEV" ]; then
    echo "  boot     rEFInd menuentry \"macOS (OpenCore)\": volume $OC_PARTUUID, /EFI/OC/OpenCore.efi"
  fi
  echo "  efivar   BootOrder: rEFInd first"
  echo "  efivar   gpu-power-prefs-fa4ce28d-…: Intel is the boot GPU (gpu-switch -i)"
  echo "  file     /usr/local/bin/gpu-switch"
  echo "  file     /etc/environment: COSMIC_RENDER_DEVICE, WGPU_POWER_PREF=low"
  echo "  file     /etc/systemd/system/dgpu-off.service (enabled; inert on -mbp kernels)"
  echo "  service  switcheroo-control enabled"
}
plan_kernel() {
  local src="download from the $RELEASE_TAG release"; [ -n "$KERNEL_DIR" ] && src="from $KERNEL_DIR"
  echo "  package  linux-image-$KVER, linux-headers-$KVER $KPKG ($src)"
  echo "  file     $POP_DIR/vmlinuz-mbp.efi, $POP_DIR/initrd-mbp.img"
  echo "  boot     $ESP/loader/entries/Pop_OS-mbp.conf: root=UUID=$ROOT_UUID … nouveau.runpm=1 intel_iommu=igfx_off i915.enable_fbc=1"
  echo "  file     $POP_DIR/refind_linux.conf (rEFInd entry for the stock kernel)"
  echo "  file     $ESP/loader/loader.conf: default Pop_OS-mbp.conf, timeout 5"
}
plan_reclocked() {
  echo "  package  build-essential git (those missing)"
  echo "  file     /usr/local/bin/reclocked, /usr/local/bin/reclockctl (built from source)"
  echo "  file     /etc/reclocked.conf ($([ -f /etc/reclocked.conf ] && echo kept || echo new)), boost-pstate = $WANT_BOOST"
  echo "  file     /etc/systemd/system/reclocked.service (enabled; runs only on -mbp kernels)"
  case " $SEL " in *" kernel "*) ;; *) pkg_installed "linux-image-$KVER" ||
    echo "  note     reclocked does nothing until the $KVER kernel is installed" ;; esac
}
plan_keyd() {
  if [ -n "$OFFLINE" ]; then echo "  package  keyd (bundle .deb)"
  elif keyd_from_apt; then echo "  package  keyd"
  else echo "  file     /usr/local/bin/keyd, /usr/local/lib/systemd/system/keyd.service (built from $KEYD_REPO $KEYD_TAG)"
  fi
  echo "  service  keyd enabled"
}
plan_clover() {
  echo "  package  just pkg-config cmake and the libcosmic -dev packages (those missing)"
  [ -x "$TARGET_HOME/.cargo/bin/cargo" ] || echo "  file     $TARGET_HOME/.cargo, $TARGET_HOME/.rustup (rustup, minimal profile)"
  echo "  file     $TARGET_HOME/.local/bin/clover-applet + clover helpers, $TARGET_HOME/.local/share/clover/"
  echo "           (latest $CLOVER_REPO release: .deb if attached, else built in $TARGET_HOME/src/clover-build)"
}
plan_clover-dock() {
  echo "  package  build-essential pkg-config git libxkbcommon-dev libwayland-dev libssl-dev (those missing)"
  echo "  file     $TARGET_HOME/.local/bin/clover-dock, ~/.local/share/applications/io.github.onuraksoy3.CloverDock.desktop"
  echo "  file     ~/.config/cosmic/com.system76.CosmicPanel.Dock/v1/plugins_center: App Tray → Clover Dock (backup kept)"
}
plan_common() {
  echo "  file     $SHARE/ (copy of this installer, verify.sh, uninstall.sh, files/)"
  echo "  file     $LAUNCHER (\"MacBook Pro 11,3 Setup\")"
  echo "  file     $LOG"
}

summary() {
  cat <<EOF
Model:        $PRODUCT
Intel GPU:    00:02.0 $IGPU_NAME
NVIDIA GPU:   $([ "$HAS_DGPU" = 1 ] && echo "01:00.0 ")$DGPU_NAME
ESP:          $ESP_DEV at $ESP${POP_REL:+ ($POP_REL)}
Root:         $ROOT_DEV, UUID $ROOT_UUID
macOS:        $MACOS
Kernel:       $CUR_KERNEL
Source:       ${OFFLINE:-network}
User:         ${TARGET_USER:-none}
$([ "$IS_ROOT" = 1 ] || echo "(not root: the ESP is unreadable, so boot-related phases may show as not installed)")

Phases:
$(for p in $ALL_PHASES; do printf '  %-12s %s\n' "$p" "$(status "$p")"; done)
EOF
}

# Selected phases in run order, with dependencies pulled in.
order() {
  local want=" $* " out=""
  [ "${want/ clover /}" = "$want" ] || done_keyd || want="$want keyd "
  for p in $ALL_PHASES; do [ "${want/ $p /}" = "$want" ] || out="$out $p"; done
  echo "${out# }"
}
plan_all() {
  for p in $SEL; do echo "[$p]"; "plan_$p"; done
  echo "[always]"; plan_common
}

# ------------------------------------------------------------------ choose
if [ "$BATCH" = 1 ]; then
  SEL=""
  for p in $(order $PHASES); do
    why=$(unavailable "$p")
    if [ -n "$why" ]; then warn "skipping $p: $why"
    elif "done_$p"; then log "$p: already done"
    else SEL="$SEL $p"; fi
  done
  SEL=${SEL# }
  if [ "$DRY_RUN" = 1 ]; then summary; echo; echo "Would write:"; plan_all; exit 0; fi
else
  TITLE="MacBook Pro 11,3 Setup"
  whiptail --title "$TITLE" --yes-button Continue --no-button Quit --scrolltext \
    --yesno "$(summary)" 24 90 || exit 0
  while :; do
    items=()
    for p in $ALL_PHASES; do
      [ -z "$(unavailable "$p")" ] || continue
      st=$(status "$p")
      on=OFF
      case "$p" in wifi|intel-boot|kernel|reclocked) [ "$st" = installed ] || on=ON ;; esac
      items+=("$p" "$st" "$on")
    done
    [ "$HAS_DGPU" = 1 ] && items+=("0f-boost" "reclocked: Apple's factory memory clock (small lock-up risk)" "$([ "$WANT_BOOST" = 0f ] && echo ON || echo OFF)")
    picked=$(whiptail --title "$TITLE" --separate-output --checklist \
      "Choose what to install. Installed phases can be ticked to re-run them." 20 90 10 "${items[@]}" 3>&1 1>&2 2>&3) || exit 0
    WANT_BOOST=-1; grep -qx 0f-boost <<<"$picked" && WANT_BOOST=0f
    # shellcheck disable=SC2046  # one phase name per word
    SEL=$(order $(grep -vx 0f-boost <<<"$picked" || true))
    [ -n "$SEL" ] || { whiptail --title "$TITLE" --msgbox "Nothing selected." 8 40; continue; }
    if [ "$DRY_RUN" = 1 ]; then
      whiptail --title "$TITLE — dry run" --scrolltext --msgbox "Would write:\n\n$(plan_all)" 30 110; exit 0
    fi
    whiptail --title "$TITLE" --yes-button Install --no-button Back --scrolltext \
      --yesno "This will write:\n\n$(plan_all)" 30 110 && break
  done
fi

# ------------------------------------------------------------------ run
touch "$LOG"; chmod 644 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo; echo "===== $(date -Is) install.sh ${SEL:-<nothing>} (ref $REF${OFFLINE:+, offline $OFFLINE})"
export DEBIAN_FRONTEND=noninteractive

# apt against the network, or against the bundle's local repository only.
APT_OPTS=(); APT_UPDATED=0
if [ -n "$OFFLINE" ]; then
  echo "deb [trusted=yes] file:$OFFLINE/debs/apt ./" > "$WORK/offline.list"
  APT_OPTS=(-o "Dir::Etc::SourceList=$WORK/offline.list" -o Dir::Etc::SourceParts=/dev/null -o APT::Get::List-Cleanup=0)
fi
apt_install() {
  local missing=() p
  for p in "$@"; do case "$p" in ./*|/*) missing+=("$p") ;; *) pkg_installed "$p" || missing+=("$p") ;; esac; done
  [ ${#missing[@]} -gt 0 ] || return 0
  if [ "$APT_UPDATED" = 0 ]; then apt-get "${APT_OPTS[@]}" update -q; APT_UPDATED=1; fi
  apt-get "${APT_OPTS[@]}" install -y -q "${missing[@]}"
}
as_user() { runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" PATH="$TARGET_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
# Latest release of a GitHub repo: prints "<tag> <url of the first .deb asset or empty>".
gh_latest() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
debs = [a["browser_download_url"] for a in r.get("assets", []) if a["name"].endswith("_amd64.deb") or a["name"].endswith("_all.deb")]
print(r["tag_name"], debs[0] if debs else "")'
}
ensure_rust() {
  [ -x "$TARGET_HOME/.cargo/bin/cargo" ] && return 0
  log "installing rustup for $TARGET_USER (Ubuntu's rustc is too old for libcosmic)"
  as_user sh -c 'curl -fsSL https://sh.rustup.rs | sh -s -- -y -q --profile minimal'
}

phase_wifi() {
  log "wifi: broadcom-sta-dkms"
  apt_install dkms broadcom-sta-dkms
  modprobe wl 2>/dev/null && log "wl loaded" || warn "wl did not load now; it will after a reboot"
}

phase_intel-boot() {
  log "intel-boot: rEFInd with macOS spoof, Intel as boot GPU, COSMIC on Intel"
  apt_install refind efibootmgr git curl switcheroo-control mesa-utils libglib2.0-bin
  if [ ! -f "$ESP/EFI/refind/refind_x64.efi" ]; then
    refind-install --yes || die "refind-install failed"
  fi
  local conf="$ESP/EFI/refind/refind.conf"
  if grep -q '^spoof_osx_version' "$conf"; then
    sed -i 's/^spoof_osx_version.*/spoof_osx_version 10.9/' "$conf"
  elif grep -q '^#spoof_osx_version' "$conf"; then
    sed -i 's/^#spoof_osx_version.*/spoof_osx_version 10.9/' "$conf"
  else
    echo 'spoof_osx_version 10.9' >> "$conf"
  fi
  sed -i '/^# pop-mbp11-3 begin/,/^# pop-mbp11-3 end/d' "$conf"
  if [ -n "$OC_DEV" ]; then
    cat >> "$conf" <<EOF
# pop-mbp11-3 begin: OpenCore found on $OC_DEV by install.sh
menuentry "macOS (OpenCore)" {
    volume  $OC_PARTUUID
    loader  /EFI/OC/OpenCore.efi
    ostype  MacOS
    icon    /EFI/refind/icons/os_mac.png
}
# pop-mbp11-3 end
EOF
    log "rEFInd entry for OpenCore on $OC_DEV"
  fi
  local num order
  num=$(efibootmgr | awk '/rEFInd/ && !n {sub("Boot","",$1); sub("\\*","",$1); print $1; n=1}')
  if [ -n "$num" ]; then
    order=$(efibootmgr | awk -F': ' '/BootOrder/ {print $2}')
    order="$num,$(echo "$order" | tr ',' '\n' | grep -v "^$num$" | paste -sd, -)"
    efibootmgr -o "${order%,}" >/dev/null
    log "rEFInd is boot entry $num, first in order"
  else
    warn "could not find a rEFInd boot entry; hold Option at the chime and choose rEFInd/EFI Boot"
  fi
  if [ ! -x /usr/local/bin/gpu-switch ]; then
    if [ -n "$OFFLINE" ]; then install -m755 "$OFFLINE/src/gpu-switch" /usr/local/bin/gpu-switch
    else git clone -q "$GPU_SWITCH_REPO" "$WORK/gpu-switch"; install -m755 "$WORK/gpu-switch/gpu-switch" /usr/local/bin/gpu-switch
    fi
  fi
  /usr/local/bin/gpu-switch -i >/dev/null && log "gpu-power-prefs set: Intel drives the panel from the next boot"

  local render
  render=$(readlink -f /dev/dri/by-path/pci-0000:00:02.0-render 2>/dev/null | xargs -r basename)
  [ -n "$render" ] || render=renderD128
  if grep -q '^COSMIC_RENDER_DEVICE=' /etc/environment; then
    sed -i "s/^COSMIC_RENDER_DEVICE=.*/COSMIC_RENDER_DEVICE=$render/" /etc/environment
  else
    echo "COSMIC_RENDER_DEVICE=$render" >> /etc/environment
  fi
  grep -q '^WGPU_POWER_PREF=' /etc/environment || echo 'WGPU_POWER_PREF=low' >> /etc/environment
  install -m644 "$HERE/files/dgpu-off.service" /etc/systemd/system/dgpu-off.service
  systemctl daemon-reload
  systemctl enable dgpu-off.service >/dev/null 2>&1
  systemctl enable switcheroo-control >/dev/null 2>&1 || true
}

phase_kernel() {
  log "kernel: $KVER ($KPKG)"
  if [ "$(dpkg-query -W -f='${Version}' "linux-image-$KVER" 2>/dev/null)" != "$KPKG" ]; then
    if [ -z "$KERNEL_DIR" ]; then
      local f
      for f in "linux-image-${KVER}_${KPKG}_amd64.deb" "linux-headers-${KVER}_${KPKG}_amd64.deb"; do
        log "downloading $f"
        curl -fL --progress-bar "https://github.com/$REPO/releases/download/$RELEASE_TAG/$f" -o "$WORK/$f" \
          || die "download failed: $f"
      done
      KIMG="$WORK/linux-image-${KVER}_${KPKG}_amd64.deb"; KHDR="$WORK/linux-headers-${KVER}_${KPKG}_amd64.deb"
    fi
    apt_install "$KIMG" "$KHDR" || die "kernel install failed"
  fi
  [ -f "/boot/vmlinuz-$KVER" ] || die "/boot/vmlinuz-$KVER missing after install"
  if pkg_installed broadcom-sta-dkms; then
    if dkms status 2>/dev/null | grep -q "broadcom-sta.*$KVER.*installed"; then
      log "Wi-Fi (broadcom-sta) built for $KVER"
    else
      warn "broadcom-sta did not build for $KVER — Wi-Fi may be missing on that kernel; run: dkms autoinstall -k $KVER"
    fi
  fi
  cp "/boot/vmlinuz-$KVER" "$POP_DIR/vmlinuz-mbp.efi"
  cp "/boot/initrd.img-$KVER" "$POP_DIR/initrd-mbp.img"
  cat > "$ESP/loader/entries/Pop_OS-mbp.conf" <<EOF
title Pop!_OS $KVER (nouveau runpm)
linux $POP_REL/vmlinuz-mbp.efi
initrd $POP_REL/initrd-mbp.img
options root=UUID=$ROOT_UUID ro quiet splash nouveau.runpm=1 intel_iommu=igfx_off i915.enable_fbc=1
EOF
  local stock lc="$ESP/loader/loader.conf"
  stock=$(awk '/^options/ {sub("^options ",""); print; exit}' "$ESP/loader/entries/Pop_OS-current.conf" 2>/dev/null || true)
  [ -n "$stock" ] || stock="root=UUID=$ROOT_UUID ro quiet splash"
  printf '"Pop!_OS stock kernel" "%s"\n' "$stock" > "$POP_DIR/refind_linux.conf"
  if grep -q '^default' "$lc"; then sed -i 's/^default .*/default Pop_OS-mbp.conf/' "$lc"; else echo 'default Pop_OS-mbp.conf' >> "$lc"; fi
  if grep -q '^timeout' "$lc"; then sed -i 's/^timeout.*/timeout 5/' "$lc"; else echo 'timeout 5' >> "$lc"; fi
  log "boot entry Pop_OS-mbp.conf written and set as default; rEFInd fallback to the stock kernel in place"
}

phase_reclocked() {
  log "reclocked"
  apt_install build-essential git
  if [ -n "$OFFLINE" ]; then
    mkdir -p "$WORK/reclocked"; tar xzf "$OFFLINE/src/reclocked.tar.gz" -C "$WORK/reclocked" --strip-components=1
  else
    git clone -q --depth 1 -b "$RECLOCKED_BRANCH" "$RECLOCKED_REPO" "$WORK/reclocked"
  fi
  make -s -C "$WORK/reclocked/src" >/dev/null || die "reclocked build failed"
  install -m755 "$WORK/reclocked/src/reclocked" "$WORK/reclocked/src/reclockctl" /usr/local/bin/
  [ -f /etc/reclocked.conf ] || install -m644 "$HERE/files/reclocked.conf" /etc/reclocked.conf
  sed -i "/^\[profile default\]/,/^\$/ s/^boost-pstate = .*/boost-pstate = $WANT_BOOST/" /etc/reclocked.conf
  if [ "$WANT_BOOST" = 0f ]; then
    warn "0f boost enabled (Apple's factory memory clock under sustained load). If the GPU ever freezes, set boost-pstate = -1 in /etc/reclocked.conf"
  fi
  install -m644 "$HERE/files/reclocked.service" /etc/systemd/system/reclocked.service
  systemctl daemon-reload
  systemctl enable reclocked.service >/dev/null 2>&1
}

phase_keyd() {
  log "keyd"
  if [ -n "$OFFLINE" ]; then
    local deb; deb=$(ls "$OFFLINE"/debs/keyd/keyd_*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || die "no keyd .deb in the bundle (debs/keyd/)"
    apt_install "$deb"
  elif keyd_from_apt; then
    apt_install keyd
  else
    apt_install build-essential git
    git clone -q --depth 1 -b "$KEYD_TAG" "$KEYD_REPO" "$WORK/keyd"
    make -s -C "$WORK/keyd" >/dev/null || die "keyd build failed"
    make -s -C "$WORK/keyd" install >/dev/null || die "keyd install failed"
  fi
  systemctl daemon-reload
  systemctl enable --now keyd >/dev/null 2>&1 || warn "keyd did not start; see: journalctl -u keyd"
}

# Install a .deb asset from the latest release if there is one; returns 1 when the caller should build.
install_release_deb() {
  local tag url
  read -r tag url < <(gh_latest "$1") || die "cannot query the $1 releases"
  RELEASE=$tag
  [ -n "$url" ] || return 1
  log "installing $(basename "$url") from $1 $tag"
  curl -fL --progress-bar "$url" -o "$WORK/$(basename "$url")" || die "download failed: $url"
  apt_install "$WORK/$(basename "$url")" || die "installing $(basename "$url") failed"
}

phase_clover() {
  log "clover (for $TARGET_USER)"
  install_release_deb "$CLOVER_REPO" && return 0
  apt_install git curl just pkg-config cmake libxkbcommon-dev libwayland-dev libfontconfig-dev libfreetype-dev \
    libexpat1-dev libinput-dev libudev-dev libdbus-1-dev libssl-dev libglib2.0-bin libnotify-bin
  ensure_rust
  local src="$TARGET_HOME/src/clover-build"
  as_user mkdir -p "$TARGET_HOME/src"
  [ -d "$src/.git" ] || as_user git clone -q "https://github.com/$CLOVER_REPO" "$src"
  as_user git -C "$src" fetch -q --tags origin
  as_user git -C "$src" checkout -q -f "$RELEASE"
  log "building Clover $RELEASE (first time ~10–15 min)"
  as_user sh -c "cd '$src' && just build-release && just prefix='$TARGET_HOME/.local' install" || die "Clover build failed"
  log "Clover installed. Add it: Settings → Desktop → Panel → Configure applets → Clover; its first-run page finishes keyd setup"
}

phase_clover-dock() {
  log "clover-dock (for $TARGET_USER)"
  install_release_deb "$CLOVER_DOCK_REPO" && return 0
  apt_install build-essential pkg-config git curl libxkbcommon-dev libwayland-dev libssl-dev
  ensure_rust
  # build.sh calls "sudo apt-get install" for the packages installed above; a shim stands in for sudo so the
  # unprivileged build does not stop at a password prompt.
  mkdir -p "$WORK/shim"; chmod 755 "$WORK" "$WORK/shim"
  printf '#!/bin/sh\n[ "$1" = apt-get ] && exit 0\necho "sudo shim: refusing $*" >&2; exit 1\n' > "$WORK/shim/sudo"
  chmod 755 "$WORK/shim/sudo"
  local src="$TARGET_HOME/src/clover-dock"
  as_user mkdir -p "$TARGET_HOME/src"
  [ -d "$src/.git" ] || as_user git clone -q "https://github.com/$CLOVER_DOCK_REPO" "$src"
  as_user git -C "$src" fetch -q --tags origin
  as_user git -C "$src" checkout -q -f "$RELEASE"
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" PATH="$WORK/shim:$TARGET_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$src/build.sh" || die "Clover Dock build failed"
}

install_launcher() {
  if [ "$HERE" != "$SHARE" ]; then
    rm -rf "$SHARE"; mkdir -p "$SHARE"
    cp -r "$HERE/install.sh" "$HERE/verify.sh" "$HERE/uninstall.sh" "$HERE/files" "$SHARE/"
  fi
  cat > "$LAUNCHER" <<EOF
[Desktop Entry]
Type=Application
Name=MacBook Pro 11,3 Setup
Comment=GPU switching, Wi-Fi, patched kernel and Clover for this MacBook
Exec=cosmic-term -- sudo env MBP_LAUNCHER=1 $SHARE/install.sh
Icon=computer-laptop
Categories=System;Settings;
Terminal=false
EOF
}

for p in $SEL; do "phase_$p"; done
install_launcher

cat <<EOF

$(printf '\033[1;32mDone:\033[0m') ${SEL:-nothing to do}. Log: $LOG
EOF
case " $SEL " in *" intel-boot "*|*" kernel "*|*" wifi "*) cat <<EOF
Reboot now. At rEFInd choose Pop!_OS; systemd-boot boots $KVER by default.
After logging in, run verify.sh (or: sudo cat /sys/kernel/debug/vgaswitcheroo/switch — the DIS line
should read DynOff after ~10 s idle, DynPwr while a DRI_PRIME app runs).

If the patched kernel misbehaves: at rEFInd pick the "vmlinuz.efi" entry (stock kernel), then
  sudo sed -i 's/^default .*/default Pop_OS-current/' $ESP/loader/loader.conf

Run apps on the GT 750M: right-click → "Run with…" in COSMIC, or DRI_PRIME=pci-0000_01_00_0 <app>.
After any macOS session: sudo gpu-switch -i, then reboot (macOS resets the boot GPU).
EOF
esac
[ -n "${MBP_LAUNCHER:-}" ] && read -rp "Press Enter to close." _ </dev/tty
exit 0
