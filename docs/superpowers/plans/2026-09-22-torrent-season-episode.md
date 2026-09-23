# Torrent S##E## Numbering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every torrent row (list and grid) shows the release's episode in TVDB numbering as `S##E##`, resolved through AniList + Fribb anime-lists + anime-relations, with a filename-only fallback that never guesses a season.

**Architecture:** A new pure-Lua module `browse_anime.lua` parses the two public lists and resolves (MAL id, episode) to a TVDB season/episode. `browse_torrents.display()` prints `e.sxe` when set, else a filename-only tag. `browse.lua` fetches/refreshes the lists weekly into `%TEMP%\mpv-browse-thumbs\`, extends the existing per-show AniList cover lookup to also return `idMal`, and sets `e.sxe` on entries when both are in hand.

**Tech Stack:** mpv's LuaJIT (Lua 5.1, no utf8 lib), `mp.utils` (`parse_json`, `format_json`, `file_info`), Windows `curl`. Unit tests run under mpv itself.

**Spec:** `docs/superpowers/specs/2026-09-22-torrent-season-episode-design.md`

## Global Constraints

- Numbering authority: TVDB (Fribb `season.tvdb`, `episode_offset.tvdb`; absent offset = 0). Ignore every `tmdb` field.
- Format: `S%02dE%02d`, batch `S%02dE%02d-E%02d`.
- Fallback (filename only): season known `S02E07`; unknown `E29`; part with unknown offset `S01 P2 E13` (`P2 E13` without a season); batch `S01E01-E12` / `E01-12`; season only `S01`. Version follows the episode (`S02E07v2`); resolution follows as its own tag.
- Never show a season the filename or lists do not give. When the filename states a season and the lists disagree, show the fallback and `mp.msg.warn` both.
- Lists refresh when missing or older than 7 days (`7 * 86400` s); a failed fetch keeps the old file and warns.
- List URLs: `https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json` and `https://github.com/erengy/anime-relations/raw/master/anime-relations.txt`.
- Do not modify `portable_config/scripts/autochapters/` (vendored upstream).
- No try/except-style swallowing: failures log via `mp.msg.warn`/`error` and fall back visibly.
- Commits: author is the user; no AI attribution lines, no `Co-Authored-By`. Never push.
- Run tests with `./mpv.exe` from the repo root in Git Bash (commands below). A Lua error while a test script loads hangs mpv: always wrap runs in `timeout 20`.

## Review Focus

1. AniList hit with `idMal: null` (common for brand-new entries): row stays on the fallback, no Lua error. Pinned in Task 1 (`sxe(nil, ...)`).
2. Single-episode and episode-0 rules (`39535:24 -> 50360:1!`, `33820:0 -> ~:1`) must cover exactly that episode, not everything after it (autochapters treats `24` as open-ended). Pinned in Task 1.
3. A fetch that returns an HTML error page or truncated JSON must not replace a good cached list. Pinned in Task 1 (`parse_relations`/`slim_seasons` return nil + message) and Task 4 (callback keeps the old file).
4. `%TEMP%\mpv-browse-thumbs` missing while in list view (today only grid mode creates it): lookups and lists must still be written. Pinned in Task 4 e2e step (delete the directory, open in list view).
5. Tags resolving while the user has a filter typed: row text changes under `list.view`'s matched indices. Re-filter keeping the focused entry. Pinned in Task 3 (`refresh_view`) and checked in Task 4 e2e.

Deliberate cut from the spec: the meta cache stores `{url, mal}` only (the spec said "the whole answer"; `id` and `episodes` have no consumer). Rules whose source has no MAL id (13 of 545 on 2026-09-22) are skipped.

---

### Task 1: `browse_anime.lua`: parse the lists, resolve to S##E##

**Files:**
- Create: `portable_config/scripts/browse_anime.lua`
- Test: `docs/tests/browse_anime_test.lua`

**Interfaces:**
- Consumes: nothing.
- Produces (all pure, no mpv calls):
  - `parse_relations(txt) -> rules | nil, msg` where `rules = {[mal_id_string] = {{a=int, b=int|nil, x=int, z=int}, ...}}`; `b == nil` means open-ended.
  - `slim_seasons(list) -> seasons | nil, msg` where `list` is Fribb's decoded JSON array and `seasons = {[mal_id_string] = {s=int, o=int}}`.
  - `resolve(mal, ep, rules, seasons) -> season, episode | nil`
  - `sxe(mal, e, rules, seasons) -> "S02E13" | "S01E01-E12" | nil[, reason]`; `e` has the fields `browse_torrents.parse_title` produces: `episode` (int), `episodes` ("01-12"), `season` (int).

- [ ] **Step 1: Write the failing test**

Create `docs/tests/browse_anime_test.lua`:

```lua
-- Unit test for scripts/browse_anime.lua, run by mpv itself:
--   mpv --no-config --idle=once --script=docs/tests/browse_anime_test.lua
-- Prints PASS/FAIL per assertion and exits non-zero on any failure.
-- Fixtures are real lines / entries from anime-relations.txt and Fribb's
-- anime-list-full.json as of 2026-09-22.

local utils = require "mp.utils"
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../../portable_config/scripts/?.lua;" .. package.path
local A = require "browse_anime"

local failed = 0
local function check(name, cond, got)
    if cond then
        print("PASS " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. (got ~= nil and ("  got: " .. tostring(got)) or ""))
    end
end
local function eq(name, got, want) check(name, got == want, got) end

-- ------------------------------------------------------------ relations
local RELATIONS = table.concat({
    "# example in the header, not a rule:",
    "#   10001|10002|10003:14-26 -> 20001|20002|20003:1-13!",
    "::rules",
    "# Sousou no Frieren -> Sousou no Frieren 2nd Season",
    "- 52991|46474|154587:29-38 -> 59978|49240|182255:1-10!",
    "- 39535|42323|108465:12-23 -> 45576|43907|127720:1-12!\r",
    "- 39535|42323|108465:24 -> 50360|45492|141534:1!",
    "- 51179|45950|146065:13-24 -> 55888|47694|166873:1-12!",
    "- ?|7205|15061:51-101 -> ?|7972|20181:1-51",
    "- 33820|12478|21898:0 -> ~|~|~:1",
    "- 1000|?|?:19-? -> 2000|?|?:1-?!",
    "- 3000|?|?:14-26 -> 4000|?|?:1-13   ",
}, "\n")

local R = A.parse_relations(RELATIONS)
eq("frieren rule count", #R["52991"], 1)
local r = R["52991"][1]
eq("frieren a", r.a, 29); eq("frieren b", r.b, 38); eq("frieren x", r.x, 1); eq("frieren z", r.z, 59978)
eq("! adds the rule under the destination", R["59978"] and R["59978"][1].z, 59978)
eq("CR stripped, both 39535 rules parsed", #R["39535"], 2)
eq("single episode is not open-ended", R["39535"][2].b, 24)
eq("episode 0 rule", R["33820"][1].a, 0)
eq("~ repeats the source id", R["33820"][1].z, 33820)
eq("? end is open-ended", R["1000"][1].b, nil)
eq("trailing spaces do not drop a rule", R["3000"] and R["3000"][1].z, 4000)
eq("source without MAL id skipped", R["?"], nil)
eq("header example not a rule", R["10001"], nil)
local bad, msg = A.parse_relations("<!doctype html><html>rate limited</html>")
eq("html body is not a relations list", bad, nil)
check("html body message", type(msg) == "string", msg)

-- --------------------------------------------------------------- seasons
local FRIBB = utils.parse_json([[
[{"type":"TV","mal_id":39535,"anilist_id":108465,"season":{"tvdb":1,"tmdb":1}},
 {"type":"TV","mal_id":45576,"anilist_id":127720,"season":{"tvdb":1,"tmdb":1},"episode_offset":{"tvdb":11,"tmdb":11}},
 {"type":"TV","mal_id":51179,"anilist_id":146065,"season":{"tvdb":2,"tmdb":2}},
 {"type":"TV","mal_id":55888,"anilist_id":166873,"season":{"tvdb":2,"tmdb":2},"episode_offset":{"tvdb":12,"tmdb":12}},
 {"type":"TV","mal_id":52991,"anilist_id":154587,"season":{"tvdb":1,"tmdb":1}},
 {"type":"TV","mal_id":59978,"anilist_id":182255,"season":{"tvdb":2,"tmdb":1},"episode_offset":{"tmdb":28}},
 {"type":"SPECIAL","mal_id":50360,"anilist_id":141534},
 {"type":"TV","anilist_id":1,"season":{"tvdb":1}},
 {"type":"TV","mal_id":99999,"season":{"tmdb":3}},
 {"type":"TV","mal_id":88888,"season":{"tvdb":1},"episode_offset":null}]
]])
local S = A.slim_seasons(FRIBB)
eq("season", S["45576"].s, 1)
eq("tvdb offset", S["45576"].o, 11)
eq("no offset is 0", S["39535"].o, 0)
eq("tmdb offset ignored", S["59978"].o, 0)
eq("tmdb season ignored", S["59978"].s, 2)
eq("entry without season skipped", S["50360"], nil)
eq("entry with only tmdb season skipped", S["99999"], nil)
eq("null offset is 0", S["88888"].o, 0)
eq("not a list", (A.slim_seasons(nil)), nil)
eq("list without seasons", (A.slim_seasons({})), nil)

-- --------------------------------------------------------------- resolve
local function res(mal, ep) local s, e = A.resolve(mal, ep, R, S); return s and (s .. "/" .. e) end
eq("Frieren 29 is season 2 episode 1", res(52991, 29), "2/1")
eq("Frieren 28 stays season 1", res(52991, 28), "1/28")
eq("Mushoku II 13 is part 2 episode 1 = S2E13", res(51179, 13), "2/13")
eq("Mushoku II Part 2 episode 1 = S2E13", res(55888, 1), "2/13")
eq("Mushoku Part 2 episode 5 = S1E16", res(45576, 5), "1/16")
-- Part 2 has 12 episodes, so "Part 2 - 13" is continuous numbering (the
-- "!" rule 45576:12-23 -> 45576:1-12): part 2 episode 2 = S1E13
eq("Mushoku Part 2 continuous 13 = S1E13", res(45576, 13), "1/13")
eq("episode 24 goes to a special without a season", res(39535, 24), nil)
eq("episode 25 is not caught by the single-episode rule", res(39535, 25), "1/25")
eq("unknown id", res(12345, 1), nil)

-- ------------------------------------------------------------------- sxe
local function sxe(mal, e) return A.sxe(mal, e, R, S) end
eq("sxe Frieren 29", sxe(52991, {episode = 29}), "S02E01")
eq("sxe Mushoku S2 - 13", sxe(51179, {episode = 13, season = 2}), "S02E13")
eq("sxe Part 2 - 01", sxe(55888, {episode = 1, part = 2}), "S02E13")
eq("sxe batch within a season", sxe(52991, {episodes = "01-12"}), "S01E01-E12")
eq("sxe batch through a rule", sxe(39535, {episodes = "12-23"}), "S01E12-E23")
eq("sxe batch across seasons", sxe(52991, {episodes = "25-30"}), nil)
eq("sxe no MAL id (AniList idMal null)", sxe(nil, {episode = 3}), nil)
eq("sxe no episode", sxe(39535, {season = 1}), nil)
local none, why = sxe(51179, {episode = 7, season = 3})
eq("sxe filename season disagrees", none, nil)
check("sxe disagreement reason names both", why and why:find("3") and why:find("2"), why)

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
-- a quit issued while the script is still loading hangs mpv; defer it
mp.add_timeout(0.5, function() mp.command(failed == 0 and "quit 0" or "quit 1") end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_anime_test.lua 2>&1 | grep -E "FAIL|ALL PASS|Lua error"; echo exit=${PIPESTATUS[0]}`
Expected: `Lua error: ... module 'browse_anime' not found` (mpv then idles until `timeout` kills it; exit=124).

- [ ] **Step 3: Write the implementation**

Create `portable_config/scripts/browse_anime.lua`:

```lua
-- browse_anime.lua: pure Lua (no mpv dependency) behind browse.lua's S##E##
-- tags on torrent rows. Parses two public lists and resolves a MAL id +
-- fansub episode number to TVDB numbering (what Sonarr / Plex use):
--   Fribb anime-lists: TVDB season and episode offset per MAL id, so a
--     split season's part 2 continues its numbering (part 2 ep 1 of
--     Mushoku Tensei = S01E12).
--   erengy anime-relations: fansub numbering that runs on across seasons
--     (Frieren 29 = 2nd Season ep 1).
-- Unit test: docs/tests/browse_anime_test.lua (run by mpv).
--
-- mpv loads every scripts/*.lua as a script, so this file is also loaded
-- once on its own; it only defines functions, so that is harmless.

local M = {}

-- anime-relations.txt -> {[mal] = {{a, b, x, z}, ...}}: episodes a..b of
-- MAL id `mal` are episodes x.. of MAL id z; b nil = open-ended ("19-?").
-- A trailing "!" repeats the rule under z (fansubs numbering part 2 on
-- from part 1 while naming part 2). Only the MAL ids are read; rules whose
-- source has none ("?") are skipped. Same shape autochapters builds, but a
-- single episode ("24") covers only itself.
function M.parse_relations(txt)
    local rules, n = {}, 0
    for line in txt:gmatch("[^\n]+") do
        local src, a, b, dst, x, bang = line:gsub("\r$", ""):match(
            "^%- ([%d?]+)|[^:]*:(%d+)%-?([%d?]*) %-> ([%d?~]+)|[^:]*:(%d+)%-?[%d?]*(!?)")
        if src and src ~= "?" and dst ~= "?" then
            local z = dst == "~" and src or dst
            local rule = {a = tonumber(a), b = b == "" and tonumber(a) or tonumber(b), x = tonumber(x), z = tonumber(z)}
            rules[src] = rules[src] or {}
            table.insert(rules[src], rule)
            if bang == "!" then
                rules[z] = rules[z] or {}
                table.insert(rules[z], rule)
            end
            n = n + 1
        end
    end
    if n == 0 then return nil, "no anime-relations rules in the response" end
    return rules
end

-- Fribb anime-list-full.json (decoded) -> {[mal] = {s = tvdb season,
-- o = tvdb episode offset}}. Entries without a MAL id or a TVDB season
-- (specials, movies, unmapped) are left out; tmdb fields are ignored.
function M.slim_seasons(list)
    if type(list) ~= "table" then return nil, "Fribb anime list is not a JSON array" end
    local out, n = {}, 0
    for _, e in ipairs(list) do
        local s = e.mal_id and e.season and e.season.tvdb
        if s then
            out[tostring(e.mal_id)] = {s = s, o = e.episode_offset and e.episode_offset.tvdb or 0}
            n = n + 1
        end
    end
    if n == 0 then return nil, "no TVDB seasons in the Fribb anime list" end
    return out
end

-- MAL id + fansub episode -> TVDB season, episode (nil when the lists do
-- not know it). One relations hop, like autochapters.
function M.resolve(mal, ep, rules, seasons)
    local id = tostring(mal)
    for _, r in ipairs(rules[id] or {}) do
        if ep >= r.a and ep <= (r.b or math.huge) then
            id, ep = tostring(r.z), ep - (r.a - r.x)
            break
        end
    end
    local s = seasons[id]
    if not s then return nil end
    return s.s, ep + s.o
end

-- A parsed release (browse_torrents.parse_title fields) -> "S02E13" /
-- "S01E01-E12", or nil. A batch whose ends land in different seasons is
-- nil. When the filename states a season and the lists disagree, nil and
-- a reason: a wrong AniList search hit must not print a wrong season.
function M.sxe(mal, e, rules, seasons)
    if not mal then return nil end
    local s, a, b
    if e.episodes then
        local lo, hi = e.episodes:match("^(%d+)%-(%d+)$")
        local s2
        s, a = M.resolve(mal, tonumber(lo), rules, seasons)
        s2, b = M.resolve(mal, tonumber(hi), rules, seasons)
        if not s or s ~= s2 then return nil end
    elseif e.episode then
        s, a = M.resolve(mal, e.episode, rules, seasons)
        if not s then return nil end
    else
        return nil
    end
    if e.season and e.season ~= s then
        return nil, string.format("filename says season %d, anime lists say season %d", e.season, s)
    end
    if b then return string.format("S%02dE%02d-E%02d", s, a, b) end
    return string.format("S%02dE%02d", s, a)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_anime_test.lua 2>&1 | grep -E "FAIL|ALL PASS|Lua error"; echo exit=${PIPESTATUS[0]}`
Expected: `[browse_anime_test] ALL PASS` and `exit=0`.

- [ ] **Step 5: Run against the real lists once (not committed)**

```sh
curl -sL -o "$CLAUDE_JOB_DIR/tmp/rel.txt" https://github.com/erengy/anime-relations/raw/master/anime-relations.txt
curl -sL -o "$CLAUDE_JOB_DIR/tmp/fribb.json" https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json
W=$(cygpath -m "$CLAUDE_JOB_DIR/tmp")
cat > "$CLAUDE_JOB_DIR/tmp/real.lua" <<EOF
package.path = "portable_config/scripts/?.lua;" .. package.path
local A, utils = require "browse_anime", require "mp.utils"
local function read(p) local f = io.open(p, "rb"); local s = f:read("*a"); f:close(); return s end
local R = A.parse_relations(read("$W/rel.txt"))
local S = A.slim_seasons(utils.parse_json(read("$W/fribb.json")))
print("frieren29", A.sxe(52991, {episode = 29}, R, S), "mushoku S2 13", A.sxe(51179, {episode = 13}, R, S))
mp.add_timeout(0.3, function() mp.command("quit") end)
EOF
timeout 30 ./mpv.exe --no-config --idle=once --script="$W/real.lua" 2>&1 | grep real
```
Expected: `frieren29	S02E01	mushoku S2 13	S02E13`.

- [ ] **Step 6: Commit**

```bash
git add portable_config/scripts/browse_anime.lua docs/tests/browse_anime_test.lua
git commit -m "browse_anime: resolve fansub episodes to TVDB S##E## from Fribb anime-lists + anime-relations"
```

---

### Task 2: `display()` prints `e.sxe` or the filename fallback

**Files:**
- Modify: `portable_config/scripts/browse_torrents.lua` (`M.display`, currently around lines 85-100)
- Test: `docs/tests/browse_torrents_test.lua` (the `display ...` assertions, currently lines 88-96 and 110-113)

**Interfaces:**
- Consumes: entry fields from `parse_title`/`parse_feed`: `group, show, season, part, episode, episodes, version, resolution`; new optional `e.sxe` (string, set by Task 4).
- Produces: `display(e) -> prefix, name, suffix` (unchanged signature). Suffix is `"  " .. tag .. "  " .. res.."p"` with empty parts omitted.

- [ ] **Step 1: Update the expected strings and add the new cases**

In `docs/tests/browse_torrents_test.lua`, replace the block from `eq("display S2", ...` through `eq("display episode 100+", ...)` with:

```lua
eq("display S2", row("[SubsPlease] Mushoku Tensei S2 - 07 (1080p) [A1B2C3D4].mkv"),
   "[SubsPlease] |Mushoku Tensei|  S02E07  1080p")
eq("display nth Season, version", row(long), "[Erai-raws] |Mushoku Tensei - Isekai Ittara Honki Dasu|  S02E07v2  1080p")
eq("display no season", row("[SubsPlease] Sousou no Frieren - 28 (1080p) [A1B2].mkv"),
   "[SubsPlease] |Sousou no Frieren|  E28  1080p")
eq("display batch", row("[SubsPlease] Show Name (01-12) (1080p) [Batch]"), "[SubsPlease] |Show Name|  E01-12  1080p")
eq("display batch with season", row("[G] Show Name Season 1 - 01 ~ 12 [1080p]"), "[G] |Show Name|  S01E01-E12  1080p")
eq("display no group, 4K", row("Show Title S01 2160p 4K UHD BluRay Remux-GROUP"), "|Show Title|  S01  2160p")
eq("display bare", row("[G] Movie Name"), "[G] |Movie Name|")
eq("display episode 100+", row("[G] One Piece - 1120 (1080p)"), "[G] |One Piece|  E1120  1080p")
local resolved = T.parse_title("[SubsPlease] Mushoku Tensei S2 - 13v2 (1080p) [A1B2].mkv")
resolved.sxe = "S02E13"
eq("display resolved tag replaces the fallback", table.concat({T.display(resolved)}, "|"),
   "[SubsPlease] |Mushoku Tensei|  S02E13v2  1080p")
```

and replace the two Part/Cour display assertions with:

```lua
eq("display Part", row("[Erai-raws] Mushoku Tensei II - Isekai Ittara Honki Dasu Part 2 - 01 [1080p].mkv"),
   "[Erai-raws] |Mushoku Tensei II - Isekai Ittara Honki Dasu|  P2 E01  1080p")
eq("display S2 Cour 2", row("[SubsPlease] Kusuriya no Hitorigoto S2 Cour 2 - 13 (1080p) [ABCD].mkv"),
   "[SubsPlease] |Kusuriya no Hitorigoto|  S02 P2 E13  1080p")
```

- [ ] **Step 2: Run test to verify the new expectations fail**

Run: `timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_torrents_test.lua 2>&1 | grep -E "FAIL|ALL PASS|Lua error"; echo exit=${PIPESTATUS[0]}`
Expected: FAIL lines for `display S2` (got `S2 E07`), `display batch with season`, `display resolved tag replaces the fallback`, `display S2 Cour 2`, `display no group, 4K` (got `S1`); exit=1.

- [ ] **Step 3: Replace `M.display` in `browse_torrents.lua`**

Replace the comment and function starting at `-- Entry -> its results row in three parts:` through the `end` of `M.display` with:

```lua
-- The episode tag from the filename alone: "S02E07", "E29" (season
-- unknown), "S01 P2 E13" (part whose offset is unknown), "S01E01-E12" /
-- "E01-12" (batch), "S01" (season batch). Never guesses a season.
local function fallback_tag(e)
    local s = e.season and string.format("S%02d", e.season)
    local ep
    if e.episodes then
        ep = "E" .. (s and not e.part and (e.episodes:gsub("%-", "-E")) or e.episodes)
    elseif e.episode then
        ep = string.format("E%02d", e.episode)
    end
    if e.part then
        local t = {}
        if s then t[#t + 1] = s end
        t[#t + 1] = "P" .. e.part
        if ep then t[#t + 1] = ep end
        return table.concat(t, " ")
    end
    return (s or "") .. (ep or "")
end

-- Entry -> its results row in three parts: "[Group] ", the show name, and
-- "  S02E07v2  1080p". The tag is e.sxe (TVDB numbering, set by browse.lua
-- once the anime lists answer) or the filename fallback. browse.lua
-- shortens only the name, so the tags stay visible however long it is. The
-- name drops its season and part (Part or Cour); the tag has them.
function M.display(e)
    local show = e.show:gsub("%s+[Pp]art%s+%d+$", ""):gsub("%s+[Cc]our%s+%d+$", "")
    show = show:gsub("%s+S%d+$", ""):gsub("%s+%d+%a%a%s+[Ss]eason$", ""):gsub("%s+[Ss]eason%s+%d+$", "")
    local tag = e.sxe or fallback_tag(e)
    if tag ~= "" and e.version and (e.episode or e.episodes) then tag = tag .. "v" .. e.version end
    local tags = {}
    if tag ~= "" then tags[1] = tag end
    if e.resolution then tags[#tags + 1] = e.resolution .. "p" end
    return e.group and "[" .. e.group .. "] " or "", show, #tags > 0 and "  " .. table.concat(tags, "  ") or ""
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_torrents_test.lua 2>&1 | grep -E "FAIL|ALL PASS|Lua error"; echo exit=${PIPESTATUS[0]}`
Expected: `ALL PASS`, exit=0.

- [ ] **Step 5: Commit**

```bash
git add portable_config/scripts/browse_torrents.lua docs/tests/browse_torrents_test.lua
git commit -m "browse_torrents: S##E## tags; e.sxe when resolved, filename fallback otherwise"
```

---

### Task 3: one AniList lookup per show feeds covers and MAL ids, in both views

**Files:**
- Modify: `portable_config/scripts/browse.lua` (cover section currently lines 372-419; `draw_list` loop ~line 355; `draw_grid` `ensure_cover` call ~line 467; `show_results` ~line 553)

**Interfaces:**
- Consumes: `torrents.cover_query(show)`, existing `djb2`, `THUMB_DIR`, `list`, `list_filter`, `list_draw`.
- Produces (used by Task 4): module-level `metas` (`show -> {url=string|nil, mal=int|nil}` or `"pending"`), `lists` (`{relations=, seasons=}`, filled by Task 4), `apply_entry(e)`, `apply_meta(show)`, `schedule_refresh()`.

This task has no unit seam (it is mpv glue). Its check is the e2e run in Step 3.

- [ ] **Step 1: Replace the covers section**

Replace everything from `-- Show covers for the grid (Torrents source): one AniList search per show` through the `end` of `ensure_cover` with:

```lua
-- Torrents: one AniList search per show name (the first hit's cover and MAL
-- id), cached on disk beside the thumbnails keyed by the search string;
-- "{}" records "no hit". Feeds the grid covers and, with the anime lists
-- (Task 4 of the S##E## plan: ensure_lists), the rows' S##E## tags. A
-- wrong hit is caught by browse_anime.sxe's season check or is cosmetic.
local metas = {} -- show -> {url=, mal=} ({} = no hit), or "pending"
local lists = {} -- relations / seasons: browse_anime tables once loaded
local list_draw

-- Row text changed under a typed filter: re-match, keep the focused entry.
local function refresh_view()
    if not list.ov then return end
    local row = list.view[list.cursor]
    local focused = row and row.i
    list_filter()
    for k, r in ipairs(list.view) do
        if r.i == focused then list.cursor = k end
    end
    list_draw()
end

-- Lookups answer from inside a draw (disk cache) or a callback; coalesce
-- into one redraw after the current one instead of drawing re-entrantly.
local refresh_pending = false
local function schedule_refresh()
    if refresh_pending then return end
    refresh_pending = true
    mp.add_timeout(0, function()
        refresh_pending = false
        refresh_view()
    end)
end

local function apply_entry(e)
    local m = metas[e.show]
    if type(m) ~= "table" then return end
    e.thumbnail = m.url
    if lists.relations and lists.seasons then
        local sxe, why = anime.sxe(m.mal, e, lists.relations, lists.seasons)
        if why then mp.msg.warn(string.format("%s: %s", e.title, why)) end
        e.sxe = sxe
    end
end

local function apply_meta(show)
    for _, e in ipairs(list.entries) do
        if e.show == show then apply_entry(e) end
    end
    schedule_refresh()
end

local function ensure_meta(show)
    if metas[show] ~= nil then return end
    metas[show] = "pending"
    -- keyed by the query, not the show: "Show S2" once cached as "no cover"
    local query = torrents.cover_query(show)
    local file = string.format("%s\\meta_%s.json", THUMB_DIR, djb2(query))
    local f = io.open(file, "r")
    if f then
        local m = utils.parse_json(f:read("*a") or "")
        f:close()
        if type(m) == "table" then
            metas[show] = m
            return apply_meta(show)
        end
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = {"curl", "-s", "-S", "--max-time", "10", "https://graphql.anilist.co",
                "-H", "Content-Type: application/json", "--data-binary", utils.format_json({
                    query = "query($s:String){Page(perPage:1){media(search:$s,type:ANIME){idMal coverImage{large}}}}",
                    variables = {s = query}})},
    }, function(ok, res)
        local data = ok and res.status == 0 and utils.parse_json(res.stdout)
        if not (data and data.data) then
            -- network error or an AniList error body (429 when rate limited):
            -- nothing this session, nothing cached, the next mpv start retries
            mp.msg.warn(string.format("AniList lookup failed: %s %s", show,
                                      res and (res.stderr .. (res.stdout or "")):sub(1, 200) or ""))
            metas[show] = {}
            return apply_meta(show)
        end
        local media = data.data.Page and data.data.Page.media
        local hit = media and media[1]
        local m = hit and {url = hit.coverImage and hit.coverImage.large, mal = hit.idMal} or {}
        local out = io.open(file, "w")
        if out then out:write(utils.format_json(m)); out:close() end
        metas[show] = m
        apply_meta(show)
    end)
end
```

- [ ] **Step 2: Wire the views and `show_results`**

Near the top of `browse.lua`, after `local torrents = require "browse_torrents"`, add:

```lua
local anime = require "browse_anime"
```

In `draw_list`, inside `for i = first, last do`, after `local row = list.view[i]`, add:

```lua
        local e = list.entries[row.i]
        if e.show then ensure_meta(e.show) end
```

In `draw_grid`, replace `if e.show and not e.thumbnail then ensure_cover(e.show) end` with:

```lua
        if e.show then ensure_meta(e.show) end
```

In `show_results`, directly after `list.entries, list.prompt, list.filter = entries, prompt, ""`, add (a show already looked up this session gets its cover/tag at once; before this a second search for the same show never got covers):

```lua
    for _, e in ipairs(entries) do
        if e.show then apply_entry(e) end
    end
```

Confirm nothing still uses the old names: `grep -nE "ensure_cover|apply_cover|covers\[" portable_config/scripts/browse.lua` prints nothing.

`show_results` is defined after the metas section, so `apply_entry` is in scope. Confirm with `grep -n "^local function apply_entry\|^local function show_results" portable_config/scripts/browse.lua` (apply_entry's line number must be lower).

- [ ] **Step 3: e2e check (covers in both views, second search keeps covers)**

Build a local fake feed and driver (same recipe as `docs/testing.md` "Fake index for the UI path"):

```sh
D="$CLAUDE_JOB_DIR/tmp"; W=$(cygpath -m "$D")
item(){ printf '<item><title>%s</title><link>https://webtorrent.io/torrents/sintel.torrent</link><pubDate>%s</pubDate><nyaa:seeders>%s</nyaa:seeders><nyaa:size>1.4 GiB</nyaa:size></item>' "$1" "$2" "$3"; }
{ echo '<?xml version="1.0"?><rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa"><channel><title>f</title>'
item "[SubsPlease] Sousou no Frieren - 29 (1080p) [A1B2].mkv" "Mon, 08 Sep 2026 10:00:00 -0000" 120
item "[SubsPlease] Mushoku Tensei S2 - 13 (1080p) [A1B2].mkv" "Mon, 08 Sep 2026 09:00:00 -0000" 90
item "[Erai-raws] Mushoku Tensei - Isekai Ittara Honki Dasu Part 2 - 01 [1080p][Multiple Subtitle].mkv" "Mon, 08 Sep 2026 08:00:00 -0000" 40
item "[SubsPlease] Kusuriya no Hitorigoto S2 - 05 (1080p) [ABCD].mkv" "Mon, 08 Sep 2026 07:00:00 -0000" 60
item "[G] Some Live Action Show S01E03 1080p WEB-DL" "Mon, 08 Sep 2026 06:00:00 -0000" 30
echo '</channel></rss>'; } > "$D/feed.xml"
cat > "$D/e2e.lua" <<EOF
mp.add_timeout(1, function() mp.command("script-binding browse/torrent-new") end)
mp.add_timeout(6, function() mp.commandv("screenshot-to-file", "$W/list.png", "window") end)
mp.add_timeout(7, function() mp.commandv("keypress", "TAB") end)
mp.add_timeout(12, function() mp.commandv("screenshot-to-file", "$W/grid.png", "window") end)
mp.add_timeout(13, function() mp.commandv("keypress", "ESC") end)
mp.add_timeout(14, function() mp.command("script-binding browse/torrent-new") end)
mp.add_timeout(18, function() mp.commandv("screenshot-to-file", "$W/grid2.png", "window") end)
mp.add_timeout(19, function() mp.command("quit") end)
EOF
(uv run --no-project python -m http.server 8765 --bind 127.0.0.1 --directory "$D" >/dev/null 2>&1 &)
timeout 60 ./mpv.exe --pause --force-window=yes --geometry=1600x900 --volume=0 --no-resume-playback \
  --save-position-on-quit=no --log-file="$W/e2e.log" --script="$W/e2e.lua" \
  "--script-opts=browse-torrent_new_url=http://127.0.0.1:8765/feed.xml" "av://lavfi:color=c=black:s=1600x900"
grep -E "Lua error|AniList lookup failed" "$D/e2e.log"
```

Expected: no `Lua error` lines. `list.png` shows fallback tags (`E29`, `S02E13`, `P2 E01`, `S02E05`, `S01E03`); `grid.png` and `grid2.png` both show covers for the four anime (the reopened view in `grid2.png` is the regression check for the second-search bug). A single ESC closes the list only when the filter is empty, which it is here. If ESC does not close it, send a second ESC.

- [ ] **Step 4: Run both unit tests (no regressions)**

```sh
timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_torrents_test.lua 2>&1 | grep -E "FAIL|ALL PASS"
timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_anime_test.lua 2>&1 | grep -E "FAIL|ALL PASS"
```
Expected: `ALL PASS` twice.

- [ ] **Step 5: Commit**

```bash
git add portable_config/scripts/browse.lua
git commit -m "browse: one AniList lookup per show (cover + MAL id) in list and grid; reopened views keep covers"
```

---

### Task 4: fetch the anime lists weekly and set `e.sxe`

**Files:**
- Modify: `portable_config/scripts/browse.lua` (after the metas section from Task 3; the three torrent bindings `torrent-search`, `torrent-new`, `torrent-followed`)
- Modify: `docs/testing.md` (Torrents section)

**Interfaces:**
- Consumes: `anime.parse_relations`, `anime.slim_seasons` (Task 1); `metas`, `lists`, `apply_meta`, `schedule_refresh` (Task 3); `THUMB_DIR`, `utils`.
- Produces: `ensure_lists()`; fills `lists.relations`, `lists.seasons`.

- [ ] **Step 1: Add `ensure_lists` after `ensure_meta`**

```lua
-- The anime lists behind S##E## (browse_anime.lua): TVDB season / offset
-- per MAL id (Fribb) and fansub renumbering rules (erengy). Slimmed into
-- THUMB_DIR and refetched when missing or older than a week; the view does
-- not wait, rows switch from the filename tag when a list lands. A failed
-- fetch or an unparsable body keeps the old file.
local LISTS = {
    seasons = {url = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json",
               slim = function(body) return anime.slim_seasons(utils.parse_json(body)) end},
    relations = {url = "https://github.com/erengy/anime-relations/raw/master/anime-relations.txt",
                 slim = anime.parse_relations},
}
local LISTS_MAX_AGE = 7 * 86400

local function ensure_lists()
    if not utils.file_info(THUMB_DIR) then
        mp.command_native({name = "subprocess", playback_only = false,
                           args = {"cmd", "/c", "mkdir", THUMB_DIR}})
    end
    for name, l in pairs(LISTS) do
        local file = string.format("%s\\%s.json", THUMB_DIR, name)
        local info = utils.file_info(file)
        if info and not lists[name] then
            local f = io.open(file, "r")
            lists[name] = utils.parse_json(f:read("*a") or "")
            f:close()
        end
        if (not info or os.time() - info.mtime > LISTS_MAX_AGE) and not l.pending then
            l.pending = true
            mp.command_native_async({
                name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
                args = {"curl", "-s", "-S", "-L", "--fail", "--max-time", "60", l.url},
            }, function(ok, res)
                l.pending = false
                if not ok or res.status ~= 0 then
                    mp.msg.warn(string.format("anime list %s: fetch failed, keeping the old one: %s",
                                              name, res and res.stderr or ""))
                    return
                end
                local t, err = l.slim(res.stdout)
                if not t then
                    mp.msg.warn(string.format("anime list %s: %s, keeping the old one", name, err))
                    return
                end
                local out = io.open(file, "w")
                if out then out:write(utils.format_json(t)); out:close() end
                lists[name] = t
                for show, m in pairs(metas) do
                    if type(m) == "table" then apply_meta(show) end
                end
            end)
        end
    end
end
```

- [ ] **Step 2: Call it from the three torrent bindings**

In each of `torrent-search`, `torrent-new`, `torrent-followed`, directly after the `if opts.torrent_... == "" then return torrent_config_message() end` line, add:

```lua
    ensure_lists()
```

`ensure_lists` is defined in the metas section, which precedes the torrent bindings; confirm with `grep -n "^local function ensure_lists\|\"torrent-search\"" portable_config/scripts/browse.lua`.

- [ ] **Step 3: e2e, live lists, starting with no cache directory**

```sh
rm -rf "$TEMP/mpv-browse-thumbs"
```
Then rerun the Task 3 Step 3 commands (feed, server, mpv) with this driver instead, which stays in list view (the default `view=list`) and types a filter (`e` matches every row) before the lists land:

```sh
cat > "$D/e2e.lua" <<EOF
mp.add_timeout(1, function() mp.command("script-binding browse/torrent-new") end)
mp.add_timeout(1.5, function() mp.commandv("keypress", "e") end)
mp.add_timeout(15, function() mp.commandv("screenshot-to-file", "$W/list.png", "window") end)
mp.add_timeout(16, function() mp.commandv("keypress", "BS") end)
mp.add_timeout(17, function() mp.commandv("keypress", "TAB") end)
mp.add_timeout(22, function() mp.commandv("screenshot-to-file", "$W/grid.png", "window") end)
mp.add_timeout(23, function() mp.command("quit") end)
EOF
```

Expected:
- `ls "$TEMP/mpv-browse-thumbs"/{seasons,relations}.json` shows both files (Review Focus 4: created from list view).
- `list.png` (filter `e`) shows resolved tags with the filter's highlight on matching characters and no Lua error: `Frieren  S02E01`, `Mushoku Tensei  S02E13`, `Mushoku Tensei - Isekai Ittara Honki Dasu  S01E12`, `Kusuriya no Hitorigoto  S02E05` (Kusuriya depends on AniList's hit for "Kusuriya no Hitorigoto Season 2"; if it shows `S02E05` from the fallback with a season-disagreement warning in the log, record the warning in the report rather than change code).
- `grid.png`: the same tags in the tiles, with covers.
- The live-action row keeps `S01E03` (no AniList hit, fallback).
- `grep -E "Lua error" "$D/e2e.log"` prints nothing.

- [ ] **Step 4: e2e, dead list URL keeps the fallback and the old file**

Run once more with the lists present but made stale, and the Fribb URL unreachable:

```sh
touch -d "10 days ago" "$TEMP/mpv-browse-thumbs/seasons.json"
cp "$TEMP/mpv-browse-thumbs/seasons.json" "$D/seasons.before"
sed -i 's#https://raw.githubusercontent.com/Fribb/#http://127.0.0.1:9/Fribb/#' portable_config/scripts/browse.lua
```
Rerun the Task 4 Step 3 driver, then restore the URL (do not use `git checkout`: Task 4's changes are not committed yet):
```sh
sed -i 's#http://127.0.0.1:9/Fribb/#https://raw.githubusercontent.com/Fribb/#' portable_config/scripts/browse.lua
grep -c "raw.githubusercontent.com/Fribb" portable_config/scripts/browse.lua   # expect 1
cmp "$D/seasons.before" "$TEMP/mpv-browse-thumbs/seasons.json" && echo kept
grep "anime list seasons" "$D/e2e.log"
```
Expected: `kept`; one `anime list seasons: fetch failed, keeping the old one` warning; tags still resolved from the old file; no `Lua error`.

(Do not commit the temporary URL. `git diff` must show no `127.0.0.1:9` before Step 6.)

Stop the fake index server:
```sh
for p in $(netstat -ano | grep "127.0.0.1:8765" | grep LISTEN | awk '{print $5}' | sort -u); do taskkill //PID $p //F; done
```

- [ ] **Step 5: Document the test**

In `docs/testing.md`, in the "Torrents source" section, after the `browse_torrents_test.lua` command block, add:

````markdown
**S##E## resolution** (`browse_anime.lua`), same runner, real excerpts of anime-relations and Fribb's anime-list as fixtures:

```sh
./mpv.exe --no-config --idle=once --script=docs/tests/browse_anime_test.lua 2>&1 | grep -E "FAIL|ALL PASS"; echo exit=${PIPESTATUS[0]}
```

The lists themselves are fetched by `browse.lua` into `%TEMP%\mpv-browse-thumbs\{seasons,relations}.json` on the first torrent view and refetched after 7 days; delete them to force a fetch. `seasons.json` is Fribb's list slimmed to `{mal_id: {s, o}}` (TVDB season, episode offset).
````

- [ ] **Step 6: Run both unit tests and commit**

```sh
timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_torrents_test.lua 2>&1 | grep -E "FAIL|ALL PASS"
timeout 20 ./mpv.exe --no-config --idle=once --script=docs/tests/browse_anime_test.lua 2>&1 | grep -E "FAIL|ALL PASS"
git diff --stat
git add portable_config/scripts/browse.lua docs/testing.md
git commit -m "browse: fetch anime lists weekly; torrent rows show resolved S##E##"
```
Expected: `ALL PASS` twice; the diff touches only `browse.lua` and `docs/testing.md`.
