-- Test for scripts/whichkey.lua, run by mpv itself:
--   mpv --no-config --idle=yes --script=portable_config/scripts/whichkey.lua --script=docs/tests/whichkey_test.lua
-- Binds keys the way input.conf does (keybind), presses them with keypress,
-- and counts which commands ran. Prints PASS/FAIL; exits non-zero on failure.

local failed = 0
local function eq(name, got, want)
    if got == want then
        print("PASS " .. name)
    else
        failed = failed + 1
        print(string.format("FAIL %s  got: %s  want: %s", name, tostring(got), tostring(want)))
    end
end

local ran = {}
mp.register_script_message("ran", function(k) ran[k] = (ran[k] or 0) + 1 end)

mp.commandv("keybind", "t", "script-binding whichkey/show t")
mp.commandv("keybind", "t-x", "script-message ran x", "run x")
mp.commandv("keybind", "t-X", "script-message ran X")
mp.commandv("keybind", "t-x-y", "script-message ran xy") -- deeper sequence: not listed
mp.commandv("keybind", "t-Ctrl+x", "script-message ran cx")
mp.commandv("keybind", "y", "script-message ran y")

local steps = {
    -- prefix, then a listed key: runs once (not again via mpv's own t-x match)
    function() mp.commandv("keypress", "t") end,
    function() mp.commandv("keypress", "x") end,
    function() eq("t x runs x once", ran.x, 1) end,
    -- case is a different key
    function() mp.commandv("keypress", "t") end,
    function() mp.commandv("keypress", "X") end,
    function() eq("t X runs X", ran.X, 1); eq("t X does not run x", ran.x, 1) end,
    -- a named (non-text) key goes through its own forced binding
    function() mp.commandv("keypress", "t") end,
    function() mp.commandv("keypress", "Ctrl+x") end,
    function() eq("t Ctrl+x runs Ctrl+x", ran.cx, 1) end,
    -- Esc closes: the next y is its normal binding, x after it runs nothing
    function() mp.commandv("keypress", "t") end,
    function() mp.commandv("keypress", "ESC") end,
    function() mp.commandv("keypress", "y") end,
    function() eq("after Esc, y is its own binding", ran.y, 1) end,
    -- an unlisted key closes without running its own binding
    function() mp.commandv("keypress", "t") end,
    function() mp.commandv("keypress", "y") end,
    function() mp.commandv("keypress", "x") end,
    function()
        eq("unlisted key closes, does not run", ran.y, 1)
        eq("closed panel: x unbound again", ran.x, 1)
        eq("deeper sequence never ran", ran.xy, nil)
    end,
    function()
        print(failed == 0 and "ALL PASSED" or failed .. " FAILED")
        mp.commandv("quit", failed == 0 and 0 or 1)
    end,
}
local i = 0
local function nxt()
    i = i + 1
    if steps[i] then mp.add_timeout(0.2, function() steps[i](); nxt() end) end
end
mp.add_timeout(0.5, nxt) -- let whichkey.lua register first
