-- stream_quality_echostorm.lua (Echostorm Edition)
--
-- Bumps ytdl-format's quality cap up/down mid-stream and reloads at the
-- current position, for YouTube/Twitch/Kick (or whatever domains
-- ytdlautoformat.lua is configured for). ytdl-format is only read by
-- yt-dlp at file-load time -- there's no way to just "ask for a different
-- quality" on an already-open stream -- so this sets the override and
-- reloads, the same way the existing "Reload stream" menu entry already
-- does for stalls (set file-local-options/start + playlist-play-index).
--
-- Relies on ytdlautoformat.lua's own respect_manual_changes/
-- external_override tracking (its ytdl-format property observer) to
-- recognize this as a manual change and not immediately overwrite it back
-- to its own static quality cap on the reload this script triggers.

local options = {
    -- Quality ladder to step through, low to high. Matches
    -- ytdlautoformat.conf's own accepted height values.
    ladder = "360,480,720,1080,1440,2160",
}
require "mp.options".read_options(options, "stream_quality_echostorm")

local levels = {}
for level in string.gmatch(options.ladder, "([^,]+)") do
    local n = tonumber(level:match("^%s*(.-)%s*$"))
    if n then levels[#levels + 1] = n end
end
table.sort(levels)

local function is_stream()
    local path = mp.get_property("path", "")
    return path:match("^%a[%a%d+.-]*://") ~= nil
end

-- Reads the height cap out of whatever ytdl-format is currently active
-- (whether set by ytdlautoformat.lua or by this script previously) so
-- repeated up/down presses step from the actual current level.
local function current_index()
    local current = mp.get_property("ytdl-format") or ""
    -- yt-dlp's own filter syntax is "height<=?N" -- that "?" is a literal
    -- character (an "optional field" marker in yt-dlp's own comparator),
    -- not a Lua pattern quantifier. Left unescaped, it silently breaks the
    -- match against every ytdl-format string this codebase ever actually
    -- produces (both this script's own set_quality() and
    -- ytdlautoformat.lua both write "height<=?N"), so current_index()
    -- always returned nil in practice. %?? matches that literal "?" if
    -- present, but tolerates its absence too.
    local height = tonumber(current:match("height<=%??(%d+)"))
    for i, level in ipairs(levels) do
        if level == height then return i end
    end
    return nil
end

local function set_quality(index)
    if #levels == 0 then return end
    index = math.max(1, math.min(#levels, index))
    local height = levels[index]

    -- Skip the reload entirely if this wouldn't actually change anything
    -- (e.g. already at the top rung and the user presses "up" again) --
    -- otherwise this would still reload at the same quality for no reason.
    local current_height = tonumber((mp.get_property("ytdl-format") or ""):match("height<=%??(%d+)"))
    if current_height == height then
        mp.osd_message("Already at " .. height .. "p", 2)
        return
    end

    mp.set_property("file-local-options/ytdl-format", "bv[height<=?" .. height .. "]+ba/b")
    mp.set_property("file-local-options/start", tostring(mp.get_property_number("time-pos") or 0))
    mp.commandv("playlist-play-index", "current", "yes")
    mp.osd_message("Stream quality: " .. height .. "p (reloading...)", 2)
end

local function bump(direction)
    if not is_stream() then
        mp.osd_message("Not a network stream", 2)
        return
    end
    -- No recognized current level (e.g. ytdlautoformat's quality=0, a
    -- "best"/unset format, or a site it doesn't cover at all) -- default
    -- to the top of the ladder as the starting point, since an uncapped
    -- format is effectively already "highest". Gives "down" an immediate
    -- first step instead of "up" needing to climb from the bottom rung.
    local idx = current_index() or #levels
    set_quality(idx + direction)
end

mp.add_key_binding(nil, "stream_quality_up", function() bump(1) end)
mp.add_key_binding(nil, "stream_quality_down", function() bump(-1) end)
