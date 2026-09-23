-- browse_torrents.lua: pure Lua (no mpv dependency) behind browse.lua's
-- Torrents source. Parses an index's RSS feed into entries, parses fansub
-- release titles into show / episode / resolution / group, and orders the
-- entries. Unit test: docs/tests/browse_torrents_test.lua (run by mpv).
--
-- mpv loads every scripts/*.lua as a script, so this file is also loaded
-- once on its own; it only defines functions, so that is harmless.

local M = {}

-- Releases with fewer seeders than this sort after everything else in
-- their show: they are unlikely to stream, so they must not outrank a
-- streamable lower-resolution release of the same episode.
M.SEEDER_FLOOR = 3

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ENTITIES = {amp = "&", lt = "<", gt = ">", quot = '"', apos = "'"}

-- code point -> UTF-8 (Lua 5.1 has no utf8.char). Feed text is untrusted:
-- past U+10FFFF string.char threw and one title lost the whole feed, so
-- invalid code points (and UTF-16 surrogates) become U+FFFD.
local function utf8_char(n)
    if n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF) then n = 0xFFFD end
    if n < 0x80 then return string.char(n) end
    if n < 0x800 then return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40) end
    if n < 0x10000 then
        return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
    end
    return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
                       0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
end

local function decode(s)
    s = s:gsub("^%s*<!%[CDATA%[(.-)%]%]>%s*$", "%1")
    s = s:gsub("&#[xX](%x+);", function(n) return utf8_char(tonumber(n, 16)) end)
    s = s:gsub("&#(%d+);", function(n) return utf8_char(tonumber(n)) end)
    s = s:gsub("&(%a+);", ENTITIES)
    return trim(s)
end

-- ---------------------------------------------------------------- titles

-- Cut a show name at the first token that is not part of the name:
-- " (", " [", " SNN", " NNNNp", " 4K", " 2160".
local function cut_show(s)
    local first = s:find("^[%(%[]") or #s + 1
    for _, pat in ipairs({"%s+[%(%[]", "%s+S%d%d%f[%D]", "%s+%d%d%d%d?p%f[%A]", "%s+4K%f[%A]", "%s+2160%f[%D]"}) do
        local i = s:find(pat)
        if i and i < first then first = i end
    end
    return trim(s:sub(1, first - 1)):gsub("%s*[-:]+$", "")
end

-- "[Group] Show - NN (1080p) [hash].mkv" and the other fansub shapes:
-- SNNENN, a bare " NN (" before a resolution, a trailing " - NN", season
-- batches without an episode, 4K remuxes without a group. Returns nil when
-- no show name survives; browse.lua shows those in an unparsed group.
function M.parse_title(title)
    local t = title:gsub("%.%a%a[%a%d]$", "")
    local group, rest = t:match("^%[([^%]]+)%]%s*(.*)$")
    rest = rest or t
    local show, episode = rest:match("^(.-)%s%-%s(%d+)%f[%D]")
    if not show then show, episode = rest:match("^(.-)%s+S%d+E(%d+)%f[%D]") end
    if not show then show, episode = rest:match("^(.-)%s+(%d%d?)%s*[%(%[]") end
    show = cut_show(show or rest)
    if show == "" then return nil end
    -- "01-12" / "01 ~ 24" is a batch, not episode 1. Zero-padded and
    -- ascending only, so "S2 - 07" and "Mob Psycho 100 - 05" stay episodes.
    -- "Cour 02 - 13" is part 2, episode 13: drop the numbered words first.
    local plain = rest:gsub("[Pp]art%s+%d+", ""):gsub("[Cc]our%s+%d+", ""):gsub("[Ss]eason%s+%d+", "")
    local a, b = plain:match("%f[%d](%d%d+)%s*[-~]%s*(%d%d+)%f[%D]")
    local episodes
    if a and tonumber(a) < tonumber(b) then episodes, episode = a .. "-" .. b, nil end
    local season = rest:match("%f[%w]S(%d+)E%d") or rest:match("%f[%w]S(%d%d?)%f[%W]") or
                   rest:match("%f[%d](%d+)%a%a%s+[Ss]eason") or rest:match("[Ss]eason%s+(%d+)")
    local part = rest:match("%f[%w][Pp]art%s+(%d+)%f[%D]") or rest:match("%f[%w][Cc]our%s+(%d+)%f[%D]")
    local version = rest:match("%f[%d]%d+v(%d)%f[%D]")
    local res = t:match("%f[%d](%d%d%d%d?)p%f[%A]")
    if res then res = tonumber(res) elseif t:find("%f[%w]4K%f[%W]") or t:find("%f[%d]2160%f[%D]") then res = 2160 end
    return {group = group, show = show, season = season and tonumber(season), part = part and tonumber(part),
            episode = episode and tonumber(episode), episodes = episodes, version = version and tonumber(version),
            resolution = res}
end

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

-- Show name -> AniList search string. AniList finds nothing for "Show S2"
-- (nor "Show Season 1": first seasons carry no number) or "Show Cour 2",
-- but does for "Show Season 2" and "Show Part 2".
function M.cover_query(show)
    local base, part = show:match("^(.-)%s+[Pp]art%s+(%d+)$")
    if not base then base, part = show:match("^(.-)%s+[Cc]our%s+(%d+)$") end
    base = base or show
    local name, n = base:match("^(.-)%s+S0*(%d+)$")
    if name then base = n == "1" and name or name .. " Season " .. n end
    return part and base .. " Part " .. tonumber(part) or base
end

-- ------------------------------------------------------------------ feeds

local MONTHS = {Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
                Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12}

-- RFC 822 "Mon, 01 Sep 2026 10:00:00 -0000" -> seconds, or nil.
-- Zone offsets are ignored: this only orders items of one feed.
local function parse_date(s)
    if not s then return nil end
    local d, mon, y, h, mi, sec = s:match("(%d+) (%a%a%a) (%d%d%d%d) (%d+):(%d+):(%d+)")
    if not d or not MONTHS[mon] then return nil end
    return os.time({year = tonumber(y), month = MONTHS[mon], day = tonumber(d),
                    hour = tonumber(h), min = tonumber(mi), sec = tonumber(sec)})
end

local function fields_of(item)
    local f = {}
    -- element by local name, whatever the namespace prefix; %1 closes the same tag
    for tag, body in item:gmatch("<([%w:%-_]+)[^>]*>(.-)</%1>") do
        f[tag:gsub("^.*:", ""):lower()] = decode(body)
    end
    f.enclosure = item:match("<enclosure[^>]-url=\"([^\"]+)\"")
    if f.enclosure then f.enclosure = decode(f.enclosure) end
    return f
end

-- A .torrent link wins over a magnet built from the info hash: the file
-- carries the index's tracker list, while a bare hash leaves the hook with
-- DHT alone, which found no peers in 75 s on the reference machine.
local function playable_url(f)
    if (f.link or ""):match("%.torrent$") then return f.link end
    if (f.enclosure or ""):match("%.torrent$") then return f.enclosure end
    local m = (f.link or ""):match("magnet:%?[^%s<\"]+") or (f.enclosure or ""):match("magnet:%?[^%s<\"]+")
    if m then return m end
    local hash = f.infohash
    if hash and hash:match("^%x+$") then
        return "magnet:?xt=urn:btih:" .. hash .. "&dn=" .. M.urlencode(f.title or "")
    end
    return nil
end

local function yes(v)
    if v == nil then return nil end
    v = v:lower()
    return v == "yes" or v == "true" or v == "1"
end

-- XML text -> entries in feed order (nil, message if it is not an RSS
-- document). `group` keeps only releases from that release group, for the
-- "Show|Group" followed-show syntax. Entry fields: url (.torrent or magnet), title,
-- channel (seeders / size / trusted line), show, group, episode,
-- resolution, seeders, size, trusted, time, index.
function M.parse_feed(xml, group)
    if not xml:find("<rss") and not xml:find("<feed") and not xml:find("<channel") then
        return nil, "index did not return an RSS feed"
    end
    local entries = {}
    for item in xml:gmatch("<item>(.-)</item>") do
        local f = fields_of(item)
        local url = playable_url(f)
        local parsed = f.title and M.parse_title(f.title) or {}
        if url and f.title and (not group or (parsed.group or ""):lower() == group:lower()) then
            local seeders = tonumber(f.seeders or f.seeds)
            local trusted = yes(f.trusted)
            local line = {}
            if seeders then line[#line + 1] = seeders .. " seeders" end
            if f.size and f.size ~= "" then line[#line + 1] = f.size end
            if trusted then line[#line + 1] = "trusted" end
            entries[#entries + 1] = {
                url = url, title = f.title, channel = table.concat(line, " · "),
                show = parsed.show, group = parsed.group, season = parsed.season, episode = parsed.episode,
                part = parsed.part, episodes = parsed.episodes, version = parsed.version,
                resolution = parsed.resolution, seeders = seeders, size = f.size,
                trusted = trusted, time = parse_date(f.pubdate) or -#entries, index = #entries + 1,
            }
        end
    end
    return entries
end

-- Group by show, groups newest first, unparsed group last. Within a show:
-- releases under SEEDER_FLOOR last, then episode desc, resolution desc,
-- seeders desc, feed order. Batches (no episode) sort after single episodes.
function M.order(entries)
    local groups, order = {}, {}
    for _, e in ipairs(entries) do
        local key = e.show and e.show:lower() or false
        if not groups[key] then
            groups[key] = {items = {}, time = -math.huge}
            order[#order + 1] = key
        end
        local g = groups[key]
        g.items[#g.items + 1] = e
        if e.time > g.time then g.time = e.time end
    end
    table.sort(order, function(a, b)
        if (a == false) ~= (b == false) then return b == false end
        return groups[a].time > groups[b].time
    end)
    local out = {}
    for _, key in ipairs(order) do
        local items = groups[key].items
        if key then
            table.sort(items, function(a, b)
                local da = a.seeders ~= nil and a.seeders < M.SEEDER_FLOOR
                local db = b.seeders ~= nil and b.seeders < M.SEEDER_FLOOR
                if da ~= db then return db end
                if (a.episode or -1) ~= (b.episode or -1) then return (a.episode or -1) > (b.episode or -1) end
                if (a.resolution or 0) ~= (b.resolution or 0) then return (a.resolution or 0) > (b.resolution or 0) end
                if (a.seeders or -1) ~= (b.seeders or -1) then return (a.seeders or -1) > (b.seeders or -1) end
                return a.index < b.index
            end)
        end
        for _, e in ipairs(items) do out[#out + 1] = e end
    end
    return out
end

-- ----------------------------------------------------------------- config

function M.urlencode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- "https://index.example/?page=rss&q={query}" + query -> URL
function M.search_url(template, query)
    return (template:gsub("{query}", (M.urlencode(query):gsub("%%", "%%%%"))))
end

-- torrent_shows: "Show A|Group, Show B" (commas in browse.conf; spaces are
-- accepted only as the --script-opts separator, so names keep their spaces).
function M.shows(s)
    local out = {}
    for part in s:gmatch("[^,]+") do
        local query, group = part:match("^(.-)|(.*)$")
        query = trim(query or part)
        if query ~= "" then out[#out + 1] = {query = query, group = group and trim(group) or nil} end
    end
    return out
end

return M
