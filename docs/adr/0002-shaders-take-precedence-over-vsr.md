# GLSL shaders and RTX VSR do not stack; shaders win

RTX Video Super Resolution runs inside the d3d11 video processor (`d3d11vpp`), which scales the frame before any GLSL hook sees it. Every upscaling shader in `portable_config/shaders/` is gated on `OUTPUT > LUMA`, so once VSR has scaled to output size the shader has nothing to do. Stacking them is not "VSR then a sharpener", it is "VSR and a dead shader". `vsr_autocrop.lua` therefore skips `@vsr` whenever `glsl-shaders` is non-empty (`vsr_autocrop.lua:360`), and whichever the user or a profile selected via `glsl-shaders` is what runs.

Measurements and the write-up are in `docs/research/research-rtx-vsr-vs-shaders.md`.

## Consequences

- Selecting a shader profile (ArtCNN, NNEDI3, RAVU, FSRCNNX, Anime4K) means no VSR for that file. The anime WEB-DL auto-profile in `mpv.conf` therefore also means no VSR for those releases; that is the intended trade.
- Clearing `glsl-shaders` at runtime hands the frame back to VSR on the next evaluation.
