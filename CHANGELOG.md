# Changelog

## v0.1.1 — 2026-10-23
- reclocked: switchd enabled under the runpm backend — without it the daemon's polling kept the dGPU awake and it never reached DynOff.
- reclocked: [dgpu-active] busy-enter/busy-exit 60/30 (was 80/40) so ~80 % loads stay in 0e instead of flapping.
- reclocked: 0f is now a boost tier (boost-pstate) above the 07/0a/0e ladder; `--max-0f` enables it, default off.
- install: fixed a false "broadcom-sta did not build" warning (pipefail + SIGPIPE).

## v0.1.0 — 2026-10-23
- First release: rEFInd spoof + gpu-switch, COSMIC on Intel, dgpu-off service for the stock kernel, patched 7.0.11-mbp kernel from the GitHub release, reclocked daemon, verify/uninstall/build scripts.
