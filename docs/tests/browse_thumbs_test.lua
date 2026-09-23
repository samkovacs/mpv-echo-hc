-- Regression test for browse.lua's grid thumbnail race: every redraw (each
-- cursor move) called ensure_thumb for all 12 tiles, and nothing tracked
-- downloads already in flight, so a page still loading started a curl +
-- ffmpeg pair per tile per keypress, all writing the same .img/.bgra paths.
-- Phase 2: Twitch previews keep one URL for a changing image, so the cached
-- file must be refetched by age (thumb_max_age) and drawn meanwhile.
--
-- Loads the real scripts/browse.lua into this script's Lua state with curl
-- simulated (1 s latency, no network; ffmpeg runs for real), draws a grid,
-- then moves the cursor every 0.2 s while the downloads are in flight.
-- Run from the repo root in Git Bash (TEMP isolates the thumbnail cache):
--   TEMP=$(cygpath -w "$(mktemp -d)") ./mpv.exe --no-config --idle=yes \
--     --script=docs/tests/browse_thumbs_test.lua
-- Prints PASS/FAIL per assertion and exits non-zero on any failure.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local utils = require "mp.utils"

-- A real image for the fake curl to "download".
local src_png = os.getenv("TEMP") .. "\\browse_thumbs_src.png"
mp.command_native({name = "subprocess", playback_only = false, args = {
    mp.command_native({"expand-path", "~~exe_dir/ffmpeg.exe"}), "-v", "error", "-y",
    "-f", "lavfi", "-i", "testsrc2=s=320x180", "-frames:v", "1", src_png}})
local fh = assert(io.open(src_png, "rb"))
local png = fh:read("*a")
fh:close()

local curls = {}      -- url -> number of curl launches
local bad_adds = 0    -- overlay-add of a file that was not complete
local adds = {}       -- overlay id -> gen it was added under

local real_async = mp.command_native_async
mp.command_native_async = function(cmd, cb)
    local a = cmd.args
    if a and a[1] == "curl" then
        local url, out = a[#a], nil
        for i = 1, #a do if a[i] == "-o" then out = a[i + 1] end end
        curls[url] = (curls[url] or 0) + 1
        mp.add_timeout(1, function()
            local f = assert(io.open(out, "wb"))
            f:write(png)
            f:close()
            cb(true, {status = 0, stderr = ""})
        end)
        return
    end
    return real_async(cmd, cb)
end

local list
local real_commandv = mp.commandv
mp.commandv = function(name, ...)
    if name == "overlay-add" then
        local id, _, _, file, _, _, w, h = ...
        local info = utils.file_info(file)
        if not info or info.size ~= w * h * 4 then bad_adds = bad_adds + 1 end
        adds[id] = list.gen
    end
    return real_commandv(name, ...)
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
list = upvalue(list_draw, "list")

local entries, view = {}, {}
for i = 1, 12 do
    entries[i] = {title = "entry " .. i, url = "https://example.invalid/" .. i,
                  thumbnail = "https://example.invalid/thumb" .. i .. ".jpg"}
    view[i] = {i = i, matched = {}}
end
mp.command_native({name = "subprocess", playback_only = false,
                   args = {"cmd", "/c", "mkdir", os.getenv("TEMP") .. "\\mpv-browse-thumbs"}})
list.entries, list.view, list.cursor, list.mode = entries, view, 1, "grid"
list.ov = mp.create_osd_overlay("ass-events")
list_draw()

local moves = 0
local mover
mover = mp.add_periodic_timer(0.2, function()
    moves = moves + 1
    list.cursor = moves % 12 + 1
    list_draw()
    if moves == 4 then mover:kill() end -- last redraw at 0.8 s, downloads still in flight
end)

local failed = 0
local function check(name, cond, got)
    print((cond and "PASS " or "FAIL ") .. name .. (cond and "" or ("  got: " .. tostring(got))))
    if not cond then failed = failed + 1 end
end
local url1, url2 = entries[1].thumbnail, entries[2].thumbnail

mp.add_timeout(4, function()
    local max = 0
    for _, n in pairs(curls) do max = math.max(max, n) end
    check("each thumbnail downloaded once despite 4 redraws in flight", max == 1, max)
    local current = 0
    for id = 1, 12 do if adds[id] == list.gen then current = current + 1 end end
    check("all 12 tiles drawn for the final redraw", current == 12, current)

    -- Phase 2: live previews (Twitch) keep one URL, so the cached file is
    -- refreshed by age. The thumbnails are ~3 s old here.
    entries[1].thumb_max_age = 1    -- stale
    entries[2].thumb_max_age = 3600 -- fresh
    list_draw()
    check("stale thumbnail still drawn at once while refreshing", adds[1] == list.gen, adds[1])
end)

mp.add_timeout(6.5, function()
    check("stale live thumbnail re-downloaded", curls[url1] == 2, curls[url1])
    check("fresh live thumbnail not re-downloaded", curls[url2] == 1, curls[url2])
    check("refreshed thumbnail drawn for the current redraw", adds[1] == list.gen, adds[1])
    check("no overlay-add of an incomplete .bgra", bad_adds == 0, bad_adds)
    print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
    mp.command(failed == 0 and "quit 0" or "quit 1")
end)
