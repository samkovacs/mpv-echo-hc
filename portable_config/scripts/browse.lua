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

local feeds = {
    {"youtube-subscriptions", "Subscriptions", ":ytsubs"},
    {"youtube-history",       "History",       ":ythistory"},
    {"youtube-watch-later",   "Watch later",   ":ytwatchlater"},
    {"youtube-home",          "Home",          ":ytrec"},
}
for _, f in ipairs(feeds) do
    mp.add_key_binding(nil, f[1], function() fetch("YouTube " .. f[2], f[3]) end)
end
