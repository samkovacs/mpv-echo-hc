-- scripts/screenshotfolder_echostorm.lua
-- Cleaned version: no more 1 Hz spam

local options = {
    screenshot_key             = 's',
    file_ext                   = "jpg",
    save_location              = "~~desktop/mpv/screenshots/",
    time_stamp_format          = "%tY-%tm-%td_%tH-%tM-%tS",
    save_as_time_stamp         = true,
    save_based_on_chapter_name = false,
    short_saved_message        = true,
    include_YouTube_ID         = true
}
require "mp.options".read_options(options)

local title       = "default"
local chaptername = ""
local count       = 0
local current_format = options.file_ext

-- Strip characters that are illegal in Windows path/file names.
-- Also strips leading/trailing spaces and dots, which Windows silently
-- mangles or rejects in directory and file names.
local function safe(name)
    return name
        :gsub('[\\/:*?"<>|]', '')
        :gsub('^[%s.]+', '')
        :gsub('[%s.]+$', '')
end

-- Builds and applies directory + template + format to mpv properties
local function set_screenshot_template()
    mp.set_property("screenshot-format", current_format)

    local subdir = options.save_location .. safe(title) .. "/"
    mp.set_property("screenshot-directory", subdir)

    if options.save_as_time_stamp then
        local suffix = (count > 0) and ("(" .. count .. ")") or ""
        if options.save_based_on_chapter_name and chaptername ~= "" then
            mp.set_property("screenshot-template",
                safe(chaptername) .. " (" .. options.time_stamp_format .. ")" .. suffix)
        else
            mp.set_property("screenshot-template",
                options.time_stamp_format .. suffix)
        end
    end
end

-- Called on file load. Uses file-loaded (not start-file) so that media-title,
-- path, and filename are guaranteed to be populated before we read them.
local function init()
    local filename = mp.get_property("filename") or ""
    local name      = mp.get_property("filename/no-ext") or filename
    local media     = mp.get_property("media-title") or name

    -- Check the source filename/URL for the network scheme, not media-title:
    -- media-title is already resolved to the human-readable video title by
    -- the time file-loaded fires (e.g. via ytdl_hook), so it never matches
    -- a URL pattern and this branch would otherwise never trigger.
    if options.include_YouTube_ID and filename:match("^[%w]+://") then
        local vid = filename:match("[?&]v=([^&]+)")
        if vid then media = media .. " [" .. vid .. "]" end
    end
    title = media

    count = 0
    set_screenshot_template()
end

-- Called when you hit the screenshot key
local function screenshot_done()
    mp.commandv("screenshot")
    count = count + 1
    set_screenshot_template()

    if options.short_saved_message then
        mp.osd_message("Screenshot saved", 2)
    else
        -- screenshot-directory already stores a "~~desktop/..." placeholder
        -- (from options.save_location), so expand-path takes it as-is --
        -- prepending another "~~" here previously produced a broken
        -- "~~~~desktop/..." path.
        local dir = mp.command_native({"expand-path", mp.get_property("screenshot-directory") or ""})
        dir = (dir or ""):gsub("\\", "/")
        mp.osd_message("Saved to: " .. dir, 2)
    end
end

-- Update template when chapter changes
mp.observe_property("chapter-metadata/title", "string", function(_, v)
    chaptername = v or ""
    set_screenshot_template()
end)

-- file-loaded is the correct event: fires after the file is fully parsed
-- and all properties (media-title, path, filename) are available.
-- start-file fires too early and was previously registered here in error.
mp.register_event("file-loaded", init)

-- Bind screenshot key
mp.add_key_binding(options.screenshot_key, "screenshot-done", screenshot_done)
