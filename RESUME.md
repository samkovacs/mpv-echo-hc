# RESUME — handoff for a fresh agent

Repo: `C:\Users\pseud\Desktop\MPV-Nvidia-VSR-main` (portable mpv install, Windows 11). Branch `main`, all work committed. Working tree clean except the untracked `MPV-Nvidia-VSR-main.code-workspace`.

Read `CLAUDE.md` rules first: no AI attribution in commits, never push, `uv`/`bun` only, plan before non-trivial work, verify before claiming.

## Machine

- EVGA RTX 3080 Ti 12 GB, i9-12900K, 64 GB. NVIDIA driver 610.88 (616.56 available, update deferred until testing is done).
- Displays: 3440x1440 @ 240 Hz primary, Windows HDR on, measured peak 603 nits, black 0; 2560x1440 @ 144 Hz; 1920x1080. mpv fullscreens on the primary.
- NVIDIA app: RTX Video Super Resolution on (quality 4), RTX Video HDR on, inverse telecine on. Leave them.
- mpv v0.41.0-923-g7b8915bc1 (shinchiro daily 2026-08-14), libplacebo v7.371. `vo=gpu-next`, `gpu-api=d3d11`, `hwdec=d3d11va-copy`. yt-dlp 2026.08.19 (latest). ffmpeg.exe in repo root is a static build whose https cannot verify TLS certificates; Windows' builtin `curl` (schannel) can.
- Browser: **Zen** (Firefox-based), profile `%APPDATA%\zen\Profiles\114ufcyv.Default (twilight)` holds the Twitch/YouTube logins; the `alpha` profile does not. Chrome exists but is not logged into anything relevant; Chrome cookie DBs are not extractable by yt-dlp on Windows anyway (App-Bound Encryption).

## What was done 2026-09-01 (commits 94e923b..1ad835d)

1. **Fullscreen freeze bugs**: removed `d3d11-exclusive-fs=yes` from mpv.conf. Right-click menu freeze **confirmed fixed by the user**. Intermittent fullscreen lockup: same root cause, **not yet confirmed** by a long session.
2. **4K HDR stutter** (reported after #1): `video-sync=display-resample` -> `audio`. Measured: every display-sync mode dropped 6-11 frames per 9 s on a 2160p10 PQ clip at 240 Hz; audio sync dropped 0. User has **not yet reported back** on the real file (A Clockwork Orange 2160p HDR remux).
3. **Removed**: uosc, inputevent.lua, playlistmanager, memo (builtin `save-watch-history=yes` replaces it), webtorrent.conf + profile, nlmeans shader. ModernZ is the sole OSC; native `menu.conf` right-click menu; builtin select.lua for lists.
4. **Shaders vs VSR**: `vsr_autocrop.lua` now skips `@vsr` when `glsl-shaders` is set (they cannot stack: d3d11vpp scales first, every shader is gated on OUTPUT > LUMA). Anime auto-profile `[WEB-DL]` in mpv.conf uses `ArtCNN_C4F16_DS.glsl`. Manual profiles `[ArtCNN]`, `[ArtCNN-DS]` replace `[Ani4k]`/`[AniSD]`.
5. **ArtCNN C4F32 and the `_CMP` compute builds do not work on d3d11** (14 cbuffer limit / 32 KB group shared memory). Files deleted. Only C4F16 variants compile. Do not re-add C4F32 unless `gpu-api=vulkan`.
6. **HDR**: `nvidia_true_hdr=no` in vsr_autocrop.conf. `inverse-tone-mapping=yes` in mpv.conf; `hdr-mode.lua` `apply_hdr_settings(inverse)` points SDR sources at the per-display peak when the display is in HDR mode (pass mode). Verified `spline tone map (480 -> 603)` in vo-passes.
7. `deband=yes` globally. `watch-later-options-remove` now also covers `af`, `deinterlace`. `priority=high`, `force-seekable=yes` removed. `4k-Downscaling` profile-cond nil-guarded. modernz `tick_delay_follow_display_fps=yes`.
8. Backups of every touched file: `backup_2026-09-01/` (gitignored).
9. Research notes with sources: `doc/research-rtx-vsr-vs-shaders.md` (has a measured addendum), `doc/research-osc-modernz-vs-uosc.md`.

## What was done 2026-09-02 (commits 9d046d6..5e5c7d4)

### Twitch 1440p / login cookies (mpv.conf)

- **Root cause**: Twitch serves the 1440p60 "Source" rendition (HEVC, `hev1.1.6.L150`, ~9.8 Mbit/s) only to logged-in accounts. Anonymous yt-dlp tops out at 1080p60 H.264 regardless of format string; yt-dlp already sends `supported_codecs=av1,h265,h264`. Twitch's own player, logged out, greys the option out with "You're logged out! Sign up or log in to view higher resolutions."
- **Fix**: `ytdl-raw-options-append=cookies=C:\Users\pseud\Desktop\MPV-Nvidia-VSR-main\yt-dlp-cookies.txt` (mpv.conf ~line 75). The file is **gitignored** and holds 13 `.twitch.tv` + 24 `.youtube.com` cookies, Netscape format.
  - Twitch cookies: "site" export from a normal Zen window ("Get cookies.txt LOCALLY" extension). The `auth-token` cookie does not rotate. After a Twitch logout in Zen, playback silently drops back to 1080p; re-export twitch.tv site cookies and merge them in.
  - YouTube cookies: **must not** come from the live browser jar. YouTube rotates account cookies on open tabs; yt-dlp then reports "The provided YouTube account cookies are no longer valid" and feeds return empty (also: Zen's latest cookie values live in `cookies.sqlite-wal`, which yt-dlp does not read). Per the yt-dlp wiki they were exported from a private window sitting on youtube.com/robots.txt, then the window was closed. yt-dlp refreshes them itself by writing the jar back after every run.
  - `cookies-from-browser` was tried and **dropped**: it worked for Twitch but yt-dlp writes the whole merged jar back into the cookies file, dumping all ~2400 browser cookies into plain text. With file-only cookies the write-back stays youtube+twitch only (verified after runs).
- `ytdl-raw-options-append=mark-watched=` added; verified: a video played from mpv appeared at the top of the account's History feed.
- YouTube resolution is **not** login-gated (same 2160p60 VP9/AV1 formats anonymous vs logged in). No YouTube Premium on the account (no format 616).
- Verified: mpv probe on twitch.tv/theburntpeanut reports 2560x1440 HEVC.

### browse.lua (portable_config/scripts/browse.lua, script-opts/browse.conf)

In-mpv browsing UI, no new dependencies (yt-dlp, Windows curl, repo ffmpeg, mpv Lua only).

- **Bindings**: `browse/youtube-search` (Ctrl+y), `youtube-subscriptions`, `youtube-home`, `youtube-history`, `youtube-watch-later` (yt-dlp `ytsearch30:` / `:ytsubs` / `:ytrec` / `:ythistory` / `:ytwatchlater`, `--flat-playlist -J --playlist-end 30`); `browse/twitch-search` (Ctrl+t), `browse/twitch-live`. Menu: Open > YouTube, Open > Twitch in menu.conf. Cookies are read from mpv's own `ytdl-raw-options` (single source of truth); `mark-watched` is stripped for listings.
- **Twitch via GraphQL** (`gql.twitch.tv/gql`, Client-Id `kimne78kx3ncx6brgo4mv6wki5h1ko`, `Authorization: OAuth <auth-token>` read from the cookies file, sent with Windows `curl`). Working fields: `searchFor(userQuery, platform:"web")`, `users(logins:[...]) { stream { title viewersCount game previewImageURL } }`, `currentUser.followedGames`, `currentUser.followers`. **Dead for third parties**: `currentUser.follows`, `currentUser.followedLiveUsers`, `personalSections(FOLLOWED_SECTION)` (silently returns POPULAR_SECTION) all answer `"service error"`. Tried: raw query, browser UA + Origin/Referer, `/integrity` token, X-Device-Id, Android and yt-dlp client ids, Helix REST (404 for the web client id), scanning the web bundles for a persisted-query hash (APQ hashes are computed client-side at runtime, nothing to find). Do not retry. Fallback: `twitch_channels=` list in browse.conf (comma-separated logins; **space-separated** if passed via `--script-opts`, mpv splits that option on commas), checked with `users(logins:)`. The real follow list would need a Helix user token (scope `user:read:follows`) from a Twitch app the user registers; not pursued.
- **Rendering**: own `mp.create_osd_overlay("ass-events")`, because the builtin `mp.input.select` runs items through `ass_escape` and cannot color parts of a row. Canvas is set to `osd-width x osd-height` (window pixels) so ASS text and `overlay-add` bitmaps share coordinates; redraws on `osd-dimensions`. Two modes, `view=list|grid` in browse.conf, **Tab** toggles while open (cursor and filter preserved).
  - List: 18 rows, title / [channel] / (H:MM:SS) or LIVE, "… N more" footer.
  - Grid: 4x3 tiles per page, 16:9 thumbnails, tile size capped by width and height. Thumbnail = `curl -sSL --max-time 10` download (ffmpeg's own https fails TLS verify) then `ffmpeg -vf scale=…:force_original_aspect_ratio=decrease,pad=… -f rawvideo -pix_fmt bgra`, cached as `%TEMP%\mpv-browse-thumbs\<djb2(url)>_WxH.bgra`, drawn with `overlay-add <1..12> x y file 0 bgra w h stride`. A `gen` counter drops late fetches; bitmaps are only cleared when page/mode/size changes (no flicker on focus moves). YouTube thumbnails from yt-dlp `thumbnails[]` (smallest ≥ tile width), Twitch from `previewImageURL(width:640,height:360)`. Cache cleanup at script load: files older than `thumb_cache_days` (default 7) deleted.
  - Colors: Solarized Dark. Title base1, dim base01, channel blue, runtime yellow, LIVE red, focus green, filter-matched chars orange, backdrop/outline base03 at ~75% opacity. Constants at the top of the list section.
  - Keys while open: Up/Down (grid: row), Left/Right, PgUp/PgDn (grid: page), Home/End, wheel, Enter loads (`loadfile … replace`), Esc clears the filter first then closes, right-click closes, Tab toggles view. **Type to fuzzy-filter**: in-order character match on "title channel", tightest span first, Backspace edits. Key text must be accepted for any non-`up` event: synthesized `keypress` and some real keys arrive as a single `press` event (first version only took `down`/`repeat`; typed letters fell through to defaults and Backspace reset speed).
  - Mouse: `mouse-pos` observer focuses the hovered row/tile via a hit-test on the last-drawn layout (`list.hit`); forced `MBTN_LEFT` on a row/tile activates it. While a list is open ModernZ is not clickable.
- **Verified end to end** (screenshots + `path`/`media-title` after Enter): YouTube search, all four feeds, Twitch search, Twitch live list (with live channels), grid render, grid navigation, Tab round-trip, fuzzy filter + highlight, no-match/Esc behaviour, hover + click in both modes, cache cleanup, idle (window-less) start.

## Verification method that worked

Synthetic clips in the session scratchpad (gone after context clear; regenerate with ffmpeg.exe in repo root):
- 1080p60 H.264: `testsrc2=size=1920x1080:rate=60,noise=alls=8:allf=t`, libx264. Copy named `[SubsPlease] test - 01 (1080p).mp4` triggers the WEB-DL profile.
- 2160p10 PQ: libx265 `-preset veryfast -x265-params colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:no-open-gop=1:keyint=48:bframes=3` plus an aac sine track. Validate first with `--vo=null --hwdec=d3d11va-copy` and count `[e|w][ffmpeg` lines; a broken clip fakes drops.
- Probe Lua script (pass via `--script=`): after ~9 s print `frame-drop-count`, `vo-delayed-frame-count`, `mistimed-frame-count`, `vo-passes` (fresh, avg per desc), then `quit`. Run mpv with `--fs --volume=0 --no-resume-playback --save-position-on-quit=no --msg-level=all=v --log-file=...`. Always kill stray `mpv.exe` (`taskkill //F //IM mpv.exe //T`); `--idle` runs never exit because `keep-open=always`.
- Shader hook health: grep the log for `Failed executing hook` and `Too many constant buffers`; libplacebo silently disables a failing hook after frame one and `vo-passes` then shows no shader pass.
- **UI scripts (browse.lua)**: drive from a `--script=` Lua with `mp.commandv("script-binding", "browse/…")`, `mp.commandv("keypress", "g")` / `"TAB"` / `"ENTER"`, `mp.commandv("mouse", x, y)` (hover) and `mp.commandv("mouse", x, y, 0)` (left click), then `mp.commandv("screenshot-to-file", png, "window")` and print `path`/`media-title`. `screenshot-to-file … window` needs a playing video (a 1280x720 `testsrc2` clip via `--geometry=1280x720`); it does nothing in `--idle`. Read the PNG to check the render. Stream-resolution check: a probe that prints `video-params` w/h and `video-codec` after 15 s.
- **yt-dlp checks**: `yt-dlp.exe -F <url>` for format lists; `--write-pages` to dump the raw usher/GQL responses; `--cookies yt-dlp-cookies.txt -J --flat-playlist ":ytsubs"` for feed health (watch for the "cookies are no longer valid" warning). Never print cookie values; count domains with `awk '{print $1}' | sort | uniq -c`.

## Open items

- User to confirm: no fullscreen lockup over a full film; 4K remux stutter gone; autocrop lands on 2.39:1 content (retries at 4/20/65/185 s); HDR tone map looks right at 603 nits.
- Then: driver update to 616.56.
- Possible next lever if 4K performance comes up again: native `hwdec=d3d11va` after cropdetect (copy-back is only needed for cropdetect). Costs a mid-play decoder reinit; the script's header warns hwdec toggling once caused a re-trigger loop.
- The `--idle` startup test showed 0 errors; the `[e]` lines you will see with native hwdec are just cropdetect failing on GPU frames (expected).
- browse.lua: `twitch_channels` in browse.conf is seeded with only `theburntpeanut`; the user has not filled in their follows yet. Watch-later's first entry may be an unavailable video (yt-dlp hides it; Enter on it loads nothing).
- If Twitch playback drops to 1080p: re-export twitch.tv cookies (see above). If YouTube feeds come back empty: re-export YouTube cookies from a fresh private window.

## User preferences observed

Wants eye-candy, modern UI (ModernZ), Solarized Dark colors. Content: mostly 1080p/1440p YouTube, Twitch, anime; occasional 4K HDR remux. Uses the Zen browser. Declined to produce mpv logs; prefers the agent to reproduce locally. Approves downloads case by case; performs cookie exports and logins themselves when asked with exact steps. Wants features they ask for kept (asked why type-to-filter was dropped; prefers fuzzy over substring). Terse reports, file:line, pass/fail.
