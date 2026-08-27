-- vsr_autocrop.lua (Echostorm Edition)
--
-- Applies NVIDIA VSR (d3d11vpp) upscaling when the video resolution is below
-- the display resolution and the pixel format is hardware-decoded. Also
-- detects and crops black bars (folded in from mpv core's autocrop.lua),
-- because the two features can't be two independent scripts.
--
-- Why crop detection lives here instead of in a separate autocrop.lua:
-- video-crop is applied by the VO *after* the entire vf chain runs
-- (verified against mpv's own source, player/video.c's apply_video_crop()).
-- cropdetect measures the crop rectangle against the RAW decoded frame, but
-- if @vsr has already upscaled that frame by the time video-crop reaches
-- the VO, the crop rectangle no longer matches the frame it's being
-- applied to -- it's in the wrong coordinate space entirely, not just
-- "slightly off". No amount of timing/ordering between two separate
-- scripts fixes that; the crop rectangle itself has to be scaled by
-- whatever factor VSR applies. That requires one script owning both.
--
-- Flow per file: wait <settle_delay> (decoder/pixel-format settle) -> run
-- cropdetect for <detect_seconds> -> compute VSR's scale factor from the
-- CROPPED content size -> apply @vsr at that scale -> set video-crop
-- using the detected rectangle scaled by that same factor (so it lines
-- up with the frame @vsr actually outputs, not the raw decoded one).
--
-- Requires hwdec=d3d11va-copy in mpv.conf (not plain d3d11va). cropdetect
-- is a plain software filter and can't read a GPU-resident D3D11 surface
-- directly -- copy-back mode makes every decoded frame land in system RAM
-- automatically, which cropdetect can read with no special handling.
-- @vsr (d3d11vpp) still works fine on a copied-back frame: per mpv's own
-- filter docs, "software frames are automatically uploaded to hardware
-- for processing", so it re-uploads whatever it's given regardless.
--
-- This used to instead toggle hwdec off/on around cropdetect (matching
-- upstream autocrop.lua, which has to support hwdec setups without a
-- copy-back mode available). That toggle caused a real, severe bug here:
-- restoring hwdec is a genuine hardware reinit that isn't guaranteed to
-- settle synchronously, and if a change notification from OUR OWN
-- restore landed after we'd already re-armed the observer watching for
-- it, it re-triggered the whole flow, toggling hwdec again, forever --
-- and rapid D3D11 device churn from that loop caused a full Windows
-- BSOD during testing. Since this build's whole premise is an NVIDIA
-- RTX card with VSR enabled, hwdec=d3d11va-copy is always available
-- here, so the toggle isn't needed at all -- removing it removes that
-- entire bug class at the root instead of patching around it.

local options = {
    -- Seconds after file-loaded before doing anything at all. Gives the
    -- decoder time to settle so video-params/hw-pixelformat reads a
    -- reliable value. This delay is intentional -- do not remove it.
    settle_delay = 3,

    -- Whether to auto-detect and crop black bars. VSR upscaling still
    -- works with this off, just without cropping first.
    auto_crop = true,

    -- Black threshold for cropdetect. Smaller values generally crop less.
    -- See limit: https://ffmpeg.org/ffmpeg-filters.html#cropdetect
    detect_limit = "24/255",
    -- The value which width/height should be divisible by. Smaller values
    -- have better detection accuracy.
    detect_round = 2,
    -- The ratio of the minimum clip size to the original (0 to 1). If the
    -- picture is over-cropped, try raising this.
    detect_min_ratio = 0.5,
    -- How long (seconds) to gather cropdetect data after settle_delay.
    detect_seconds = 1,

    -- Whether to suppress the OSD message when crop/VSR are applied.
    suppress_osd = false,

    -- Whether to also request NVIDIA RTX Video HDR (SDR->HDR enhancement)
    -- from the same d3d11vpp filter used for VSR upscaling. Requires mpv
    -- 0.40+ (d3d11vpp's nvidia-true-hdr suboption) and RTX Video HDR
    -- enabled in the NVIDIA app. Off by default -- this only ever engages
    -- when the display is confirmed already in HDR mode via the companion
    -- mpv-display-plugin (see hdr-mode.lua, whose own default hdr_mode=pass
    -- already assumes HDR is passed through rather than switched live, so
    -- there's no race with this script's own once-per-file check). mpv's
    -- own nvidia-true-hdr filter has no display-state check built in and
    -- visibly misbehaves (wrong colors) if applied on an SDR display --
    -- https://github.com/mpv-player/mpv/issues/17800 -- so this script
    -- does that gating itself rather than trusting the filter to.
    nvidia_true_hdr = false,
}

require "mp.options".read_options(options, "vsr_autocrop")

local cropdetect_label = mp.get_script_name() .. "-cropdetect"
local command_prefix = options.suppress_osd and "no-osd" or ""

local timers = {
    settle = nil,
    detect_crop = nil,
    crop_confirm = nil,
}

local applying       = false  -- guard against re-entrant trigger from vf changes
local vsr_was_applied = false -- tracks whether @vsr is currently in the chain
local crop_watcher    = nil   -- pending video-out-params/w observer fn, if any

local function unwatch_crop_confirm()
    if crop_watcher then
        mp.unobserve_property(crop_watcher)
        crop_watcher = nil
    end
end

local function kill_timer(key)
    if timers[key] then
        timers[key]:kill()
        timers[key] = nil
    end
end

local function remove_cropdetect()
    local vf = mp.get_property_native("vf") or {}
    for _, filter in pairs(vf) do
        if filter.label == cropdetect_label then
            mp.command(string.format("%s vf remove @%s", command_prefix, filter.label))
            return
        end
    end
end

-- RTX Video HDR (nvidia-true-hdr) converts SDR->HDR inside the d3d11vpp
-- filter. That changes video-out-params (bt.1886/bt.709 -> pq/bt.2020) but
-- NOT video-params, which is what the [HDR] profile in profiles.conf keys
-- on -- so that profile never fires for this content and the render target
-- is left at target-peak=auto / target-contrast=auto / image-subs-hdr-peak
-- =1000 while mpv is emitting a PQ signal.
--
-- Re-keying the profile on video-out-params does NOT work: the profile sets
-- d3d11-output-format and dither-depth, forcing a VO reconfig that nulls
-- video-out-params, un-firing the condition -- measured flapping between pq
-- and nil every ~1.5s. So it is applied from here instead, where we know
-- deterministically and exactly once whether true-HDR was turned on.
local hdr_profile_applied = false

local function apply_hdr_profile()
    if hdr_profile_applied then return end
    hdr_profile_applied = true
    mp.command("apply-profile HDR")
    mp.msg.info("applied [HDR] profile for RTX Video HDR output")
end

local function restore_hdr_profile()
    if not hdr_profile_applied then return end
    hdr_profile_applied = false
    -- Only meaningful for SDR sources we converted. A natively-HDR file has
    -- the profile applied by profile-cond, which does its own restore.
    for _, o in ipairs({"target-trc", "target-prim", "target-peak",
                        "target-contrast", "sub-hdr-peak", "dither-depth",
                        "d3d11-output-format", "d3d11-output-csp",
                        "hdr-compute-peak", "target-colorspace-hint",
                        "video-output-levels"}) do
        mp.commandv("set", o, "auto")
    end
    -- image-subs-hdr-peak has no "auto": its choices are sdr/video/
    -- video-static/video-dynamic or an integer, and its default is 1000.
    -- Setting "auto" here silently no-ops and strands it at "sdr".
    mp.commandv("set", "image-subs-hdr-peak", "1000")
    mp.msg.info("restored render target after RTX Video HDR")
end

local function clear_all()
    -- Strip any existing @vsr filter and video-crop immediately (not
    -- after a delay), so a new file isn't briefly shown through a filter
    -- or crop rectangle computed for the previous one.
    applying = true

    remove_cropdetect()
    kill_timer("settle")
    kill_timer("detect_crop")
    kill_timer("crop_confirm")
    unwatch_crop_confirm()

    local vf_current = mp.get_property("vf") or ""
    if vf_current:find("@vsr") then
        mp.command("vf remove @vsr")
    end
    vsr_was_applied = false

    if mp.get_property("video-crop") ~= "" then
        mp.command(string.format("%s set file-local-options/video-crop ''", command_prefix))
    end

    restore_hdr_profile()

    applying = false
end

local function is_cropable(time_needed)
    if mp.get_property_native("current-tracks/video/image") ~= false then
        return false
    end
    local playtime_remaining = mp.get_property_native("playtime-remaining")
    return playtime_remaining and (time_needed + 1) < playtime_remaining
end

local function set_scaled_crop(crop_meta, factor)
    local cw = math.floor(crop_meta.w * factor)
    local ch = math.floor(crop_meta.h * factor)
    local cx = math.floor(crop_meta.x * factor)
    local cy = math.floor(crop_meta.y * factor)
    mp.command(string.format("%s set file-local-options/video-crop %dx%d+%d+%d",
                              command_prefix, cw, ch, cx, cy))
end

-- Computes VSR's scale factor for the given content dimensions, applies
-- @vsr if warranted, and sets video-crop (if crop_meta is valid) using
-- coordinates scaled to match whatever @vsr actually outputs.
local function apply_combined(crop_meta)
    applying = true

    local display_width  = mp.get_property_native("display-width")
    local display_height = mp.get_property_native("display-height")
    local raw_width       = mp.get_property_native("width")
    local raw_height      = mp.get_property_native("height")
    local pixfmt = mp.get_property_native("video-params/hw-pixelformat")
               or mp.get_property_native("video-params/pixelformat")

    local vf_current = mp.get_property("vf") or ""
    if vf_current:find("@vsr") then
        mp.command("vf remove @vsr")
    end
    vsr_was_applied = false

    -- Use the cropped content size for the scale decision when we have a
    -- valid crop; otherwise fall back to the raw decoded size.
    local content_width  = (crop_meta and crop_meta.w) or raw_width
    local content_height = (crop_meta and crop_meta.h) or raw_height

    -- Fit-aware scale factor: mpv letterboxes/pillarboxes content to fit the
    -- display, so the factor that actually reaches the screen is whichever
    -- axis runs out first -- i.e. the MINIMUM of the two ratios, not the
    -- maximum of the raw dimensions.
    --
    -- The old form (max(display_w,display_h) / max(content_w,content_h)) always
    -- picked display WIDTH on a 21:9 panel. On 3440x1440 that made 16:9 sources
    -- overshoot badly: 1280x720 -> scale 2.6 -> 3328x1872, which mpv then had
    -- to DOWNSCALE to 2560x1440 to fit by height. That burned ~1.7x the VSR
    -- cost and pushed VSR's output back through dscale, softening it.
    --
    -- min() is correct for both orientations: 16:9 content on a 21:9 panel is
    -- height-limited, while genuinely 2.39:1 content (or 16:9 content after
    -- autocrop strips letterbox bars) is width-limited and still picks width.
    local scale = nil
    if content_width and content_height and display_width and display_height
       and content_width > 0 and content_height > 0 then
        scale = math.min(display_width  / content_width,
                         display_height / content_height)
        scale = math.floor(scale * 10) / 10  -- round down to nearest 0.1
    end

    -- p010/p016 (10-bit HW decode) and other formats are excluded here --
    -- NVIDIA VSR support for 10-bit is inconsistent, and RTX Video HDR is
    -- an SDR->HDR enhancement, so an already-HDR (10-bit) source is out of
    -- scope for both anyway.
    local is_sdr_pixfmt  = (pixfmt == "nv12" or pixfmt == "yuv420p")
    local upscale_wanted = scale and scale > 1
    local hdr_wanted = options.nvidia_true_hdr and is_sdr_pixfmt and
        mp.get_property_native("user-data/display-info/hdr-status") == "on"

    local vsr_applied_now = false
    local hdr_applied_now = false
    if upscale_wanted or hdr_wanted then
        if is_sdr_pixfmt then
            -- scale=1 (no resize) is used whenever upscaling itself isn't
            -- wanted -- content already at/above display resolution, or
            -- this insert is for HDR-only reasons. `scale` can be a real
            -- sub-1 value here (content larger than the display/window),
            -- and using it unguarded would silently downscale the frame
            -- as a side effect of an HDR-only apply -- gate on
            -- upscale_wanted explicitly rather than just nil-checking.
            local filter = "@vsr:d3d11vpp:scaling-mode=nvidia:scale=" .. (upscale_wanted and scale or 1)
            if hdr_wanted then
                -- x2bgr10: a 10-bit output format is required to actually
                -- carry the enhanced range out of the filter.
                filter = filter .. ":format=x2bgr10:nvidia-true-hdr"
            end
            -- Check success before trusting VSR/HDR was actually applied --
            -- otherwise a failed insert (unsupported GPU, driver hiccup)
            -- still marks vsr_was_applied=true, and the vf observer
            -- below would then re-trigger a full re-evaluation on every
            -- unrelated filter toggle for the rest of the file, since
            -- each retry fails the same way.
            if mp.command("vf append " .. filter) then
                vsr_applied_now = upscale_wanted
                hdr_applied_now = hdr_wanted
                vsr_was_applied = true
                if hdr_wanted then apply_hdr_profile() end
            else
                mp.msg.warn("Failed to apply @vsr filter (unsupported GPU/driver?)")
            end
        else
            mp.msg.info("VSR/HDR skipped: unsupported pixel format " .. tostring(pixfmt))
        end
    end

    local function report(cropped)
        if vsr_applied_now or hdr_applied_now then
            local parts = {}
            if vsr_applied_now then table.insert(parts, scale .. "x upscale") end
            if hdr_applied_now then table.insert(parts, "RTX HDR") end
            mp.osd_message("NVIDIA " .. table.concat(parts, " + ")
                .. (cropped and " (cropped)" or ""), 2)
        end
    end

    if crop_meta and vsr_applied_now then
        -- @vsr's filter-graph reconfiguration isn't synchronous with the
        -- `vf append` call above -- the pipeline is still emitting the
        -- OLD (pre-upscale) frame size for a beat after we insert the
        -- filter. Confirmed by testing: setting the scaled video-crop
        -- immediately here got it validated against the stale size and
        -- silently discarded by mpv ("Ignoring invalid --video-crop=...
        -- for 1920x1080 image" while @vsr was scaling to 3840x2160).
        -- video-out-params reflects dimensions AFTER the filter chain
        -- runs, so wait for it to actually change before setting the
        -- crop, instead of guessing a delay.
        -- Tracked via crop_watcher/timers.crop_confirm (not local-only)
        -- so clear_all() can cancel both if a new file loads while this
        -- wait is still pending -- otherwise a stale observer/timer from
        -- THIS file could fire later against the NEXT file's state,
        -- setting a wrong crop rectangle or clobbering `applying`.
        local pre_scale_out_w = mp.get_property_native("video-out-params/w")
        crop_watcher = function(_, new_w)
            if not new_w or new_w == pre_scale_out_w then return end
            unwatch_crop_confirm()
            kill_timer("crop_confirm")
            set_scaled_crop(crop_meta, scale)
            applying = false
            report(true)
        end
        mp.observe_property("video-out-params/w", "native", crop_watcher)
        -- Fallback in case video-out-params never changes for some reason
        -- (e.g. the VO doesn't reconfigure as expected) -- don't leave
        -- the observer or `applying` dangling forever.
        timers.crop_confirm = mp.add_timeout(2, function()
            timers.crop_confirm = nil
            unwatch_crop_confirm()
            mp.msg.warn("video-out-params never confirmed the @vsr resize; leaving crop unset")
            applying = false
            report(false)
        end)
    elseif crop_meta then
        -- No @vsr resize happening, so the frame size isn't changing --
        -- safe to set the (unscaled) crop immediately.
        set_scaled_crop(crop_meta, 1)
        applying = false
        report(true)
    else
        if mp.get_property("video-crop") ~= "" then
            mp.command(string.format("%s set file-local-options/video-crop ''", command_prefix))
        end
        applying = false
        report(false)
    end
end

-- Reads cropdetect's vf-metadata, validates it (mirrors mpv core's
-- autocrop.lua checks), and hands off to apply_combined().
local function finish_detection()
    local metadata = mp.get_property_native("vf-metadata/" .. cropdetect_label)
    remove_cropdetect()
    kill_timer("detect_crop")

    local raw_width  = mp.get_property_native("width")
    local raw_height = mp.get_property_native("height")

    -- raw_width/raw_height can be nil here if the video track changed or
    -- disappeared during the ~1s detection window (e.g. the vid observer
    -- fired mid-detection) -- guard before using them in arithmetic below,
    -- or a nil-arithmetic error here would abort before apply_combined()
    -- runs, leaving `applying` stuck true for the rest of the file.
    local crop_meta = nil
    if not (raw_width and raw_height) then
        mp.msg.warn("No video dimensions (track changed mid-detection?), skipping crop.")
    elseif metadata and metadata["lavfi.cropdetect.w"] then
        local w = tonumber(metadata["lavfi.cropdetect.w"])
        local h = tonumber(metadata["lavfi.cropdetect.h"])
        local x = tonumber(metadata["lavfi.cropdetect.x"])
        local y = tonumber(metadata["lavfi.cropdetect.y"])

        local is_effective = w and h and x and y and
            (x > 0 or y > 0 or w < raw_width or h < raw_height)
        local is_excessive = is_effective and
            (w < raw_width * options.detect_min_ratio or h < raw_height * options.detect_min_ratio)

        if is_effective and not is_excessive then
            crop_meta = { w = w, h = h, x = x, y = y }
        elseif is_excessive then
            mp.msg.info("Crop area too large, skipping (try lowering detect_min_ratio).")
        end
    else
        mp.msg.warn("No cropdetect data -- was the filter inserted successfully?")
    end

    apply_combined(crop_meta)
end

-- Inserts the cropdetect filter and starts the detection timer. No hwdec
-- handling needed here -- hwdec=d3d11va-copy (required in mpv.conf) means
-- every decoded frame already lands in system RAM, which the plain
-- cropdetect filter can read directly.
--
-- Sets `applying` for this function's entire duration through
-- finish_detection()/apply_combined() (not just the final apply step),
-- since the vf-remove calls in between would otherwise spuriously
-- re-trigger the vf observer mid-flight via our own changes, not an
-- external one.
local function start_detection()
    applying = true

    if not is_cropable(options.detect_seconds) then
        apply_combined(nil)
        return
    end

    mp.command(string.format(
        "%s vf pre @%s:cropdetect=limit=%s:round=%d:reset=0",
        command_prefix, cropdetect_label, options.detect_limit, options.detect_round
    ))

    timers.detect_crop = mp.add_timeout(options.detect_seconds, finish_detection)
end

local function begin_evaluation()
    if applying then return end

    if options.auto_crop then
        start_detection()
    else
        apply_combined(nil)
    end
end

-- Routes through the settle delay every time, not just on file-loaded --
-- e.g. the vid observer below could in principle fire close to file-load
-- time too. Calling begin_evaluation() directly from a trigger like that
-- would bypass the delay entirely (the same "evaluated too early" bug
-- this script exists to fix for crop, just via a different trigger).
local function schedule_evaluation()
    if applying then return end
    kill_timer("settle")
    timers.settle = mp.add_timeout(options.settle_delay, function()
        timers.settle = nil
        begin_evaluation()
    end)
end

local function on_file_loaded()
    clear_all()
    schedule_evaluation()
end

-- Manual toggle: "c" (autocrop.lua's own default key, taken over since
-- this script replaces it). If crop or VSR is currently active, clears
-- both; otherwise runs detection immediately (no settle delay -- this is
-- an explicit user action well into playback, hwdec is already stable).
local function on_toggle()
    kill_timer("settle")
    if mp.get_property("video-crop") ~= "" or vsr_was_applied then
        clear_all()
        return
    end
    if timers.detect_crop then
        mp.msg.warn("Already detecting crop!")
        return
    end
    begin_evaluation()
end

-- Toggles whether crop-detection runs automatically on file load. VSR
-- upscaling itself is unaffected -- it just runs against the raw
-- (uncropped) frame size when this is off.
local function toggle_auto_crop()
    options.auto_crop = not options.auto_crop
    mp.osd_message("auto-crop " .. (options.auto_crop and "enabled" or "disabled"), 2)
end

-- Toggles NVIDIA RTX Video HDR enhancement. Takes effect on the next
-- crop/VSR evaluation (next file load, or the manual "c" toggle) -- same
-- lazy-apply convention as toggle_auto_crop above, rather than forcing an
-- immediate re-evaluation of the current file.
local function toggle_nvidia_true_hdr()
    options.nvidia_true_hdr = not options.nvidia_true_hdr
    mp.osd_message("NVIDIA RTX HDR " .. (options.nvidia_true_hdr and "enabled" or "disabled"), 2)
end

mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.add_key_binding(nil, "toggle_auto_crop", toggle_auto_crop)
mp.add_key_binding(nil, "toggle_nvidia_true_hdr", toggle_nvidia_true_hdr)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", clear_all)

-- Re-evaluate on video track switch mid-file (a different track can have
-- a different resolution).
mp.observe_property("vid", "native", schedule_evaluation)

-- Re-apply if vf chain is externally cleared (e.g. user runs 'vf clr')
-- but NOT when we're the ones changing it, and NOT on videos where VSR
-- was never applied (avoids spurious reschedules on deband toggle etc.)
mp.observe_property("vf", "native", function()
    if applying then return end
    local vf_current = mp.get_property("vf") or ""
    if vsr_was_applied and not vf_current:find("@vsr") then
        schedule_evaluation()
    end
end)
