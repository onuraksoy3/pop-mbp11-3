#!/bin/bash
# uninstall.sh — removes what the pop-mbp11-3 kit added. The dGPU part (kernel default, boot entries, reclocked,
# dgpu-off, /etc/environment, boot GPU) is undone by pop-mbp11-3-dgpu's own uninstall.sh.
#   --purge-kernel   also apt-remove the 7.0.11-mbp packages
#   --keep-boot-gpu  leave rEFInd spoof and gpu-power-prefs (Intel boot) in place (recommended)
#   --remove-apps    also remove keyd, Clover and Clover Dock (for the user running sudo)
#   --remove-wifi    also apt-remove broadcom-sta-dkms (no Wi-Fi afterwards on this MacBook)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }
DGPU_ARGS=(); APPS=0; WIFI=0
for a in "$@"; do
  case "$a" in
    --purge-kernel|--keep-boot-gpu) DGPU_ARGS+=("$a") ;; --remove-apps) APPS=1 ;; --remove-wifi) WIFI=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
  esac
done
SHARE=/usr/local/share/pop-mbp11-3
HERE=$(cd "$(dirname "$0")" && pwd)
ESP=$(findmnt -no TARGET /boot/efi 2>/dev/null || echo /boot/efi)

# The dGPU snapshot the kit installed with (or the one in this bundle).
DGPU=""
for d in "$SHARE/dgpu" "$HERE/dgpu"; do [ -f "$d/uninstall.sh" ] && { DGPU=$d; break; }; done
if [ -n "$DGPU" ]; then
  bash "$DGPU/uninstall.sh" "${DGPU_ARGS[@]}"
else
  echo "pop-mbp11-3-dgpu not found in $SHARE/dgpu: the dGPU setup is left in place"
fi

[ -f "$ESP/EFI/refind/refind.conf" ] && sed -i '/^# pop-mbp11-3 begin/,/^# pop-mbp11-3 end/d' "$ESP/EFI/refind/refind.conf"
rm -f /usr/share/applications/pop-mbp11-3-setup.desktop
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
rm -rf "$SHARE"
echo "Kit removed (launcher, $SHARE)."
