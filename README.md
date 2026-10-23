# pop-mbp11-3-dgpu

macOS-style GPU switching for the 15" Retina MacBook Pro (Late 2013 / Mid 2014, **MacBookPro11,3**:
Intel Iris Pro 5200 + NVIDIA GeForce GT 750M) on **Pop!_OS 24.04 with COSMIC**.

- The Intel GPU drives the panel and the desktop.
- The GT 750M is **powered off** until an app launched on it needs it (~1 s to wake), runs at full
  clocks under load, and powers off again a few seconds after the app exits.
- Fans follow a sane curve. Wi-Fi, suspend, everything else keeps working.

Measured on the machine this was built on: Intel 540 vs GT 750M 1063 (`0e`) / 1309 (`0f`) in
`glmark2 --off-screen -s 1920x1200`; roughly 4–9 W saved at idle versus leaving the card powered.

## One-line install

```sh
curl -fsSL https://github.com/onuraksoy3/pop-mbp11-3-dgpu/raw/main/install.sh | sudo bash
```

Then reboot. At rEFInd choose Pop!_OS; the patched kernel boots by default. Run `verify.sh` afterwards
(`--bench` adds the glmark2 comparison).

Flags: `--max-0f` (Apple's factory memory clock, +20 % GPU throughput, small lock-up risk),
`--no-kernel` (Intel-only setup: dGPU off at boot, no patched kernel), `--kernel-dir DIR` (use your own
`.deb` files).

## What it installs

| Piece | Why |
|---|---|
| rEFInd + `spoof_osx_version 10.9` | Apple's EFI powers the Intel GPU only when it thinks macOS is booting |
| `gpu-switch -i` (0xbb) | Sets the `gpu-power-prefs` EFI variable so Intel is the boot GPU |
| `COSMIC_RENDER_DEVICE`, `WGPU_POWER_PREF` | COSMIC otherwise renders its shell on the NVIDIA card |
| `dgpu-off.service` | On the **stock** kernel: cut the dGPU at boot (it cannot be woken there) |
| `linux-image-7.0.11-mbp` | Vanilla 7.0.11 + 16 patches from [reclocked](https://github.com/KrzysztofKowalski/reclocked) that fix the gmux power-cycle hang; built with Pop's own config; `kernel/build.sh` reproduces it |
| `Pop_OS-mbp.conf` boot entry | `nouveau.runpm=1` only on this kernel; the stock kernel stays a rEFInd click away |
| `reclocked` daemon + config | Raises the 750M's clocks under load (nouveau has no governor), controls the fans via applesmc |

## Day to day

- Run something on the 750M: right-click → **Run with…** in COSMIC's app library, `DRI_PRIME=pci-0000_01_00_0 app`,
  or `PrefersNonDefaultGPU=true` in the app's `.desktop` file.
- After booting macOS: `sudo gpu-switch -i` and reboot — macOS resets the boot GPU.
- Pop kernel updates may reset the systemd-boot default to the stock kernel; if the card stops sleeping,
  check `default` in `/boot/efi/loader/loader.conf`.
- The HDMI and Thunderbolt display outputs are wired to the NVIDIA GPU; plug a monitor in while a `DRI_PRIME`
  app is running, or run `sudo reclockctl dgpu-on` first.

## Uninstall

`sudo ./uninstall.sh` (add `--purge-kernel` to remove the packages, `--keep-boot-gpu` to keep booting on Intel).

## Credits

- Kernel patches and the `reclocked` daemon: Krzysztof Kowalski (MIT; patches signed-off for the kernel).
- MacBookPro11,3 Arch runbook and the 6.18 series, which proved this works end to end: IgorChicherin.
- `gpu-switch` and the AppleMuxControl reverse-engineering: 0xbb.
- Companion applet for Mac-style keys and trackpad on COSMIC: [Clover](https://github.com/onuraksoy3/cosmic-ext-applet-clover).

## Licence

Scripts and config in this repo: MIT. The kernel packages are GPL-2.0 like Linux; source is kernel.org 7.0.11 plus
the patches linked above, reproducible with `kernel/build.sh`.
