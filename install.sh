#!/bin/bash
# pop-mbp11-3 — guided setup for the 15" MacBook Pro (Late 2013 / Mid 2014, MacBookPro11,3: Intel Iris
# Pro + NVIDIA GT 750M) on Pop!_OS 24.04 with COSMIC: macOS-style GPU switching, Wi-Fi, patched kernel, Clover.
#
#   curl -fsSL https://raw.githubusercontent.com/onuraksoy3/pop-mbp11-3/main/install.sh | sudo bash
#
# With no flags this opens a TUI: detection summary, phase checklist, then a list of everything it will write.
# Phases (each is checked first and skipped when already done; --all runs them in this order):
#   wifi         broadcom-sta-dkms (wl driver for the BCM4360)
#   intel-boot   rEFInd with the macOS spoof, gpu-switch -i (Intel is the boot GPU), COSMIC on Intel,
#                dgpu-off.service for the stock kernel (OpenCore is left to rEFInd's own scan)
#   kernel       7.0.11-mbp (vanilla 7.0.11 + gmux/nouveau power-cycle patches + TB runtime PM), its own
#                systemd-boot entry with nouveau.runpm=1, rEFInd fallback to the stock kernel
#   reclocked    pstate governor + fans for the GT 750M, service gated to the -mbp kernel
#                (intel-boot, kernel and reclocked run pop-mbp11-3-dgpu's install.sh, pinned below)
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
#         --allow-11-2    allow a MacBookPro11,2 (no dGPU: wifi, keyd, clover, clover-dock only)
#         --oc-stanza     also write a "macOS (OpenCore)" rEFInd entry, if rEFInd's scan does not show OpenCore
#         --dgpu-ref R    pop-mbp11-3-dgpu at tag/commit R instead of its newest vX.Y.Z tag
#         --clover-ref R, --clover-dock-ref R   Clover / Clover Dock at tag/commit R instead of the latest release
#         --from-main     main of all three (developer shortcut; explicit --*-ref flags still win)
#   --max-0f / --no-kernel / --kernel-dir on their own keep the v0.1 behaviour: intel-boot, kernel, reclocked.
#   Installed versions are recorded in /var/lib/pop-mbp11-3/versions; a newer release shows as an update.
#
# Log: /var/log/pop-mbp11-3-install.log. Undo: uninstall.sh. Verify after reboot: verify.sh.
set -euo pipefail

REPO="onuraksoy3/pop-mbp11-3"
REF=${MBP_REF:-main}
# The dGPU phases are pop-mbp11-3-dgpu's own install.sh; this kit keeps no copy. The kernel names below are
# fallbacks: the fetched dGPU installer's own values replace them.
DGPU_REPO="onuraksoy3/pop-mbp11-3-dgpu"
RELEASE_TAG="kernel-7.0.11-mbp"
KVER="7.0.11-mbp"
KPKG="7.0.11-7"
VERSIONS=/var/lib/pop-mbp11-3/versions
KEYD_REPO="https://github.com/rvaiya/keyd"
KEYD_TAG="v2.6.0"
CLOVER_REPO="onuraksoy3/cosmic-ext-applet-clover"
CLOVER_DOCK_REPO="onuraksoy3/cosmic-ext-applet-clover-dock"
LOG=/var/log/pop-mbp11-3-install.log
SHARE=/usr/local/share/pop-mbp11-3
LAUNCHER=/usr/share/applications/pop-mbp11-3-setup.desktop
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
if [ ! -f "$HERE/uninstall.sh" ]; then
  [ -z "${MBP_BOOTSTRAPPED:-}" ] || die "bootstrap failed: uninstall.sh missing in $HERE"
  BOOT=$(mktemp -d /tmp/pop-mbp11-3.XXXXXX)
  curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" | tar xz -C "$BOOT" --strip-components=1 \
    || die "could not download $REPO@$REF (no network? see the README: \"No Wi-Fi on first boot?\")"
  export MBP_BOOTSTRAPPED=1
  if [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then exec bash "$BOOT/install.sh" "$@" </dev/tty; fi
  exec bash "$BOOT/install.sh" "$@"
fi

MAX_0F=0; NO_KERNEL=0; KERNEL_DIR=""; OFFLINE=""; DRY_RUN=0; ALLOW_11_2=0; OC_STANZA=0; PHASES=""; LEGACY=0
declare -A REF_ARG=([dgpu]="" [clover]="" [clover-dock]=""); FROM_MAIN=0
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
    --oc-stanza) OC_STANZA=1 ;;
    --dgpu-ref) REF_ARG[dgpu]=${2:?--dgpu-ref needs a tag or commit}; shift ;;
    --clover-ref) REF_ARG[clover]=${2:?--clover-ref needs a tag or commit}; shift ;;
    --clover-dock-ref) REF_ARG[clover-dock]=${2:?--clover-dock-ref needs a tag or commit}; shift ;;
    --from-main) FROM_MAIN=1 ;;
    -h|--help) sed -n '2,35p' "$0"; exit 0 ;;
    *) die "unknown flag: $1 (see --help)" ;;
  esac
  shift
done
if [ "$FROM_MAIN" = 1 ]; then
  for c in dgpu clover clover-dock; do [ -n "${REF_ARG[$c]}" ] || REF_ARG[$c]=main; done
fi
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
if [ -n "$OC_DEV" ]; then
  MACOS="yes — OpenCore on $OC_DEV ($([ "$OC_STANZA" = 1 ] && echo "rEFInd entry will be added" || echo "auto-detected by rEFInd"))"
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

# ------------------------------------------------------------------ versions
# Clover, Clover Dock and pop-mbp11-3-dgpu are fetched at the newest vX.Y.Z release (or, for a repo with no such
# release, its newest vX.Y.Z tag: pop-mbp11-3-dgpu's only release holds the kernel packages), unless --*-ref or
# --from-main names a tag, branch or commit.
. "$HERE/lib/refs.sh"
# What each component should be at (W_*), and how that was chosen (W_HOW).
declare -A W_REF=([dgpu]="" [clover]="" [clover-dock]="") W_SHA=([dgpu]="" [clover]="" [clover-dock]="")
declare -A W_DEB=([dgpu]=- [clover]=- [clover-dock]=-) W_HOW=([dgpu]="" [clover]="" [clover-dock]="")
want_version() {
  local c=$1 repo=$2 r
  W_HOW[$c]="latest release"; [ "$c" = dgpu ] && W_HOW[$c]="newest vX.Y.Z tag"
  if [ -n "${REF_ARG[$c]}" ]; then W_HOW[$c]="--$c-ref"; [ "$FROM_MAIN" = 1 ] && [ "${REF_ARG[$c]}" = main ] && W_HOW[$c]="--from-main"; fi
  if r=$(resolve "$repo" "${REF_ARG[$c]}"); then read -r "W_REF[$c]" "W_SHA[$c]" "W_DEB[$c]" <<<"$r"
  elif [ -n "${REF_ARG[$c]}" ]; then die "$repo has no tag, branch or commit '${REF_ARG[$c]}' (or GitHub is not reachable)"
  else warn "could not find the latest $repo version (GitHub not reachable?)"; fi
}
recorded() { awk -v c="$1" '$1 == c {print $2, $3}' "$VERSIONS" 2>/dev/null | tail -1; }
record() {
  mkdir -p "${VERSIONS%/*}"
  { grep -v "^$1 " "$VERSIONS" 2>/dev/null || true; echo "$1 $2 $3"; } > "$VERSIONS.new" && mv "$VERSIONS.new" "$VERSIONS"
}

# pop-mbp11-3-dgpu: the bundle's snapshot offline; otherwise a copy at the wanted commit (this bundle, the installed
# copy, or a download). Its install.sh also supplies the kernel version the checks expect.
DGPU_DIR=""
fetch_dgpu() {
  local d
  if [ -n "$OFFLINE" ]; then
    [ -f "$OFFLINE/dgpu/install.sh" ] || return 1
    DGPU_DIR="$OFFLINE/dgpu"; W_REF[dgpu]=$(cat "$DGPU_DIR/.tag" 2>/dev/null || echo bundle)
    W_SHA[dgpu]=$(cat "$DGPU_DIR/.rev" 2>/dev/null || true); W_HOW[dgpu]="bundle"; return 0
  fi
  [ -n "${W_SHA[dgpu]}" ] || return 1
  for d in "$HERE/dgpu" "$SHARE/dgpu"; do
    if [ -f "$d/install.sh" ] && [ "$(cat "$d/.rev" 2>/dev/null)" = "${W_SHA[dgpu]}" ]; then DGPU_DIR=$d; return 0; fi
  done
  mkdir -p "$WORK/dgpu"
  curl -fsSL "https://github.com/$DGPU_REPO/archive/${W_SHA[dgpu]}.tar.gz" | tar xz -C "$WORK/dgpu" --strip-components=1 || return 1
  echo "${W_SHA[dgpu]}" > "$WORK/dgpu/.rev"; echo "${W_REF[dgpu]}" > "$WORK/dgpu/.tag"
  DGPU_DIR="$WORK/dgpu"
}
conf() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$2" | head -1; }
if [ "$HAS_DGPU" = 1 ]; then
  [ -n "$OFFLINE" ] || want_version dgpu "$DGPU_REPO"
  if fetch_dgpu; then
    for v in KVER KPKG RELEASE_TAG; do x=$(conf "$v" "$DGPU_DIR/install.sh"); [ -z "$x" ] || printf -v "$v" '%s' "$x"; done
  else
    warn "pop-mbp11-3-dgpu is not available; its phases cannot run"
  fi
  [ -z "$KIMG" ] || KPKG=$(dpkg-deb -f "$KIMG" Version)
fi
if [ -z "$OFFLINE" ] && [ -n "$TARGET_USER" ]; then
  want_version clover "$CLOVER_REPO"
  want_version clover-dock "$CLOVER_DOCK_REPO"
fi

# ------------------------------------------------------------------ state checks
pkg_installed() { [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ]; }
# gpu-power-prefs is not visible after boot; boot_vga shows whether the firmware actually booted on Intel.
intel_boots() { [ "$(cat /sys/bus/pci/devices/0000:00:02.0/boot_vga 2>/dev/null)" = 1 ]; }
oc_block_present() { grep -q '^# pop-mbp11-3 begin' "$ESP/EFI/refind/refind.conf" 2>/dev/null; }
boost_current() { sed -n '/^\[profile default\]/,/^$/ s/^boost-pstate = //p' /etc/reclocked.conf 2>/dev/null | head -1; }
keyd_from_apt() { [ -z "$OFFLINE" ] && apt-cache policy keyd 2>/dev/null | grep -q 'Candidate: [0-9]'; }
user_has() { [ -n "$TARGET_HOME" ] && { [ -x "$TARGET_HOME/.local/bin/$1" ] || [ -x "/usr/bin/$1" ]; }; }

# 0f boost: --max-0f turns it on; otherwise an existing config keeps its setting and a new one starts off.
WANT_BOOST=-1; [ "$MAX_0F" = 1 ] && WANT_BOOST=0f
[ "$MAX_0F" = 0 ] && [ "$(boost_current)" = 0f ] && WANT_BOOST=0f

# Each phase's state is a list of named sub-checks: ck records PASS/FAIL, ck_esp records "??" instead when the
# ESP (root-only, mode 0700) cannot be read, so a normal-user dry run does not mistake that for "not installed".
CK_LINES=(); CK_FAIL=(); CK_UNKNOWN=()
ck() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then CK_LINES+=("PASS  $label"); else CK_LINES+=("FAIL  $label"); CK_FAIL+=("$label"); fi
}
ck_esp() {
  if [ -r "$ESP/EFI" ]; then ck "$@"; else CK_LINES+=("??    $1 (ESP unreadable: needs root)"); CK_UNKNOWN+=("$1"); fi
}
# Installed version against the wanted one. With no record (installed before versions were recorded) it counts as
# current while following the latest release, and as missing when a ref was named.
ck_version() {
  local c=$1 name=$2 ref sha
  read -r ref sha <<<"$(recorded "$c")"
  if [ -z "${W_SHA[$c]}" ]; then
    CK_LINES+=("INFO  $name: wanted version unknown (GitHub not reachable)")
  elif [ -z "$sha" ]; then
    if [ "${W_HOW[$c]}" = "${W_HOW[$c]#--}" ]; then
      CK_LINES+=("INFO  $name: installed version not recorded; counted as current (${W_REF[$c]} is ${W_HOW[$c]})")
    else
      ck "$name at ${W_REF[$c]} (${W_HOW[$c]}; installed version not recorded)" false
    fi
  elif [ "$sha" = "${W_SHA[$c]}" ]; then
    CK_LINES+=("PASS  $name at ${W_REF[$c]} (${sha:0:7})")
  else
    CK_LINES+=("FAIL  update: $name $ref → ${W_REF[$c]}"); CK_FAIL+=("update: $name $ref → ${W_REF[$c]}")
  fi
}
run_checks() { CK_LINES=(); CK_FAIL=(); CK_UNKNOWN=(); "checks_$1"; }
is_done() { run_checks "$1"; [ ${#CK_FAIL[@]} = 0 ] && [ ${#CK_UNKNOWN[@]} = 0 ]; }

checks_wifi() { ck "broadcom-sta-dkms installed" pkg_installed broadcom-sta-dkms; }
checks_intel-boot() {
  ck_esp "rEFInd installed ($ESP/EFI/refind/refind_x64.efi)" test -f "$ESP/EFI/refind/refind_x64.efi"
  ck_esp "spoof_osx_version in refind.conf" grep -q '^spoof_osx_version' "$ESP/EFI/refind/refind.conf"
  ck "firmware boots on Intel (00:02.0 boot_vga = 1)" intel_boots
  ck "COSMIC_RENDER_DEVICE in /etc/environment" grep -q '^COSMIC_RENDER_DEVICE=' /etc/environment
  ck "WGPU_POWER_PREF in /etc/environment" grep -q '^WGPU_POWER_PREF=' /etc/environment
  ck "dgpu-off.service enabled" systemctl -q is-enabled dgpu-off.service
  # rEFInd's own scan finds EFI/OC/OpenCore.efi; a stanza is only checked for when --oc-stanza asks for one.
  if [ -n "$OC_DEV" ] && [ "$OC_STANZA" = 1 ]; then
    ck_esp "rEFInd entry for OpenCore on $OC_DEV (--oc-stanza)" oc_block_present
  elif [ -n "$OC_DEV" ]; then
    ck "OpenCore on $OC_DEV: auto-detected by rEFInd (--oc-stanza adds an entry)" true
  fi
  ck_version dgpu pop-mbp11-3-dgpu
}
checks_kernel() {
  ck "linux-image-$KVER is $KPKG" test "$(dpkg-query -W -f='${Version}' "linux-image-$KVER" 2>/dev/null)" = "$KPKG"
  ck_esp "boot entry Pop_OS-mbp.conf" test -f "$ESP/loader/entries/Pop_OS-mbp.conf"
  ck_esp "ESP vmlinuz-mbp.efi matches /boot" cmp -s "/boot/vmlinuz-$KVER" "$POP_DIR/vmlinuz-mbp.efi"
  ck_esp "loader.conf default Pop_OS-mbp.conf" grep -q '^default Pop_OS-mbp.conf' "$ESP/loader/loader.conf"
  ck_version dgpu pop-mbp11-3-dgpu
}
checks_reclocked() {
  ck "reclocked and reclockctl in /usr/local/bin" test -x /usr/local/bin/reclocked -a -x /usr/local/bin/reclockctl
  ck "/etc/reclocked.conf present" test -f /etc/reclocked.conf
  ck "reclocked.service enabled" systemctl -q is-enabled reclocked.service
  ck "boost-pstate = $WANT_BOOST" test "$(boost_current)" = "$WANT_BOOST"
  ck_version dgpu pop-mbp11-3-dgpu
}
checks_keyd() {
  ck "keyd binary" command -v keyd
  ck "keyd.service enabled" systemctl -q is-enabled keyd
}
checks_clover() { ck "clover-applet for ${TARGET_USER:-?}" user_has clover-applet; ck_version clover Clover; }
checks_clover-dock() { ck "clover-dock for ${TARGET_USER:-?}" user_has clover-dock; ck_version clover-dock "Clover Dock"; }

# Why a phase cannot run here (empty: it can).
unavailable() {
  case "$1" in
    intel-boot|kernel|reclocked) [ "$HAS_DGPU" = 1 ] || echo "no dGPU on the MacBookPro11,2" ;;
    clover|clover-dock)
      if [ -n "$OFFLINE" ]; then echo "needs the network (built from source); run again once Wi-Fi works"
      elif [ -z "$TARGET_USER" ]; then echo "no desktop user: run with sudo from your own account"; fi ;;
  esac
}
status() {
  local why; why=$(unavailable "$1")
  [ -z "$why" ] || { echo "n/a: $why"; return; }
  run_checks "$1"
  if [ ${#CK_FAIL[@]} = 0 ] && [ ${#CK_UNKNOWN[@]} = 0 ]; then echo installed
  elif [ ${#CK_UNKNOWN[@]} = 0 ] && ! printf '%s\n' "${CK_FAIL[@]}" | grep -qv '^update: '; then
    echo "installed, update available: ${CK_FAIL[0]#update: }"
  elif [ ${#CK_FAIL[@]} = 0 ]; then echo "unknown: run as root to check the ESP"
  elif [ ${#CK_FAIL[@]} = ${#CK_LINES[@]} ]; then echo "not installed"
  else echo "partly installed, missing: ${CK_FAIL[0]}$([ ${#CK_FAIL[@]} -gt 1 ] && echo " (+$((${#CK_FAIL[@]} - 1)) more)")"
  fi
}
checks_report() {
  local p l
  for p in $ALL_PHASES; do
    [ -z "$(unavailable "$p")" ] || continue
    echo "[$p]"; run_checks "$p"; for l in "${CK_LINES[@]}"; do echo "  $l"; done
  done
}

# ------------------------------------------------------------------ plan (what each phase writes)
plan_wifi() {
  echo "  package  broadcom-sta-dkms + dkms (wl driver for the BCM4360, built for every installed kernel)"
}
plan_intel-boot() {
  echo "  package  refind efibootmgr git curl switcheroo-control mesa-utils libglib2.0-bin (those missing)"
  [ -f "$ESP/EFI/refind/refind_x64.efi" ] || echo "  file     $ESP/EFI/refind/ (refind-install)"
  echo "  file     $ESP/EFI/refind/refind.conf: spoof_osx_version 10.9"
  if [ -n "$OC_DEV" ] && [ "$OC_STANZA" = 1 ]; then
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
  echo "           ($CLOVER_REPO ${W_REF[clover]} ${W_SHA[clover]:0:7}: $([ "${W_DEB[clover]}" != - ] && echo "release .deb" || echo "built in $TARGET_HOME/src/clover-build"))"
}
plan_clover-dock() {
  echo "  package  build-essential pkg-config git libxkbcommon-dev libwayland-dev libssl-dev (those missing)"
  echo "  file     $TARGET_HOME/.local/bin/clover-dock, ~/.local/share/applications/io.github.onuraksoy3.CloverDock.desktop"
  echo "  file     ~/.config/cosmic/com.system76.CosmicPanel.Dock/v1/plugins_center: App Tray → Clover Dock (backup kept)"
  echo "           ($CLOVER_DOCK_REPO ${W_REF[clover-dock]} ${W_SHA[clover-dock]:0:7}: $([ "${W_DEB[clover-dock]}" != - ] && echo "release .deb" || echo "built in $TARGET_HOME/src/clover-dock"))"
}
plan_common() {
  echo "  file     $SHARE/ (copy of this installer, verify.sh, uninstall.sh, lib/, dgpu/ = pop-mbp11-3-dgpu ${W_REF[dgpu]:-?})"
  echo "  file     $VERSIONS (installed versions of what this run fetched)"
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
Versions:
$(for c in dgpu clover clover-dock; do
    [ -n "${W_REF[$c]}${W_HOW[$c]}" ] || continue
    printf '  %-12s %s\n' "$c" "${W_REF[$c]:-?} ${W_SHA[$c]:0:7} (${W_HOW[$c]}; installed: $(recorded "$c" | cut -d' ' -f1 | grep . || echo "not recorded"))"
  done)

Phases:
$(for p in $ALL_PHASES; do printf '  %-12s %s\n' "$p" "$(status "$p")"; done)
EOF
}

# Selected phases in run order, with dependencies pulled in.
order() {
  local want=" $* " out=""
  [ "${want/ clover /}" = "$want" ] || is_done keyd || want="$want keyd "
  for p in $ALL_PHASES; do [ "${want/ $p /}" = "$want" ] || out="$out $p"; done
  echo "${out# }"
}
dgpu_phases() { local p out=""; for p in $SEL; do case "$p" in intel-boot|kernel|reclocked) out="$out,$p" ;; esac; done; echo "${out#,}"; }
plan_all() {
  if [ -n "$(dgpu_phases)" ]; then
    echo "[pop-mbp11-3-dgpu ${W_REF[dgpu]:-?} ${W_SHA[dgpu]:0:7} (${W_HOW[dgpu]})]"
    echo "  run      install.sh --only $(dgpu_phases) (writes what intel-boot / kernel / reclocked list below)"
  fi
  for p in $SEL; do echo "[$p]"; "plan_$p"; done
  echo "[always]"; plan_common
}

# ------------------------------------------------------------------ choose
if [ "$BATCH" = 1 ]; then
  SEL=""
  for p in $(order $PHASES); do
    why=$(unavailable "$p")
    if [ -n "$why" ]; then warn "skipping $p: $why"
    elif is_done "$p"; then log "$p: already done"
    else SEL="$SEL $p"; fi
  done
  SEL=${SEL# }
  if [ "$DRY_RUN" = 1 ]; then summary; echo; echo "Checks:"; checks_report; echo; echo "Would write:"; plan_all; exit 0; fi
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
      case "$st" in "installed, update available"*) on=ON ;; esac
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
      whiptail --title "$TITLE — dry run" --scrolltext --msgbox "Checks:\n$(checks_report)\n\nWould write:\n\n$(plan_all)" 30 110; exit 0
    fi
    whiptail --title "$TITLE" --yes-button Install --no-button Back --scrolltext \
      --yesno "This will write:\n\n$(plan_all)" 30 110 && break
  done
fi

# ------------------------------------------------------------------ run
touch "$LOG"; chmod 644 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo; echo "===== $(date -Is) install.sh ${SEL:-<nothing>} (ref $REF${OFFLINE:+, offline $OFFLINE}; dgpu ${W_REF[dgpu]:-n/a}, clover ${W_REF[clover]:-n/a}, clover-dock ${W_REF[clover-dock]:-n/a})"
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

# intel-boot, kernel and reclocked in one call to the dGPU installer; then the two settings it does not cover.
run_dgpu() {
  local phases args
  phases=$(dgpu_phases)
  args=(--only "$phases")
  [ "$WANT_BOOST" = 0f ] && args+=(--max-0f)
  [ -n "$KERNEL_DIR" ] && args+=(--kernel-dir "$KERNEL_DIR")
  [ -n "$OFFLINE" ] && args+=(--offline "$OFFLINE")
  [ -n "$DGPU_DIR" ] || die "pop-mbp11-3-dgpu could not be fetched (see the warning above)"
  log "pop-mbp11-3-dgpu ${W_REF[dgpu]} (${W_SHA[dgpu]:0:7}): install.sh ${args[*]}"
  bash "$DGPU_DIR/install.sh" "${args[@]}" || die "pop-mbp11-3-dgpu install.sh failed"
  record dgpu "${W_REF[dgpu]}" "${W_SHA[dgpu]:-unknown}"
  case ",$phases," in *,reclocked,*)
    # The dGPU installer only ever lowers boost-pstate; set it either way so the checklist's 0f choice sticks.
    sed -i "/^\[profile default\]/,/^\$/ s/^boost-pstate = .*/boost-pstate = $WANT_BOOST/" /etc/reclocked.conf ;;
  esac
  case ",$phases," in *,intel-boot,*)
    # Without --oc-stanza OpenCore is left to rEFInd's scan, and a stanza from an earlier --oc-stanza run is kept.
    if [ -n "$OC_DEV" ] && [ "$OC_STANZA" = 1 ]; then
      local conf="$ESP/EFI/refind/refind.conf"
      sed -i '/^# pop-mbp11-3 begin/,/^# pop-mbp11-3 end/d' "$conf"
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
    fi ;;
  esac
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

# The wanted version's release .deb if it has one; returns 1 when the caller should build from source instead.
install_release_deb() {
  local c=$1 url
  [ -n "${W_SHA[$c]}" ] || die "could not resolve the $c version (see the warning above)"
  url=${W_DEB[$c]}
  [ "$url" != - ] || return 1
  log "installing $(basename "$url") ($c ${W_REF[$c]})"
  curl -fL --progress-bar "$url" -o "$WORK/$(basename "$url")" || die "download failed: $url"
  apt_install "$WORK/$(basename "$url")" || die "installing $(basename "$url") failed"
}

phase_clover() {
  log "clover (for $TARGET_USER)"
  install_release_deb clover && { record clover "${W_REF[clover]}" "${W_SHA[clover]}"; return 0; }
  apt_install git curl just pkg-config cmake libxkbcommon-dev libwayland-dev libfontconfig-dev libfreetype-dev \
    libexpat1-dev libinput-dev libudev-dev libdbus-1-dev libssl-dev libglib2.0-bin libnotify-bin
  ensure_rust
  local src="$TARGET_HOME/src/clover-build"
  as_user mkdir -p "$TARGET_HOME/src"
  [ -d "$src/.git" ] || as_user git clone -q "https://github.com/$CLOVER_REPO" "$src"
  as_user git -C "$src" fetch -q --tags origin
  as_user git -C "$src" checkout -q -f "${W_SHA[clover]}"
  log "building Clover ${W_REF[clover]} (first time ~10–15 min)"
  as_user sh -c "cd '$src' && just build-release && just prefix='$TARGET_HOME/.local' install" || die "Clover build failed"
  record clover "${W_REF[clover]}" "${W_SHA[clover]}"
  log "Clover installed. Add it: Settings → Desktop → Panel → Configure applets → Clover; its first-run page finishes keyd setup"
}

phase_clover-dock() {
  log "clover-dock (for $TARGET_USER)"
  install_release_deb clover-dock && { record clover-dock "${W_REF[clover-dock]}" "${W_SHA[clover-dock]}"; return 0; }
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
  as_user git -C "$src" checkout -q -f "${W_SHA[clover-dock]}"
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" PATH="$WORK/shim:$TARGET_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$src/build.sh" || die "Clover Dock build failed"
  record clover-dock "${W_REF[clover-dock]}" "${W_SHA[clover-dock]}"
}

install_launcher() {
  if [ "$HERE" != "$SHARE" ]; then
    rm -rf "$SHARE"; mkdir -p "$SHARE"
    cp -r "$HERE/install.sh" "$HERE/verify.sh" "$HERE/uninstall.sh" "$HERE/lib" "$SHARE/"
  fi
  if [ -n "$DGPU_DIR" ] && [ "$DGPU_DIR" != "$SHARE/dgpu" ]; then rm -rf "$SHARE/dgpu"; cp -r "$DGPU_DIR" "$SHARE/dgpu"; fi
  cat > "$LAUNCHER" <<EOF
[Desktop Entry]
Type=Application
Name=MacBook Pro 11,3 Setup
Comment=GPU switching, Wi-Fi, patched kernel and Clover for this MacBook (pop-mbp11-3)
Exec=cosmic-term -- sudo env MBP_LAUNCHER=1 $SHARE/install.sh
Icon=computer-laptop
Categories=System;Settings;
Terminal=false
EOF
}

for p in $SEL; do
  case "$p" in
    intel-boot|kernel|reclocked) [ -n "${DGPU_DONE:-}" ] || { run_dgpu; DGPU_DONE=1; } ;;
    *) "phase_$p" ;;
  esac
done
install_launcher

cat <<EOF

$(printf '\033[1;32mDone:\033[0m') ${SEL:-nothing to do}. Log: $LOG
EOF
case " $SEL " in *" intel-boot "*|*" kernel "*|*" wifi "*) echo "Reboot to finish, then run verify.sh." ;; esac
[ -n "${MBP_LAUNCHER:-}" ] && read -rp "Press Enter to close." _ </dev/tty
exit 0
