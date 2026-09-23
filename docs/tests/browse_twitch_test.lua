-- Test for browse.lua's Twitch rows and the dimmed torrent rows, run by mpv:
--   ./mpv.exe --no-config --idle=yes --script-opts=browse-twitch_channels=a \
--     --script=docs/tests/browse_twitch_test.lua
-- Loads the real scripts/browse.lua into this script's Lua state with the
-- GraphQL endpoint answered by canned JSON (no network, no real cookies)
-- and the search prompt answered at once. Prints PASS/FAIL per assertion
-- and exits non-zero on any failure.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local utils = require "mp.utils"

local failed = 0
local function check(name, cond, got)
    print((cond and "PASS " or "FAIL ") .. name .. (cond and "" or ("  got: " .. tostring(got))))
    if not cond then failed = failed + 1 end
end

-- browse.lua reads the auth-token from the cookies file yt-dlp uses
local cookies = os.getenv("TEMP") .. "\\browse_twitch_cookies.txt"
local f = assert(io.open(cookies, "w"))
f:write(".twitch.tv\tTRUE\t/\tTRUE\t0\tauth-token\tfake\n")
f:close()
mp.set_property_native("ytdl-raw-options", {cookies = cookies})

local ago = function(s) return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - s) end
local function user(login, viewers, age)
    return {login = login, displayName = login:upper(), stream = viewers and {
        title = "t", viewersCount = viewers, createdAt = ago(age), game = {displayName = "Game"},
        previewImageURL = "https://example.invalid/" .. login .. ".jpg"} or utils.parse_json("null")}
end
local function search(users)
    local edges = {}
    for _, u in ipairs(users) do edges[#edges + 1] = {item = u} end
    return {searchFor = {channels = {edges = edges}}}
end
local ANSWERS = {
    live = {users = {user("small", 950, 60), user("big", 1234567, 7200), user("mid", 12345, 3600),
                     user("off")}},
    ["allofflineq"] = search({user("aaa"), user("bbb")}),
    ["mixedq"] = search({user("onair", 1000, 30), user("sleeping")}),
}

local real_async = mp.command_native_async
mp.command_native_async = function(cmd, cb)
    local a = cmd.args
    if a and a[1] == "curl" then
        local body = a[#a]
        local data
        if a[5] == "https://gql.twitch.tv/gql" then
            local q = utils.parse_json(body).query
            data = q:find("users%(logins") and ANSWERS.live or ANSWERS[q:match('userQuery: "([^"]+)"')]
        end
        -- AniList and anything else: fail, which browse.lua treats as "no hit"
        mp.add_timeout(0.05, function()
            if data then return cb(true, {status = 0, stdout = utils.format_json({data = data}), stderr = ""}) end
            cb(true, {status = 1, stdout = "", stderr = "offline test"})
        end)
        return
    end
    return real_async(cmd, cb)
end

local query
package.loaded["mp.input"] = {get = function(t) t.submit(query) end, terminate = function() end}

local osd = {}
local real_osd = mp.osd_message
mp.osd_message = function(text, ...)
    if text ~= "" then osd[#osd + 1] = text end
    return real_osd(text, ...)
end

-- list_draw is a local; its osd-dimensions observer closure captures it.
local on_resize
local real_observe = mp.observe_property
mp.observe_property = function(name, fmt, fn)
    if name == "osd-dimensions" then on_resize = fn end
    return real_observe(name, fmt, fn)
end

dofile(here .. "/../../portable_config/scripts/browse.lua")

local function upvalue(fn, name)
    for i = 1, math.huge do
        local n, v = debug.getupvalue(fn, i)
        if not n then return nil end
        if n == name then return v end
    end
end
local list_draw = upvalue(on_resize, "list_draw")
local list = upvalue(list_draw, "list")
local me = mp.get_script_name()

local steps = {
    function() mp.commandv("script-binding", me .. "/twitch-live") end,
    function()
        local e = list.entries
        check("offline channel left out", #e == 3, #e)
        check("sorted by viewers", e[1].viewers == 1234567 and e[2].viewers == 12345 and e[3].viewers == 950,
              e[1].viewers .. "," .. e[2].viewers .. "," .. e[3].viewers)
        check("1234567 -> 1.2M", e[1].channel == "Game 1.2M viewers", e[1].channel)
        check("12345 -> 12.3K", e[2].channel == "Game 12.3K viewers", e[2].channel)
        check("950 stays 950", e[3].channel == "Game 950 viewers", e[3].channel)
        check("uptime from createdAt (UTC)", math.abs(e[1].duration - 7200) <= 5, e[1].duration)
        check("row shows LIVE and uptime", list.ov.data:find("LIVE {\\1c&H0089B5&}(2:00:0", 1, true) ~= nil,
              list.ov.data:match("LIVE[^\n]*"))
        list.mode = "grid"
        list_draw()
        check("tile shows LIVE and uptime", list.ov.data:find("LIVE {\\1c&H0089B5&}2:00:0", 1, true) ~= nil,
              list.ov.data:match("LIVE[^\n]*"))
        list.mode = "list"
    end,
    function() query = "allofflineq"; mp.commandv("script-binding", me .. "/twitch-search") end,
    function()
        check("all offline: says so", osd[#osd]:find("2 Twitch channels match, none live: AAA, BBB", 1, true) ~= nil,
              osd[#osd])
        check("all offline: list not reopened", list.prompt == "Twitch: live now", list.prompt)
    end,
    function() query = "mixedq"; mp.commandv("script-binding", me .. "/twitch-search") end,
    function()
        check("mixed: live channel listed", #list.entries == 1 and list.entries[1].viewers == 1000, #list.entries)
        check("1000 -> 1K", list.entries[1].channel == "Game 1K viewers", list.entries[1].channel)
        check("mixed: header counts offline", list.prompt == "Twitch: mixedq  (+1 offline)", list.prompt)
    end,
    -- torrent rows under SEEDER_FLOOR are drawn dim (base01)
    function()
        list.entries = {{show = "Thin Show", title = "[G] Thin Show - 01 (1080p).mkv", seeders = 1, url = "x"},
                        {show = "Fine Show", title = "[G] Fine Show - 01 (1080p).mkv", seeders = 50, url = "y"}}
        list.view = {{i = 1, matched = {}}, {i = 2, matched = {}}}
        list.cursor = 2
        list_draw()
        check("starved release dimmed", list.ov.data:find("{\\1c&H756E58&}Thin Show", 1, true) ~= nil,
              list.ov.data:match("Thin Show"))
        check("healthy release not dimmed", list.ov.data:find("{\\1c&H756E58&}Fine Show", 1, true) == nil)
    end,
    function()
        os.remove(cookies)
        print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
        mp.command(failed == 0 and "quit 0" or "quit 1")
    end,
}
local i = 0
local function nxt()
    i = i + 1
    if steps[i] then mp.add_timeout(0.3, function() steps[i](); nxt() end) end
end
nxt()
