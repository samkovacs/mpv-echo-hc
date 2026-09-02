# RESUME — handoff for a fresh agent

Repo: `C:\Users\pseud\Desktop\MPV-Nvidia-VSR-main` (portable mpv install, Windows 11). Branch `main`, all work committed. Working tree clean except the untracked `MPV-Nvidia-VSR-main.code-workspace`.

Read `CLAUDE.md` rules first: no AI attribution in commits, never push, `uv`/`bun` only, plan before non-trivial work, verify before claiming.

## Machine

- EVGA RTX 3080 Ti 12 GB, i9-12900K, 64 GB. NVIDIA driver 610.88 (616.56 available, update deferred until testing is done).
- Displays: 3440x1440 @ 240 Hz primary, Windows HDR on, measured peak 603 nits, black 0; 2560x1440 @ 144 Hz; 1920x1080. mpv fullscreens on the primary.
- NVIDIA app: RTX Video Super Resolution on (quality 4), RTX Video HDR on, inverse telecine on. Leave them.
- mpv v0.41.0-923-g7b8915bc1 (shinchiro daily 2026-08-14), libplacebo v7.371. `vo=gpu-next`, `gpu-api=d3d11`, `hwdec=d3d11va-copy`.

## What was done (2026-09-01, commits 94e923b..1ad835d)

1. **Fullscreen freeze bugs**: removed `d3d11-exclusive-fs=yes` from mpv.conf. Right-click menu freeze **confirmed fixed by the user**. Intermittent fullscreen lockup: same root cause, **not yet confirmed** by a long session.
2. **4K HDR stutter** (reported after #1): `video-sync=display-resample` -> `audio`. Measured: every display-sync mode dropped 6-11 frames per 9 s on a 2160p10 PQ clip at 240 Hz; audio sync dropped 0. User has **not yet reported back** on the real file (A Clockwork Orange 2160p HDR remux).
3. **Removed**: uosc, inputevent.lua, playlistmanager, memo (builtin `save-watch-history=yes` replaces it), webtorrent.conf + profile, nlmeans shader. ModernZ is the sole OSC; native `menu.conf` right-click menu; builtin select.lua for lists.
4. **Shaders vs VSR**: `vsr_autocrop.lua` now skips `@vsr` when `glsl-shaders` is set (they cannot stack: d3d11vpp scales first, every shader is gated on OUTPUT > LUMA). Anime auto-profile `[WEB-DL]` in mpv.conf uses `ArtCNN_C4F16_DS.glsl`. Manual profiles `[ArtCNN]`, `[ArtCNN-DS]` replace `[Ani4k]`/`[AniSD]`.
5. **ArtCNN C4F32 and the `_CMP` compute builds do not work on d3d11** (14 cbuffer limit / 32 KB group shared memory). Files deleted. Only C4F16 variants compile. Do not re-add C4F32 unless `gpu-api=vulkan`.
6. **HDR**: `nvidia_true_hdr=no` in vsr_autocrop.conf. `inverse-tone-mapping=yes` in mpv.conf; `hdr-mode.lua` `apply_hdr_settings(inverse)` points SDR sources at the per-display peak when the display is in HDR mode (pass mode). Verified `spline tone map (480 -> 603)` in vo-passes.
7. `deband=yes` globally. `watch-later-options-remove` now also covers `af`, `deinterlace`. `priority=high`, `force-seekable=yes` removed. `4k-Downscaling` profile-cond nil-guarded. modernz `tick_delay_follow_display_fps=yes`.
8. Backups of every touched file: `backup_2026-09-01/` (gitignored).
9. Research notes with sources: `doc/research-rtx-vsr-vs-shaders.md` (has a measured addendum), `doc/research-osc-modernz-vs-uosc.md`.

## Verification method that worked

Synthetic clips in the session scratchpad (gone after context clear; regenerate with ffmpeg.exe in repo root):
- 1080p60 H.264: `testsrc2=size=1920x1080:rate=60,noise=alls=8:allf=t`, libx264. Copy named `[SubsPlease] test - 01 (1080p).mp4` triggers the WEB-DL profile.
- 2160p10 PQ: libx265 `-preset veryfast -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:no-open-gop=1:keyint=48:bframes=3` plus an aac sine track. Validate first with `--vo=null --hwdec=d3d11va-copy` and count `[e|w][ffmpeg` lines; a broken clip fakes drops.
- Probe Lua script (pass via `--script=`): after ~9 s print `frame-drop-count`, `vo-delayed-frame-count`, `mistimed-frame-count`, `vo-passes` (fresh, avg per desc), then `quit`. Run mpv with `--fs --volume=0 --no-resume-playback --save-position-on-quit=no --msg-level=all=v --log-file=...`. Always kill stray `mpv.exe` (`taskkill //F //IM mpv.exe //T`); `--idle` runs never exit because `keep-open=always`.
- Shader hook health: grep the log for `Failed executing hook` and `Too many constant buffers`; libplacebo silently disables a failing hook after frame one and `vo-passes` then shows no shader pass.

## Open items

- User to confirm: no fullscreen lockup over a full film; 4K remux stutter gone; autocrop lands on 2.39:1 content (retries at 4/20/65/185 s); HDR tone map looks right at 603 nits.
- Then: driver update to 616.56.
- Possible next lever if 4K performance comes up again: native `hwdec=d3d11va` after cropdetect (copy-back is only needed for cropdetect). Costs a mid-play decoder reinit; the script's header warns hwdec toggling once caused a re-trigger loop.
- The `--idle` startup test showed 0 errors; the `[e]` lines you will see with native hwdec are just cropdetect failing on GPU frames (expected).

## User preferences observed

Wants eye-candy, modern UI (ModernZ). Content: mostly 1080p/1440p YouTube, Twitch, anime; occasional 4K HDR remux. Declined to produce mpv logs; prefers the agent to reproduce locally. Approves downloads case by case. Terse reports, file:line, pass/fail.
