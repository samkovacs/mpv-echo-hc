-- Regression test: thumbfast on a YouTube video, run by mpv itself with the
-- real config (needs network):
--   ./mpv.exe --no-resume-playback --save-position-on-quit=no --volume=0 \
--     --script=docs/tests/thumbfast_youtube_test.lua "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
-- ytdl_hook's all-formats EDL lists every format (~57 KB); passed as-is it
-- overflowed Windows' 32767-char command line and the thumbnailer never started.
-- Pass = thumbfast wrote a thumbnail (<thumbnail>.bgra) for a hover request.
local utils = require "mp.utils"
local failed, thumbnail = false, nil

mp.enable_messages("error")
mp.register_event("log-message", function(e)
    if e.prefix == "thumbfast" and e.text:find("subprocess create failed") then failed = true end
end)
mp.register_script_message("thumbfast-info", function(json)
    thumbnail = utils.parse_json(json).thumbnail
end)

local function rendered()
    return thumbnail ~= nil and utils.file_info(thumbnail .. ".bgra") ~= nil
end

local function finish()
    if rendered() and not failed then
        print("ALL PASS")
    else
        print(string.format("FAIL rendered=%s create_failed=%s", tostring(rendered()), tostring(failed)))
    end
    mp.commandv("quit")
end

local sent = false
mp.observe_property("time-pos", "number", function(_, t)
    if sent or not t or t < 1 then return end
    sent = true
    local deadline = mp.get_time() + 20
    local poll
    poll = mp.add_periodic_timer(0.25, function()
        -- what ModernZ sends on every redraw while the seekbar is hovered:
        -- time, overlay x, overlay y
        mp.commandv("script-message-to", "thumbfast", "thumb", 5, 100, 100)
        if rendered() or failed or mp.get_time() > deadline then poll:kill(); finish() end
    end)
end)
mp.add_timeout(90, finish)
