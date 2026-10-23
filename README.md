# pop-mbp11-3-dgpu

macOS-style GPU switching for the 15" Retina MacBook Pro (Late 2013 / Mid 2014, **MacBookPro11,3**:
Intel Iris Pro 5200 + NVIDIA GeForce GT 750M) on **Pop!_OS 24.04 with COSMIC**.

## One command

```sh
curl -fsSL https://raw.githubusercontent.com/onuraksoy3/pop-mbp11-3-dgpu/main/install.sh | sudo bash
```

A text menu shows what it detected, lets you pick what to install, and lists every file, package, EFI variable
and boot entry before it changes anything. Reboot afterwards. At rEFInd choose Pop!_OS; the patched kernel boots
by default. Then run `verify.sh` (`--bench` adds the glmark2 comparison). To re-run it later, open
**MacBook Pro 11,3 Setup** from the app grid. Everything is logged to `/var/log/pop-mbp11-3-install.log`.

## What you get

- The Intel GPU drives the panel and the desktop.
- The GT 750M is **powered off** until an app launched on it needs it (~1 s to wake), runs at full
  clocks under load, and powers off again a few seconds after the app exits.
- Fans follow a sane curve. Wi-Fi, suspend, everything else keeps working.

Measured on the machine this was built on: Intel 540 vs GT 750M 1063 (`0e`) / 1309 (`0f`) in
`glmark2 --off-screen -s 1920x1200`; roughly 4–9 W saved at idle versus leaving the card powered.

## Phases and flags

| Phase | What it does | Ticked by default |
|---|---|---|
| `wifi` | `broadcom-sta-dkms` (wl driver for the BCM4360) | yes |
| `intel-boot` | rEFInd + macOS spoof, `gpu-switch -i`, COSMIC on Intel, `dgpu-off.service` | yes |
| `kernel` | `7.0.11-mbp` and its systemd-boot entry | yes |
| `reclocked` | GT 750M clocks and fans | yes |
| `keyd` | key remapping daemon, needed by Clover | no |
| `clover` | [Clover](https://github.com/onuraksoy3/cosmic-ext-applet-clover): Mac-style keys and trackpad | no |
| `clover-dock` | [Clover Dock](https://github.com/onuraksoy3/cosmic-ext-applet-clover-dock): app list with hover previews | no |

Phases that are already done are shown as installed and skipped. Clover and Clover Dock are built from source for
the user who ran `sudo` (rustup is installed for them if missing; the first build takes 10–15 min each).

Flags for scripted use (no menu):
- `--all` runs every phase; `--phases wifi,kernel` runs only those.
- `--max-0f` adds the 0f boost tier under sustained load (Apple's factory memory clock, ~+20 %, small lock-up risk).
- `--no-kernel` gives the Intel-only setup (dGPU off at boot, no patched kernel).
- `--kernel-dir DIR` uses your own `.deb` files.
- `--offline DIR` installs from the bundle (below).
- `--dry-run` shows what would be written and stops.
- `--allow-11-2` accepts a MacBookPro11,2. It has no NVIDIA GPU, so only wifi, kernel, keyd, clover and clover-dock apply.
- `--oc-stanza` writes a "macOS (OpenCore)" entry into `refind.conf`. Only needed if rEFInd's own scan doesn't show OpenCore.

`--max-0f`, `--no-kernel` and `--kernel-dir` on their own still do what they did in v0.1: intel-boot, kernel and
reclocked.

The installer refuses to run on anything but a MacBookPro11,3. It also checks for the Intel GPU at PCI 00:02.0 and
the NVIDIA GPU at 01:00.0.

## No Wi-Fi on first boot?

Pop!_OS has no driver for the BCM4360, so a fresh install has no network. Use another machine:

1. Download `pop-mbp11-3-bundle.tar.gz` from the
   [latest release](https://github.com/onuraksoy3/pop-mbp11-3-dgpu/releases/latest/download/pop-mbp11-3-bundle.tar.gz)
   and copy it to a USB stick.
2. On the MacBook:
   ```sh
   tar xzf /media/$USER/<stick>/pop-mbp11-3-bundle.tar.gz && cd pop-mbp11-3-bundle
   sudo ./install.sh --offline .
   ```

The bundle includes the kernel, the Wi-Fi driver, rEFInd, build tools, keyd and the reclocked and gpu-switch
sources (~260 MB). Clover and Clover Dock need the network. Once Wi-Fi works, run the setup again from the app
grid to add them.

## Fresh install

1. If you dual-boot macOS, shrink the APFS container in macOS Disk Utility first to make room.
2. Boot the Pop!_OS 24.04 USB (hold Option at the chime) and choose **Custom (Advanced)** partitioning.
3. Create a new EFI partition (1 GB, FAT32, mounted at `/boot/efi`) and a root partition (ext4, `/`) in the free space.
   If you dual-boot, **keep** the macOS APFS partitions and Apple's EFI partition (the first one on the disk, where
   OpenCore lives): don't format or delete them.
4. Finish the install, reboot into Pop!_OS, and run the one command above (or the offline steps).

You don't need to note partition numbers. The installer takes the root filesystem from `/` and the ESP from
`/boot/efi`. It finds macOS by scanning every EFI partition for `EFI/OC` or `EFI/APPLE` and reports what it found.
rEFInd's own scan picks up OpenCore, so nothing is written for it. If OpenCore doesn't appear in rEFInd, re-run with
`sudo ./install.sh --phases intel-boot --oc-stanza`.

## Building the offline bundle

On any Pop!_OS 24.04 machine with internet:

```sh
tools/make-bundle.sh                     # → ./pop-mbp11-3-bundle.tar.gz
gh release upload v0.2.0 pop-mbp11-3-bundle.tar.gz -R onuraksoy3/pop-mbp11-3-dgpu
```

Attach it to the newest release (currently `v0.2.0`, which must be marked latest) so the `releases/latest/download`
link above keeps working. Rebuild and re-attach it whenever the kernel packages or `files/` change.

## What it installs

| Piece | Why |
|---|---|
| rEFInd + `spoof_osx_version 10.9` | Apple's EFI powers the Intel GPU only when it thinks macOS is booting |
| `gpu-switch -i` (0xbb) | Sets the `gpu-power-prefs` EFI variable so Intel is the boot GPU |
| `COSMIC_RENDER_DEVICE`, `WGPU_POWER_PREF` | COSMIC otherwise renders its shell on the NVIDIA card |
| `dgpu-off.service` | On the **stock** kernel: cut the dGPU at boot (it cannot be woken there) |
| `linux-image-7.0.11-mbp` | Vanilla 7.0.11 + 16 patches from [reclocked](https://github.com/KrzysztofKowalski/reclocked) that fix the gmux power-cycle hang, plus `kernel/patches/0018` (Thunderbolt runtime PM); built with Pop's own config; `kernel/build.sh` reproduces it |
| `Pop_OS-mbp.conf` boot entry | `nouveau.runpm=1 intel_iommu=igfx_off i915.enable_fbc=1` only on this kernel; the stock kernel stays a rEFInd click away |
| `reclocked` daemon + config | Raises the 750M's clocks under load (nouveau has no governor), controls the fans via applesmc |
| `broadcom-sta-dkms` | Wi-Fi: the BCM4360 needs Broadcom's `wl` driver |
| rEFInd "macOS (OpenCore)" entry | Only with `--oc-stanza`; rEFInd's scan finds OpenCore on its own |
| keyd, Clover, Clover Dock | Optional: Mac-style keyboard, trackpad and dock on COSMIC |

## Day to day

- Run something on the 750M: right-click → **Run with…** in COSMIC's app library, `DRI_PRIME=pci-0000_01_00_0 app`,
  or `PrefersNonDefaultGPU=true` in the app's `.desktop` file.
- After booting macOS: `sudo gpu-switch -i` and reboot — macOS resets the boot GPU.
- Pop kernel updates may reset the systemd-boot default to the stock kernel; if the card stops sleeping,
  check `default` in `/boot/efi/loader/loader.conf`.
- The HDMI and Thunderbolt display outputs are wired to the NVIDIA GPU; plug a monitor in while a `DRI_PRIME`
  app is running, or run `sudo reclockctl dgpu-on` first.

## Power

`kernel/patches/0018-thunderbolt-runtime-pm-tb2-host.patch` sets `tb->root_switch->rpm = true` in `tb_start()`, so the
Falcon Ridge TB2 host router and its NHI runtime-suspend (upstream only enables this for USB4 routers). The NHI
reaches D3hot ~15 s after boot and idle draw fell ~1.7 W: 15.5 → 13.8 W at 10 % brightness, measured with `upower`.
Booting with `acpi_osi=!Darwin` (the firmware then powers the controller off completely) saved nothing further, so
the patch captures the whole gain while keeping the ports.

- The remaining ~4 W is the CPU package stuck at PC3: the NVMe (Lexar NM610 PRO) advertises no ASPM. A drive with
  ASPM L1 (e.g. SK Hynix Gold P31) is the fix.
- `i915.enable_fbc=1` is set, but FBC stays inactive in practice because cosmic-comp scans out 10-bit (XB30).
- If Thunderbolt hotplug fails to wake the ports, keep the controller powered:
  `echo on | sudo tee /sys/bus/pci/devices/0000:08:00.0/power/control`

## Uninstall

`sudo ./uninstall.sh` (also installed as `/usr/local/share/pop-mbp11-3/uninstall.sh`). Add `--purge-kernel` to
remove the kernel packages, `--keep-boot-gpu` to keep booting on Intel, `--remove-apps` to remove keyd, Clover and
Clover Dock, and `--remove-wifi` to remove the Wi-Fi driver.

## TODO

- Rename the repository to `pop-mbp11-3` (it does more than the dGPU now). GitHub redirects the old URLs, but
  update `REPO` in `install.sh` and `tools/make-bundle.sh`, the README links, and the bootstrap tarball path.

## Credits

- Kernel patches and the `reclocked` daemon: Krzysztof Kowalski (MIT; patches signed-off for the kernel).
- MacBookPro11,3 Arch runbook and the 6.18 series, which proved this works end to end: IgorChicherin.
- `gpu-switch` and the AppleMuxControl reverse-engineering: 0xbb.
- Companion applet for Mac-style keys and trackpad on COSMIC: [Clover](https://github.com/onuraksoy3/cosmic-ext-applet-clover).

## Licence

Scripts and config in this repo: MIT. The kernel packages are GPL-2.0 like Linux; source is kernel.org 7.0.11 plus
the patches linked above, reproducible with `kernel/build.sh`.
