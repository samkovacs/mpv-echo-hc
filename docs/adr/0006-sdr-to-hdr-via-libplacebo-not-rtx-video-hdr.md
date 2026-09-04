# SDR→HDR through libplacebo inverse tone mapping, not NVIDIA RTX Video HDR

Two things can expand SDR content onto the HDR display: NVIDIA's RTX Video HDR filter (`nvidia_true_hdr` in `vsr_autocrop.conf`) or libplacebo's `inverse-tone-mapping`. The NVIDIA filter is a black box that mpv cannot check or steer, and mpv's own implementation of it misbehaves on an SDR display (mpv#17800). libplacebo's path is deterministic and can be pointed at the display's measured peak. So `mpv.conf` sets `inverse-tone-mapping=yes`, `nvidia_true_hdr=no`, and `hdr-mode.lua` owns the render target per display: in `pass` mode with the display in HDR it sets the target peak to the measured value (603 nits on the primary), which was verified as `spline tone map (480 -> 603)` in `vo-passes`.

## Consequences

- `hdr-mode.lua` is the only thing that should touch `target-peak` / `target-trc` / `target-prim`. Profiles and other scripts must not.
- RTX Video HDR stays available as an opt-in toggle in the right-click Window menu for comparison, gated on the display already being in HDR mode.
