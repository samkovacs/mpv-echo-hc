-- browse.lua: search YouTube, Twitch and a user-configured torrent index
-- from inside mpv, using the builtin console (mp.input) for text entry and
-- the same select menu that select.lua's History / Watch later entries use.
--
-- YouTube goes through yt-dlp. Cookies come from mpv's own ytdl-raw-options
-- (mpv.conf), so there is one place to configure auth. Torrents come from
-- the RSS feeds in script-opts/browse.conf and play through the vendored
-- webtorrent-mpv-hook (scripts/webtorrent.js) in memory mode.
--
-- Bindings (input.conf / menu.conf):
--   browse/youtube-search          prompt for a query, list results
--   browse/youtube-subscriptions   :ytsubs
--   browse/youtube-history         :ythistory
--   browse/youtube-watch-later     :ytwatchlater
--   browse/youtube-home            :ytrec
--   browse/twitch-search           prompt for a query, list live channels
--   browse/twitch-live             live status of script-opts twitch_channels
--   browse/torrent-search          prompt for a query, list releases
--   browse/torrent-new             newest releases on the index
--   browse/torrent-followed        releases of script-opts torrent_shows
--
-- Results show as a list or a 4x3 thumbnail grid (script-opts view=list|grid,
-- Tab toggles while open). Type to fuzzy-filter, Enter loads, Esc closes.
-- Mouse: hover focuses a row/tile, left click loads it, wheel scrolls.

local utils = require "mp.utils"
local input = require "mp.input"
-- mpv's require path is ~~/lua, not scripts/; the torrent module lives here
package.path = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") .. "/?.lua;" .. package.path
local torrents = require "browse_torrents"
local anime = require "browse_anime"

local RESULTS = 30

local function ytdlp_path()
    local p = mp.command_native({"expand-path", "~~exe_dir/yt-dlp.exe"})
    if utils.file_info(p) then return p end
    return "yt-dlp"
end

-- ytdl_hook passes raw options to yt-dlp verbatim, so mpv.conf cannot use
-- ~~home/ for the cookies path. Expand it here, once, at script load.
do
    local raw = mp.get_property_native("ytdl-raw-options") or {}
    if raw.cookies and raw.cookies:find("^~~") then
        raw.cookies = mp.command_native({"expand-path", raw.cookies})
        mp.set_property_native("ytdl-raw-options", raw)
    end
end

-- Reuse mpv's ytdl-raw-options so cookies stay configured in one place.
-- mark-watched is dropped: listing a feed must not mark 30 videos watched.
local function raw_option_args()
    local args = {}
    for k, v in pairs(mp.get_property_native("ytdl-raw-options") or {}) do
        if k ~= "mark-watched" then
            if v == "" then
                args[#args + 1] = "--" .. k
            else
                args[#args + 1] = "--" .. k .. "=" .. v
            end
        end
    end
    return args
end

local function fmt_duration(s)
    if not s then return "" end
    s = math.floor(s)
    if s >= 3600 then
        return string.format("%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    end
    return string.format("%d:%02d", s / 60, s % 60)
end

-- ---------------------------------------------------------------------------
-- Result list. The builtin console picker (mp.input.select) escapes ASS tags,
-- so it cannot color parts of an item. This is a minimal ASS-overlay list
-- with the same keys: Up/Down/PgUp/PgDn/Home/End/wheel, Enter, Esc.
-- Colors are Solarized Dark, written as ASS &HBBGGRR& (byte-reversed hex).
-- ---------------------------------------------------------------------------

local C_TITLE   = "A1A193" -- base1  #93a1a1
local C_DIM     = "756E58" -- base01 #586e75
local C_CHANNEL = "D28B26" -- blue   #268bd2
local C_TIME    = "0089B5" -- yellow #b58900
local C_LIVE    = "2F32DC" -- red    #dc322f
local C_FOCUS   = "009985" -- green  #859900
local C_MATCH   = "164BCB" -- orange #cb4b16 (filter-matched characters)
local C_BACK    = "362B00" -- base03 #002b36
local ROWS = 18

local function ass_escape(s)
    return (s:gsub("[\\{}\n]", {["\\"] = "\\\239\187\191", ["{"] = "\\{",
                                ["}"] = "\\}", ["\n"] = " "}))
end

local function colored(color, text)
    return string.format("{\\1c&H%s&}%s", color, ass_escape(text))
end

-- UTF-8 aware split into characters (mpv's Lua is 5.1 / LuaJIT, no utf8 lib)
local function chars(s)
    local t = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
    return t
end

-- Fuzzy match: every character of `needle` appears in `hay` in order
-- (case-insensitive, ASCII case folding). Greedy leftmost. Returns the set
-- of matched hay character indices and the span (last - first), or nil.
local function fuzzy(hay, needle)
    if #needle == 0 then return {}, 0 end
    local matched, j, first, last = {}, 1, nil, nil
    for i, c in ipairs(hay) do
        if c:lower() == needle[j]:lower() then
            matched[i] = true
            first, last = first or i, i
            j = j + 1
            if j > #needle then return matched, last - first end
        end
    end
    return nil
end

-- Render `text` in `color`, with hay chars from `offset` on highlighted when
-- they are in `matched`. Runs of same-colored chars share one tag.
local function render(text, color, offset, matched)
    local out, cur = {}, nil
    for i, c in ipairs(chars(text)) do
        local col = matched[offset + i] and C_MATCH or color
        if col ~= cur then
            out[#out + 1] = string.format("{\\1c&H%s&}", col)
            cur = col
        end
        out[#out + 1] = ass_escape(c)
    end
    return table.concat(out)
end

local function truncate(s, max_chars)
    local cs = chars(s)
    if #cs <= max_chars then return s end
    return table.concat(cs, "", 1, math.max(1, max_chars - 1)) .. "…"
end

-- A row's title as prefix, name, suffix. Torrents show "[Group] Show  S2 E07
-- 1080p" parsed from the release title; other sources their plain title.
local function title_parts(e)
    if e.show then return torrents.display(e) end
    return "", e.title or e.url, ""
end

-- The string the filter matches against: "title channel"
local function haystack(e)
    local pre, name, post = title_parts(e)
    return chars(pre .. name .. post .. " " .. (e.channel or e.uploader or ""))
end

-- The title in at most max_chars; only the name is shortened. Returns the
-- ASS text and the title's length in haystack characters.
local function render_title(e, max_chars, focused, matched)
    local pre, name, post = title_parts(e)
    local np, nn = #chars(pre), #chars(name)
    local short = truncate(name, math.max(1, max_chars - np - #chars(post)))
    return render(pre, C_CHANNEL, 0, matched) .. render(short, focused and C_FOCUS or C_TITLE, np, matched) ..
           render(post, C_TIME, np + nn, matched), np + nn + #chars(post)
end

local function label(e, focused, matched, max_chars)
    local who = e.channel or e.uploader or ""
    local title, n = render_title(e, max_chars - #chars(who) - 12, focused, matched)
    local parts = {title}
    if who ~= "" then
        parts[#parts + 1] = colored(C_CHANNEL, "[") ..
            render(who, C_CHANNEL, n + 1, matched) .. colored(C_CHANNEL, "]")
    end
    if e.live_status == "is_live" then
        parts[#parts + 1] = colored(C_LIVE, "LIVE")
    elseif e.duration then
        parts[#parts + 1] = colored(C_TIME, "(" .. fmt_duration(e.duration) .. ")")
    end
    return table.concat(parts, "  ")
end

-- entries: all results; view: {entry index, matched set} rows that pass the
-- filter, best (tightest) match first; cursor indexes into view.
-- mode: "list" or "grid" (opts.view picks the initial one, Tab toggles).
-- gen: bumped on every redraw/close so late thumbnail fetches are dropped.
local list = {ov = nil, entries = {}, view = {}, cursor = 1, prompt = "", filter = "",
              mode = "list", gen = 0, keys = {}}

local opts = {view = "list", twitch_channels = "", thumb_cache_days = 7,
              torrent_search_url = "", torrent_new_url = "", torrent_shows = ""}
require("mp.options").read_options(opts, "browse")
list.mode = opts.view == "grid" and "grid" or "list"
-- menu.conf hides Open > Torrents on this while no index is configured
mp.set_property_native("user-data/browse/torrents",
                       opts.torrent_search_url ~= "" or opts.torrent_new_url ~= "")

-- Grid: thumbnails are bitmaps via overlay-add (the only way to draw images
-- on the OSD), fetched and scaled by the repo's ffmpeg.exe straight from the
-- thumbnail URL into raw BGRA files cached under %TEMP%.
local GRID_COLS, GRID_ROWS = 4, 3
local GRID_PAGE = GRID_COLS * GRID_ROWS
local THUMB_DIR = (os.getenv("TEMP") or ".") .. "\\mpv-browse-thumbs"

local function ffmpeg_path()
    local p = mp.command_native({"expand-path", "~~exe_dir/ffmpeg.exe"})
    if utils.file_info(p) then return p end
    return "ffmpeg"
end

-- Drop cached thumbnails not touched for thumb_cache_days. Runs once per mpv
-- start; ~500 KB per page of 12, so a week of heavy use stays well under
-- 100 MB. ponytail: age-based only, add a size cap if that ever matters.
local function thumb_cache_cleanup()
    local files = utils.readdir(THUMB_DIR, "files")
    if not files then return end
    local cutoff, removed = os.time() - opts.thumb_cache_days * 86400, 0
    for _, f in ipairs(files) do
        local path = THUMB_DIR .. "\\" .. f
        local info = utils.file_info(path)
        if info and info.mtime < cutoff and os.remove(path) then removed = removed + 1 end
    end
    if removed > 0 then mp.msg.info(string.format("removed %d stale thumbnails", removed)) end
end
thumb_cache_cleanup()

local function grid_clear()
    for id = 1, GRID_PAGE do mp.commandv("overlay-remove", id) end
end

local function list_close()
    if not list.ov then return end
    list.ov:remove()
    list.ov = nil
    list.gen = list.gen + 1
    grid_clear()
    list.page, list.hit = nil, nil
    for _, k in ipairs(list.keys) do mp.remove_key_binding("browse-" .. k) end
    list.keys = {}
end

-- Smallest thumbnail at least `w` wide, else the largest available.
local function thumb_url(e, w)
    if e.thumbnail then return e.thumbnail end
    local best
    for _, t in ipairs(e.thumbnails or {}) do
        local tw, bw = t.width or 0, best and (best.width or 0)
        if not best or (bw < w and tw > bw) or (tw >= w and tw < bw) then best = t end
    end
    return best and best.url
end

local function djb2(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

-- Download with Windows' curl (schannel, has the system CA store; the static
-- ffmpeg build cannot verify TLS certificates), then scale/pad with ffmpeg.
--
-- Every redraw (each cursor move) asks for all 12 tiles again. A fetch
-- already in flight only collects the new callback: without that, a page
-- still loading started a curl + ffmpeg pair per tile per keypress, all on
-- the same paths, and one finishing deleted the .img under the others.
-- ffmpeg writes .part and renames, so a draw never sees a half-written file.
-- max_age (seconds, optional): live previews keep one URL whose image
-- changes, so a cached file older than this is drawn at once and refetched.
local pending = {} -- .bgra path -> callbacks waiting on its fetch
local function ensure_thumb(url, w, h, cb, max_age)
    local base = string.format("%s\\%s_%dx%d", THUMB_DIR, djb2(url), w, h)
    local file, img, part = base .. ".bgra", base .. ".img", base .. ".part"
    local info = utils.file_info(file)
    if info then
        if not max_age or os.time() - info.mtime < max_age then return cb(file) end
        cb(file) -- stale: show it now, the callback runs again when refreshed
    end
    if pending[file] then
        table.insert(pending[file], cb)
        return
    end
    pending[file] = {cb}
    local function fail(step, res)
        pending[file] = nil
        mp.msg.warn(string.format("thumbnail %s failed: %s %s", step, url, res and res.stderr or ""))
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stderr = true,
        args = {"curl", "-f", "-s", "-S", "-L", "--max-time", "10", "-o", img, url},
    }, function(ok, res)
        if not (ok and res.status == 0) then return fail("download", res) end
        mp.command_native_async({
            name = "subprocess", playback_only = false, capture_stderr = true,
            args = {ffmpeg_path(), "-y", "-loglevel", "error", "-i", img,
                    "-vf", string.format("scale=%d:%d:force_original_aspect_ratio=decrease," ..
                                         "pad=%d:%d:(ow-iw)/2:(oh-ih)/2:color=0x002b36", w, h, w, h),
                    "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "bgra", part},
        }, function(ok2, res2)
            os.remove(img)
            if ok2 and res2.status == 0 then os.remove(file) end -- rename cannot replace on Windows
            if not (ok2 and res2.status == 0 and os.rename(part, file)) then
                os.remove(part)
                return fail("convert", res2)
            end
            local cbs = pending[file]
            pending[file] = nil
            for _, c in ipairs(cbs) do c(file) end
        end)
    end)
end

local function list_filter()
    local needle = chars(list.filter)
    list.view = {}
    for i, e in ipairs(list.entries) do
        local matched, span = fuzzy(haystack(e), needle)
        if matched then list.view[#list.view + 1] = {i = i, matched = matched, span = span} end
    end
    table.sort(list.view, function(a, b)
        if a.span ~= b.span then return a.span < b.span end
        return a.i < b.i
    end)
    list.cursor = 1
end

-- Torrents: one AniList search per show name (the first hit's cover and MAL
-- id), cached on disk beside the thumbnails keyed by the search string;
-- "{}" records "no hit". Feeds the grid covers and, with the anime lists
-- (Task 4 of the S##E## plan: ensure_lists), the rows' S##E## tags. A
-- wrong hit is caught by browse_anime.sxe's season check or is cosmetic.
local metas = {} -- show -> {url=, mal=} ({} = no hit), or "pending"
local lists = {} -- relations / seasons: browse_anime tables once loaded
local list_draw

-- Row text changed under a typed filter: re-match, keep the focused entry.
local function refresh_view()
    if not list.ov then return end
    local row = list.view[list.cursor]
    local focused = row and row.i
    list_filter()
    for k, r in ipairs(list.view) do
        if r.i == focused then list.cursor = k end
    end
    list_draw()
end

-- Lookups answer from inside a draw (disk cache) or a callback; coalesce
-- into one redraw after the current one instead of drawing re-entrantly.
local refresh_pending = false
local function schedule_refresh()
    if refresh_pending then return end
    refresh_pending = true
    mp.add_timeout(0, function()
        refresh_pending = false
        refresh_view()
    end)
end

local function apply_entry(e)
    local m = metas[e.show]
    if type(m) ~= "table" then return end
    e.thumbnail = m.url
    if lists.relations and lists.seasons then
        local sxe, why = anime.sxe(m.mal, e, lists.relations, lists.seasons)
        if why then mp.msg.warn(string.format("%s: %s", e.title, why)) end
        e.sxe = sxe
    end
end

local function apply_meta(show)
    for _, e in ipairs(list.entries) do
        if e.show == show then apply_entry(e) end
    end
    schedule_refresh()
end

local function ensure_meta(show)
    if metas[show] ~= nil then return end
    metas[show] = "pending"
    -- keyed by the query, not the show: "Show S2" once cached as "no cover"
    local query = torrents.cover_query(show)
    local file = string.format("%s\\meta_%s.json", THUMB_DIR, djb2(query))
    local f = io.open(file, "r")
    if f then
        local m = utils.parse_json(f:read("*a") or "")
        f:close()
        if type(m) == "table" then
            metas[show] = m
            return apply_meta(show)
        end
    end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = {"curl", "-s", "-S", "--max-time", "10", "https://graphql.anilist.co",
                "-H", "Content-Type: application/json", "--data-binary", utils.format_json({
                    query = "query($s:String){Page(perPage:1){media(search:$s,type:ANIME){idMal coverImage{large}}}}",
                    variables = {s = query}})},
    }, function(ok, res)
        local data = ok and res.status == 0 and utils.parse_json(res.stdout)
        if not (data and data.data) then
            -- network error or an AniList error body (429 when rate limited):
            -- nothing this session, nothing cached, the next mpv start retries
            mp.msg.warn(string.format("AniList lookup failed: %s %s", show,
                                      res and (res.stderr .. (res.stdout or "")):sub(1, 200) or ""))
            metas[show] = {}
            return apply_meta(show)
        end
        local media = data.data.Page and data.data.Page.media
        local hit = media and media[1]
        local m = hit and {url = hit.coverImage and hit.coverImage.large, mal = hit.idMal} or {}
        local out = io.open(file, "w")
        if out then out:write(utils.format_json(m)); out:close() end
        metas[show] = m
        apply_meta(show)
    end)
end

-- The anime lists behind S##E## (browse_anime.lua): TVDB season / offset
-- per MAL id (Fribb) and fansub renumbering rules (erengy). Slimmed into
-- THUMB_DIR and refetched when missing or older than a week; the view does
-- not wait, rows switch from the filename tag when a list lands. A failed
-- fetch or an unparsable body keeps the old file.
local LISTS = {
    seasons = {url = "https://raw.githubusercontent.com/Fribb/anime-lists/master/anime-list-full.json",
               slim = function(body) return anime.slim_seasons(utils.parse_json(body)) end},
    relations = {url = "https://github.com/erengy/anime-relations/raw/master/anime-relations.txt",
                 slim = anime.parse_relations},
}
local LISTS_MAX_AGE = 7 * 86400

local function ensure_lists()
    if not utils.file_info(THUMB_DIR) then
        mp.command_native({name = "subprocess", playback_only = false,
                           args = {"cmd", "/c", "mkdir", THUMB_DIR}})
    end
    for name, l in pairs(LISTS) do
        local file = string.format("%s\\%s.json", THUMB_DIR, name)
        local info = utils.file_info(file)
        if info and not lists[name] then
            local f = io.open(file, "r")
            local t, err = utils.parse_json(f:read("*a") or "")
            f:close()
            if t then
                lists[name] = t
            else
                -- truncated write or hand edit: refetch now, not in a week
                mp.msg.warn(string.format("anime list %s: cached file unreadable (%s), refetching", name, err))
                info = nil
            end
        end
        if (not info or os.time() - info.mtime > LISTS_MAX_AGE) and not l.pending then
            l.pending = true
            mp.command_native_async({
                name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
                args = {"curl", "-s", "-S", "-L", "--fail", "--max-time", "60", l.url},
            }, function(ok, res)
                l.pending = false
                if not ok or res.status ~= 0 then
                    mp.msg.warn(string.format("anime list %s: fetch failed, keeping the old one: %s",
                                              name, res and res.stderr or ""))
                    return
                end
                local t, err = l.slim(res.stdout)
                if not t then
                    mp.msg.warn(string.format("anime list %s: %s, keeping the old one", name, err))
                    return
                end
                local out = io.open(file, "w")
                if out then out:write(utils.format_json(t)); out:close() end
                lists[name] = t
                for show, m in pairs(metas) do
                    if type(m) == "table" then apply_meta(show) end
                end
            end)
        end
    end
end

local function header_text()
    local n = #list.view
    local h = string.format("{\\b1}%s{\\b0}  %s", colored(C_TITLE, list.prompt),
                            colored(C_DIM, string.format("%d/%d", math.min(list.cursor, n), n)))
    if list.filter ~= "" then
        h = h .. "  " .. colored(C_DIM, "> ") .. colored(C_MATCH, list.filter) .. colored(C_DIM, "_")
    end
    return h .. "  " .. colored(C_DIM, list.mode == "grid" and "[Tab: list]" or "[Tab: grid]")
end

local function backdrop(x, y, w, h)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    return string.format("{\\an7\\pos(%d,%d)\\1c&H%s&\\1a&H40&\\bord0\\shad0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                         x, y, C_BACK, w, w, h, h)
end

-- Both renderers work in window pixels (the canvas is set to osd-width x
-- osd-height) so ASS text and overlay-add bitmaps share one coordinate
-- space. s = scale relative to a 720-high window.
local function draw_list(W, H)
    local s = H / 720
    local n = #list.view
    local first = math.max(1, math.min(list.cursor - math.floor(ROWS / 2), n - ROWS + 1))
    local last = math.min(n, first + ROWS - 1)
    local lines = {header_text()}
    -- ~0.52 em per character, as in the grid; keeps long titles on one line
    local max_chars = math.floor((W - 40 * s) / (22 * s * 0.52))
    for i = first, last do
        local focused = i == list.cursor
        local row = list.view[i]
        local e = list.entries[row.i]
        if e.show then ensure_meta(e.show) end
        lines[#lines + 1] = (focused and colored(C_FOCUS, "▸ ") or "  ") ..
                            label(list.entries[row.i], focused, row.matched, max_chars)
    end
    if n == 0 then lines[#lines + 1] = colored(C_DIM, "  no match") end
    if last < n then lines[#lines + 1] = colored(C_DIM, string.format("  … %d more", n - last)) end
    -- ~22px per line at fs22 in a 720-high window
    list.hit = {mode = "list", x0 = 20 * s, x1 = W - 20 * s, y0 = 42 * s, lh = 22 * s,
                first = first, count = last - first + 1}
    list.ov.data = backdrop(10 * s, 10 * s, W - 20 * s, (#lines * 22 + 20) * s) .. "\n" ..
        string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord1\\3c&H%s&\\shad0}%s",
                      math.floor(20 * s), math.floor(20 * s), math.floor(22 * s), C_BACK,
                      table.concat(lines, "\\N"))
end

local function draw_grid(W, H)
    local s = H / 720
    local m, fs, top = math.floor(16 * s), math.floor(15 * s), math.floor(44 * s)
    local hfs = math.floor(20 * s)
    -- tile width from the window width, capped so GRID_ROWS rows fit the height
    local text_h = math.floor(fs * 2.8)
    local tw = math.floor((W - m * (GRID_COLS + 1)) / GRID_COLS)
    local th_max = math.floor((H - top - m) / GRID_ROWS) - text_h - m
    tw = math.min(tw, math.floor(th_max * 16 / 9))
    local th = math.floor(tw * 9 / 16)
    local cell_h = th + text_h + m
    local max_chars = math.floor(tw / (fs * 0.52))
    local n = #list.view
    local first = math.floor((list.cursor - 1) / GRID_PAGE) * GRID_PAGE + 1
    local last = math.min(n, first + GRID_PAGE - 1)
    list.hit = {mode = "grid", m = m, top = top, tw = tw, th = th, cell_h = cell_h,
                first = first, count = last - first + 1}
    local ev = {backdrop(0, 0, W, top + GRID_ROWS * cell_h),
                string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord1\\3c&H%s&\\shad0}%s",
                              m, m, hfs, C_BACK, header_text())}
    if n == 0 then
        ev[#ev + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord1\\3c&H%s&\\shad0}%s",
                                    m, top, hfs, C_BACK, colored(C_DIM, "no match"))
    end
    local gen = list.gen
    for i = first, last do
        local k = i - first
        local x = m + (k % GRID_COLS) * (tw + m)
        local y = top + math.floor(k / GRID_COLS) * cell_h
        local row = list.view[i]
        local e = list.entries[row.i]
        local focused = i == list.cursor
        if focused then
            ev[#ev + 1] = string.format(
                "{\\an7\\pos(%d,%d)\\1a&HFF&\\3c&H%s&\\bord%d\\shad0\\p1}m 0 0 l %d 0 l %d %d l 0 %d{\\p0}",
                x, y, C_FOCUS, math.max(2, math.floor(3 * s)), tw, tw, th, th)
        end
        local who = e.channel or e.uploader or ""
        local line2 = colored(C_CHANNEL, truncate(who, max_chars - 8))
        if e.live_status == "is_live" then
            line2 = line2 .. "  " .. colored(C_LIVE, "LIVE")
        elseif e.duration then
            line2 = line2 .. "  " .. colored(C_TIME, fmt_duration(e.duration))
        end
        ev[#ev + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord1\\3c&H%s&\\shad0\\q2}%s\\N%s",
                                    x, y + th + math.floor(3 * s), fs, C_BACK,
                                    (render_title(e, max_chars, focused, row.matched)),
                                    line2)
        if e.show then ensure_meta(e.show) end
        local url = thumb_url(e, tw)
        if url then
            ensure_thumb(url, tw, th, function(file)
                if list.gen ~= gen then return end -- list redrawn or closed meanwhile
                mp.commandv("overlay-add", k + 1, x, y, file, 0, "bgra", tw, th, tw * 4)
            end, e.thumb_max_age)
        end
    end
    list.ov.data = table.concat(ev, "\n")
end

function list_draw()
    if not list.ov then return end
    list.gen = list.gen + 1
    local W, H = mp.get_property_number("osd-width", 0), mp.get_property_number("osd-height", 0)
    if H == 0 then W, H = 1280, 720 end -- no window yet (idle)
    -- keep the bitmaps when only the focus moved within the same grid page
    -- (overlay-add replaces an id in place); clear them on any other change
    local page = list.mode == "grid" and
        string.format("%d/%dx%d", math.floor((list.cursor - 1) / GRID_PAGE), W, H) or "list"
    if page ~= list.page then grid_clear() end
    list.page = page
    list.ov.res_x, list.ov.res_y = W, H
    if list.mode == "grid" then draw_grid(W, H) else draw_list(W, H) end
    list.ov:update()
end

-- redraw on resize / fullscreen so bitmaps and text stay aligned
mp.observe_property("osd-dimensions", "native", function() list_draw() end)

-- window pixel -> view index of the row/tile under it, or nil
local function hit_test(x, y)
    local h = list.hit
    if not h or not x then return nil end
    local k
    if h.mode == "grid" then
        local col = math.floor((x - h.m) / (h.tw + h.m))
        local row = math.floor((y - h.top) / h.cell_h)
        local in_x = x >= h.m + col * (h.tw + h.m) and x < h.m + col * (h.tw + h.m) + h.tw
        if col < 0 or col >= GRID_COLS or row < 0 or row >= GRID_ROWS or not in_x then return nil end
        k = row * GRID_COLS + col
    else
        if x < h.x0 or x > h.x1 or y < h.y0 then return nil end
        k = math.floor((y - h.y0) / h.lh)
    end
    if k < 0 or k >= h.count then return nil end
    return h.first + k
end

local function activate()
    local row = list.view[list.cursor]
    if not row then return end
    local e = list.entries[row.i]
    local url = e.url or e.webpage_url
    list_close()
    mp.commandv("loadfile", url, "replace")
    mp.osd_message("Loading: " .. (e.title or url), 3)
end

-- hover moves the focus
mp.observe_property("mouse-pos", "native", function(_, pos)
    if not list.ov or not pos or not pos.hover then return end
    local i = hit_test(pos.x, pos.y)
    if i and i ~= list.cursor then
        list.cursor = i
        list_draw()
    end
end)

local function list_move(delta)
    local n = #list.view
    list.cursor = math.max(1, math.min(n, list.cursor + delta))
    list_draw()
end

-- step sizes differ per mode: in the grid Up/Down move a row, PgUp/PgDn a page
local function step(kind)
    if list.mode == "grid" then
        return ({row = GRID_COLS, page = GRID_PAGE})[kind]
    end
    return ({row = 1, page = ROWS})[kind]
end

local function show_results(prompt, entries)
    if #entries == 0 then
        mp.osd_message("browse: no results", 3)
        return
    end
    list_close()
    list.entries, list.prompt, list.filter = entries, prompt, ""
    for _, e in ipairs(entries) do
        if e.show then apply_entry(e) end
    end
    if list.mode == "grid" and not utils.file_info(THUMB_DIR) then
        mp.command_native({name = "subprocess", playback_only = false,
                           args = {"cmd", "/c", "mkdir", THUMB_DIR}})
    end
    list_filter()
    list.ov = mp.create_osd_overlay("ass-events")
    local bind = {
        UP = function() list_move(-step("row")) end,   DOWN = function() list_move(step("row")) end,
        LEFT = function() list_move(-1) end,           RIGHT = function() list_move(1) end,
        WHEEL_UP = function() list_move(-step("row")) end, WHEEL_DOWN = function() list_move(step("row")) end,
        PGUP = function() list_move(-step("page")) end, PGDWN = function() list_move(step("page")) end,
        HOME = function() list_move(-math.huge) end,   END = function() list_move(math.huge) end,
        MBTN_RIGHT = list_close,
        TAB = function()
            list.mode = list.mode == "grid" and "list" or "grid"
            if list.mode == "grid" and not utils.file_info(THUMB_DIR) then
                mp.command_native({name = "subprocess", playback_only = false,
                                   args = {"cmd", "/c", "mkdir", THUMB_DIR}})
            end
            list_draw()
        end,
        -- Esc clears an active filter first, closes on the second press
        ESC = function()
            if list.filter == "" then return list_close() end
            list.filter = ""
            list_filter()
            list_draw()
        end,
        BS = function()
            local cs = chars(list.filter)
            cs[#cs] = nil
            list.filter = table.concat(cs)
            list_filter()
            list_draw()
        end,
        ENTER = activate,
        -- click on the hovered row/tile loads it; clicks elsewhere do nothing
        MBTN_LEFT = function()
            local pos = mp.get_property_native("mouse-pos")
            local i = pos and hit_test(pos.x, pos.y)
            if i then
                list.cursor = i
                activate()
            end
        end,
    }
    for key, fn in pairs(bind) do
        list.keys[#list.keys + 1] = key
        mp.add_forced_key_binding(key, "browse-" .. key, fn, {repeatable = true})
    end
    -- type to filter (fuzzy). ANY_UNICODE delivers printable text; SPACE is
    -- a named key so it needs its own binding.
    local function type_text(text)
        list.filter = list.filter .. text
        list_filter()
        list_draw()
    end
    list.keys[#list.keys + 1] = "ANY_UNICODE"
    mp.add_forced_key_binding("ANY_UNICODE", "browse-ANY_UNICODE", function(ev)
        if ev.event ~= "up" and ev.key_text and ev.key_text ~= "" then type_text(ev.key_text) end
    end, {complex = true, repeatable = true})
    list.keys[#list.keys + 1] = "SPACE"
    mp.add_forced_key_binding("SPACE", "browse-SPACE", function() type_text(" ") end, {repeatable = true})
    list_draw()
end

local function fetch(prompt, url)
    mp.osd_message("browse: fetching " .. prompt .. "...", 30)
    local args = {ytdlp_path(), "--no-warnings", "-J", "--flat-playlist",
                  "--playlist-end", tostring(RESULTS)}
    for _, a in ipairs(raw_option_args()) do args[#args + 1] = a end
    args[#args + 1] = "--"
    args[#args + 1] = url
    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(ok, res, err)
        mp.osd_message("", 0)
        if not ok or res.status ~= 0 then
            local msg = (res and res.stderr or err or ""):gsub("%s+$", "")
            mp.msg.error("yt-dlp failed: " .. msg)
            mp.osd_message("browse: yt-dlp failed\n" .. msg, 8)
            return
        end
        local data = utils.parse_json(res.stdout)
        if not data then
            mp.msg.error("yt-dlp returned unparsable JSON")
            mp.osd_message("browse: bad JSON from yt-dlp", 5)
            return
        end
        show_results(prompt, data.entries or {data})
    end)
end

mp.add_key_binding(nil, "youtube-search", function()
    input.get({
        prompt = "YouTube search: ",
        submit = function(text)
            input.terminate()
            if text:match("^%s*$") then return end
            fetch("YouTube: " .. text, "ytsearch" .. RESULTS .. ":" .. text)
        end,
    })
end)

-- ---------------------------------------------------------------------------
-- Twitch. yt-dlp cannot search Twitch or list follows, so this talks to the
-- web player's GraphQL endpoint directly, authenticated with the auth-token
-- cookie from the same cookies.txt yt-dlp uses (ytdl-raw-options cookies=).
-- Undocumented API: when Twitch changes it, only this section breaks.
-- ---------------------------------------------------------------------------

local TWITCH_CLIENT_ID = "kimne78kx3ncx6brgo4mv6wki5h1ko" -- twitch.tv web player

local function twitch_auth_token()
    local file = (mp.get_property_native("ytdl-raw-options") or {}).cookies
    if not file then
        return nil, "ytdl-raw-options has no cookies= entry"
    end
    local f = io.open(file, "r")
    if not f then return nil, "cannot open " .. file end
    for line in f:lines() do
        -- Netscape format: domain, flag, path, secure, expiry, name, value
        local domain, name, value = line:match("^(%S+)\t%S+\t%S+\t%S+\t%S+\t(%S+)\t(%S+)")
        if domain and domain:find("twitch%.tv$") and name == "auth-token" then
            f:close()
            return value
        end
    end
    f:close()
    return nil, "no twitch.tv auth-token cookie in " .. file
end

local function twitch_gql(query, cb)
    local token, err = twitch_auth_token()
    if not token then
        mp.msg.error(err)
        mp.osd_message("browse: " .. err, 8)
        return
    end
    mp.command_native_async({
        name = "subprocess",
        args = {"curl", "-s", "-S", "--fail-with-body", "https://gql.twitch.tv/gql",
                "-H", "Client-Id: " .. TWITCH_CLIENT_ID,
                "-H", "Authorization: OAuth " .. token,
                "-H", "Content-Type: application/json",
                "--data-binary", utils.format_json({query = query})},
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(ok, res, e)
        mp.osd_message("", 0)
        local data = ok and res.status == 0 and utils.parse_json(res.stdout)
        if not data or data.errors or not data.data then
            local msg = data and data.errors and utils.format_json(data.errors)
                        or (res and (res.stderr .. res.stdout) or e or "")
            mp.msg.error("twitch gql failed: " .. msg)
            mp.osd_message("browse: Twitch API failed\n" .. msg:sub(1, 300), 8)
            return
        end
        cb(data.data)
    end)
end

-- Stream node -> entry in the same shape show_results() expects
local function twitch_entry(user)
    local s = user.stream
    return {
        title = string.format("%s: %s", user.displayName or user.login, s.title or ""),
        channel = (s.game and s.game.displayName or "") ..
                  string.format(" %d viewers", s.viewersCount or 0),
        live_status = "is_live",
        url = "https://www.twitch.tv/" .. user.login,
        thumbnail = s.previewImageURL,
        thumb_max_age = 300, -- same URL, new frame: refetch after 5 min
    }
end

local function show_live(users)
    local entries = {}
    for _, u in ipairs(users) do
        if u and u.stream then entries[#entries + 1] = twitch_entry(u) end
    end
    table.sort(entries, function(a, b) return a.channel > b.channel end)
    show_results("Twitch: live now", entries)
end

-- Followed channels. Twitch's follows service answers every third-party
-- GraphQL request with "service error" (tested 2026-09-02: raw query,
-- browser UA, integrity token, other client ids), so the account's follow
-- list is unreachable. The working route is a channel list in
-- script-opts/browse.conf (twitch_channels=a,b,c) checked for live status.
-- ponytail: swap for currentUser.followedLiveUsers if Twitch reopens it.
mp.add_key_binding(nil, "twitch-live", function()
    local logins = {}
    for l in opts.twitch_channels:gmatch("[^,%s]+") do logins[#logins + 1] = l:lower() end
    if #logins == 0 then
        mp.osd_message("browse: set twitch_channels=a,b,c in script-opts/browse.conf", 8)
        return
    end
    mp.osd_message("browse: checking Twitch channels...", 30)
    twitch_gql(string.format([[
        query { users(logins: %s) {
            login displayName
            stream { title viewersCount game { displayName } previewImageURL(width: 640, height: 360) }
        } }]], utils.format_json(logins)),
        function(d) show_live(d.users) end)
end)

mp.add_key_binding(nil, "twitch-search", function()
    input.get({
        prompt = "Twitch search: ",
        submit = function(text)
            input.terminate()
            if text:match("^%s*$") then return end
            mp.osd_message("browse: searching Twitch...", 30)
            twitch_gql(string.format([[
                query { searchFor(userQuery: %s, platform: "web") {
                    channels { edges { item { ... on User {
                        login displayName
                        stream { title viewersCount game { displayName } previewImageURL(width: 640, height: 360) }
                    } } } } } }]], utils.format_json(text)),
                function(d)
                    local entries = {}
                    for _, e in ipairs(d.searchFor.channels.edges) do
                        if e.item and e.item.stream then
                            entries[#entries + 1] = twitch_entry(e.item)
                        end
                    end
                    show_results("Twitch: " .. text, entries)
                end)
        end,
    })
end)

local feeds = {
    {"youtube-subscriptions", "Subscriptions", ":ytsubs"},
    {"youtube-history",       "History",       ":ythistory"},
    {"youtube-watch-later",   "Watch later",   ":ytwatchlater"},
    {"youtube-home",          "Home",          ":ytrec"},
}
for _, f in ipairs(feeds) do
    mp.add_key_binding(nil, f[1], function() fetch("YouTube " .. f[2], f[3]) end)
end

-- ---------------------------------------------------------------------------
-- Torrents. The index is whatever RSS feeds the user pasted into browse.conf
-- (torrent_search_url with a {query} placeholder, torrent_new_url); the repo
-- names none. Parsing and ordering live in browse_torrents.lua (pure Lua,
-- unit test in docs/tests). Picking a release loads its magnet URL and
-- webtorrent-mpv-hook streams it in memory.
-- ---------------------------------------------------------------------------

local function torrent_config_message()
    mp.osd_message("browse: set torrent_search_url= and torrent_new_url= in script-opts/browse.conf", 8)
end

-- GET an index feed with curl. cb(entries), or cb(nil) after an OSD message
-- when the request fails, times out or does not return RSS.
local function fetch_feed(url, group, cb)
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = {"curl", "-s", "-S", "-L", "--fail-with-body", "--max-time", "20", url},
    }, function(ok, res, err)
        mp.osd_message("", 0)
        if not ok or res.status ~= 0 then
            local msg = (res and res.stderr or err or ""):gsub("%s+$", "")
            mp.msg.error("index feed failed: " .. url .. " " .. msg)
            mp.osd_message("browse: index feed failed\n" .. msg:sub(1, 300), 8)
            return cb(nil)
        end
        local entries, perr = torrents.parse_feed(res.stdout, group)
        if not entries then
            mp.msg.error(perr .. ": " .. res.stdout:sub(1, 200))
            mp.osd_message("browse: " .. perr, 8)
            return cb(nil)
        end
        cb(entries)
    end)
end

mp.add_key_binding(nil, "torrent-search", function()
    if opts.torrent_search_url == "" then return torrent_config_message() end
    ensure_lists()
    input.get({
        prompt = "Torrent search: ",
        submit = function(text)
            input.terminate()
            if text:match("^%s*$") then return end
            mp.osd_message("browse: searching index...", 30)
            fetch_feed(torrents.search_url(opts.torrent_search_url, text), nil, function(entries)
                if entries then show_results("Torrents: " .. text, torrents.order(entries)) end
            end)
        end,
    })
end)

mp.add_key_binding(nil, "torrent-new", function()
    if opts.torrent_new_url == "" then return torrent_config_message() end
    ensure_lists()
    mp.osd_message("browse: fetching new releases...", 30)
    fetch_feed(opts.torrent_new_url, nil, function(entries)
        if entries then show_results("Torrents: new releases", torrents.order(entries)) end
    end)
end)

-- One search per followed show ("Show|Group" keeps only that release
-- group), merged into one ordered list once every request has answered.
mp.add_key_binding(nil, "torrent-followed", function()
    if opts.torrent_search_url == "" then return torrent_config_message() end
    ensure_lists()
    local shows = torrents.shows(opts.torrent_shows)
    if #shows == 0 then
        mp.osd_message("browse: set torrent_shows=Show A|Group,Show B in script-opts/browse.conf", 8)
        return
    end
    mp.osd_message("browse: checking followed shows...", 30)
    local merged, pending = {}, #shows
    for _, show in ipairs(shows) do
        fetch_feed(torrents.search_url(opts.torrent_search_url, show.query), show.group, function(entries)
            for _, e in ipairs(entries or {}) do merged[#merged + 1] = e end
            pending = pending - 1
            if pending == 0 then show_results("Torrents: followed shows", torrents.order(merged)) end
        end)
    end
end)
