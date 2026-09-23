# Torrent rows: resolved S##E## numbering

Date: 2026-09-22. Status: approved design, not implemented.

## Goal

Every torrent row, in list and grid, shows the release's episode in TVDB
numbering (the one Sonarr / Plex / Jellyfin use) as `S##E##`, including
when the filename does not say it:

| Release title | Row tag |
|---|---|
| `[SubsPlease] Sousou no Frieren - 29 (1080p)` | `S02E01` |
| `[SubsPlease] Mushoku Tensei S2 - 13 (1080p)` | `S02E13` |
| `[Erai-raws] Mushoku Tensei - ... Part 2 - 01 [1080p]` | `S01E12` |
| `[SubsPlease] Show Name (01-12) (1080p)` | `S01E01-E12` |

A split season's second part continues its season's numbering: part 1 of
13 episodes makes part 2 episode 13 `S01E26`.

A season is never guessed. Until it is known the row shows only what the
filename says (see Fallback).

## Data

Two public lists, fetched at runtime and refreshed weekly.

- **Fribb anime-lists**
  `https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json`
  (~7.5 MB, ~39k entries). Per entry: `mal_id`, `anilist_id`,
  `season.tvdb`, `episode_offset.tvdb` (absent means 0). Verified
  2026-09-22 for Mushoku Tensei: MAL 39535 S1+0, 45576 S1+11, 51179 S2+0,
  55888 S2+12, 59193 S3+0.
- **anime-relations** (erengy)
  `https://github.com/erengy/anime-relations/raw/master/anime-relations.txt`.
  Maps fansub numbering that runs on across seasons, by MAL id:
  Frieren 52991 ep 29-38 -> 59978 ep 1; Mushoku 51179 ep 13-24 -> 55888 ep 1.

Both are cached in `%TEMP%\mpv-browse-thumbs\` as slimmed JSON:

- `seasons.json`: `{[mal_id] = {s = tvdb_season, o = tvdb_offset}}`
- `relations.json`: `{[mal_id] = {{a, b, x, z}, ...}}` (rule applies to
  episodes a..b, b nil = open-ended; output episode = ep - (a - x) of MAL
  id z), the shape autochapters uses.

When a torrent view opens, each file missing or older than 7 days is
re-fetched with async `curl`, slimmed once, and written. The view does not
wait; rows update when data lands. A failed fetch keeps the old file and
logs a warning. The thumbnail cleanup (files untouched for
thumb_cache_days) may delete them; the next torrent view fetches again.

autochapters is vendored upstream (po5/mpv-auto-chapters) and is not
modified. browse parses anime-relations itself: only the rule lines
(MAL ids and episode ranges, including `!` self-redirects), not the titles
autochapters derives.

## Resolution

One AniList request per show name per session, shared with the covers:
`Page(perPage:1){media(search:$s,type:ANIME){id idMal episodes coverImage{large}}}`,
searched with `cover_query(show)`. The on-disk cache stores the whole
answer under a new `meta_<hash>.txt` name (the old `cover_*.txt` files are
no longer read).

`resolve(mal_id, episode, relations, seasons)`:

1. If a relations rule of `mal_id` covers `episode`, move to its target
   MAL id and episode.
2. Look up the MAL id in `seasons`; return season `s` and episode
   `episode + o`.
3. No seasons entry, or no episode: nil.

Batch ranges resolve both ends; if they land in the same season the tag is
`S01E01-E12`, otherwise the fallback.

Safety check: when the filename states a season (`S2`, `2nd Season`,
`Season 2`) and the resolved season differs, keep the fallback and log
both. This catches a wrong AniList search hit.

## Fallback (filename only)

- season known: `S02E07`
- season unknown: `E29`
- part with unknown offset: `S01 P2 E13`
- batch: `S01E01-E12` / `E01-12`

Version and resolution follow either form: `S02E07v2  1080p`.

## Wiring (browse.lua)

- `ensure_cover` becomes `ensure_meta`, called from both views. On an
  answer it sets `e.thumbnail` as now and `e.sxe` (the resolved tag) on
  every entry of that show, then redraws the current view.
- `browse_torrents.display()` uses `e.sxe` when set, the fallback when not.
  Name shortening, tag visibility and the filter matching the row text are
  unchanged.
- `order()` keeps sorting by the filename's numbers; resolving does not
  reorder rows.

## Code layout

- `portable_config/scripts/browse_anime.lua` (new, pure Lua):
  `parse_relations(txt)`, `slim_seasons(list)`, `resolve(...)`.
- `browse_torrents.lua`: `display()` takes `e.sxe`; fallback format.
- `browse.lua`: fetch and refresh, `ensure_meta`, redraw.

## Testing

- `docs/tests/browse_anime_test.lua` (new, run by mpv like the torrents
  test), with real anime-relations and Fribb excerpts as fixtures:
  Frieren 29 -> S02E01, Mushoku S2 13 -> S02E13, Mushoku Part 2 01 ->
  S01E12, batch within one season and across two, the season-disagreement
  check, no entry -> nil, `!` self-redirect.
- `docs/tests/browse_torrents_test.lua`: `display()` with and without
  `e.sxe`, and each fallback form.
- End to end against the local fake feed, list and grid screenshotted:
  live lists (rows go from fallback to resolved), and the Fribb URL
  pointed at a dead address (fallback only, no Lua errors).
- `docs/testing.md` gains the new test command.

## Out of scope

- Roman-numeral seasons in names (`Mushoku Tensei II`) are not parsed;
  the lookup covers them.
- Sorting by resolved numbers.
- Non-anime releases: no AniList hit, fallback only.
