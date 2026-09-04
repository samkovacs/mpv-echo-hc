# One hand-exported cookies.txt for yt-dlp, never cookies-from-browser

Twitch serves its 1440p60 "Source" rendition only to logged-in accounts, and the YouTube account feeds (subscriptions, history, watch later) need a login too, so yt-dlp needs cookies. Two ways to supply them were tried on 2026-09-02.

`--cookies-from-browser` worked for Twitch but yt-dlp writes the *entire merged jar* back to the cookies file after every run, dumping roughly 2400 browser cookies for every site into a plain-text file next to `mpv.exe`. Rejected. A hand-exported `yt-dlp-cookies.txt` holding only twitch.tv and youtube.com cookies keeps the write-back to those two domains (verified after runs). It is gitignored and referenced from `mpv.conf` as `~~home/../yt-dlp-cookies.txt`.

Two constraints on how the file is produced, both learned the hard way:

- **YouTube cookies must come from a private window that is then closed**, opened on `youtube.com/robots.txt`. YouTube rotates account cookies on open tabs; cookies lifted from the live session are rejected within minutes ("The provided YouTube account cookies are no longer valid") and feeds return empty. Firefox-family browsers also keep the freshest values in `cookies.sqlite-wal`, which yt-dlp does not read.
- **Twitch cookies come from a normal window.** The `auth-token` cookie does not rotate, but dies when you log out of Twitch in the browser; playback then silently drops to 1080p.

## Consequences

- `browse.lua` reads the Twitch `auth-token` from the same file, so there is one source of truth for login state (`ytdl-raw-options`).
- Chrome cookies are not an option on Windows regardless: App-Bound Encryption prevents yt-dlp from decrypting them.
- YouTube resolution is not login-gated (same 2160p60 formats anonymous and logged in), so the cookies buy feeds and mark-watched on YouTube, and resolution only on Twitch.
