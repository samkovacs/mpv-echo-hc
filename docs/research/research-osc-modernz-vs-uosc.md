# Research: ModernZ vs uosc as the OSC (mpv 0.41 daily, Windows 11)

Date: 2026-09-01. Local state: ModernZ v0.3.3 (`portable_config/scripts/modernz.lua:1`), uosc **5.10.0** (`scripts/uosc/main.lua:2`), mpv `v0.41.0-923-g7b8915bc1` (built 2026-08-14), `osc=no` + `osd-bar=no` + `border=yes` (`mpv.conf:109-111`), `load-select=yes` (`mpv.conf:8`), uosc `disable_elements=timeline,controls,volume,idle_indicator,audio_indicator,buffering_indicator,pause_indicator,window_border` (`script-opts/uosc.conf:255`), native `menu.conf` present.

## Question
Which OSC gives the best eye candy + UX for YouTube/Twitch/anime/4K HDR on a 3440x1440 244 Hz Windows desktop: ModernZ, uosc, or something else? Can ModernZ + "uosc menus only" coexist cleanly? What should be deleted?

## Feature matrix (documented facts; opinion is flagged)

| Feature | ModernZ v0.3.3 | uosc 5.13.0 |
|---|---|---|
| Menus: playlist / tracks / chapters / audio device | Yes, delegated to mpv builtin **select.lua** (`modernz.lua:225-282`: `script-binding select/select-playlist`, `select-sid`, `select-aid`, `select-chapter`, `select-audio-device`, `select/menu`). README: "Interactive menus for playlist, subtitles, chapters, audio tracks, and audio devices" ([README](https://github.com/Samillion/ModernZ#readme)). | Own menu engine: file browser, playlist, subtitle/audio/video tracks, chapters, stream quality, keybind palette, Open Subtitles download, external track loading ([README](https://github.com/tomasklaen/uosc#readme)). |
| Stream quality menu | No built-in; you wire `stream_quality_echostorm.lua`. | `script-binding uosc/stream-quality`, `stream_quality_options` ([README](https://github.com/tomasklaen/uosc#readme)). |
| File browser | No. #684 "adding in built file browser like UOSC" closed as already-implemented via select.lua/open-file ([#684](https://github.com/Samillion/ModernZ/issues/684)). | Yes ([README](https://github.com/tomasklaen/uosc#readme)). |
| Keyboard-navigable menus + type-to-search | Depends on select.lua (console-style). | Yes: `menu_type_to_search`, up/down/enter/tab/esc (`uosc/elements/Menu.lua:1197-1258`); README: "Keyboard-navigable menus with instant search". |
| Thumbnails | thumbfast; thumbnail box colour/outline/padding/radius options ([modernz.conf](https://github.com/Samillion/ModernZ/blob/main/modernz.conf)). | thumbfast ("Fast and efficient thumbnails", [README](https://github.com/tomasklaen/uosc#readme)). |
| Animations / hover | Fade in/out (`fadeduration`, `fadein`), button `hover_effect=size,glow,color,box` (`modernz.lua:171`). No blur (ASS cannot blur; neither can). | Proximity-based reveal, `animation_duration`, `flash_duration` (`uosc.conf`). No blur. |
| Chapter markers | `nibbles_style=gap/triangle/bar/single-bar` ([modernz.conf](https://github.com/Samillion/ModernZ/blob/main/modernz.conf)). | Markers plus **chapter ranges** ("Transforming chapters into timeline ranges", [README](https://github.com/tomasklaen/uosc#readme)). |
| Touch | Touch state tracked (`modernz.lua:583-599`). | Documented; observes `touch-pos` (`uosc/lib/cursor.lua:437`). |
| HiDPI | `vidscale`, `scalewindowed`, `scalefullscreen` only; zero `display-hidpi-scale` references in `modernz.lua`. | Observes `display-hidpi-scale` (`uosc/main.lua:731`), `scale`/`scale_fullscreen`. |
| Theming | 4 layouts (default/compact/mini/seekbar), 2 icon themes x 3 styles, 4 seekbar heights, full colour options, JSON locales ([README](https://github.com/Samillion/ModernZ#readme)). | Colours + font (`color=`, `font_scale`, `font_bold`, `border_radius`, per-element `opacity=`) ([uosc.conf](https://github.com/tomasklaen/uosc/blob/main/src/uosc.conf)). One icon set. |
| Idle screen | `idlescreen=yes` mpv logo ([modernz.conf](https://github.com/Samillion/ModernZ/blob/main/modernz.conf)). | `idle_indicator` element ([uosc.conf](https://github.com/tomasklaen/uosc/blob/main/src/uosc.conf)). |
| Window controls / title bar in borderless | `window_controls=yes`, `window_top_bar=auto`; README suggests `title-bar=no` ([README](https://github.com/Samillion/ModernZ#readme)). | `top_bar=never/no-border/always`, `top_bar_controls`, own border via `window_border_size` with `border=no` ([uosc.conf](https://github.com/tomasklaen/uosc/blob/main/src/uosc.conf)). |
| Render loop | Tick throttled: `tick_delay=1/60` minimum, optional `tick_delay_follow_display_fps` (`modernz.lua:204-205, 4122-4128`). | Event driven: `request_render()` arms a one-shot timer throttled to `render_delay` (1/60, follows `display-fps`/`estimated-display-fps`) (`uosc/lib/utils.lua:1004-1010`, `main.lua:609-617, 786-787`). No free-running loop. |
| mpv version | Not documented; select.lua delegation implies 0.40+ ([#368](https://github.com/Samillion/ModernZ/issues/368) closed already-implemented). | "MPV 0.33 or higher" ([README](https://github.com/tomasklaen/uosc#readme)). |
| Windows quirks | None documented. | #1200 "Video corners occasionally render outside window bounds on Windows 11 when using osc=no and title-bar=no" (closed Jan 2026, [issue search](https://github.com/tomasklaen/uosc/issues?q=is%3Aissue+select.lua+OR+context_menu+OR+%22osc%3Dno%22+OR+menu.conf)). README: if sluggish, `video-sync=display-resample`. |

Opinion: both redraw at 60 Hz by default; on 244 Hz set `tick_delay_follow_display_fps=yes` (ModernZ) if you want a smoother seekbar. Neither is a perf concern.

## Maintenance (GitHub API, 2026-09-01)

| | ModernZ | uosc |
|---|---|---|
| Repo | [Samillion/ModernZ](https://github.com/Samillion/ModernZ) | [tomasklaen/uosc](https://github.com/tomasklaen/uosc) |
| Last push | 2026-06-04 | 2026-08-30 |
| Latest release | v0.3.3, 2026-05-20 ([releases](https://github.com/Samillion/ModernZ/releases)) | 5.13.0, 2026-08-03 ([releases](https://github.com/tomasklaen/uosc/releases)) |
| Cadence (last 12 mo) | v0.2.9..v0.3.3: 5 releases, monthly Jan-May 2026, none since | 5.12.0 (2025-09), 5.13.0 (2026-08): 2 releases |
| Open issues | 25 | 34 |
| Stars / forks | 1,203 / 48 | 3,358 / 112 |
| Contributors | 16 (Samillion 1,527 commits; next 130) | 38 (tomasklaen 574, darsain 217, christoph-heinrich 200, dyphire 32) |
| License | LGPL-2.1 | LGPL-2.1 |
| mpv 0.40/0.41 breakage | None found ([search](https://github.com/Samillion/ModernZ/issues?q=is%3Aissue+0.41+OR+0.40+OR+context_menu+OR+select.lua) returns only closed items). | #1211 (Mar 2026): uosc mouse handling broke mpv OSD `context_menu.lua`/`input.lua` menus near window edges, "absent in mpv's official OSC or ModernZ" ([#1211](https://github.com/tomasklaen/uosc/issues/1211)). Fixed by PR #1214 (merged 2026-04-18), shipped in **5.13.0**: "Disable uosc's cursor handling when any mpv UI's are open" ([5.13.0](https://github.com/tomasklaen/uosc/releases/tag/5.13.0)). Your 5.10.0 predates the fix. |

Both healthy. ModernZ is one maintainer (bus factor 1); uosc has more contributors but slower releases.

## Coexistence: what uosc does with your `disable_elements`

From the installed `scripts/uosc/` (5.10.0), checked against `main`:

- `mp.set_property('osc','no')` unconditionally on load (`uosc/main.lua:6`). Harmless, already set.
- `disable_elements` runs `Manager:disable('user', ...)` which destroys / never constructs those elements (`main.lua:1176-1199`). Managed IDs: `window_border, buffering_indicator, pause_indicator, top_bar, timeline, controls, volume, idle_indicator, audio_indicator` ([uosc.conf](https://github.com/tomasklaen/uosc/blob/main/src/uosc.conf)). **`top_bar` is missing from your list**; the TopBar element still exists (dormant because `top_bar=no-border` and you run `border=yes`).
- Not disable-able: `Curtain` (`main.lua:1160`), `Menu`, `Updater`, the cursor module.
- Render loop: no free-running timer. `request_render()` schedules one throttled `render()` (`lib/utils.lua:1006-1010`); still fires on `playback-time`, `pause`, `osd-dimensions` etc. (`main.lua:727, 786-787`). With everything disabled it is a cheap no-op per event.
- Mouse: `cursor.lua` always observes `mouse-pos` and `touch-pos` (`lib/cursor.lua:436-437`) and always registers **forced** groups for `mbtn_left` (all modifier combos), `mbtn_left_dbl` (ignore), `mbtn_right`, `wheel_up/down` (`cursor.lua:453-460`). But `cursor:decide_keybinds()` only enables a group when a handler or hit zone exists (`cursor.lua:229-237`, level 0 when `#handlers == 0`). With elements disabled and no menu open the groups sit at level 0, so ModernZ's own forced `mbtn_left/mbtn_right/wheel` bindings (`modernz.lua:4233-4253`) win. When a uosc menu is open uosc takes the mouse. Works, but by accident of design.
- Official "menu-only" mode: **none documented**. Nearest primary source is #592 "Using uosc with other UIs" where po5 shows the same recipe (`controls=never`, `top_bar=never`, timeline size 0, border 0) and notes the buffering indicator could not be disabled then ([#592](https://github.com/tomasklaen/uosc/issues/592), 2023); `disable_elements` now covers it. #1078 "An option to override select.lua" (closed Mar 2025) asked uosc to replace select.lua; no such option exists ([#1078](https://github.com/tomasklaen/uosc/issues/1078)).
- Context menu on Windows: native Win32 menu support merged in mpv PR #13700 (2024-04-06, [PR](https://github.com/mpv-player/mpv/pull/13700)); `context_menu.lua` (ASS menu for other platforms) merged 2025-09-15 ([PR #16726](https://github.com/mpv-player/mpv/pull/16726)); `menu.conf` population via select.lua merged 2026-01-25 ([PR #16816](https://github.com/mpv-player/mpv/pull/16816)). None are in 0.41.0 stable; they are in your Aug-2026 daily ([discussion #17220](https://github.com/mpv-player/mpv/discussions/17220)). On platforms with native integration `context_menu.lua` is disabled by default ([context_menu.rst](https://github.com/mpv-player/mpv/blob/master/DOCS/man/context_menu.rst)), so your right-click menu is native Win32 and #1211 does not affect it; it only affected the ASS select.lua lists, which are exactly what ModernZ buttons open. Update uosc to 5.13.0 if you keep it.

## Other candidates (2025-2026 activity)

| Project | Last push | Verdict |
|---|---|---|
| [zydezu/ModernX](https://github.com/zydezu/ModernX) | 2026-08-11, 4 open issues, 292 stars | Alive. ModernX fork: SponsorBlock bar, yt metadata, PiP. Screenshot: [preview.png](https://raw.githubusercontent.com/zydezu/ModernX/refs/heads/main/preview.png). Smaller than ModernZ, same select.lua-style menus. |
| [cyl0/ModernX](https://github.com/cyl0/ModernX) | 2026-02-04, 20 open issues | Low activity; ModernZ is its superset. Skip. |
| [maoiscat/mpv-osc-modern](https://github.com/maoiscat/mpv-osc-modern) | 2024-04-20 | Dead. |
| [Zren/mpv-osc-tethys](https://github.com/Zren/mpv-osc-tethys) | 2024-04-30 | Dead. |
| [tsl0922/mpv-menu-plugin](https://github.com/tsl0922/mpv-menu-plugin) | 2025-01-15 | Stale; author upstreamed native Win32 menus (PR #13700). Superseded by `menu.conf`. |
| [dyphire/mpv-config](https://github.com/dyphire/mpv-config) | 2026-08-26, 1,863 stars | Alive. Full Windows config built on uosc (dyphire is a uosc contributor). Reference for uosc menu wiring, not a separate OSC. |
| ModernZ extras ([README](https://github.com/Samillion/ModernZ#readme)) | - | Open-File, Pause-Indicator-Lite, PiP-Lite, ytdlAutoFormat, BoxtoWide. You already run pause_indicator_lite and ytdlautoformat. |

## Screenshots (official)
- ModernZ main preview: https://github.com/user-attachments/assets/69a967ae-cf8a-4a92-9193-4799f901cd94 ; the other 24 images live in README sections "Layouts", "Themes", "Icon Styles", "Seek Bar", "Chapter Markers", "Colors" ([README](https://github.com/Samillion/ModernZ#readme)).
- uosc single preview: https://github.com/tomasklaen/uosc/assets/47283320/9f99f2ae-3b65-4935-8af3-8b80c605f022 ([README](https://github.com/tomasklaen/uosc#readme)).
- zydezu/ModernX: https://raw.githubusercontent.com/zydezu/ModernX/refs/heads/main/preview.png

I did not view these images; no aesthetic judgement is made here.

## Recommendation (opinion, grounded above)

Keep **ModernZ** as the single OSC. It is the only one of the two with layouts, icon themes, hover effects and chapter-nibble styles as first-class options; it ships monthly; and it is mpv-0.40-native (lists via select.lua, no OSD-menu conflict per #1211).

Menus: your daily build already gives you the native Win32 right-click menu via `menu.conf` plus select.lua lists (playlist, tracks, chapters, history, watch-later, speed). uosc's remaining unique features are the ASS file browser and stream-quality menu; you replaced the latter with `stream_quality_echostorm.lua` and open files via Win32 dialogs (`open_file_echostorm`). uosc is doing nothing you cannot get natively.

Delete: `scripts/uosc/`, `script-opts/uosc.conf`, and any `script-binding uosc/...` in `menu.conf` / `input.conf` (grep first). That removes a second forced mouse-binding layer, a second `mouse-pos` observer and a second render scheduler. If you keep uosc anyway: upgrade to 5.13.0 (fixes #1211) and add `top_bar` to `disable_elements`.

Keep: thumbfast (both OSCs use it), pause_indicator_lite, memo. playlistmanager is optional now that `$playlist` in menu.conf and `select-playlist` exist. Consider `tick_delay_follow_display_fps=yes` in `modernz.conf` for the 244 Hz panel.

Not checked: side-by-side visual comparison, in-app behaviour, and whether ModernZ `showonselect` interacts with the native menu (no issue found either way).
