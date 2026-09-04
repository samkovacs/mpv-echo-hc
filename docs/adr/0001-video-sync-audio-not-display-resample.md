# video-sync=audio instead of display-resample

mpv's usual recommendation for smooth playback on a high-refresh display is `video-sync=display-resample`. On this setup (RTX 3080 Ti, 3440x1440 at 240 Hz, Windows HDR on) it does the opposite: measured on a 2160p10 PQ clip on 2026-09-01, every `display-*` sync mode dropped 6–11 frames per 9 s, while `video-sync=audio` dropped none. So `mpv.conf` uses `audio`, and the Configuration Manager exposes the switch for anyone whose display behaves differently.

## Consequences

- Interpolation (`interpolation=yes`, off by default) needs a display-sync mode to do anything. Turning it on without switching `video-sync` is a silent no-op.
- Re-measure if the driver or mpv/libplacebo changes materially; the drop was reproducible, not a one-off.
