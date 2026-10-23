#!/bin/bash
# verify.sh — run as your normal user after rebooting. Checks every install.sh phase, then (on the -mbp kernel)
# whether the GT 750M sleeps, wakes for a DRI_PRIME app, and sleeps again; optional benchmark with --bench.
set -u
sw() { sudo cat /sys/kernel/debug/vgaswitcheroo/switch | sed -n 2p; }
# gpu-power-prefs is not visible after boot; boot_vga shows which GPU the firmware booted on.
prefs() { [ "$(cat /sys/bus/pci/devices/0000:00:02.0/boot_vga 2>/dev/null)" = 1 ] && echo Intel || echo "NVIDIA (run: sudo gpu-switch -i, reboot)"; }
have() { [ -x "$HOME/.local/bin/$1" ] || command -v "$1" >/dev/null && echo installed || echo "not installed"; }
echo "model:         $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "kernel:        $(uname -r)"
echo "wifi:          $(lsmod | grep -q '^wl ' && echo 'wl loaded' || echo 'wl NOT loaded'); $(nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -m1 wl || echo 'no wifi device')"
echo "boot GPU:      $(prefs) (expected: Intel)"
echo "rEFInd macOS:  $(sudo grep -q '^# pop-mbp11-3 begin' "$(findmnt -no TARGET /boot/efi)/EFI/refind/refind.conf" 2>/dev/null && echo 'OpenCore entry present' || echo 'no OpenCore entry')"
echo "keyd:          $(systemctl is-active keyd 2>/dev/null)"
echo "clover:        $(have clover-applet)"
echo "clover-dock:   $(have clover-dock)"
echo "dgpu-off:      $(systemctl is-active dgpu-off.service) (expected: active on the stock kernel, inactive on -mbp)"
echo "reclocked:     $(systemctl is-active reclocked.service)"
case "$(uname -r)" in *-mbp) ;; *) echo; echo "not the -mbp kernel: skipping the dGPU sleep test (reboot and pick Pop!_OS in rEFInd)"; exit 1 ;; esac
[ -e /sys/bus/pci/devices/0000:01:00.0 ] || { echo; echo "no dGPU at 01:00.0: nothing more to test"; exit 0; }
echo
echo -n "idle 12 s… "; sleep 12; echo "dGPU: $(sw)"
echo -n "wake with DRI_PRIME… "; r=$(DRI_PRIME=pci-0000_01_00_0 glxinfo -B 2>/dev/null | awk -F': ' '/OpenGL renderer/ {print $2}'); echo "renderer: ${r:-FAILED}"
echo "during:        $(sw)"
echo -n "idle 12 s… "; sleep 12; echo "dGPU: $(sw)"
echo
echo "Expected: DynOff → NVE7 → DynPwr → DynOff."
if [ "${1:-}" = --bench ] && command -v glmark2-wayland >/dev/null; then
  echo; echo "glmark2 off-screen 1920x1200 — Intel, then GT 750M (2–3 min each):"
  glmark2-wayland --off-screen -s 1920x1200 2>/dev/null | tail -2 | head -1
  DRI_PRIME=pci-0000_01_00_0 glmark2-wayland --off-screen -s 1920x1200 2>/dev/null | tail -2 | head -1
  sleep 12; echo "after bench:   $(sw)"
fi
