# ModernZ is the only OSC; uosc and its satellites removed

The config shipped both uosc (menu-only) and ModernZ for a while. On 2026-09-01 uosc, inputevent.lua, playlistmanager and memo were removed. ModernZ is the single OSC, mpv's native `menu.conf` provides the right-click menu, the built-in `select.lua` provides playlist/track/chapter pickers, and mpv's own `save-watch-history=yes` replaces memo. The comparison is in `doc/research-osc-modernz-vs-uosc.md`; the short version is that two OSCs fight over input sections and OSD ownership, and everything uosc was still doing had a native or ModernZ equivalent.

## Consequences

- Do not add a second OSC-class script. `browse.lua` deliberately does its own overlay (ADR-0009) rather than depending on uosc's menu.
- History lives in `portable_config/watch_history.jsonl` (gitignored), read by `select.lua`'s history picker.
