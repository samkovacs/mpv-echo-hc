# Anime comes from a user-configured torrent index streamed in-process by webtorrent-mpv-hook, and the repo names no index

`browse.lua` gets a third source, Torrents. The user pastes two RSS URLs into `browse.conf`: a search feed with a `{query}` placeholder and a newest-releases feed. The repo ships no index URL, no site name and no site-specific query grammar, so nothing in it points at any particular torrent site; with both keys empty the Torrents submenu is absent. The RSS parser reads seeders, size, info hash and trusted flag by local element name regardless of XML namespace, and falls back to a magnet link in `<link>` or `<enclosure>`, so it works across indexes without a per-site adapter. Playback goes through the vendored `webtorrent-mpv-hook` (a symlink in `scripts/`, node on PATH, bun-installed under `webtorrent/`) in `path=memory` mode, so nothing is written to disk and the mental model stays "watch like YouTube". Show cover art for the grid comes from AniList's public GraphQL API, one lookup per parsed show name, cached like the YouTube thumbnails.

## Considered options

- **Licensed streamers through yt-dlp** (Crunchyroll, HiDive): paid login plus DRM on nearly every stream, which yt-dlp cannot decrypt. Dead on arrival.
- **Hand magnets to an external torrent client** and play the file from disk: two apps, a download wait, files to clean up. Loses the browse-then-play flow the other two sources have.
- **A built-in default index**: simpler for the user, but ties the repo to a site. Left to the user's config on purpose.
- **Episode screenshots from animepahe or fancaps**: both Cloudflare-fronted, 403 to plain requests, scraping that breaks on every site change. Cover art per show from a documented API covers the grid well enough.
- **Follow list**: no account exists here, so followed shows are a hand-maintained list in `browse.conf`, the same shape as the Twitch channel list in ADR 0008.

## Consequences

- Release titles are parsed into show, episode and resolution with Lua patterns tuned to fansub naming. Titles that do not parse sort to the bottom in an unparsed group and get no cover.
- Fields the index's feed lacks degrade gracefully: no seeders means no seeder sort or floor, no trusted flag means no marker.
- The hook allows one torrent per mpv process. Picking a second release in the same session needs a fix to the hook, kept as a `bun patch` under `webtorrent/`, not a fork repo.
- The `scripts/webtorrent.js` symlink has an absolute path, so the install is not relocatable. Known, out of scope here, tracked as its own issue.
- Node is an external runtime dependency alongside yt-dlp, ffmpeg and curl.
