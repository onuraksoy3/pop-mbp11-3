# Changelog

## Unreleased
- Versions: pop-mbp11-3-dgpu now follows its newest `vX.Y.Z` tag instead of a commit pinned in `install.sh`; Clover
  and Clover Dock follow their latest `vX.Y.Z` release as before. `--dgpu-ref`, `--clover-ref` and
  `--clover-dock-ref` take a tag, branch or commit; `--from-main` uses `main` for all three. A ref that doesn't
  exist is an error.
- Installed versions are recorded in `/var/lib/pop-mbp11-3/versions`. A newer release shows as "update available",
  is ticked in the menu, and is re-run by `--all`. Installs from before this are counted as current until they next run.
- The dry run lists the version of each component and where it came from. `lib/refs.sh` holds the resolver, shared
  with `tools/make-bundle.sh`, which gains `--dgpu-ref` / `--from-main` and records the snapshot's tag.

## v0.1.0 — 2026-10-24
First release of the kit, split out of pop-mbp11-3-dgpu (its history up to a094fa7 is this repo's start).
- One guided installer: with no flags, a whiptail menu (detection summary, phase checklist with sensible defaults,
  then a list of every file, package, EFI variable and boot entry it will write). `--all` and `--phases` run
  without questions; `--dry-run` stops before writing and prints every sub-check.
- Phases: `wifi` (broadcom-sta-dkms), `intel-boot`, `kernel`, `reclocked`, `keyd`, `clover`, `clover-dock`. Each one
  checks its own state and is skipped when done.
- `intel-boot`, `kernel` and `reclocked` run pop-mbp11-3-dgpu's own `install.sh`, pinned to v0.1.3 (`d196584`), with
  `--only` and the matching flags. The dGPU logic lives only there.
- Detection instead of assumptions: root UUID from `/`, ESP from `/boot/efi`, GPUs checked at PCI 00:02.0 / 01:00.0,
  and OpenCore found on any EFI partition. rEFInd's own scan shows OpenCore; `--oc-stanza` writes an explicit entry.
  MacBookPro11,2 is accepted with `--allow-11-2`, for the phases that don't need a dGPU.
- Offline: `--offline DIR` plus `tools/make-bundle.sh`, which builds `pop-mbp11-3-bundle.tar.gz`. The bundle holds
  the dGPU snapshot, the kernel, the Wi-Fi driver, rEFInd and build tools as a local apt repository, keyd as a .deb,
  and the reclocked and gpu-switch sources.
- Logs to `/var/log/pop-mbp11-3-install.log`; a "MacBook Pro 11,3 Setup" launcher re-opens the menu.
- `uninstall.sh` runs the dGPU repo's `uninstall.sh`, then removes the kit's own pieces (`--remove-apps`,
  `--remove-wifi`). `verify.sh` checks the kit's phases, then runs the dGPU repo's `verify.sh`.
