# Changelog

## v0.2.0 — 2026-10-24
- install: one guided installer. Running it with no flags opens a whiptail menu (detection summary, phase checklist,
  then a list of everything it will write). `--all` and `--phases` run without questions. The v0.1 flags behave as before.
- New phases: `wifi` (broadcom-sta-dkms), `keyd`, `clover`, `clover-dock`. Every phase checks its own state and
  skips itself when done.
- Detection replaces assumptions: root UUID from `/`, ESP from `/boot/efi`, GPUs checked at PCI 00:02.0 / 01:00.0,
  and OpenCore found on any EFI partition and added to rEFInd. MacBookPro11,2 is accepted with `--allow-11-2`.
- `--dry-run`, logging to `/var/log/pop-mbp11-3-install.log`, and a "MacBook Pro 11,3 Setup" launcher.
- Offline: `--offline DIR` plus `tools/make-bundle.sh`, which builds `pop-mbp11-3-bundle.tar.gz` for machines
  without Wi-Fi yet.
- reclocked: re-running without `--max-0f` keeps an existing 0f setting instead of turning it off.
- uninstall: `--remove-apps`, `--remove-wifi`; it also removes the OpenCore entry and the launcher. verify:
  checks every phase on any kernel.
- README: one command, "No Wi-Fi on first boot?", a fresh-install walkthrough, and how to build the bundle.

## v0.1.2 — 2026-10-23
- kernel 7.0.11-7: new `kernel/patches/0018` enables runtime PM for the Falcon Ridge TB2 host router; the NHI reaches D3hot and idle draw drops ~1.7 W (15.5 → 13.8 W).
- install: boot entry adds `intel_iommu=igfx_off i915.enable_fbc=1`; downloads the -7 packages.
- reclocked: `interval-ms` 500 (was 200); config comments clarify 0e is the ladder max and 0f is boost-only.
- README: new Power section (TB runtime PM, NVMe ASPM / PC3 limit, FBC with 10-bit scanout, TB escape hatch).

## v0.1.1 — 2026-10-23
- reclocked: switchd enabled under the runpm backend — without it the daemon's polling kept the dGPU awake and it never reached DynOff.
- reclocked: [dgpu-active] busy-enter/busy-exit 60/30 (was 80/40) so ~80 % loads stay in 0e instead of flapping.
- reclocked: 0f is now a boost tier (boost-pstate) above the 07/0a/0e ladder; `--max-0f` enables it, default off.
- install: fixed a false "broadcom-sta did not build" warning (pipefail + SIGPIPE).

## v0.1.0 — 2026-10-23
- First release: rEFInd spoof + gpu-switch, COSMIC on Intel, dgpu-off service for the stock kernel, patched 7.0.11-mbp kernel from the GitHub release, reclocked daemon, verify/uninstall/build scripts.
