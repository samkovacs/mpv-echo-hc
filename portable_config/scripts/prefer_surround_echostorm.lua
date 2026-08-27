-- prefer_surround_echostorm.lua (Echostorm Edition)
--
-- mpv's own --aid=auto has no channel-count preference: it selects
-- whichever track is flagged "default" in the container, tie-breaking
-- to track order when that's ambiguous (per mpv's own manual: "The
-- track selection options... sometimes expose behavior that may appear
-- strange"). Confirmed via mpv.log: a file with both an mp3 2ch track
-- and an ac3 6ch track, BOTH flagged default, auto-selected the 2ch one.
--
-- On every file load, selects whichever audio track reports the
-- highest channel count -- but ONLY among tracks sharing the same
-- language as whatever mpv's own --alang-based selection already
-- landed on, so a foreign-language track with more channels never
-- silently overrides your language preference (mpv.conf's own
-- alang=eng,en,und,auto). mpv resolves alang before file-loaded fires,
-- so this piggybacks on that resolved choice rather than re-implementing
-- alang's matching logic itself. Only acts once per file (at
-- file-loaded); manual track switches mid-playback are left alone.

local options = {
    enabled = true,
}

require "mp.options".read_options(options, "prefer_surround_echostorm")

local function pick_best_audio_track()
    if not options.enabled then return end

    local current_aid = mp.get_property_native("aid")
    if current_aid == false then return end -- audio explicitly disabled, leave it off

    local tracks = mp.get_property_native("track-list")
    if not tracks then return end

    local current_lang = nil
    for _, track in ipairs(tracks) do
        if track.type == "audio" and track.id == current_aid then
            current_lang = track.lang
            break
        end
    end

    local best_id, best_channels = current_aid, 0
    for _, track in ipairs(tracks) do
        -- track.lang == current_lang also groups untagged tracks
        -- together correctly, since nil == nil is true in Lua.
        if track.type == "audio" and track.lang == current_lang then
            local ch = track["demux-channel-count"] or 0
            if ch > best_channels then
                best_channels = ch
                best_id = track.id
            end
        end
    end

    if best_id ~= current_aid then
        mp.set_property_native("aid", best_id)
        mp.msg.info("Selected audio track " .. best_id .. " (" .. best_channels ..
            " channels, same language as mpv's default pick)")
    end
end

mp.register_event("file-loaded", pick_best_audio_track)
