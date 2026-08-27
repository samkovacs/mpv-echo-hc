-- chapterskip.lua
--
-- Ain't Nobody Got Time for That
--
-- This script skips chapters based on their title.

local categories = {
    prologue = "^Prologue/^Intro",
    opening = "^OP/ OP$/^Opening",
    ending = "^ED/ ED$/^Ending",
    preview = "Preview$"
}

local options = {
    enabled = true,
    skip_once = true,
    categories = "",
    skip = ""
}

mp.options = require "mp.options"

function matches(i, title)
    for category in string.gmatch(options.skip, " *([^;]*[^; ]) *") do
        if categories[category:lower()] then
            if string.find(category:lower(), "^idx%-") == nil then
                if title then
                    for pattern in string.gmatch(categories[category:lower()], "([^/]+)") do
                        if string.match(title, pattern) then
                            return true
                        end
                    end
                end
            else
                for pattern in string.gmatch(categories[category:lower()], "([^/]+)") do
                    if tonumber(pattern) == i then
                        return true
                    end
                end
            end
        end
    end
end

local skipped = {}
local parsed = {}

function chapterskip(_, current)
    mp.options.read_options(options, "chapterskip")
    if not options.enabled then return end
    -- current can be nil (property momentarily unavailable, e.g. mid-seek
    -- or on a file with no chapters at all); the arithmetic below assumes
    -- a number, so bail rather than erroring out of this callback.
    if current == nil then return end
    for category in string.gmatch(options.categories, "([^;]+)") do
        local name, patterns = string.match(category, " *([^+>]*[^+> ]) *[+>](.*)")
        if name then
            categories[name:lower()] = patterns
        elseif not parsed[category] then
            mp.msg.warn("Improper category definition: " .. category)
        end
        parsed[category] = true
    end
    local chapters = mp.get_property_native("chapter-list")
    local skip = false
    for i, chapter in ipairs(chapters) do
        if (not options.skip_once or not skipped[i]) and matches(i, chapter.title) then
            if i == current + 1 or skip == i - 1 then
                if skip then
                    skipped[skip] = true
                end
                skip = i
            end
        elseif skip then
            mp.set_property("time-pos", chapter.time)
            skipped[skip] = true
            return
        end
    end
    if skip then
        if mp.get_property_native("playlist-count") == mp.get_property_native("playlist-pos-1") then
            return mp.set_property("time-pos", mp.get_property_native("duration"))
        end
        mp.commandv("playlist-next")
    end
end

-- Echostorm Edition: toggle chapter-skip on/off at runtime. Writes back
-- through script-opts (not just the local table), since chapterskip()
-- above calls read_options() on every chapter change, which would
-- otherwise immediately overwrite an in-memory-only toggle.
local function toggle_enabled()
    local new_state = not options.enabled
    mp.commandv("change-list", "script-opts", "append", "chapterskip-enabled=" .. tostring(new_state))
    options.enabled = new_state
    mp.osd_message("chapterskip: " .. (new_state and "enabled" or "disabled"), 2)
end

mp.add_key_binding(nil, "toggle_enabled", toggle_enabled)

mp.observe_property("chapter", "number", chapterskip)
mp.register_event("file-loaded", function() skipped = {} end)
