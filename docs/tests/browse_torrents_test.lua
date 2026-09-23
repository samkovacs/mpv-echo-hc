-- Unit test for scripts/browse_torrents.lua, run by mpv itself:
--   mpv --no-config --idle=once --script=docs/tests/browse_torrents_test.lua
-- Prints PASS/FAIL per assertion and exits non-zero on any failure.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../../portable_config/scripts/?.lua;" .. package.path
local T = require "browse_torrents"

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

-- ---------------------------------------------------------------- titles
local t = T.parse_title("[SubsPlease] Sousou no Frieren - 28 (1080p) [A1B2C3D4].mkv")
eq("weekly group", t.group, "SubsPlease")
eq("weekly show", t.show, "Sousou no Frieren")
eq("weekly episode", t.episode, 28)
eq("weekly resolution", t.resolution, 1080)

t = T.parse_title("[Erai-raws] Dandadan 2nd Season - 05v2 [1080p][HEVC][Multiple Subtitle][ABCD].mkv")
eq("v2 episode", t.episode, 5)
eq("bracket resolution", t.resolution, 1080)
eq("bracket show", t.show, "Dandadan 2nd Season")

t = T.parse_title("[Judas] Frieren - Beyond Journey's End (Season 1) [1080p][HEVC x265 10bit][Multi-Subs] (Batch)")
eq("batch show", t.show, "Frieren - Beyond Journey's End")
eq("batch has no episode", t.episode, nil)
eq("batch resolution", t.resolution, 1080)

t = T.parse_title("[SubsPlease] Show Name (01-12) (1080p) [Batch]")
eq("range batch show", t.show, "Show Name")
eq("range batch no episode", t.episode, nil)

t = T.parse_title("[EMBER] Show Title S02E07 [1080p] [HEVC WEBRip DDP] (Some Title)")
eq("SxxExx show", t.show, "Show Title")
eq("SxxExx episode", t.episode, 7)

t = T.parse_title("Show Title S01 2160p 4K UHD BluRay Remux HEVC DV HDR TrueHD Atmos 7.1-GROUP")
eq("remux no group", t.group, nil)
eq("remux show", t.show, "Show Title")
eq("remux resolution", t.resolution, 2160)

t = T.parse_title("[Anime Time] Show Title (Dual Audio) [1080p][HEVC 10bit x265][AAC][Eng Sub] - 05")
eq("trailing episode show", t.show, "Show Title")
eq("trailing episode", t.episode, 5)

t = T.parse_title("[Group] Other Show - 03 (4K)")
eq("4K resolution", t.resolution, 2160)

-- season / version / batch range, and the row text built from them
t = T.parse_title("[SubsPlease] Mushoku Tensei S2 - 07 (1080p) [A1B2C3D4].mkv")
eq("S2 show keeps the season (groups seasons apart)", t.show, "Mushoku Tensei S2")
eq("S2 season", t.season, 2)
eq("S2 episode", t.episode, 7)

local long = "[Erai-raws] Mushoku Tensei - Isekai Ittara Honki Dasu 2nd Season - 07v2 [1080p][Multiple Subtitle][ABCD].mkv"
t = T.parse_title(long)
eq("nth Season season", t.season, 2)
eq("nth Season episode", t.episode, 7)
eq("version", t.version, 2)

eq("SxxExx season", T.parse_title("[EMBER] Show Title S02E07 [1080p]").season, 2)
eq("Season N season", T.parse_title("[Judas] Frieren (Season 1) [1080p] (Batch)").season, 1)
eq("S01 remux season", T.parse_title("Show Title S01 2160p 4K UHD BluRay Remux-GROUP").season, 1)
eq("no season", T.parse_title("[SubsPlease] Sousou no Frieren - 28 (1080p)").season, nil)
eq("no version", T.parse_title("[SubsPlease] Sousou no Frieren - 28 (1080p)").version, nil)

t = T.parse_title("[SubsPlease] Show Name (01-12) (1080p) [Batch]")
eq("range batch episodes", t.episodes, "01-12")
t = T.parse_title("[Group] Show Name - 01 ~ 24 [1080p]")
eq("dash range is a batch, not episode 1", t.episode, nil)
eq("dash range episodes", t.episodes, "01-24")
eq("dash range show", t.show, "Show Name")
eq("year is not a range", T.parse_title("[G] Show (2024) - 05 (1080p)").episodes, nil)

local function row(title)
    local p = T.parse_title(title)
    p.title = title
    return table.concat({T.display(p)}, "|")
end
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

-- Part / Cour: the second half of a split season
t = T.parse_title("[Erai-raws] Mushoku Tensei II - Isekai Ittara Honki Dasu Part 2 - 01 [1080p][Multiple Subtitle].mkv")
eq("Part part", t.part, 2)
eq("Part episode", t.episode, 1)
eq("Part show keeps the part (groups halves apart)", t.show, "Mushoku Tensei II - Isekai Ittara Honki Dasu Part 2")
t = T.parse_title("[SubsPlease] Kusuriya no Hitorigoto S2 Cour 2 - 13 (1080p) [ABCD].mkv")
eq("Cour part", t.part, 2)
eq("Cour season", t.season, 2)
eq("Cour episode", t.episode, 13)
eq("zero-padded Cour is not a batch range", T.parse_title("[G] Show Cour 02 - 13 (1080p)").episode, 13)
eq("zero-padded Season is not a batch range", T.parse_title("[G] Show Season 02 - 13 (1080p)").episode, 13)
eq("no part", T.parse_title("[SubsPlease] Sousou no Frieren - 28 (1080p)").part, nil)
eq("display Part", row("[Erai-raws] Mushoku Tensei II - Isekai Ittara Honki Dasu Part 2 - 01 [1080p].mkv"),
   "[Erai-raws] |Mushoku Tensei II - Isekai Ittara Honki Dasu|  P2 E01  1080p")
eq("display S2 Cour 2", row("[SubsPlease] Kusuriya no Hitorigoto S2 Cour 2 - 13 (1080p) [ABCD].mkv"),
   "[SubsPlease] |Kusuriya no Hitorigoto|  S02 P2 E13  1080p")

-- AniList search finds nothing for "Mushoku Tensei S2" or "Frieren Season 1"
eq("cover query S2", T.cover_query("Mushoku Tensei S2"), "Mushoku Tensei Season 2")
eq("cover query S02", T.cover_query("Kaiju No. 8 S02"), "Kaiju No. 8 Season 2")
eq("cover query S1 dropped", T.cover_query("Show Title S01"), "Show Title")
eq("cover query nth Season kept", T.cover_query("Dandadan 2nd Season"), "Dandadan 2nd Season")
eq("cover query no season", T.cover_query("Sousou no Frieren"), "Sousou no Frieren")
-- ... nor for "Show Season 2 Cour 2", but does for "Show Season 2 Part 2"
eq("cover query S2 Cour 2", T.cover_query("Kusuriya no Hitorigoto S2 Cour 2"), "Kusuriya no Hitorigoto Season 2 Part 2")
eq("cover query Part kept", T.cover_query("Mushoku Tensei Part 2"), "Mushoku Tensei Part 2")

eq("unparsed title", T.parse_title("[Group][1080p][HEVC]"), nil)
eq("unparsed extension only", T.parse_title("(1080p) [ABCD].mkv"), nil)

-- ------------------------------------------------------------------ feeds
local function item(fields)
    local s = "<item>"
    for _, kv in ipairs(fields) do s = s .. string.format("<%s>%s</%s>", kv[1], kv[2], kv[1]) end
    return s .. "</item>"
end

local function rss(ns, items)
    return string.format('<?xml version="1.0"?><rss version="2.0" xmlns:%s="https://example.invalid/xmlns">' ..
                         '<channel><title>feed</title>%s</channel></rss>', ns, table.concat(items))
end

local function full_feed(ns)
    local p = ns .. ":"
    return rss(ns, {
        item({{"title", "[SubsPlease] Frieren - 27 (1080p) [AAAA].mkv"}, {"link", "https://example.invalid/1.torrent"},
              {"pubDate", "Mon, 01 Sep 2026 10:00:00 -0000"}, {p .. "seeders", "50"}, {p .. "size", "1.4 GiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000001"}, {p .. "trusted", "Yes"}, {p .. "category", "Anime"}}),
        item({{"title", "[SubsPlease] Frieren - 28 (720p) [BBBB].mkv"}, {"link", "https://example.invalid/2.torrent"},
              {"pubDate", "Mon, 08 Sep 2026 10:00:00 -0000"}, {p .. "seeders", "40"}, {p .. "size", "700 MiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000002"}, {p .. "trusted", "No"}}),
        item({{"title", "[SubsPlease] Frieren - 28 (1080p) [CCCC].mkv"}, {"link", "https://example.invalid/3.torrent"},
              {"pubDate", "Mon, 08 Sep 2026 10:01:00 -0000"}, {p .. "seeders", "1"}, {p .. "size", "1.4 GiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000003"}, {p .. "trusted", "Yes"}}),
        item({{"title", "[Erai-raws] Frieren - 28 [1080p][DDDD].mkv"}, {"link", "https://example.invalid/4.torrent"},
              {"pubDate", "Mon, 08 Sep 2026 09:00:00 -0000"}, {p .. "seeders", "20"}, {p .. "size", "1.3 GiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000004"}, {p .. "trusted", "No"}}),
        item({{"title", "[Group] Dandadan - 12 (1080p) [EEEE].mkv"}, {"link", "https://example.invalid/5.torrent"},
              {"pubDate", "Tue, 09 Sep 2026 10:00:00 -0000"}, {p .. "seeders", "5"}, {p .. "size", "1.2 GiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000005"}, {p .. "trusted", "No"}}),
        item({{"title", "[Group][1080p][HEVC]"}, {"link", "https://example.invalid/6.torrent"},
              {"pubDate", "Wed, 10 Sep 2026 10:00:00 -0000"}, {p .. "seeders", "99"}, {p .. "size", "9 GiB"},
              {p .. "infoHash", "0000000000000000000000000000000000000006"}, {p .. "trusted", "Yes"}}),
    })
end

local entries = T.parse_feed(full_feed("nyaa"))
eq("feed item count", #entries, 6)
local e = entries[1]
eq("feed .torrent link wins over info hash (carries trackers)", e.url, "https://example.invalid/1.torrent")
local hash_only = T.parse_feed(rss("x", {item({{"title", "[G] Hash Only - 01 (1080p)"}, {"link", "https://example.invalid/view/1"},
                                               {"x:infoHash", "0000000000000000000000000000000000000001"}})}))
eq("feed magnet from info hash when there is no .torrent link",
   hash_only[1].url:match("^magnet:%?xt=urn:btih:(%x+)"), "0000000000000000000000000000000000000001")
eq("feed seeders", e.seeders, 50)
eq("feed size", e.size, "1.4 GiB")
eq("feed trusted", e.trusted, true)
eq("feed untrusted", entries[2].trusted, false)
eq("feed show", e.show, "Frieren")
check("feed channel line has seeders", e.channel:find("50 seeders", 1, true) ~= nil, e.channel)
check("feed channel line has trusted", e.channel:find("trusted", 1, true) ~= nil, e.channel)
check("feed channel line untrusted has no marker", not entries[2].channel:find("trusted", 1, true), entries[2].channel)
check("feed pubdate parsed", entries[2].time > entries[1].time, entries[2].time)

local other = T.parse_feed(full_feed("torrent"))
eq("namespace prefix ignored", other[1].seeders, 50)
eq("namespace prefix ignored (trusted)", other[1].trusted, true)

local ordered = T.order(entries)
local titles = {}
for i, o in ipairs(ordered) do titles[i] = o.title end
-- Dandadan group is newest (09 Sep), then Frieren, then unparsed last.
eq("group order: newest group first", titles[1], "[Group] Dandadan - 12 (1080p) [EEEE].mkv")
eq("in-show: newest episode, best res, most seeders", titles[2], "[Erai-raws] Frieren - 28 [1080p][DDDD].mkv")
eq("in-show: same episode lower res next", titles[3], "[SubsPlease] Frieren - 28 (720p) [BBBB].mkv")
eq("in-show: older episode after newer", titles[4], "[SubsPlease] Frieren - 27 (1080p) [AAAA].mkv")
eq("seeder floor: 1-seeder 1080p sinks below its show", titles[5], "[SubsPlease] Frieren - 28 (1080p) [CCCC].mkv")
eq("unparsed group last", titles[6], "[Group][1080p][HEVC]")

-- magnet fallback: no infoHash element, magnet in <link>, then in <enclosure>
local plain = rss("x", {
    item({{"title", "[G] Plain Show - 01 (1080p)"}, {"link", "magnet:?xt=urn:btih:00000000000000000000000000000000000000AA&amp;dn=x"}}),
    '<item><title>[G] Plain Show - 02 (1080p)</title><enclosure url="magnet:?xt=urn:btih:00000000000000000000000000000000000000BB" type="application/x-bittorrent" /></item>',
    item({{"title", "[G] Plain Show - 03 (1080p)"}, {"link", "https://example.invalid/3.torrent"}}),
    item({{"title", "[G] Plain Show - 04 (1080p)"}, {"link", "https://example.invalid/nothing"}}),
})
local pe = T.parse_feed(plain)
eq("plain feed count (no playable url is dropped)", #pe, 3)
eq("magnet from link, entity decoded", pe[1].url, "magnet:?xt=urn:btih:00000000000000000000000000000000000000AA&dn=x")
eq("magnet from enclosure", pe[2].url, "magnet:?xt=urn:btih:00000000000000000000000000000000000000BB")
eq(".torrent link", pe[3].url, "https://example.invalid/3.torrent")
eq("missing seeders is nil", pe[1].seeders, nil)
eq("missing trusted is nil", pe[1].trusted, nil)
eq("sparse channel line", pe[1].channel, "")
local po = T.order(pe)
eq("no seeders: no floor demotion, episode order holds", po[1].title, "[G] Plain Show - 03 (1080p)")

-- CDATA and entities in titles
local cd = T.parse_feed(rss("x", {item({{"title", "<![CDATA[[G] Tom &amp; Jerry - 01 (1080p)]]>"},
                                        {"link", "magnet:?xt=urn:btih:00000000000000000000000000000000000000CC"}})}))
eq("cdata + entity title", cd[1].title, "[G] Tom & Jerry - 01 (1080p)")
eq("cdata + entity show", cd[1].show, "Tom & Jerry")

local ent = T.parse_feed(rss("x", {item({{"title", "[G] Show&#8217;s Title &#x2013; 02 (1080p)"},
                                         {"link", "magnet:?xt=urn:btih:00000000000000000000000000000000000000DD"}})}))
eq("numeric entities above 255 become UTF-8", ent[1].title, "[G] Show" .. string.char(226, 128, 153) .. "s Title " .. string.char(226, 128, 147) .. " 02 (1080p)")

-- Invalid code points (above U+10FFFF, UTF-16 surrogates) used to make
-- string.char throw inside parse_feed, losing the whole feed for one title.
local FFFD = string.char(239, 191, 189)
local okp, inv = pcall(T.parse_feed, rss("x", {
    item({{"title", "[G] Bad &#9999999; &#xD800; &#99999999999999999999; - 03 (1080p)"},
          {"link", "magnet:?xt=urn:btih:00000000000000000000000000000000000000EE"}}),
    item({{"title", "[G] Good Show - 04 (1080p)"},
          {"link", "magnet:?xt=urn:btih:00000000000000000000000000000000000000FF"}})}))
check("invalid numeric entity does not throw", okp, inv)
eq("invalid code points become U+FFFD", okp and inv[1].title, "[G] Bad " .. FFFD .. " " .. FFFD .. " " .. FFFD .. " - 03 (1080p)")
eq("rest of the feed survives", okp and #inv, 2)

-- not XML
local bad, err = T.parse_feed("<!doctype html><html><body>blocked</body></html>")
eq("non-xml returns nil", bad, nil)
check("non-xml error message", type(err) == "string" and #err > 0, err)
local empty = T.parse_feed(rss("x", {}))
eq("empty feed is an empty list", #empty, 0)

-- |Group filter on a followed show
local filtered = T.parse_feed(full_feed("nyaa"), "subsplease")
eq("group filter keeps only that group", #filtered, 3)
for _, f in ipairs(filtered) do check("group filter entry is SubsPlease", f.group == "SubsPlease", f.group) end

-- followed-show list parsing and the {query} template
local shows = T.shows("Frieren|SubsPlease, Dandadan ,Show Three|Erai-raws")
eq("shows count", #shows, 3)
eq("shows query", shows[1].query, "Frieren")
eq("shows group", shows[1].group, "SubsPlease")
eq("shows no group", shows[2].group, nil)
eq("shows trimmed", shows[2].query, "Dandadan")
eq("search url encodes query", T.search_url("https://example.invalid/?page=rss&q={query}&c=1_2", "Sousou no Frieren & co"),
   "https://example.invalid/?page=rss&q=Sousou%20no%20Frieren%20%26%20co&c=1_2")

-- starved: below SEEDER_FLOOR dims the row; unknown seeders do not
check("starved below floor", T.starved({seeders = T.SEEDER_FLOOR - 1}))
check("not starved at floor", not T.starved({seeders = T.SEEDER_FLOOR}))
check("unknown seeders not starved", not T.starved({}))

print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
-- a quit issued while the script is still loading hangs mpv; defer it
mp.add_timeout(0.5, function() mp.command(failed == 0 and "quit 0" or "quit 1") end)
