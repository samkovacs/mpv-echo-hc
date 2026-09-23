-- Regression test for scripts/autodeint.lua against the real config:
--   1. its filters (idet, setfield, pullup) must sit BEFORE @vsr, not be
--      appended after it onto already-upscaled d3d11 frames;
--   2. what it set (deinterlace, setfield) must not carry into the next file;
--   3. a detection cut short by a file change must not throw when its timer
--      fires on the next file (vf-metadata is gone), leaving its filters and
--      the "already detecting!" state behind.
-- Needs the 480i and progressive gradient clips from docs/testing.md, and a
-- window larger than the clip so vsr_autocrop inserts @vsr:
--   ./mpv.exe --window-scale=2 --volume=0 --no-resume-playback \
--     --save-position-on-quit=no --script-opts-append=autoload-disabled=yes \
--     --script-opts-append=autodeint.detect_seconds=2 \
--     --script=docs/tests/autodeint_test.lua int480i.mkv prog480.mkv
-- Prints PASS/FAIL per assertion and exits non-zero on any failure.

local failed = 0
local function check(name, cond, got)
    print((cond and "PASS " or "FAIL ") .. name .. (cond and "" or ("  got: " .. tostring(got))))
    if not cond then failed = failed + 1 end
end

local function labels()
    local out = {}
    for i, f in ipairs(mp.get_property_native("vf")) do out[i] = f.label or f.name end
    return out
end
local function pos(ls, label)
    for i, l in ipairs(ls) do if l == label then return i end end
end
local function autodeint_filters(ls)
    local n = 0
    for _, l in ipairs(ls) do if l:find("autodeint", 1, true) == 1 then n = n + 1 end end
    return n
end
local function detect() mp.command("script-binding autodeint/autodeint") end

local file = 0
mp.register_event("file-loaded", function()
    file = file + 1
    if file == 1 then
        -- interlaced: wait for vsr_autocrop's @vsr, then detect
        local waited = 0
        local poll
        poll = mp.add_periodic_timer(0.25, function()
            waited = waited + 0.25
            if not pos(labels(), "vsr") and waited < 12 then return end
            poll:kill()
            check("@vsr present before detection", pos(labels(), "vsr") ~= nil, table.concat(labels(), ","))
            detect()
            mp.add_timeout(0.3, function()
                local ls = labels()
                local vsr = pos(ls, "vsr")
                local ok = vsr ~= nil
                for i, l in ipairs(ls) do
                    if l:find("autodeint", 1, true) == 1 and vsr and i > vsr then ok = false end
                end
                check("detection filters inserted before @vsr", ok, table.concat(ls, ","))
            end)
            mp.add_timeout(3, function()
                check("interlaced clip detected: deinterlace=yes",
                      mp.get_property("deinterlace") == "yes", mp.get_property("deinterlace"))
                -- start another detection, then change file before it ends
                detect()
                mp.add_timeout(0.3, function() mp.command("playlist-next") end)
            end)
        end)
    elseif file == 2 then
        mp.add_timeout(0.3, function()
            local ls = labels()
            check("deinterlace reset on the next file", mp.get_property("deinterlace") == "no",
                  mp.get_property("deinterlace"))
            check("no autodeint filters carried into the next file", autodeint_filters(ls) == 0,
                  table.concat(ls, ","))
        end)
        -- after the interrupted detection's timer would have fired
        mp.add_timeout(3, function()
            check("interrupted detection left no filters", autodeint_filters(labels()) == 0,
                  table.concat(labels(), ","))
            detect() -- must start: not stuck in "already detecting!"
            mp.add_timeout(0.3, function()
                check("a new detection starts after the interrupted one", autodeint_filters(labels()) > 0,
                      table.concat(labels(), ","))
            end)
            mp.add_timeout(3, function()
                check("progressive clip: deinterlace stays no", mp.get_property("deinterlace") == "no",
                      mp.get_property("deinterlace"))
                check("progressive clip: filters removed", autodeint_filters(labels()) == 0,
                      table.concat(labels(), ","))
                print(failed == 0 and "ALL PASS" or (failed .. " FAILED"))
                mp.command(failed == 0 and "quit 0" or "quit 1")
            end)
        end)
    end
end)
