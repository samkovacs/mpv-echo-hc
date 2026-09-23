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
    -- decoder time to settle so video-params/pixelformat and the frame
    -- dimensions read reliable values. This delay is intentional -- do not
    -- remove it.
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
    -- mpv-display-plugin (see hdr-mode.lua, configured hdr_mode=pass in
    -- script-opts/hdr_mode.conf -- note the UNDERSCORE, mpv derives that
    -- filename from the script name "hdr_mode" and silently ignores a
    -- hyphenated one -- which passes HDR through rather than switching it
    -- live, so there's no race with this script's once-per-file check).
    -- mpv's own nvidia-true-hdr filter has no display-state check built in and
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
    sample = nil,
    crop_confirm = nil,
    retry = nil,
}

-- Seconds to wait after each failed detection before trying again. These
-- are gaps BETWEEN attempts, not offsets from the start of the file, so
-- the passes land at roughly 4s / 20s / 65s / 185s -- spread across the
-- film rather than bunched at the front. A single 1-second sample
-- taken settle_delay into the file lands inside the studio logo, the
-- distributor card or the fade-in from black on a large share of feature
-- films, and cropdetect over an all-black window returns a degenerate
-- rectangle (measured: -1918x-1078+1920+1080 on a 1920x1080 source). That
-- gets rejected below, and without a retry the file then plays letterboxed
-- to the end -- the exact thing this script exists to prevent, failing
-- silently because suppress_osd hides the only diagnostic.
--
-- Retries stop at the first usable crop, so a film that detects correctly
-- on the first attempt pays nothing.
local retry_delays = {15, 45, 120}

local applying       = false  -- guard against re-entrant trigger from vf changes
local vsr_was_applied = false -- tracks whether @vsr is currently in the chain
local crop_watcher    = nil   -- pending video-out-params/w observer fn, if any
local crop_attempt    = 0     -- how many detections have run for this file

-- Signature of the state apply_combined() last actually put in place, so a
-- re-evaluation reaching the same conclusion can return without touching
-- the filter chain. Removing and re-appending @vsr forces a VO reconfig,
-- which is visible; a genuinely 16:9 film runs the whole retry schedule
-- finding no bars each time, and without this every one of those attempts
-- would tear the filter down and rebuild it identically mid-playback.
--
-- Declared up here, not next to apply_combined(): clear_all() is defined
-- earlier in the file and has to reset it, and a local declared below that
-- point would leave clear_all()'s assignment writing to a global instead.
local last_applied    = nil

-- Forward declaration: finish_detection() schedules a retry through
-- begin_evaluation(), which is defined further down. Without this the
-- name inside that closure would compile as a global lookup and be nil at
-- call time.
local begin_evaluation

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
-- Re-keying the profile on video-out-params does NOT work: the profile then
-- set d3d11-output-format, forcing a VO reconfig that nulls
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
    -- the profile applied by profile-cond; [SDR] undoes it on the next file.
    --
    -- This list must mirror exactly what [HDR] in profiles.conf sets, and
    -- nothing else. target-trc/-prim/-peak/-contrast/-colorspace-hint used
    -- to be reset here too; they now belong to hdr-mode.lua, which restores
    -- them itself when video-out-params drops back below the HDR threshold.
    -- Forcing them to "auto" from here would just be a second writer
    -- clobbering the owner -- the situation this split exists to end.
    --
    -- Verified that hdr-mode.lua does cover the RTX Video HDR case: with
    -- nvidia-true-hdr active on an SDR source, video-out-params reports
    -- gamma=pq primaries=bt.2020 max-luma=1000, which is above its >203
    -- test, so apply_hdr_settings() runs and the render target comes out
    -- trc=pq prim=bt.2020 peak=603 contrast=inf hint=yes.
    for _, o in ipairs({"sub-hdr-peak", "dither-depth",
                        "hdr-compute-peak", "video-output-levels"}) do
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
    kill_timer("sample")
    kill_timer("crop_confirm")
    kill_timer("retry")
    unwatch_crop_confirm()
    -- Reset here rather than in on_file_loaded: clear_all() is also the
    -- end-file handler and the manual-toggle reset path, and a retry
    -- schedule left over from the previous file would otherwise fire
    -- against this one.
    crop_attempt = 0
    -- Must be cleared with the rest of the state: a new file that happens
    -- to produce the same scale/crop signature as the previous one would
    -- otherwise hit apply_combined's no-change short-circuit and never get
    -- its @vsr filter inserted at all.
    last_applied = nil

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
    -- video-params/hw-pixelformat is always nil here: hwdec=d3d11va-copy
    -- copies every decoded frame back to system RAM, so mpv reports the
    -- software format and the hw one stays unset (measured: nv12 for 8-bit
    -- H.264, p010 for 10-bit HEVC, hw-pixelformat nil for both). Reading it
    -- first was dead code.
    local pixfmt = mp.get_property_native("video-params/pixelformat")

    -- @vsr is NOT removed here. The teardown is deferred until after the
    -- no-change check below, so a re-evaluation that reaches the same
    -- conclusion leaves the existing filter untouched instead of rebuilding
    -- it identically.

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
    --
    -- The ratio is used exactly as computed. It used to be rounded DOWN to
    -- the nearest 0.1, which cost up to 12.6% of the picture on this setup:
    --
    --   display     content              exact  floored  VSR out    ideal
    --   3440x1440   1080p 1.85 cropped   1.390    1.3   2496x1346  2668x1440
    --   3440x1440   1080p 2.39 cropped   1.791    1.7   3264x1366  3438x1440
    --   3440x1440   1080p 16:9           1.333    1.3   2496x1404  2560x1440
    --
    -- Whatever VSR left undersized was then made up by mpv's own
    -- scale=ewa_lanczossharp -- i.e. VSR's output getting re-upscaled by a
    -- conventional scaler, precisely the softening the min() reasoning
    -- above exists to avoid. The 0.1 grid bought nothing either: d3d11vpp
    -- takes arbitrary float scales (verified: scale=1.791 on 1280x720
    -- produces 2292x1290 with "NVIDIA RTX Super Resolution enabled").
    local scale = nil
    if content_width and content_height and display_width and display_height
       and content_width > 0 and content_height > 0 then
        scale = math.min(display_width  / content_width,
                         display_height / content_height)
    end

    -- VSR upscaling: NVIDIA's d3d11vpp path handles 10-bit as happily as
    -- 8-bit. Verified on this GPU -- feeding it p010 logs "NVIDIA RTX Super
    -- Resolution enabled" exactly as nv12 does. The previous gate allowed
    -- only nv12/yuv420p, which silently excluded every 10-bit source:
    -- modern HEVC/AV1 web releases, most current anime encodes, all HDR.
    local vsr_supported_pixfmt =
        pixfmt == "nv12"  or pixfmt == "yuv420p" or
        pixfmt == "p010"  or pixfmt == "p016"    or
        pixfmt == "yuv420p10"

    -- RTX Video HDR is an SDR->HDR conversion, so it has to gate on the
    -- source actually being SDR. That is a transfer-function question, not
    -- a bit-depth one -- the old test conflated the two, rejecting 10-bit
    -- bt.709/bt.1886 encodes (which are SDR and valid input) purely for
    -- being 10-bit.
    local gamma = mp.get_property_native("video-params/gamma")
    local source_is_sdr = gamma ~= "pq" and gamma ~= "hlg"

    -- Guard with an epsilon: a ratio of 1.0001 (content already at display
    -- size, off by a rounding step) is not worth a filter insert, and
    -- inserting @vsr at scale~=1 costs a full d3d11vpp pass for nothing.
    --
    -- A GLSL shader chain takes precedence over VSR. d3d11vpp runs before
    -- the VO, so libplacebo sees VSR's output as the source; every upscaler
    -- in shaders/ is gated on OUTPUT > LUMA (//!WHEN) and silently no-ops
    -- once VSR has already scaled to display size. Stacking is impossible,
    -- so whichever the user (or a profile) selected via glsl-shaders wins.
    local shaders_active = (mp.get_property("glsl-shaders") or "") ~= ""
    local upscale_wanted = scale and scale > 1.01 and not shaders_active
    local hdr_wanted = options.nvidia_true_hdr and source_is_sdr and
        vsr_supported_pixfmt and
        mp.get_property_native("user-data/display-info/hdr-status") == "on"

    -- No-change short-circuit. Scale is quantised to 4 decimals here only
    -- for comparison, matching the %.4f actually handed to the filter, so
    -- float noise below what was applied cannot count as a difference.
    local signature = string.format("%s|%.4f|%s|%s|%s",
        crop_meta and (crop_meta.w .. "x" .. crop_meta.h .. "+" ..
                       crop_meta.x .. "+" .. crop_meta.y) or "nocrop",
        scale or 0, tostring(upscale_wanted), tostring(hdr_wanted),
        tostring(pixfmt))
    if last_applied == signature and (mp.get_property("vf") or ""):find("@vsr") then
        applying = false
        return
    end

    local vf_current = mp.get_property("vf") or ""
    if vf_current:find("@vsr") then
        mp.command("vf remove @vsr")
    end
    vsr_was_applied = false
    last_applied = signature

    local vsr_applied_now = false
    local hdr_applied_now = false
    if upscale_wanted or hdr_wanted then
        if vsr_supported_pixfmt then
            -- scale=1 (no resize) is used whenever upscaling itself isn't
            -- wanted -- content already at/above display resolution, or
            -- this insert is for HDR-only reasons. `scale` can be a real
            -- sub-1 value here (content larger than the display/window),
            -- and using it unguarded would silently downscale the frame
            -- as a side effect of an HDR-only apply -- gate on
            -- upscale_wanted explicitly rather than just nil-checking.
            --
            -- %.4f, not tostring(): Lua would render the float in whatever
            -- form %.14g picks, which for some ratios is exponent notation
            -- ("1e+00") that the filter's option parser does not accept.
            local filter = string.format("@vsr:d3d11vpp:scaling-mode=nvidia:scale=%.4f",
                                         upscale_wanted and scale or 1)
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
            -- Two decimals: the scale is no longer quantised to 0.1, so
            -- concatenating the raw float would put "1.7909090909091x" on
            -- the OSD.
            if vsr_applied_now then
                table.insert(parts, string.format("%.2fx upscale", scale))
            end
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
-- Union of the valid cropdetect rectangles sampled during this detection.
local crop_union = nil

-- cropdetect (reset=N) reports the bounds since its last reset, which may be
-- only a frame or two old at any single read -- so a detection samples it
-- every 0.1 s across its window and keeps the union of the valid readings.
local function sample_cropdetect()
    local m = mp.get_property_native("vf-metadata/" .. cropdetect_label)
    local w = m and tonumber(m["lavfi.cropdetect.w"])
    local h = m and tonumber(m["lavfi.cropdetect.h"])
    local x = m and tonumber(m["lavfi.cropdetect.x"])
    local y = m and tonumber(m["lavfi.cropdetect.y"])
    if not (w and h and x and y and w > 0 and h > 0 and x >= 0 and y >= 0) then return end
    if not crop_union then
        crop_union = {x1 = x, y1 = y, x2 = x + w, y2 = y + h}
    else
        crop_union.x1, crop_union.y1 = math.min(crop_union.x1, x), math.min(crop_union.y1, y)
        crop_union.x2, crop_union.y2 = math.max(crop_union.x2, x + w), math.max(crop_union.y2, y + h)
    end
end

local function finish_detection()
    sample_cropdetect()
    kill_timer("sample")
    kill_timer("detect_crop")
    -- cropdetect stays in the chain for the rest of the file (clear_all()
    -- removes it): inserting or removing a filter once @vsr is in the chain
    -- rebuilds it and drops a frame ("pin disconnect"), which every retry
    -- on a bar-less film used to pay twice.
    local metadata = nil
    if crop_union then
        metadata = {
            ["lavfi.cropdetect.w"] = crop_union.x2 - crop_union.x1,
            ["lavfi.cropdetect.h"] = crop_union.y2 - crop_union.y1,
            ["lavfi.cropdetect.x"] = crop_union.x1,
            ["lavfi.cropdetect.y"] = crop_union.y1,
        }
    end

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

        -- Positive-dimension check first, and on its own. cropdetect over
        -- an all-black sample window returns a degenerate rectangle with
        -- NEGATIVE width/height (measured on a 1920x1080 source whose first
        -- five seconds are black: w=-1918 h=-1078 x=1920 y=1080). The
        -- min-ratio test below happens to reject that too, but only by
        -- accident of -1918 being less than half of 1920 -- which makes
        -- detect_min_ratio load-bearing for correctness while
        -- vsr_autocrop.conf presents it as a taste knob. Tune that option
        -- toward 0 and a negative rectangle would reach set_scaled_crop().
        local is_valid = w and h and x and y and w > 0 and h > 0
                         and x >= 0 and y >= 0
        local is_effective = is_valid and
            (x > 0 or y > 0 or w < raw_width or h < raw_height)
        local is_excessive = is_effective and
            (w < raw_width * options.detect_min_ratio or h < raw_height * options.detect_min_ratio)

        if is_effective and not is_excessive then
            crop_meta = { w = w, h = h, x = x, y = y }
        elseif not is_valid then
            mp.msg.info("cropdetect returned a degenerate rectangle "
                .. "(sample window was probably all black).")
        elseif is_excessive then
            mp.msg.info("Crop area too large, skipping (try lowering detect_min_ratio).")
        end
    else
        mp.msg.info("No usable cropdetect reading (window all black, or the filter is missing).")
    end

    -- Apply now regardless: VSR should not wait on a crop retry, and if a
    -- later attempt does find bars, apply_combined() re-inserts @vsr with
    -- the corrected scale anyway.
    apply_combined(crop_meta)

    -- Nothing usable this time -- try again later in the file, where the
    -- picture is more likely to be representative than it was during the
    -- opening titles. Note this also retries the "no bars detected" case:
    -- a film that opens on a full-frame studio logo before settling into
    -- 2.39:1 reports an entirely legitimate-looking "no crop needed" on
    -- the first pass, and that is exactly the case worth re-checking.
    if not crop_meta and options.auto_crop then
        crop_attempt = crop_attempt + 1
        local delay = retry_delays[crop_attempt]
        if delay then
            kill_timer("retry")
            timers.retry = mp.add_timeout(delay, function()
                timers.retry = nil
                mp.msg.info(string.format("re-running crop detection (attempt %d of %d)",
                                          crop_attempt + 1, #retry_delays + 1))
                begin_evaluation()
            end)
        else
            mp.msg.info("crop detection gave up after "
                .. (#retry_delays + 1) .. " attempts; playing uncropped.")
        end
    end
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

    -- Inserted once per file (before @vsr exists on the first attempt, so
    -- free) and left in; retries reuse it. reset=N: bounds restart every
    -- detection-window of frames, so a full-frame studio logo early on does
    -- not pin the union to full frame for the rest of the film.
    local present = false
    for _, f in ipairs(mp.get_property_native("vf") or {}) do
        if f.label == cropdetect_label then present = true end
    end
    if not present then
        local fps = mp.get_property_number("container-fps") or 24
        mp.command(string.format(
            "%s vf pre @%s:cropdetect=limit=%s:round=%d:reset=%d",
            command_prefix, cropdetect_label, options.detect_limit, options.detect_round,
            math.max(1, math.floor(fps * options.detect_seconds + 0.5))
        ))
    end

    crop_union = nil
    timers.sample = mp.add_periodic_timer(0.1, sample_cropdetect)
    timers.detect_crop = mp.add_timeout(options.detect_seconds, finish_detection)
end

-- Assigns the forward-declared local above; must not re-introduce `local`
-- here or finish_detection()'s reference would still see nil.
function begin_evaluation()
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

-- Re-evaluate when the window moves to a different display. Both the VSR
-- scale factor and the crop rectangle derived from it are computed from
-- display-width/display-height, and were previously read exactly once per
-- file. This machine drives 3440x1440, 2560x1440 and 1920x1080 panels, and
-- the fit-aware min() above gives materially different answers on each:
-- 1080p 2.39:1 content wants 1.79x on the ultrawide and 1.33x on the
-- 2560x1440. Dragging the window mid-film previously kept the old display's
-- scale and a crop rectangle computed against it.
--
-- schedule_evaluation() routes through settle_delay, which also debounces
-- the burst of property changes a drag between monitors produces.
mp.observe_property("display-width", "native", schedule_evaluation)
mp.observe_property("display-height", "native", schedule_evaluation)

-- Re-evaluate when a shader profile is switched mid-file (shaders and @vsr
-- are mutually exclusive, see apply_combined).
mp.observe_property("glsl-shaders", "native", schedule_evaluation)

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
