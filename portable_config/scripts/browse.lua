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

-- ---------------------------------------------------------------------------
-- Result list. The builtin console picker (mp.input.select) escapes ASS tags,
-- so it cannot color parts of an item. This is a minimal ASS-overlay list
-- with the same keys: Up/Down/PgUp/PgDn/Home/End/wheel, Enter, Esc.
-- Colors are Solarized Dark, written as ASS &HBBGGRR& (byte-reversed hex).
-- ---------------------------------------------------------------------------

local C_TITLE   = "A1A193" -- base1  #93a1a1
local C_DIM     = "756E58" -- base01 #586e75
local C_CHANNEL = "D28B26" -- blue   #268bd2
local C_TIME    = "0089B5" -- yellow #b58900
local C_LIVE    = "2F32DC" -- red    #dc322f
local C_FOCUS   = "009985" -- green  #859900
local C_MATCH   = "164BCB" -- orange #cb4b16 (filter-matched characters)
local C_BACK    = "362B00" -- base03 #002b36
local ROWS = 18

local function ass_escape(s)
    return (s:gsub("[\\{}\n]", {["\\"] = "\\\239\187\191", ["{"] = "\\{",
                                ["}"] = "\\}", ["\n"] = " "}))
end

local function colored(color, text)
    return string.format("{\\1c&H%s&}%s", color, ass_escape(text))
end

-- UTF-8 aware split into characters (mpv's Lua is 5.1 / LuaJIT, no utf8 lib)
local function chars(s)
    local t = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
    return t
end

-- Fuzzy match: every character of `needle` appears in `hay` in order
-- (case-insensitive, ASCII case folding). Greedy leftmost. Returns the set
-- of matched hay character indices and the span (last - first), or nil.
local function fuzzy(hay, needle)
    if #needle == 0 then return {}, 0 end
    local matched, j, first, last = {}, 1, nil, nil
    for i, c in ipairs(hay) do
        if c:lower() == needle[j]:lower() then
            matched[i] = true
            first, last = first or i, i
            j = j + 1
            if j > #needle then return matched, last - first end
        end
    end
    return nil
end

-- Render `text` in `color`, with hay chars from `offset` on highlighted when
-- they are in `matched`. Runs of same-colored chars share one tag.
local function render(text, color, offset, matched)
    local out, cur = {}, nil
    for i, c in ipairs(chars(text)) do
        local col = matched[offset + i] and C_MATCH or color
        if col ~= cur then
            out[#out + 1] = string.format("{\\1c&H%s&}", col)
            cur = col
        end
        out[#out + 1] = ass_escape(c)
    end
    return table.concat(out)
end

-- The string the filter matches against: "title channel"
local function haystack(e)
    return chars((e.title or e.url) .. " " .. (e.channel or e.uploader or ""))
end

local function label(e, focused, matched)
    local title, who = e.title or e.url, e.channel or e.uploader or ""
    local parts = {render(title, focused and C_FOCUS or C_TITLE, 0, matched)}
    if who ~= "" then
        parts[#parts + 1] = colored(C_CHANNEL, "[") ..
            render(who, C_CHANNEL, #chars(title) + 1, matched) .. colored(C_CHANNEL, "]")
    end
    if e.live_status == "is_live" then
        parts[#parts + 1] = colored(C_LIVE, "LIVE")
    elseif e.duration then
        parts[#parts + 1] = colored(C_TIME, "(" .. fmt_duration(e.duration) .. ")")
    end
    return table.concat(parts, "  ")
end

-- entries: all results; view: {entry index, matched set} rows that pass the
-- filter, best (tightest) match first; cursor indexes into view.
local list = {ov = nil, entries = {}, view = {}, cursor = 1, prompt = "", filter = ""}

local function list_close()
    if not list.ov then return end
    list.ov:remove()
    list.ov = nil
    for _, k in ipairs(list.keys) do mp.remove_key_binding("browse-" .. k) end
end

local function list_filter()
    local needle = chars(list.filter)
    list.view = {}
    for i, e in ipairs(list.entries) do
        local matched, span = fuzzy(haystack(e), needle)
        if matched then list.view[#list.view + 1] = {i = i, matched = matched, span = span} end
    end
    table.sort(list.view, function(a, b)
        if a.span ~= b.span then return a.span < b.span end
        return a.i < b.i
    end)
    list.cursor = 1
end

local function list_draw()
    local n = #list.view
    local first = math.max(1, math.min(list.cursor - math.floor(ROWS / 2), n - ROWS + 1))
    local last = math.min(n, first + ROWS - 1)
    local header = string.format("{\\b1}%s{\\b0}  %s", colored(C_TITLE, list.prompt),
                                 colored(C_DIM, string.format("%d/%d", math.min(list.cursor, n), n)))
    if list.filter ~= "" then
        header = header .. "  " .. colored(C_DIM, "> ") .. colored(C_MATCH, list.filter) .. colored(C_DIM, "_")
    end
    local lines = {header}
    for i = first, last do
        local focused = i == list.cursor
        local row = list.view[i]
        lines[#lines + 1] = (focused and colored(C_FOCUS, "▸ ") or "  ") ..
                            label(list.entries[row.i], focused, row.matched)
    end
    if n == 0 then lines[#lines + 1] = colored(C_DIM, "  no match") end
    if last < n then lines[#lines + 1] = colored(C_DIM, string.format("  … %d more", n - last)) end
    -- backdrop (own event) then text; ~22px per line at fs22 in a 720-high canvas
    local w, h = list.ov.res_x - 20, #lines * 22 + 20
    list.ov.data = string.format(
        "{\\an7\\pos(10,10)\\1c&H" .. C_BACK .. "&\\1a&H40&\\bord0\\shad0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}\n" ..
        "{\\an7\\pos(20,20)\\fs22\\bord1\\3c&H" .. C_BACK .. "&\\shad0}%s", w, w, h, h, table.concat(lines, "\\N"))
    list.ov:update()
end

local function list_move(delta)
    local n = #list.view
    list.cursor = math.max(1, math.min(n, list.cursor + delta))
    list_draw()
end

local function show_results(prompt, entries)
    if #entries == 0 then
        mp.osd_message("browse: no results", 3)
        return
    end
    list_close()
    list.entries, list.prompt, list.filter = entries, prompt, ""
    list_filter()
    list.ov = mp.create_osd_overlay("ass-events")
    list.ov.res_y = 720
    local w, h = mp.get_property_number("osd-width", 0), mp.get_property_number("osd-height", 0)
    if h == 0 then w, h = 16, 9 end -- no window yet (idle): assume 16:9
    list.ov.res_x = math.floor(720 * w / h)
    local bind = {
        UP = function() list_move(-1) end,     DOWN = function() list_move(1) end,
        WHEEL_UP = function() list_move(-1) end, WHEEL_DOWN = function() list_move(1) end,
        PGUP = function() list_move(-ROWS) end, PGDWN = function() list_move(ROWS) end,
        HOME = function() list_move(-math.huge) end, END = function() list_move(math.huge) end,
        MBTN_RIGHT = list_close,
        -- Esc clears an active filter first, closes on the second press
        ESC = function()
            if list.filter == "" then return list_close() end
            list.filter = ""
            list_filter()
            list_draw()
        end,
        BS = function()
            local cs = chars(list.filter)
            cs[#cs] = nil
            list.filter = table.concat(cs)
            list_filter()
            list_draw()
        end,
        ENTER = function()
            local row = list.view[list.cursor]
            if not row then return end
            local e = list.entries[row.i]
            local url = e.url or e.webpage_url
            list_close()
            mp.commandv("loadfile", url, "replace")
            mp.osd_message("Loading: " .. (e.title or url), 3)
        end,
    }
    list.keys = {}
    for key, fn in pairs(bind) do
        list.keys[#list.keys + 1] = key
        mp.add_forced_key_binding(key, "browse-" .. key, fn, {repeatable = true})
    end
    -- type to filter (fuzzy). ANY_UNICODE delivers printable text; SPACE is
    -- a named key so it needs its own binding.
    local function type_text(text)
        list.filter = list.filter .. text
        list_filter()
        list_draw()
    end
    list.keys[#list.keys + 1] = "ANY_UNICODE"
    mp.add_forced_key_binding("ANY_UNICODE", "browse-ANY_UNICODE", function(ev)
        if ev.event ~= "up" and ev.key_text and ev.key_text ~= "" then type_text(ev.key_text) end
    end, {complex = true, repeatable = true})
    list.keys[#list.keys + 1] = "SPACE"
    mp.add_forced_key_binding("SPACE", "browse-SPACE", function() type_text(" ") end, {repeatable = true})
    list_draw()
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
