-- whichkey.lua: which-key.nvim for mpv. A prefix key opens a panel listing
-- the bindings that continue it (input.conf key sequences "g-p", "b-y"),
-- labelled with their input.conf comment; the next key runs one.
--
--   input.conf:  g  script-binding whichkey/show g
--
-- While open, the listed keys are forced bindings, so they win over mpv's
-- own sequence matching (the command runs once, not twice). Esc or any
-- key not in the list closes it. Colors are browse.lua's Solarized Dark.

local C_KEY   = "009985" -- green  #859900
local C_LABEL = "A1A193" -- base1  #93a1a1
local C_DIM   = "756E58" -- base01 #586e75
local C_BACK  = "362B00" -- base03 #002b36
local ROWS = 8

local ov = mp.create_osd_overlay("ass-events")
ov.z = 1000 -- above the OSC
local keys = {}

local function ass_escape(s)
    return (s:gsub("[\\{}\n]", {["\\"] = "\\\239\187\191", ["{"] = "\\{", ["}"] = "\\}", ["\n"] = " "}))
end

-- The binding mpv would run for each key, as select.lua's Key bindings list
-- resolves it: non-weak over weak (builtin defaults), then higher priority.
local function active_bindings()
    local out = {}
    for _, b in ipairs(mp.get_property_native("input-bindings")) do
        local cur = out[b.key]
        if b.priority >= 0 and not b.section:find("^input_forced_") and b.cmd ~= "ignore" and
           (not cur or (cur.is_weak and not b.is_weak) or
            (b.is_weak == cur.is_weak and b.priority > cur.priority)) then
            out[b.key] = b
        end
    end
    return out
end

local function close()
    ov:remove()
    for _, k in ipairs(keys) do mp.remove_key_binding("whichkey-" .. k) end
    keys = {}
end

local function bind(key, fn, opts)
    keys[#keys + 1] = key
    mp.add_forced_key_binding(key, "whichkey-" .. key, fn, opts)
end

local function draw(prefix, items)
    local W, H = mp.get_property_number("osd-width", 0), mp.get_property_number("osd-height", 0)
    if H == 0 then W, H = 1280, 720 end
    local s = H / 720
    local fs, lh, m = math.floor(20 * s), math.floor(26 * s), math.floor(16 * s)
    local cols = math.ceil(#items / ROWS)
    local rows = math.min(#items, ROWS)
    local cw = math.floor((W - 2 * m) / math.max(cols, 3))
    local max_chars = math.floor(cw / (fs * 0.52)) - 4
    -- top of the window: the bottom belongs to ModernZ and subtitles
    local top, bh = m, (rows + 1) * lh + 2 * m
    local ev = {string.format("{\\an7\\pos(0,0)\\1c&H%s&\\1a&H50&\\bord1\\3c&H%s&\\shad0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                              C_BACK, C_DIM, W, W, bh, bh),
                string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s-  {\\1c&H%s&}Esc close",
                              m, top, fs, C_KEY, ass_escape(prefix), C_DIM)}
    for i, it in ipairs(items) do
        local col, row = math.floor((i - 1) / ROWS), (i - 1) % ROWS
        local label = it.label
        if #label > max_chars then label = label:sub(1, math.max(1, max_chars - 1)) .. "…" end
        ev[#ev + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s  {\\1c&H%s&}%s",
                                    m + col * cw, top + (row + 1) * lh, fs,
                                    C_KEY, ass_escape(it.key), C_LABEL, ass_escape(label))
    end
    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(ev, "\n")
    ov:update()
end

mp.add_key_binding(nil, "show", function(t)
    if t.event == "up" or t.event == "repeat" then return end
    local prefix = t.arg
    if not prefix or prefix == "" then
        return mp.msg.error("usage: script-binding whichkey/show <prefix key>")
    end
    close()
    local items = {}
    for key, b in pairs(active_bindings()) do
        local rest = key:sub(#prefix + 2)
        -- one more key only: "g-p", not "g-p-x"
        if key:sub(1, #prefix + 1) == prefix .. "-" and rest ~= "" and not rest:find(".%-") then
            items[#items + 1] = {key = rest, cmd = b.cmd,
                                 label = b.comment or b.cmd:gsub("^script%-binding ", "")}
        end
    end
    if #items == 0 then return mp.osd_message("whichkey: nothing bound under " .. prefix .. "-", 3) end
    table.sort(items, function(a, b)
        if a.key:lower() ~= b.key:lower() then return a.key:lower() < b.key:lower() end
        return a.key > b.key -- "s" before "S"
    end)
    local by_key = {}
    for _, it in ipairs(items) do
        local function run()
            close()
            mp.command(it.cmd)
        end
        by_key[it.key] = run
        bind(it.key, run)
    end
    bind("ESC", close)
    -- mpv hands text keys to ANY_UNICODE before a same-section "x" binding,
    -- so text keys are dispatched here; any key not listed closes the panel
    bind("ANY_UNICODE", function(ev)
        if ev.event == "up" then return end
        local run = by_key[ev.key_name]
        if run then run() else close() end
    end, {complex = true})
    draw(prefix, items)
end, {complex = true})
