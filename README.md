# pop-mbp11-3

MacBook Pro 11,3 kit for Pop!_OS 24.04: one guided installer for the 15" Retina MacBook Pro (Late 2013 / Mid 2014,
**MacBookPro11,3**: Intel Iris Pro 5200 + NVIDIA GeForce GT 750M) on **Pop!_OS 24.04 with COSMIC**.

## Supported hardware
- MacBook Pro 15" Late 2013 and Mid 2014 (MacBookPro11,3, Iris Pro 5200 + GeForce GT 750M) — fully supported
- MacBook Pro 15" Late 2013 / Mid 2014 Intel-only (MacBookPro11,2) — Wi-Fi, keys and applets only (`--allow-11-2`)
- Anything else (2015 models, 13" models, 2012 Retina) — not supported; the installer checks the model and refuses

## What it sets up
- Wi-Fi: Broadcom BCM4360 via broadcom-sta (`wl`) — works, no power-save support in that driver
- Boot on the Intel GPU: rEFInd with the macOS-version spoof, gpu-switch, COSMIC rendering on Intel. The Intel GPU drives the panel and the desktop
- NVIDIA GT 750M on demand: patched 7.0.11 kernel with nouveau runtime PM. The card stays **powered off** (DynOff) until an app launched on it needs it (~1 s to wake, e.g. a `DRI_PRIME` app), runs at full clocks under load, and powers off again a few seconds after the app exits. reclocked sets the clocks and runs the fans on a sane curve
- Power: Thunderbolt 2 controller runtime-suspends (≈1.7 W saved, the same as a full firmware power-off); iGPU excluded from the IOMMU; measured idle ≈14 W at 10% brightness. The remaining gap to ~10 W is the CPU package held at PC3 by NVMe drives without ASPM — see the [Power section](https://github.com/onuraksoy3/pop-mbp11-3-dgpu#power) of pop-mbp11-3-dgpu
- Keys, trackpad and dock on COSMIC (optional): keyd Mac-style shortcuts and trackpad settings via Clover, window previews via Clover Dock
- Suspend/resume, battery and backlight work; the stock Pop kernel stays one rEFInd click away as a fallback

The boot, GPU and power pieces come from [pop-mbp11-3-dgpu](https://github.com/onuraksoy3/pop-mbp11-3-dgpu) and are
not copied here. The kit runs that repo's own `install.sh` (see [Versions and updates](#versions-and-updates)). It
passes `--only` with the phases you picked, plus `--max-0f`, `--kernel-dir` and `--offline` when they apply. Detection,
the menu, Wi-Fi, keyd, Clover and the offline bundle live in this repo.

## Versions and updates

Each component follows its newest release by default:

| Component | Default | Override |
|---|---|---|
| pop-mbp11-3-dgpu (intel-boot, kernel, reclocked) | newest `vX.Y.Z` tag (its only GitHub release holds the kernel packages) | `--dgpu-ref R` |
| Clover | latest `vX.Y.Z` release: its `.deb` if one is attached, else built at that tag | `--clover-ref R` |
| Clover Dock | latest `vX.Y.Z` release, same rule | `--clover-dock-ref R` |

- `R` is a tag, branch, or short or full commit hash; `--from-main` sets all three to `main` (an explicit `--*-ref` still wins). Refs are resolved with `git ls-remote`, so they aren't subject to GitHub's API rate limit. The API is asked once per repo for the release list; if that fails, the newest `vX.Y.Z` tag stands in. A ref that doesn't exist stops the installer.
- Re-running the installer (or the launcher) updates a component when a newer release exists. Installed versions are recorded in `/var/lib/pop-mbp11-3/versions`; the phase then shows "installed, update available: … v0.5.0 → v0.5.1", the menu ticks it, and `--all` re-runs it. A newer dGPU version re-runs intel-boot, kernel and reclocked together.
- Something installed before versions were recorded counts as current while you follow the latest release (`--dry-run` shows "installed version not recorded"). It's recorded the next time that phase runs, and naming a ref with `--*-ref` re-runs it.
- Offline, the bundle's dGPU snapshot is used as is.
- After booting macOS, the firmware may reset the boot order and GPU preference. Hold Option at power-on to pick rEFInd, or re-run the intel-boot phase — it's idempotent.

Status: beta. Everything here was built and verified on one MacBookPro11,3. A fresh-install run has not yet been done — if you're the first, please open an issue with /var/log/pop-mbp11-3-install.log attached.

## One command

```sh
curl -fsSL https://raw.githubusercontent.com/onuraksoy3/pop-mbp11-3/main/install.sh | sudo bash
```

A text menu shows what it detected, lets you pick what to install, and lists every file, package, EFI variable
and boot entry before it changes anything. Reboot afterwards. At rEFInd choose Pop!_OS; the patched kernel boots
by default. Then run `verify.sh` (`--bench` adds the glmark2 comparison). To re-run it later, open
**MacBook Pro 11,3 Setup** from the app grid. Everything is logged to `/var/log/pop-mbp11-3-install.log`.

## Phases and flags

| Phase | What it does | Ticked by default |
|---|---|---|
| `wifi` | `broadcom-sta-dkms` (wl driver for the BCM4360) | yes |
| `intel-boot` | rEFInd + macOS spoof, `gpu-switch -i`, COSMIC on Intel, `dgpu-off.service` (pop-mbp11-3-dgpu) | yes |
| `kernel` | `7.0.11-mbp` and its systemd-boot entry (pop-mbp11-3-dgpu) | yes |
| `reclocked` | GT 750M clocks and fans (pop-mbp11-3-dgpu) | yes |
| `keyd` | key remapping daemon, needed by Clover | no |
| `clover` | [Clover](https://github.com/onuraksoy3/cosmic-ext-applet-clover): Mac-style keys and trackpad | no |
| `clover-dock` | [Clover Dock](https://github.com/onuraksoy3/cosmic-ext-applet-clover-dock): app list with hover previews | no |

Phases that are already done are shown as installed and skipped. `--dry-run` lists every sub-check behind that.
Clover and Clover Dock are built from source for the user who ran `sudo` (rustup is installed for them if missing;
the first build takes 10–15 min each).

Flags for scripted use (no menu):
- `--all` runs every phase; `--phases wifi,kernel` runs only those.
- `--max-0f` adds the 0f boost tier under sustained load (Apple's factory memory clock, ~+20 %, small lock-up risk).
- `--no-kernel` gives the Intel-only setup (dGPU off at boot, no patched kernel).
- `--kernel-dir DIR` uses your own `.deb` files.
- `--offline DIR` installs from the bundle (below).
- `--dry-run` shows what would be written and stops.
- `--allow-11-2` accepts a MacBookPro11,2. It has no NVIDIA GPU, so only wifi, keyd, clover and clover-dock apply.
- `--oc-stanza` writes a "macOS (OpenCore)" entry into `refind.conf`. Only needed if rEFInd's own scan doesn't show OpenCore.
- `--dgpu-ref R`, `--clover-ref R`, `--clover-dock-ref R` use a tag, branch or commit instead of the latest release.
- `--from-main` uses `main` of all three (a developer shortcut; an explicit `--*-ref` still wins).

`--max-0f`, `--no-kernel` and `--kernel-dir` on their own run intel-boot, kernel and reclocked, like
pop-mbp11-3-dgpu's installer.

The installer refuses to run on anything but a MacBookPro11,3. It also checks for the Intel GPU at PCI 00:02.0 and
the NVIDIA GPU at 01:00.0.

## No Wi-Fi on first boot?

Pop!_OS has no driver for the BCM4360, so a fresh install has no network. Use another machine:

1. Download `pop-mbp11-3-bundle.tar.gz` from the
   [latest release](https://github.com/onuraksoy3/pop-mbp11-3/releases/latest/download/pop-mbp11-3-bundle.tar.gz)
   and copy it to a USB stick.
2. On the MacBook:
   ```sh
   tar xzf /media/$USER/<stick>/pop-mbp11-3-bundle.tar.gz && cd pop-mbp11-3-bundle
   sudo ./install.sh --offline .
   ```

The bundle includes a snapshot of pop-mbp11-3-dgpu, the kernel, the Wi-Fi driver, rEFInd, build tools, keyd and the
reclocked and gpu-switch sources (~260 MB). Clover and Clover Dock need the network. Once Wi-Fi works, run the setup
again from the app grid to add them.

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
tools/make-bundle.sh --out ~/src            # → ~/src/pop-mbp11-3-bundle.tar.gz
gh release upload <tag> ~/src/pop-mbp11-3-bundle.tar.gz -R onuraksoy3/pop-mbp11-3
```

Attach it to the newest release, which must be marked latest, so the `releases/latest/download` link above keeps
working. Rebuild and re-attach it whenever `install.sh` or the dGPU pin changes.

The bundle's dGPU snapshot is pop-mbp11-3-dgpu's newest `vX.Y.Z` tag at build time (`--dgpu-ref R` or `--from-main`
to choose another). `make-bundle.sh` takes the kernel version and the reclocked and gpu-switch sources from that
snapshot's `install.sh`. Rebuild the bundle after a new dGPU tag.

## Day to day

- Run something on the 750M: right-click → **Run with…** in COSMIC's app library, `DRI_PRIME=pci-0000_01_00_0 app`,
  or `PrefersNonDefaultGPU=true` in the app's `.desktop` file.
- After booting macOS: `sudo gpu-switch -i` and reboot — macOS resets the boot GPU.
- Pop kernel updates may reset the systemd-boot default to the stock kernel; if the card stops sleeping,
  check `default` in `/boot/efi/loader/loader.conf`.
- The HDMI and Thunderbolt display outputs are wired to the NVIDIA GPU; plug a monitor in while a `DRI_PRIME`
  app is running, or run `sudo reclockctl dgpu-on` first.

Power measurements, the Thunderbolt runtime-PM patch, and how the kernel is built are in
[pop-mbp11-3-dgpu](https://github.com/onuraksoy3/pop-mbp11-3-dgpu#power).

## Uninstall

`sudo ./uninstall.sh` (also installed as `/usr/local/share/pop-mbp11-3/uninstall.sh`). It runs pop-mbp11-3-dgpu's
`uninstall.sh` for the dGPU part, then removes the kit's launcher. Add `--purge-kernel` to remove the kernel packages,
`--keep-boot-gpu` to keep booting on Intel, `--remove-apps` to remove keyd, Clover and Clover Dock, and
`--remove-wifi` to remove the Wi-Fi driver.

## Credits

- Kernel patches and the `reclocked` daemon: Krzysztof Kowalski (MIT; patches signed-off for the kernel).
- MacBookPro11,3 Arch runbook and the 6.18 series, which proved this works end to end: IgorChicherin.
- `gpu-switch` and the AppleMuxControl reverse-engineering: 0xbb.
- `keyd`: rvaiya.

## Licence

MIT.
