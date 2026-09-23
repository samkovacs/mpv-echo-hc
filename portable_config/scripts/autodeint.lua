-- This script uses the lavfi idet filter to automatically insert the
-- appropriate deinterlacing filter based on a short section of the
-- currently playing video.
--
-- It registers the key-binding ctrl+d, which when pressed, inserts the filters
-- ``vf=idet,lavfi-pullup,idet``. After 4 seconds, it removes these
-- filters and decides whether the content is progressive, interlaced, or
-- telecined and the interlacing field dominance.
--
-- Based on this information, it may set mpv's ``deinterlace`` property (which
-- usually inserts the bwdif filter), or insert the ``pullup`` filter if the
-- content is telecined.  It also sets field dominance with lavfi setfield.
--
-- OPTIONS:
-- The default detection time may be overridden by adding
--
-- --script-opts=autodeint.detect_seconds=<number of seconds>
--
-- to mpv's arguments. This may be desirable to allow idet more
-- time to collect data.
--
-- To see counts of the various types of frames for each detection phase,
-- the verbosity can be increased with
--
-- --msg-level=autodeint=v

require "mp.msg"

local script_name = mp.get_script_name()
local detect_label = string.format("%s-detect", script_name)
local pullup_label = string.format("%s", script_name)
local dominance_label = string.format("%s-dominance", script_name)
local ivtc_detect_label = string.format("%s-ivtc-detect", script_name)
local timer
local progressive, interlaced_tff, interlaced_bff, interlaced = 0, 1, 2, 3

-- number of seconds to gather cropdetect data
local detect_seconds = tonumber(mp.get_opt(string.format("%s.detect_seconds", script_name)))
if not detect_seconds then
    detect_seconds = 4
end

local function del_filter_if_present(label)
    -- necessary because mp.command('vf del @label:filter') raises an
    -- error if the filter doesn't exist
    local vfs = mp.get_property_native("vf")

    for i,vf in pairs(vfs) do
        if vf["label"] == label then
            table.remove(vfs, i)
            mp.set_property_native("vf", vfs)
            return true
        end
    end
    return false
end

-- Echostorm: "vf pre", not "vf add". Appending put idet/setfield/pullup after
-- vsr_autocrop.lua's @vsr, i.e. on upscaled d3d11 frames, where idet never
-- produced metadata and judge() threw. A label already in the chain is
-- replaced in place, so callers prepend in reverse chain order.
local function add_vf(label, filter)
    return mp.command(('vf pre @%s:%s'):format(label, filter))
end

-- deinterlace as it was before this script first changed it this file, so
-- nothing carries into the next file (mpv.conf also keeps it out of
-- watch_later).
local saved_deinterlace
local function set_deinterlace(v)
    saved_deinterlace = saved_deinterlace or mp.get_property("deinterlace")
    mp.set_property("deinterlace", v)
end

local function stop_detect()
    del_filter_if_present(detect_label)
    del_filter_if_present(ivtc_detect_label)
    timer = nil
end

local function judge(label)
    -- get the metadata
    local result = mp.get_property_native(string.format("vf-metadata/%s", label))
    if not result or not result["lavfi.idet.multiple.tff"] then
        return nil -- no frames reached idet (no video, or the file changed)
    end
    local num_tff          = tonumber(result["lavfi.idet.multiple.tff"])
    local num_bff          = tonumber(result["lavfi.idet.multiple.bff"])
    local num_progressive  = tonumber(result["lavfi.idet.multiple.progressive"])
    local num_undetermined = tonumber(result["lavfi.idet.multiple.undetermined"])
    local num_interlaced   = num_tff + num_bff
    local num_determined   = num_interlaced + num_progressive

    mp.msg.verbose(label.." progressive    = "..num_progressive)
    mp.msg.verbose(label.." interlaced-tff = "..num_tff)
    mp.msg.verbose(label.." interlaced-bff = "..num_bff)
    mp.msg.verbose(label.." undetermined   = "..num_undetermined)

    if num_determined < num_undetermined then
        mp.msg.warn("majority undetermined frames")
    end
    if num_progressive > 20*num_interlaced then
        return progressive
    elseif num_tff > 10*num_bff then
        return interlaced_tff
    elseif num_bff > 10*num_tff then
        return interlaced_bff
    else
        return interlaced
    end
end

local function select_filter()
    -- handle the first detection filter results
    local verdict = judge(detect_label)
    local ivtc_verdict = judge(ivtc_detect_label)
    local dominance = "auto"
    if verdict == nil or ivtc_verdict == nil then
        mp.msg.warn("no frames analysed: doing nothing")
        stop_detect()
        del_filter_if_present(dominance_label)
        del_filter_if_present(pullup_label)
        return
    end
    if verdict == progressive then
        mp.msg.info("progressive: doing nothing")
        stop_detect()
        del_filter_if_present(dominance_label)
        del_filter_if_present(pullup_label)
        return
    else
        if verdict == interlaced_tff then
            dominance = "tff"
            add_vf(dominance_label, 'setfield=mode='..dominance)
        elseif verdict == interlaced_bff then
            dominance = "bff"
            add_vf(dominance_label, 'setfield=mode='..dominance)
        else
            del_filter_if_present(dominance_label)
        end
    end

    -- handle the ivtc detection filter results
    if ivtc_verdict == progressive then
        mp.msg.info(string.format("telecined with %s field dominance: using pullup", dominance))
        stop_detect()
    else
        mp.msg.info("interlaced with " .. dominance ..
                    " field dominance: setting deinterlace property")
        del_filter_if_present(pullup_label)
        set_deinterlace("yes")
        stop_detect()
    end
end

local function start_detect()
    -- exit if detection is already in progress
    if timer then
        mp.msg.warn("already detecting!")
        return
    end

    set_deinterlace("no")
    del_filter_if_present(pullup_label)
    del_filter_if_present(dominance_label)

    -- insert the detection filters (prepended, so in reverse chain order)
    if not (add_vf(ivtc_detect_label, 'idet') and
            add_vf(pullup_label, 'lavfi-pullup') and
            add_vf(dominance_label, 'setfield=mode=auto') and
            add_vf(detect_label, 'idet')) then
        mp.msg.error("failed to insert detection filters")
        return
    end

    -- wait to gather data
    timer = mp.add_timeout(detect_seconds, select_filter)
end

-- Echostorm: per file. A detection still running is cancelled, and the
-- filters and deinterlace setting chosen for this file are undone.
mp.register_event("end-file", function()
    if timer then timer:kill() end
    stop_detect()
    del_filter_if_present(dominance_label)
    del_filter_if_present(pullup_label)
    if saved_deinterlace then
        mp.set_property("deinterlace", saved_deinterlace)
        saved_deinterlace = nil
    end
end)

mp.add_key_binding("ctrl+d", script_name, start_detect)
