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
