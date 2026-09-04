# Testing recipes

How changes to this config get verified without a human watching a screen. Everything here runs from the repo root with the bundled `mpv.exe`, `ffmpeg.exe` and `yt-dlp.exe`. Commands are Git Bash unless marked PowerShell.

## Ground rules

- **Kill stray players after every run:** `taskkill //F //IM mpv.exe //T`. `keep-open=always` in `mpv.conf` means an `--idle` or ended run never exits on its own.
- **Always pass** `--no-resume-playback --save-position-on-quit=no` so test runs do not write `watch_later/` entries, and `--volume=0`.
- **Read logs, not eyes.** `--msg-level=all=v --log-file=<path>` and grep. The signals that matter are listed per section.
- **Never print cookie values.** To check the cookie jar, count domains only:
  `awk -F'\t' 'NF>=7{print $1}' yt-dlp-cookies.txt | sort | uniq -c`

## Synthetic clips

Real files are not in the repo. Generate what a test needs into the scratch directory and delete it afterwards.

**1080p60 H.264, SDR.** Triggers nothing special. A copy named `[SubsPlease] test - 01 (1080p).mp4` triggers the anime WEB-DL profile (ArtCNN, no VSR).

```sh
./ffmpeg.exe -y -f lavfi -i "testsrc2=size=1920x1080:rate=60,noise=alls=8:allf=t" \
  -t 20 -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p sdr1080p60.mp4
```

**2160p10 PQ HDR.** Exercises the HDR passthrough path, 10-bit hwdec and the 240 Hz frame-drop case.

```sh
./ffmpeg.exe -y -f lavfi -i "testsrc2=size=3840x2160:rate=24" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 20 \
  -c:v libx265 -preset veryfast -pix_fmt yuv420p10le \
  -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1:no-open-gop=1:keyint=48:bframes=3" \
  -c:a aac -shortest hdr2160p.mp4
```

Validate the HDR clip before trusting any result from it. A broken clip fakes frame drops:

```sh
./mpv.exe --vo=null --ao=null --hwdec=d3d11va-copy --msg-level=all=v --log-file=validate.log hdr2160p.mp4
grep -c -E "^\[[0-9. ]+\]\[(e|w)\]\[ffmpeg" validate.log   # expect 0
```

**Pretty demo clip for screenshots** (muted gradient, no test pattern):

```sh
./ffmpeg.exe -y -f lavfi -i "gradients=s=1920x1080:r=60:d=60:speed=0.015:nb_colors=4:c0=0x07131c:c1=0x12324a:c2=0x2a2540:c3=0x0d3b3f" \
  -f lavfi -i "sine=frequency=220:sample_rate=48000:d=60" \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -c:a aac -shortest "Demo Clip (1080p).mp4"
```

## Frame-drop probe (video-sync, 240 Hz, 4K HDR)

Drives mpv for ~9 s fullscreen and prints the counters. Save as `probe.lua`:

```lua
mp.register_event("file-loaded", function()
    mp.add_timeout(9, function()
        for _, p in ipairs({"frame-drop-count", "vo-delayed-frame-count"}) do
            print(p .. "=" .. tostring(mp.get_property(p)))
        end
        local passes = mp.get_property_native("vo-passes") or {}
        for _, pass in ipairs(passes.fresh or {}) do
            print(string.format("pass %-40s avg=%d", pass.desc, pass.avg or 0))
        end
        mp.command("quit")
    end)
end)
```

```sh
./mpv.exe --fs --volume=0 --no-resume-playback --save-position-on-quit=no \
  --msg-level=all=v --log-file=probe.log --script=probe.lua hdr2160p.mp4
grep -E "frame-drop-count|vo-delayed|\[probe\] pass" probe.log
```

`mistimed-frame-count` is `nil` on the current build; do not rely on it.

Compare `video-sync` modes by adding `--video-sync=display-resample` etc. On the reference machine (3080 Ti, 3440x1440 @ 240 Hz, HDR on) every `display-*` mode dropped 6–11 frames in 9 s on the 2160p10 clip; `audio` dropped 0 (ADR-0001). Re-run after driver or mpv updates.

## Shader hook health

libplacebo disables a failing shader hook after frame one and keeps playing. Playback looking fine proves nothing.

```sh
./mpv.exe --fs --volume=0 --no-resume-playback --save-position-on-quit=no \
  --glsl-shaders="~~/shaders/ArtCNN_C4F16_DS.glsl" \
  --msg-level=all=v --log-file=shader.log --script=probe.lua sdr1080p60.mp4
grep -E "Failed executing hook|Too many constant buffers" shader.log   # expect nothing
grep -E "\[probe\] pass" shader.log | grep -i "artcnn"                 # expect one pass per stage
```

Passes are named after the shader's `//!DESC` line, e.g. `ArtCNN C4F16 DS (Conv2D-1-ReLU)`, not "hook" or "user shader". Verified 2026-09-03: eight ArtCNN passes fullscreen on the 3440x1440 display, none in a 1280x720 window.

If the first grep hits, the shader does not fit d3d11 (ADR-0003). If the second is empty with no error, the shader was never eligible: every upscaler here is gated on `OUTPUT > LUMA`, so the window must be **larger than the source**. A 1080p clip in a 1280x720 window shows only `downscaling` passes and no hook, which is correct behaviour, not a failure. Use `--fs` on a display above 1080p, or a 720p source.

## VSR / autocrop

`vsr_autocrop.lua` logs its decisions at `info`. Look for the crop rectangle and the `@vsr` filter being added or skipped:

```sh
./mpv.exe --fs --volume=0 --no-resume-playback --save-position-on-quit=no \
  --msg-level=all=v --log-file=vsr.log --script=probe.lua sdr1080p60.mp4
grep -i -E "vsr_autocrop|d3d11vpp|video-crop" vsr.log | head -40
```

With a shader profile active the script must log that VSR is skipped (ADR-0002). Crop detection retries at 4 / 20 / 65 / 185 s, so a 2.39:1 test needs a clip with real black bars (`pad=` in ffmpeg) and at least 25 s of playback.

## HDR target

In `pass` mode with the display in HDR, `hdr-mode.lua` sets the target peak to the measured display peak. The proof is a tone-map pass in `vo-passes` naming the source and target nits:

```sh
grep -E "tone map|\(4[0-9]{2} -> [0-9]+\)" probe.log
```

Reference: `spline tone map (480 -> 603)` on the primary display (ADR-0006).

## UI scripts (browse.lua, ModernZ, menu)

Drive the UI from a `--script=` Lua rather than by hand. Relevant commands:

| Action | Command |
|---|---|
| Invoke a binding | `mp.commandv("script-binding", "browse/youtube-search")` |
| Type a key | `mp.commandv("keypress", "g")`, `"TAB"`, `"ENTER"`, `"ESC"`, `"SPACE"` |
| Hover | `mp.commandv("mouse", x, y)` |
| Left click | `mp.commandv("mouse", x, y, 0)` |
| Window screenshot | `mp.commandv("screenshot-to-file", "out.png", "window")` |
| What loaded | `print(mp.get_property("path"), mp.get_property("media-title"))` |

Gotchas learned the hard way:

- **Pace typed text.** Consecutive `keypress` calls in one tick lose letters that have bindings in `input.conf` (`a`, `i`, ...). Space them ~80 ms apart with `mp.add_timeout`.
- **`screenshot-to-file ... window` needs a playing video.** It does nothing in `--idle`. Use the demo clip with `--geometry=1280x720`.
- **On an HDR display, mpv's screenshots are PQ-encoded** and look washed out in any SDR viewer. For README images use a GDI screen grab of the client area instead (PowerShell `System.Drawing` `CopyFromScreen` with `GetClientRect` + `ClientToScreen`; call `SetProcessDPIAware` first). The native right-click menu is a Win32 popup and only shows up in a screen grab anyway.
- **Real mouse position matters** for the right-click menu (it opens at the OS cursor, not mpv's `mouse` position) and for ModernZ staying visible. Park the real cursor off the window before browser shots.
- **Thumbnail grid needs ~10 s** after `Tab` for downloads on a cold cache.
- Stream-resolution check for a loaded network file: a probe that prints `video-params/w`, `video-params/h` and `video-codec` after 15 s.

## yt-dlp and cookies

```sh
# formats a site offers with the current cookies (Twitch should show 2560x1440 hev1)
./yt-dlp.exe --cookies yt-dlp-cookies.txt -F https://twitch.tv/<channel>

# feed health; the warning "cookies are no longer valid" means re-export YouTube cookies (README, Installation step 3)
./yt-dlp.exe --cookies yt-dlp-cookies.txt -J --flat-playlist --playlist-end 5 ":ytsubs" | head -c 400

# raw usher / GraphQL responses when an extractor misbehaves
./yt-dlp.exe --cookies yt-dlp-cookies.txt --write-pages -J <url>

# what mpv actually passes to yt-dlp (confirms the cookies path resolved)
./mpv.exe --idle=once --vo=null --ao=null --frames=0 --no-resume-playback --save-position-on-quit=no \
  --msg-level=ytdl_hook=debug "ytdl://ytsearch1:test" 2>&1 | grep -o -E "\-\-cookies, [^,]+"
```

The last command is the regression test for ADR-0007's `~~home/../` expansion: run it from a directory that is **not** the repo root and expect an absolute path.

## Twitch GraphQL by hand

`browse.lua` uses Windows' built-in `curl` (the bundled ffmpeg's https cannot verify TLS; `curl` uses schannel). To poke the endpoint directly, pull the token without printing it:

```sh
TOKEN=$(awk -F'\t' '$1 ~ /twitch\.tv$/ && $6=="auth-token"{print $7}' yt-dlp-cookies.txt)
curl -s https://gql.twitch.tv/gql -H "Client-Id: kimne78kx3ncx6brgo4mv6wki5h1ko" -H "Authorization: OAuth $TOKEN" \
  -d '{"query":"{ users(logins:[\"theburntpeanut\"]) { login stream { title viewersCount } } }"}'
```

Anything under `currentUser.follows*` will return `"service error"`; see ADR-0008 before trying again.
