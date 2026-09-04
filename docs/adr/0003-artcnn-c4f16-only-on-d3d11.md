# Only ArtCNN C4F16 variants; C4F32 and compute (_CMP) builds removed

The larger ArtCNN builds (C4F32, and every `_CMP` compute-shader variant) exceed d3d11's limits: 14 constant buffers per stage and 32 KB of thread-group shared memory. libplacebo logs `Too many constant buffers` / `Failed executing hook`, disables the hook after the first frame, and `vo-passes` shows no shader pass. The video plays, unshaded, with no visible error. The files were deleted on 2026-09-01 rather than left as a trap. Only `ArtCNN_C4F16.glsl` and `ArtCNN_C4F16_DS.glsl` compile and run on `gpu-api=d3d11`.

## Considered options

- `gpu-api=vulkan` would lift the limit, but RTX VSR requires d3d11. VSR is the point of this config.

## Consequences

- Do not re-add C4F32 or `_CMP` builds unless the config moves to Vulkan.
- The way to check a new shader is to grep the log for `Failed executing hook` and confirm a shader pass appears in `vo-passes`; a clean-looking playback proves nothing.
