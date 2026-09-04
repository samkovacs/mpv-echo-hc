# hwdec=d3d11va-copy rather than native d3d11va

Native `d3d11va` keeps decoded frames on the GPU, which is faster. `vsr_autocrop.lua` needs `cropdetect` to read the raw decoded frame to find the black bars that decide both the crop and VSR's scale factor, and `cropdetect` cannot read GPU surfaces. Copy-back mode (`d3d11va-copy`) lands every frame in system RAM, so `cropdetect` works with no special handling (`vsr_autocrop.lua:25`). The copy cost is accepted for the sake of a crop that never disagrees with the scale factor.

## Consequences

- If 4K performance becomes a problem again, the next lever is switching to native `d3d11va` after crop detection completes. It costs a mid-play decoder reinit, and the script header warns that toggling hwdec once caused a re-trigger loop. Not attempted yet.
- With native hwdec the log fills with `[e]` lines from `cropdetect` failing on GPU frames. That is expected, not a bug.
