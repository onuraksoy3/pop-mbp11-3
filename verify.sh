#!/bin/bash
# verify.sh — run as your normal user after rebooting. Checks the kit's own phases, then hands over to
# pop-mbp11-3-dgpu's verify.sh for the dGPU (sleep test on the -mbp kernel; --bench adds glmark2).
set -u
SHARE=/usr/local/share/pop-mbp11-3
# gpu-power-prefs is not visible after boot; boot_vga shows which GPU the firmware booted on.
prefs() { [ "$(cat /sys/bus/pci/devices/0000:00:02.0/boot_vga 2>/dev/null)" = 1 ] && echo Intel || echo "NVIDIA (run: sudo gpu-switch -i, reboot)"; }
have() { [ -x "$HOME/.local/bin/$1" ] || command -v "$1" >/dev/null && echo installed || echo "not installed"; }
echo "model:         $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo "wifi:          $(lsmod | grep -q '^wl ' && echo 'wl loaded' || echo 'wl NOT loaded')"
echo "boot GPU:      $(prefs) (expected: Intel)"
echo "rEFInd macOS:  $(sudo grep -q '^# pop-mbp11-3 begin' "$(findmnt -no TARGET /boot/efi)/EFI/refind/refind.conf" 2>/dev/null && echo 'OpenCore entry present (--oc-stanza)' || echo "no stanza (rEFInd's scan finds OpenCore)")"
echo "keyd:          $(systemctl is-active keyd 2>/dev/null)"
echo "clover:        $(have clover-applet)"
echo "clover-dock:   $(have clover-dock)"
[ -e /sys/bus/pci/devices/0000:01:00.0 ] || { echo; echo "no dGPU at 01:00.0: nothing more to test"; exit 0; }
HERE=$(cd "$(dirname "$0")" && pwd)
for d in "$HERE/dgpu" "$SHARE/dgpu"; do
  if [ -f "$d/verify.sh" ]; then echo; echo "— pop-mbp11-3-dgpu verify.sh —"; exec bash "$d/verify.sh" "$@"; fi
done
echo; echo "pop-mbp11-3-dgpu not found in $SHARE/dgpu: run the setup once to install it"
