-- Regression test: thumbfast on a network video (YouTube, Twitch VOD), run by
-- mpv itself with the real config (needs network):
--   ./mpv.exe --no-resume-playback --save-position-on-quit=no --volume=0 \
--     --script=docs/tests/thumbfast_youtube_test.lua "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
-- Guards two bugs:
-- 1. ytdl_hook's all-formats EDL lists every format (~57 KB); passed as-is it
--    overflowed Windows' 32767-char command line and the thumbnailer never
--    started ("subprocess create failed").
-- 2. vsr_autocrop's video-crop is in the upscaled output frame; forwarded as
--    pixels it did not fit the thumbnailer's raw frame, the thumbnailer kept
--    its old size, and thumbfast misread the file at a wrong width (stripes).
--    Shows up as a thumbnail whose aspect ratio differs from the video's.
-- Pass = a thumbnail exists after the crop settled, and its aspect ratio
-- matches the displayed video's.
local utils = require "mp.utils"
local failed, thumbnail, tw, th = false, nil, nil, nil

mp.enable_messages("error")
mp.register_event("log-message", function(e)
    if e.prefix == "thumbfast" and e.text:find("subprocess create failed") then failed = true end
end)
mp.register_script_message("thumbfast-info", function(json)
    local t = utils.parse_json(json)
    thumbnail, tw, th = t.thumbnail, t.width, t.height
end)

local function finish()
    local rendered = thumbnail ~= nil and utils.file_info(thumbnail .. ".bgra") ~= nil
    local vop = mp.get_property_native("video-out-params") or {}
    local want = vop.dw and vop.dh and vop.dw / vop.dh
    local got = tw and th and tw / th
    local aspect_ok = want and got and math.abs(got - want) / want < 0.03
    if rendered and aspect_ok and not failed then
        print("ALL PASS")
    else
        print(string.format("FAIL rendered=%s create_failed=%s thumb=%sx%s video=%sx%s",
            tostring(rendered), tostring(failed), tostring(tw), tostring(th), tostring(vop.dw), tostring(vop.dh)))
    end
    mp.commandv("quit")
end

local sent = false
mp.observe_property("time-pos", "number", function(_, t)
    if sent or not t or t < 1 then return end
    sent = true
    -- what ModernZ sends on every redraw while the seekbar is hovered:
    -- time, overlay x, overlay y
    local poll = mp.add_periodic_timer(0.25, function()
        mp.commandv("script-message-to", "thumbfast", "thumb", 5, 100, 100)
    end)
    -- vsr_autocrop crops after settle_delay (3 s) + detect_seconds (1 s)
    mp.add_timeout(15, function() poll:kill(); finish() end)
end)
mp.add_timeout(120, finish)
