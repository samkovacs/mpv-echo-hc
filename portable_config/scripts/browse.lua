-- browse.lua: search YouTube and browse the signed-in account's feeds from
-- inside mpv, using the builtin console (mp.input) for text entry and the
-- same select menu that select.lua's History / Watch later entries use.
--
-- Everything goes through yt-dlp. Cookies come from mpv's own
-- ytdl-raw-options (mpv.conf), so there is one place to configure auth.
--
-- Bindings (input.conf / menu.conf):
--   browse/youtube-search          prompt for a query, list results
--   browse/youtube-subscriptions   :ytsubs
--   browse/youtube-history         :ythistory
--   browse/youtube-watch-later     :ytwatchlater
--   browse/youtube-home            :ytrec
--   browse/twitch-search           prompt for a query, list live channels
--   browse/twitch-live             live status of script-opts twitch_channels

local utils = require "mp.utils"
local input = require "mp.input"

local RESULTS = 30

local function ytdlp_path()
    local p = mp.command_native({"expand-path", "~~exe_dir/yt-dlp.exe"})
    if utils.file_info(p) then return p end
    return "yt-dlp"
end

-- Reuse mpv's ytdl-raw-options so cookies stay configured in one place.
-- mark-watched is dropped: listing a feed must not mark 30 videos watched.
local function raw_option_args()
    local args = {}
    for k, v in pairs(mp.get_property_native("ytdl-raw-options") or {}) do
        if k ~= "mark-watched" then
            if v == "" then
                args[#args + 1] = "--" .. k
            else
                args[#args + 1] = "--" .. k .. "=" .. v
            end
        end
    end
    return args
end

local function fmt_duration(s)
    if not s then return "" end
    s = math.floor(s)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    end
    return string.format("%d:%02d", s / 60, s % 60)
end

local function label(e)
    local who = e.channel or e.uploader or ""
    local extra
    if e.live_status == "is_live" then
        extra = "LIVE"
    else
        extra = fmt_duration(e.duration)
    end
    local parts = {e.title or e.url}
    if who ~= "" then parts[#parts + 1] = "[" .. who .. "]" end
    if extra ~= "" then parts[#parts + 1] = "(" .. extra .. ")" end
    return table.concat(parts, "  ")
end

local function show_results(prompt, entries)
    if #entries == 0 then
        mp.osd_message("browse: no results", 3)
        return
    end
    local items = {}
    for i, e in ipairs(entries) do items[i] = label(e) end
    input.select({
        prompt = prompt,
        items = items,
        submit = function(i)
            local e = entries[i]
            local url = e.url or e.webpage_url
            mp.commandv("loadfile", url, "replace")
            mp.osd_message("Loading: " .. (e.title or url), 3)
        end,
    })
end

local function fetch(prompt, url)
    mp.osd_message("browse: fetching " .. prompt .. "...", 30)
    local args = {ytdlp_path(), "--no-warnings", "-J", "--flat-playlist",
                  "--playlist-end", tostring(RESULTS)}
    for _, a in ipairs(raw_option_args()) do args[#args + 1] = a end
    args[#args + 1] = "--"
    args[#args + 1] = url
    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(ok, res, err)
        mp.osd_message("", 0)
        if not ok or res.status ~= 0 then
            local msg = (res and res.stderr or err or ""):gsub("%s+$", "")
            mp.msg.error("yt-dlp failed: " .. msg)
            mp.osd_message("browse: yt-dlp failed\n" .. msg, 8)
            return
        end
        local data = utils.parse_json(res.stdout)
        if not data then
            mp.msg.error("yt-dlp returned unparsable JSON")
            mp.osd_message("browse: bad JSON from yt-dlp", 5)
            return
        end
        show_results(prompt, data.entries or {data})
    end)
end

mp.add_key_binding(nil, "youtube-search", function()
    input.get({
        prompt = "YouTube search: ",
        submit = function(text)
            input.terminate()
            if text:match("^%s*$") then return end
            fetch("YouTube: " .. text, "ytsearch" .. RESULTS .. ":" .. text)
        end,
    })
end)

-- ---------------------------------------------------------------------------
-- Twitch. yt-dlp cannot search Twitch or list follows, so this talks to the
-- web player's GraphQL endpoint directly, authenticated with the auth-token
-- cookie from the same cookies.txt yt-dlp uses (ytdl-raw-options cookies=).
-- Undocumented API: when Twitch changes it, only this section breaks.
-- ---------------------------------------------------------------------------

local TWITCH_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko" -- twitch.tv web player

local function twitch_auth_token()
    local file = (mp.get_property_native("ytdl-raw-options") or {}).cookies
    if not file then
        return nil, "ytdl-raw-options has no cookies= entry"
    end
    local f = io.open(file, "r")
    if not f then return nil, "cannot open " .. file end
    for line in f:lines() do
        -- Netscape format: domain, flag, path, secure, expiry, name, value
        local domain, name, value = line:match("^(%S+)\t%S+\t%S+\t%S+\t%S+\t(%S+)\t(%S+)")
        if domain and domain:find("twitch%.tv$") and name == "auth-token" then
            f:close()
            return value
        end
    end
    f:close()
    return nil, "no twitch.tv auth-token cookie in " .. file
end

local function twitch_gql(query, cb)
    local token, err = twitch_auth_token()
    if not token then
        mp.msg.error(err)
        mp.osd_message("browse: " .. err, 8)
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "-S", "--fail-with-body", "https://gql.twitch.tv/gql",
                "-H", "Client-Id: " .. TWITCH_CLIENT_ID,
                "-H", "Authorization: OAuth " .. token,
                "-H", "Content-Type: application/json",
                "--data-binary", utils.format_json({query = query})},
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(ok, res, e)
        mp.osd_message("", 0)
        local data = ok and res.status == 0 and utils.parse_json(res.stdout)
        if not data or data.errors or not data.data then
            local msg = data and data.errors and utils.format_json(data.errors)
                        or (res and (res.stderr .. res.stdout) or e or "")
            mp.msg.error("twitch gql failed: " .. msg)
            mp.osd_message("browse: Twitch API failed\n" .. msg:sub(1, 300), 8)
            return
        end
        cb(data.data)
    end)
end

-- Stream node -> entry in the same shape show_results() expects
local function twitch_entry(user)
    local s = user.stream
    return {
        title = string.format("%s: %s", user.displayName or user.login, s.title or ""),
        channel = (s.game and s.game.displayName or "") ..
                  string.format(" %d viewers", s.viewersCount or 0),
        live_status = "is_live",
        url = "https://www.twitch.tv/" .. user.login,
    }
end

local function show_live(users)
    local entries = {}
    for _, u in ipairs(users) do
        if u and u.stream then entries[#entries + 1] = twitch_entry(u) end
    end
    table.sort(entries, function(a, b) return a.channel > b.channel end)
    show_results("Twitch: live now", entries)
end

-- Followed channels. Twitch's follows service answers every third-party
-- GraphQL request with "service error" (tested 2026-09-02: raw query,
-- browser UA, integrity token, other client ids), so the account's follow
-- list is unreachable. The working route is a channel list in
-- script-opts/browse.conf (twitch_channels=a,b,c) checked for live status.
-- ponytail: swap for currentUser.followedLiveUsers if Twitch reopens it.
local opts = {twitch_channels = ""}
require("mp.options").read_options(opts, "browse")

mp.add_key_binding(nil, "twitch-live", function()
    local logins = {}
    for l in opts.twitch_channels:gmatch("[^,%s]+") do logins[#logins + 1] = l:lower() end
    if #logins == 0 then
        mp.osd_message("browse: set twitch_channels=a,b,c in script-opts/browse.conf", 8)
        return
    end
    mp.osd_message("browse: checking Twitch channels...", 30)
    twitch_gql(string.format([[
        query { users(logins: %s) {
            login displayName
            stream { title viewersCount game { displayName } }
        } }]], utils.format_json(logins)),
        function(d) show_live(d.users) end)
end)

mp.add_key_binding(nil, "twitch-search", function()
    input.get({
        prompt = "Twitch search: ",
        submit = function(text)
            input.terminate()
            if text:match("^%s*$") then return end
            mp.osd_message("browse: searching Twitch...", 30)
            twitch_gql(string.format([[
                query { searchFor(userQuery: %s, platform: "web") {
                    channels { edges { item { ... on User {
                        login displayName
                        stream { title viewersCount game { displayName } }
                    } } } } } }]], utils.format_json(text)),
                function(d)
                    local entries = {}
                    for _, e in ipairs(d.searchFor.channels.edges) do
                        if e.item and e.item.stream then
                            entries[#entries + 1] = twitch_entry(e.item)
                        end
                    end
                    show_results("Twitch: " .. text, entries)
                end)
        end,
    })
end)

local feeds = {
    {"youtube-subscriptions", "Subscriptions", ":ytsubs"},
    {"youtube-history",       "History",       ":ythistory"},
    {"youtube-watch-later",   "Watch later",   ":ytwatchlater"},
    {"youtube-home",          "Home",          ":ytrec"},
}
for _, f in ipairs(feeds) do
    mp.add_key_binding(nil, f[1], function() fetch("YouTube " .. f[2], f[3]) end)
end
