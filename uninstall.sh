#!/bin/bash
# uninstall.sh — reverts to the stock kernel as default and removes what install.sh added.
#   --purge-kernel   also apt-remove the 7.0.11-mbp packages
#   --keep-boot-gpu  leave rEFInd spoof and gpu-power-prefs (Intel boot) in place (recommended)
#   --remove-apps    also remove keyd, Clover and Clover Dock (for the user running sudo)
#   --remove-wifi    also apt-remove broadcom-sta-dkms (no Wi-Fi afterwards on this MacBook)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
PURGE=0; KEEP_BOOT=0; APPS=0; WIFI=0
for a in "$@"; do
  case "$a" in
    --purge-kernel) PURGE=1 ;; --keep-boot-gpu) KEEP_BOOT=1 ;; --remove-apps) APPS=1 ;; --remove-wifi) WIFI=1 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
  esac
done
ESP=$(findmnt -no TARGET /boot/efi 2>/dev/null || echo /boot/efi); KVER=7.0.11-mbp
LC="$ESP/loader/loader.conf"
[ -f "$LC" ] && sed -i 's/^default .*/default Pop_OS-current/' "$LC"
rm -f "$ESP"/loader/entries/Pop_OS-mbp.conf "$ESP"/EFI/Pop_OS-*/vmlinuz-mbp.efi "$ESP"/EFI/Pop_OS-*/initrd-mbp.img "$ESP"/EFI/Pop_OS-*/refind_linux.conf
[ -f "$ESP/EFI/refind/refind.conf" ] && sed -i '/^# pop-mbp11-3 begin/,/^# pop-mbp11-3 end/d' "$ESP/EFI/refind/refind.conf"
systemctl disable --now reclocked.service 2>/dev/null || true
rm -f /etc/systemd/system/reclocked.service /usr/local/bin/reclocked /usr/local/bin/reclockctl /etc/reclocked.conf
systemctl disable dgpu-off.service 2>/dev/null || true
rm -f /etc/systemd/system/dgpu-off.service; rm -rf /etc/systemd/system/dgpu-off.service.d
sed -i '/^COSMIC_RENDER_DEVICE=/d; /^WGPU_POWER_PREF=/d' /etc/environment
rm -f /usr/share/applications/pop-mbp11-3-setup.desktop; rm -rf /usr/local/share/pop-mbp11-3
systemctl daemon-reload
if [ "$PURGE" = 1 ]; then apt-get remove -y -q "linux-image-$KVER" "linux-headers-$KVER" >/dev/null || true; fi
if [ "$WIFI" = 1 ]; then apt-get remove -y -q broadcom-sta-dkms >/dev/null || true; echo "broadcom-sta-dkms removed"; fi

if [ "$APPS" = 1 ]; then
  U=${SUDO_USER:-}; H=""; [ -n "$U" ] && H=$(getent passwd "$U" | cut -d: -f6)
  if [ -n "$H" ]; then
    # Clover Dock: put the stock App Tray back (same as the dock's own uninstall.sh).
    dock="$H/.config/cosmic/com.system76.CosmicPanel.Dock/v1/plugins_center"
    [ -f "$dock" ] && sed -i 's/io.github.onuraksoy3.CloverDock/com.system76.CosmicAppList/g' "$dock"
    rm -f "$H/.local/bin/clover-dock" "$H/.local/share/applications/io.github.onuraksoy3.CloverDock.desktop" \
      "$H"/.config/cosmic/com.system76.CosmicAppList/v1/hover_preview{,_delay_ms}
    # Clover: the files its justfile installs.
    rm -f "$H"/.local/bin/clover{,-applet,-empty-trash,-kbd-backlight,-screenshot,-sensord,-gpu-rules} \
      "$H/.local/share/applications/io.github.onuraksoy3.Clover.desktop" "$H/.local/share/appdata/io.github.onuraksoy3.Clover.metainfo.xml" \
      "$H/.local/share/icons/hicolor/scalable/apps/io.github.onuraksoy3.Clover.svg"
    rm -rf "$H/.local/share/clover"
    echo "Clover and Clover Dock removed for $U (build trees left in $H/src)"
  else
    echo "no sudo user: Clover and Clover Dock left in place"
  fi
  for p in clover-applet clover-dock; do
    [ "$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null)" = "install ok installed" ] && apt-get remove -y -q "$p" >/dev/null || true
  done
  systemctl disable --now keyd 2>/dev/null || true
  if [ "$(dpkg-query -W -f='${Status}' keyd 2>/dev/null)" = "install ok installed" ]; then
    apt-get remove -y -q keyd >/dev/null
  else
    rm -rf /usr/local/bin/keyd /usr/local/bin/keyd-application-mapper /usr/local/share/doc/keyd /usr/local/share/keyd \
      /usr/local/share/man/man1/keyd*.gz /usr/local/lib/systemd/system/keyd.service /usr/local/lib/sysusers.d/keyd.conf
  fi
  systemctl daemon-reload
  echo "keyd removed (/etc/keyd kept)"
fi

if [ "$KEEP_BOOT" = 0 ]; then
  [ -x /usr/local/bin/gpu-switch ] && /usr/local/bin/gpu-switch -d >/dev/null && echo "boot GPU back to NVIDIA (gpu-power-prefs)"
  echo "rEFInd left installed; to stop using it: sudo efibootmgr -o <Pop entry number>,…  (see: efibootmgr)"
fi
echo "Reverted. Reboot. The stock kernel is the default again; the dGPU will stay powered (no dgpu-off service)."
