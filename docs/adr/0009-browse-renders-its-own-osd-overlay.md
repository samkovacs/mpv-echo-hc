# browse.lua draws its own ASS overlay instead of using mp.input.select

mpv ships a console picker, `mp.input.select`, and the first version of `browse.lua` used it. It escapes every item through `ass_escape`, so a row cannot mix colours (title, channel, duration, LIVE, fuzzy-match highlights) and cannot show thumbnails. `browse.lua` therefore renders results itself with `mp.create_osd_overlay("ass-events")`, with the canvas set to `osd-width x osd-height` so ASS text and `overlay-add` bitmaps share one coordinate space. The search *prompt* still uses the console (`mp.input.get`); only the result list is custom.

## Consequences

- The list has its own key handling (`input_browse` sections), fuzzy filter, mouse hit-testing and two views (list, 4x3 thumbnail grid). ModernZ is not clickable while a list is open.
- Key text must be accepted on any non-`up` event: synthesized `keypress` and some real keys arrive as a single `press` event rather than `down`/`repeat`. The first version only took `down` and lost typed letters.
- Thumbnails are fetched with Windows' built-in `curl` and scaled by the bundled `ffmpeg.exe`, because that ffmpeg is a static build whose https cannot verify TLS certificates while `curl` (schannel) can.
- Solarized Dark colours are constants at the top of the list section; they are the user's stated preference, not a default to be "modernised".
