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
