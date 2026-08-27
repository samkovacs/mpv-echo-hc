-- clip_export_echostorm.lua (Echostorm Edition)
--
-- Marks an in/out point during playback and exports that range via
-- ffmpeg.exe (bundled alongside mpv.exe by 1_Full_Latest_MPV_Installer.ps1)
-- as a lossless stream-copy clip -- no re-encoding, so it's fast, but the
-- cut points snap to the nearest keyframe (a stream-copy limitation, not a
-- bug here). For frame-accurate cuts, re-encode the exported clip
-- afterwards in a real editor.
--
-- -ss before -i (fast input seek) + -to after -i (output option, absolute
-- position in the ORIGINAL timeline, not relative to -ss) is ffmpeg's own
-- documented pattern for this -- both mark_in/mark_out below are already
-- absolute time-pos values, so no extra math is needed either way.

local options = {
    save_location = "~~desktop/mpv/clips/",
    ffmpeg_path = "ffmpeg.exe",
}
require "mp.options".read_options(options, "clip_export_echostorm")

local mark_in = nil
local mark_out = nil
local exporting = false

-- Same illegal-character stripping as screenshotfolder_echostorm.lua, for
-- the same reason: Windows silently mangles/rejects these in file names.
local function safe(name)
    return name
        :gsub('[\\/:*?"<>|]', '')
        :gsub('^[%s.]+', '')
        :gsub('[%s.]+$', '')
end

local function fmt_time(t)
    local h = math.floor(t / 3600)
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    return string.format("%02d:%02d:%05.2f", h, m, s)
end

local function reset_marks()
    mark_in = nil
    mark_out = nil
end

local function mark_in_point()
    local t = mp.get_property_number("time-pos")
    if not t then return end
    mark_in = t
    -- Drop a stale out-point that's no longer after the new in-point,
    -- rather than silently exporting an inverted/empty range later.
    if mark_out and mark_out <= mark_in then
        mark_out = nil
    end
    mp.osd_message("Clip start: " .. fmt_time(mark_in), 2)
end

local function mark_out_point()
    local t = mp.get_property_number("time-pos")
    if not t then return end
    if mark_in and t <= mark_in then
        mp.osd_message("Clip end must be after start", 2)
        return
    end
    mark_out = t
    mp.osd_message("Clip end: " .. fmt_time(mark_out), 2)
end

local function clear_marks()
    reset_marks()
    mp.osd_message("Clip marks cleared", 2)
end

local function export_clip()
    if exporting then
        mp.osd_message("Export already in progress", 2)
        return
    end
    if not (mark_in and mark_out) then
        mp.osd_message("Set both clip start and end first", 2)
        return
    end

    local path = mp.get_property("path")
    if not path then
        mp.osd_message("Nothing playing", 2)
        return
    end

    -- Snapshot the marks this export actually uses -- export runs async,
    -- and the user can set new marks (for the next clip) before this one
    -- finishes. The completion callback below must only clear the marks
    -- it exported, not whatever happens to be current by the time it fires.
    local export_in, export_out = mark_in, mark_out

    local title = mp.get_property("filename/no-ext") or "clip"
    local dir = mp.command_native({"expand-path", options.save_location})
    local out_name = string.format("%s_%s-%s.mkv", safe(title),
        fmt_time(export_in):gsub("[:.]", ""), fmt_time(export_out):gsub("[:.]", ""))
    local out_path = dir .. "/" .. out_name

    -- ffmpeg won't create missing output directories itself -- ensure it
    -- exists first. Blocking (not "run"/fire-and-forget): the export below
    -- must not start before this completes, and a local mkdir is fast
    -- enough that this matches the existing blocking-subprocess pattern
    -- already used for the native dialogs in open_file_echostorm.lua.
    mp.command_native({
        name = "subprocess",
        playback_only = false,
        args = {"cmd", "/c", string.format('if not exist "%s" mkdir "%s"', dir, dir)},
    })

    exporting = true
    mp.osd_message("Exporting clip...", 3)

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = false,
        capture_stderr = true,
        args = {
            options.ffmpeg_path, "-y",
            "-ss", fmt_time(export_in),
            "-i", path,
            "-to", fmt_time(export_out),
            "-c", "copy",
            out_path,
        },
    }, function(success, result)
        exporting = false
        if success and result and result.status == 0 then
            mp.osd_message("Clip saved: " .. out_name, 3)
            -- Only clear marks if they still match what THIS export used --
            -- if the user already set new ones while this was in flight,
            -- leave those alone instead of wiping them.
            if mark_in == export_in and mark_out == export_out then
                reset_marks()
            end
        else
            mp.msg.error("ffmpeg export failed: " .. tostring(result and result.stderr))
            mp.osd_message("Clip export failed -- see console/log", 3)
        end
    end)
end

mp.add_key_binding(nil, "clip_mark_in", mark_in_point)
mp.add_key_binding(nil, "clip_mark_out", mark_out_point)
mp.add_key_binding(nil, "clip_export", export_clip)
mp.add_key_binding(nil, "clip_clear_marks", clear_marks)

mp.register_event("file-loaded", reset_marks)
