-- Copyright (c) 2025 dyphire <qimoge@gmail.com>
-- License: MIT
-- link: https://github.com/dyphire/mpv-scripts
-- Automatically switches the display's SDR and HDR modes for HDR passthrough
-- based on the content of the video being played by the mpv, only works on Windows 10 and later systems

--! Required for use with mpv-display-plugin: https://github.com/dyphire/mpv-display-plugin

local msg = require 'mp.msg'
local utils = require 'mp.utils'
local options = require 'mp.options'

local o = {
    -- Specify the script working mode, value: noth, pass, switch. default: noth
    -- noth: Do nothing
    -- pass: Passing HDR signals for HDR content when the monitor is in HDR mode
    -- switch: Automatically switch between HDR displays and SDR displays
    -- on Windows 10 and later based on video specifications
    hdr_mode = "noth",
    -- Specify whether to switch HDR mode only when the window is in fullscreen or window maximized
    -- only works with hdr_mode = "switch", default: false
    fullscreen_only = false,
     -- Specify the target peak of the HDR display, default: 0
    -- By default, the display peak information property provided by mpv-display-plugin 
    -- will be used: "user-data/display-info/max-luminance"
    -- Specific values can also be specified to override internal detection,
    -- but it must be the true peak brightness of the monitor,
    target_peak = "0",
    -- Specifies the measured contrast of the output display.
    -- Used in black point compensation during HDR tone-mapping and HDR passthrough.
    -- Must be the true contrast information of the display, e.g. 100000 means 100000:1 maximum contrast
    -- The default value auto will try to use the display black level attribute provided 
    -- by mpv-display-plugin to calculate the correct value: "user-data/display-info/min-luminance"
    -- OLED displays can specify the special value "inf" to apply infinite contrast
    target_contrast = "auto",
}
options.read_options(o, _, function() end)

local hdr_active = false
local hdr_supported = false
local first_switch_check = true
local file_loaded = false

local state = {
    icc_profile = mp.get_property_native("icc-profile"),
    icc_profile_auto = mp.get_property_native("icc-profile-auto"),
    target_peak = mp.get_property_native("target-peak"),
    target_prim = mp.get_property_native("target-prim"),
    target_trc = mp.get_property_native("target-trc"),
    -- "target-contrast", not "target_contrast". mpv property names use
    -- hyphens; the underscore form does not exist, so this read returned
    -- nil and every restore path below (apply_sdr_settings,
    -- reset_target_settings, effective_contrast's fallback) was handing
    -- nil to set_property_native instead of the pre-playback value.
    target_contrast = mp.get_property_native("target-contrast"),
    colorspace_hint = mp.get_property_native("target-colorspace-hint"),
    inverse_mapping = mp.get_property_native("inverse-tone-mapping")
}

local function is_protocol(path)
    return type(path) == 'string' and (path:find('^%a[%w.+-]-://') ~= nil or path:find('^%a[%w.+-]-:%?') ~= nil)
end

local function query_hdr_state()
    hdr_supported = mp.get_property_native("user-data/display-info/hdr-supported")
    hdr_active = mp.get_property_native("user-data/display-info/hdr-status") == "on"
end

local function switch_display_mode(enable)
    if enable == hdr_active then return end
    local arg = enable and "on" or "off"
    mp.commandv('script-message', 'toggle-hdr-display', arg)
end

-- Peak/contrast for the display mpv is CURRENTLY on, recomputed on every
-- call rather than cached.
--
-- These used to be resolved once and assigned back into o.target_peak /
-- o.target_contrast. That latched them permanently: once o.target_peak
-- held a detected value it was > 203, so the "detect it" branch could
-- never run again; once o.target_contrast was no longer the literal
-- string "auto", its branch could never run again either. mpv-display-
-- plugin does push fresh max-luminance/min-luminance when the window
-- moves to a different monitor (switch_hdr is wired to
-- user-data/display-info/hdr-status), but every one of those updates was
-- discarded. On a machine with three displays of different peak and
-- black level that meant whichever monitor mpv started on set the tone-
-- mapping target for the rest of the session.
--
-- Keeping them as pure functions of current plugin state is what makes
-- the values track the display. Do not hoist the results into `o`.
local function effective_peak()
    -- An explicit peak in hdr_mode.conf still wins, matching the original
    -- semantics: only a configured value of <= 203 (i.e. the default "0",
    -- or a nonsense one) defers to detection.
    local configured = tonumber(o.target_peak) or 0
    if configured > 203 then return configured end
    local detected = tonumber(mp.get_property_native("user-data/display-info/max-luminance"))
    if detected and detected > 203 then return math.floor(detected) end
    return 203
end

local function effective_contrast(peak)
    if o.target_contrast ~= "auto" then return o.target_contrast end
    local min_luma = tonumber(mp.get_property_native("user-data/display-info/min-luminance"))
    if peak > 203 and min_luma then
        -- A measured black level of exactly 0 is how an OLED reports; any
        -- finite ratio would be wrong, and dividing by it would error.
        if min_luma == 0 then return "inf" end
        return math.floor(peak / min_luma)
    end
    return state.target_contrast
end

-- inverse: true for an SDR source being expanded to the HDR display via
-- libplacebo's inverse tone mapping (mpv.conf sets inverse-tone-mapping=yes;
-- this is what state.inverse_mapping records). The render target is the
-- same HDR target either way; only the mapping direction differs.
local function apply_hdr_settings(inverse)
    local peak = effective_peak()
    mp.set_property_native("icc-profile", "")
    mp.set_property_native("icc-profile-auto", false)
    mp.set_property_native("target-prim", "bt.2020")
    mp.set_property_native("target-trc", "pq")
    mp.set_property_native("target-peak", peak)
    mp.set_property_native("target-contrast", effective_contrast(peak))
    mp.set_property_native("target-colorspace-hint", "yes")
    mp.set_property_native("inverse-tone-mapping", inverse and "yes" or "no")
end

local function apply_sdr_settings()
    mp.set_property_native("icc-profile", state.icc_profile)
    mp.set_property_native("icc-profile-auto", state.icc_profile_auto)
    mp.set_property_native("target-peak", "203")
    mp.set_property_native("target-contrast", state.target_contrast)
    mp.set_property_native("target-colorspace-hint", "no")
    if state.target_prim ~= "bt.2020" then
        mp.set_property_native("target-prim", state.target_prim)
    else
        mp.set_property_native("target-prim", "auto")
    end
    if state.target_trc ~= "pq" then
        mp.set_property_native("target-trc", state.target_trc)
    else
        mp.set_property_native("target-trc", "auto")
    end
end

local function reset_target_settings()
    mp.set_property_native("target-peak", state.target_peak)
    mp.set_property_native("target-prim", state.target_prim)
    mp.set_property_native("target-trc", state.target_trc)
    mp.set_property_native("target-contrast", state.target_contrast)
    mp.set_property_native("target-colorspace-hint", state.colorspace_hint)
    mp.set_property_native("inverse-tone-mapping", state.inverse_mapping)
end

local function pause_if_needed()
    local paused = mp.get_property_native("pause")
    if not paused then
        mp.set_property_native("pause", true)
        return true
    end
    return false
end

local function resume_if_needed(paused_before)
    if paused_before then
        mp.add_timeout(1, function()
            mp.set_property_native("pause", false)
        end)
    end
end

local function handle_hdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if hdr_active then
        apply_hdr_settings()
        resume_if_needed(paused_before)
    elseif (tonumber(target_peak) ~= 203 or target_prim == "bt.2020" or
        target_trc == "pq") then
        apply_sdr_settings()
    end
end

local function handle_sdr_logic(paused_before, target_peak, target_prim, target_trc)
    query_hdr_state()
    if not hdr_active then
        if not state.inverse_mapping and (tonumber(target_peak) ~= 203 or
            target_prim == "bt.2020" or target_trc == "pq") then
            apply_sdr_settings()
        elseif state.inverse_mapping then
            reset_target_settings()
        end
        resume_if_needed(paused_before)
    elseif o.hdr_mode == "pass" and state.inverse_mapping then
        -- SDR source, display in HDR mode, inverse-tone-mapping=yes in
        -- mpv.conf: point the render target at this display's measured
        -- peak so libplacebo expands SDR into it. Safe to key on: target-*
        -- changes do not alter video-out-params (only filters do), so the
        -- "sdr" branch stays stable and check_paramet's is_hdr stays false.
        apply_hdr_settings(true)
    end
end

local function should_switch_hdr(hdr_active, is_fullscreen)
    if o.hdr_mode ~= "switch" then return false end
    if not hdr_active and (not o.fullscreen_only or is_fullscreen) then
        return true
    elseif hdr_active and o.fullscreen_only and not is_fullscreen then
        return true
    end
    return false
end

local function switch_hdr()
    query_hdr_state()
    local path = mp.get_property("path")
    local params = mp.get_property_native("video-out-params")
    local gamma = params and params["gamma"]
    local max_luma = params and params["max-luma"]
    local is_hdr = max_luma and max_luma > 203
    if not path or not gamma then return end

    -- Peak/contrast resolution used to happen here, writing its results
    -- back into `o` and latching them for the session. It now lives in
    -- effective_peak()/effective_contrast(), evaluated at the point of
    -- use so a move to another monitor picks up that monitor's values.

    local current_state = is_hdr and "hdr" or "sdr"
    local pause_changed = false
    local fullscreen = mp.get_property_native("fullscreen")
    local maximized = mp.get_property_native("window-maximized")
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local is_fullscreen = fullscreen or maximized

    -- effective_peak(), not tonumber(o.target_peak): o is no longer
    -- mutated, so with the default target_peak=0 the old test would be
    -- permanently false and the entire HDR branch unreachable.
    if current_state == "hdr" and effective_peak() > 203 then
        local function continue_hdr()
            local time = mp.get_property_number("time-pos")
            local paused = mp.get_property_native("pause")
            if time > 0 and not is_protocol(path) then
                mp.commandv("frame-back-step")
                if not paused then
                    pause_changed = true
                end
            end
            handle_hdr_logic(pause_changed, target_peak, target_prim, target_trc)
        end

        if first_switch_check and o.fullscreen_only and not is_fullscreen then
            first_switch_check = false
        elseif should_switch_hdr(hdr_active, is_fullscreen) then
            pause_changed = pause_if_needed()
            if hdr_active and o.fullscreen_only and not is_fullscreen then
                msg.info("Switching to SDR output...")
                switch_display_mode(false)
            else
                msg.info("Switching to HDR output...")
                switch_display_mode(true)
            end
            mp.add_timeout(3, continue_hdr)
            return
        end

        handle_hdr_logic(false, target_peak, target_prim, target_trc)
    elseif current_state == "sdr" then
        local function continue_sdr()
            local time = mp.get_property_native("time-pos")
            local paused = mp.get_property_native("pause")
            if time > 0 and not is_protocol(path) then
                mp.commandv("frame-back-step")
                if not paused then
                    pause_changed = true
                end
            end
            handle_sdr_logic(pause_changed, target_peak, target_prim, target_trc)
        end

        if hdr_active and o.hdr_mode == "switch" and (not o.fullscreen_only or is_fullscreen) then
            msg.info("Switching back to SDR output...")
            pause_changed = pause_if_needed()
            switch_display_mode(false)
            mp.add_timeout(3, continue_sdr)
            return
        end

        handle_sdr_logic(false, target_peak, target_prim, target_trc)
    end
end

local function check_paramet()
    query_hdr_state()
    local target_peak = mp.get_property_native("target-peak")
    local target_prim = mp.get_property_native("target-prim")
    local target_trc = mp.get_property_native("target-trc")
    local target_contrast = mp.get_property_native("target-contrast")
    local colorspace_hint = mp.get_property_native("target-colorspace-hint")
    local inverse_mapping = mp.get_property_native("inverse-tone-mapping")
    local params = mp.get_property_native("video-out-params")
    local gamma = params and params["gamma"]
    local max_luma = params and params["max-luma"]
    local is_hdr = max_luma and max_luma > 203
    if not gamma then return end

    local peak = effective_peak()
    if is_hdr and hdr_active and o.hdr_mode ~= "noth" and peak > 203 then
        local contrast = effective_contrast(peak)
        if target_peak ~= peak then
            mp.set_property_native("target-peak", peak)
        end
        if target_contrast ~= contrast then
            mp.set_property_native("target-contrast", contrast)
        end
        if target_prim ~= "bt.2020" then
            mp.set_property_native("target-prim", "bt.2020")
        end
        if target_trc ~= "pq" then
            mp.set_property_native("target-trc", "pq")
        end
        if colorspace_hint ~= "yes" then
            mp.set_property_native("target-colorspace-hint", "yes")
        end
        if inverse_mapping then
            mp.set_property_native("inverse-tone-mapping", "no")
        end
    end
end

local function on_start()
    if o.hdr_mode == "noth" then
        return
    end
    local vo = mp.get_property("vo")
    if vo and vo ~= "gpu-next" then
        msg.warn("The current video output is not supported, please use gpu-next")
        return
    end
    file_loaded = true
    query_hdr_state()
    mp.observe_property("video-out-params", "native", switch_hdr)
    mp.observe_property("target-peak", "native", check_paramet)
    mp.observe_property("target-prim", "native", check_paramet)
    mp.observe_property("target-trc", "native", check_paramet)
    mp.observe_property("target-contrast", "native", check_paramet)
    mp.observe_property("target-colorspace-hint", "native", check_paramet)
    mp.observe_property("user-data/display-info/hdr-status", "native", switch_hdr)
    if o.fullscreen_only then
        mp.observe_property("fullscreen", "native", switch_hdr)
        mp.observe_property("window-maximized", "native", switch_hdr)
    end
end

local function on_end(event)
    query_hdr_state()
    first_switch_check = true
    mp.unobserve_property(switch_hdr)
    mp.unobserve_property(check_paramet)
    if event["reason"] == "quit" and o.hdr_mode == "switch" then
        if hdr_active then
            msg.info("Restoring display to SDR on shutdown")
            switch_display_mode(false)
        end
    end
end

local function on_idle(_, active)
    if active and file_loaded and o.hdr_mode == "switch" then
        file_loaded = false
        query_hdr_state()
        if hdr_active then
            msg.info("Restoring display to SDR on shutdown")
            switch_display_mode(false)
        end
    end
end

-- Echostorm Edition: cycle hdr_mode noth -> switch -> pass -> noth at
-- runtime. o.hdr_mode is read live throughout this script (not cached),
-- so this takes effect immediately, no restart needed. switch/pass are
-- no-ops without the companion mpv-display-plugin installed.
local hdr_mode_cycle = { noth = "switch", switch = "pass", pass = "noth" }
local function cycle_mode()
    o.hdr_mode = hdr_mode_cycle[o.hdr_mode] or "noth"
    mp.osd_message("hdr-mode: " .. o.hdr_mode, 2)
end

mp.add_key_binding(nil, "cycle_mode", cycle_mode)

mp.register_event("start-file", on_start)
mp.register_event("end-file", on_end)
mp.observe_property("idle-active", "native", on_idle)
