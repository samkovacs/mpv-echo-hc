# RTX VSR / RTX Video HDR vs GLSL shaders in mpv

Research note, 2026-09-01. Target machine: RTX 3080 Ti, 3440x1440 244 Hz HDR
primary, i9-12900K, mpv `vo=gpu-next` / `gpu-api=d3d11` / `hwdec=d3d11va-copy`.
Content mix: mostly 1080p/1440p YouTube, Twitch and anime; occasional 4K HDR remux.

**Question.** Should this setup upscale with NVIDIA RTX VSR (`d3d11vpp
scaling-mode=nvidia`) and convert SDR->HDR with RTX Video HDR (`nvidia-true-hdr`),
with the shipped GLSL shaders (nnedi3, ravu-zoom, FSRCNNX, ArtCNN, Anime4K,
SSimSR/DS, adaptive-sharpen), or with a per-content mix?

Legend: **[M]** measured / primary-source fact. **[O]** opinion or unverified
community claim. **[I]** inference drawn in this note from [M] facts.

---

## 1. What mpv's `d3d11vpp` filter actually does

Sources: mpv manual `vf.rst` (https://github.com/mpv-player/mpv/blob/master/DOCS/man/vf.rst)
and `video/filter/vf_d3d11vpp.c` (https://github.com/mpv-player/mpv/blob/master/video/filter/vf_d3d11vpp.c).

- [M] It is a thin wrapper over the Direct3D 11 `ID3D11VideoProcessor`
  (`VideoProcessorBlt`). mpv does no upscaling math itself; `scaling-mode=nvidia`
  only calls `VideoProcessorSetStreamExtension` with `NVIDIA_PPE_INTERFACE_GUID`
  (`enable_nvidia_rtx_extension`, method=2/version=1). The manual is explicit:
  "this only enables the appropriate processing extensions; whether it actually
  works or not depends on your hardware and the settings in your GPU driver's
  control panel". Quality level (1-4) comes from the NVIDIA control panel/app,
  not from mpv.
- [M] Input format: the filter accepts only `IMGFMT_D3D11`
  (`mp_refqueue_add_in_format(p->queue, IMGFMT_D3D11, 0)`), but the manual says
  "Software frames are automatically uploaded to hardware for processing" (mpv's
  `f_autoconvert` inserts the upload). So `hwdec=d3d11va-copy` works; the cost is
  one extra RAM->VRAM upload per frame versus plain `d3d11va`. [I] Direct
  `d3d11va` would avoid that copy but `vsr_autocrop.lua`'s cropdetect needs the
  copied-back frame, so the current choice is a deliberate trade.
- [M] Output size is fixed by `scale`: `out.w = (int)(scale * in.w)` rounded up to
  even, crop rectangle scaled the same way. There is no "fit the display" mode;
  the maintainer said filters run before the window exists, so a Lua script is
  the intended way to pick the factor (PR #14698 discussion,
  https://github.com/mpv-player/mpv/pull/14698; discussion #17492,
  https://github.com/mpv-player/mpv/discussions/17492).
- [M] `require_filtering` is true only when output params differ from input or
  true-HDR is wanted; with `scale=1` and no HDR the frame is passed through
  untouched (no VSR de-artifact pass at native resolution unless `scale` != 1 or
  a format change forces the blit). [I] The repo's `scale=1` HDR-only insert does
  go through the blit because `want_nvidia_true_hdr` is set, so VSR 1.5-style
  native de-artifacting will also apply on that path if the driver enables it.
- [M] `nvidia-true-hdr`: checked via `NVIDIA_TRUE_HDR_INTERFACE_GUID`; only applied
  when the source is SDR (`want_nvidia_true_hdr` = option && !is_hdr(source);
  commit 5abce15f "enable NVIDIA RTX Video only for SDR input", 2026-06-28). On
  success mpv tags the output `pl_color_space_hdr10` with
  `hdr.max_luma = 1000` and a source comment "This is only a guess. Adjust the
  value to match NVIDIA settings", and forces `IMGFMT_X2BGR10` output (commit
  f7ad4a5f "set output format for NVIDIA RTX Video HDR", fixes #17265). The
  filter has no knowledge of the display: PR #18199's text says "it also seems
  to be disabled if HDR is disabled in Windows, but we don't check that, because
  filters are not related to display. Use conditional profile"
  (https://github.com/mpv-player/mpv/pull/18199).
- [M] Chroma/bit-depth: VPP output stays a D3D11 surface in the source
  `hw_subfmt` (nv12/p010) unless `format=` overrides. NVIDIA's own SDK
  documents the VSR filter as 8-bit BGRA/RGBA in and out
  (https://docs.nvidia.com/maxine/vfx/latest/Filters/VideoSuperResolution.html).
  [I] Whatever internal precision the driver uses, the hand-off to gpu-next is a
  scaled nv12/p010 texture, so chroma is scaled inside the driver, not by
  libplacebo's chroma path (KrigBilateral etc. then act on already-scaled chroma).

### Interaction with `glsl-shaders` (hook semantics)

Source: libplacebo `docs/custom-shaders.md`
(https://github.com/haasn/libplacebo/blob/master/docs/custom-shaders.md).

- [M] `vf` filters run in the decoder->VO chain; the VO/libplacebo receives the
  filter's output as its source. `LUMA`/`MAIN` hooks therefore see the
  **VSR-scaled** frame, and `OUTPUT.w` is the final render rectangle.
  `//!WHEN` "If this evaluates to 0, the shader stage will be skipped."
- [M] Conditions in the shipped shaders (grep of `portable_config/shaders`):
  - ArtCNN / FSRCNNX: `//!WHEN OUTPUT.w LUMA.w / 1.2 > OUTPUT.h LUMA.h / 1.2 > *`
  - nnedi3: `//!WHEN HOOKED.w OUTPUT.w / 0.833333 <`
  - SSimSuperRes: `//!WHEN NATIVE_CROPPED.h OUTPUT.h <`
  - Anime4K Restore CNN (`HOOK MAIN`) and KrigBilateral: no size condition.
- [I] Consequence: when `@vsr` has already scaled the frame to (or near)
  display size, every size-gated upscaler (ArtCNN, FSRCNNX, nnedi3, ravu,
  SSimSR) silently evaluates to "no upscale needed" and does nothing. Only the
  unconditional passes (Anime4K Restore, adaptive-sharpen's ">" branch, Krig)
  still run, and they run on the VSR output at display resolution, which is the
  most expensive place to run them. "VSR + ArtCNN" in one profile is not a
  chain; it is VSR alone plus a wasted shader compile. Verify with `--v` or
  `shader stats` in the OSD; not measured here.

## 2. NVIDIA's own claims for RTX VSR / RTX Video HDR

- [M] Supported GPUs: RTX 30/40 at launch (Feb 2023, driver 531.18); RTX 20 added
  with VSR 1.5 (Oct 2023, driver 545.84). 3080 Ti is supported.
  (https://www.nvidia.com/en-my/geforce/news/atomic-heart-dlss-3-the-finals-closed-beta-game-ready-driver/,
  https://blogs.nvidia.com/blog/rtx-video-super-resolution-ai-obs-broadcast/)
- [M] Quality levels 1-4: "sharper images and improved artifact reduction" at
  higher levels; "all 30 and 40 series RTX GPUs are able to comfortably upscale
  using quality level 1", "xx70 class or higher are able to play most content at
  quality level 4" (same nvidia.com article). No nits/PSNR/GPU-% numbers published.
- [M] What it does: "removing blocky compression artifacts and upscaling video
  resolution", models "trained on a wide variety of video genres, from gaming to
  live video". VSR 1.5 "retrained to more accurately identify the difference
  between subtle details and compression artifacts" and now de-artifacts video
  played at native resolution (NVIDIA blog above).
- [M] Resolution envelope: NVIDIA's RTX Video FAQ (nvidia.custhelp.com a_id 5448;
  returned 403 to this fetch, figures confirmed via secondary reports citing it)
  states input 360p-1440p, output up to 4K. The SDK guide gives "suggested
  minimum input resolution for VSR is 360p", denoise/deblur modes require output
  size == input size, 8-bit RGBA I/O.
  (https://docs.nvidia.com/maxine/vfx/latest/Filters/VideoSuperResolution.html)
- [M] Spatial vs temporal: neither the consumer pages nor the VFX SDK guide state
  whether frames are processed with temporal context. NVIDIA's public materials
  describe per-frame enhancement only; treat "temporal" claims online as [O].
- [M] RTX Video HDR (driver 551.23, Jan 2024): "automatically converts SDR video
  into more vibrant HDR video" via Tensor Cores; requires an HDR10 display with
  Windows HDR enabled; can be combined with VSR.
  (https://www.nvidia.com/en-us/geforce/news/geforce-rtx-4070-ti-super-rtx-video-hdr-game-ready-driver/)
  NVIDIA describes it to developers as "AI-Enhanced SDR to HDR Tone Mapping" to
  HDR10 with "tuning parameters for stylization" (https://developer.nvidia.com/rtx-video-sdk).
  No target-peak or curve is documented; mpv's 1000-nit tag is a guess (see 1).
- [O] Community claim (discussion #17492, user Damole-wer): VSR always works at
  2x internally then Lanczos-rescales, so "no benefit setting VSR scale to
  anything other than 2". No primary source; the mpv code scales by whatever
  `scale` you pass, and the driver's internals are undocumented.

## 3. Comparisons with evidence

**Measured, shader vs shader (no RTX VSR in any measured table found).**

- [M] Artoriuz blog (https://artoriuz.github.io/blog/mpv_upscaling.html), single
  anime luma image (kumiko.png), box-downsampled 50%, 2x upscale; author's own
  caveat "Testing with a single image makes this very unscientific". PSNR/SSIM:
  ArtCNN_C4F32 43.47/0.9923, ArtCNN_C4F16 42.68/0.9916, ravu-zoom-ar-r3
  39.39/0.9880, ravu-lite-ar-r4 39.66/0.9878, lanczos 36.51/0.9799,
  polar_lanczossharp 36.07/0.9786, bilinear 34.16/0.9735.
- [M] CuNNy results (https://github.com/funnyplanter/CuNNy/blob/master/results/README.md),
  anime image aoko.png, greyscale, 2x, RTX 4090. PSNR / frametime:
  ArtCNN-C4F32 35.63 dB / 7.2 ms, ArtCNN-C4F16 34.42 / 2.0 ms,
  Anime4K_Upscale_UL 32.53 / 2.65 ms, FSRCNNX_x2_16 31.73 / 2.36 ms,
  FSRCNNX_x2_8 31.05 / 0.6 ms, ravu-lite-ar-r4 30.54 / 0.18 ms,
  ewa_lanczossharp 27.88 / 0.15 ms, lanczos 28.31 / 0.10 ms.
  Ordering on anime line art is consistent across both sources: ArtCNN >
  Anime4K/FSRCNNX > ravu > polar Lanczos.
- [M] Doom9 thread "Mathematically Evaluating mpv's Upscaling Algorithms"
  (https://forum.doom9.org/archive/index.php/t-184985.html): same author, adds
  live-action images; reviewers there note "better psnr doesn't mean the scaler
  is better" and that Lanczos "is sharper but rings more".

**Opinion / unmeasured.**

- [O] dyphire (mpv-config discussion #78,
  https://github.com/dyphire/mpv-config/discussions/78): ArtCNN vs FSRCNNX "no
  significant difference" on HD, ArtCNN "only slightly stronger" on SD; Anime4K
  (Ani4K) "significantly outperforms ArtCNN in the effect of removing compression
  artifacts, especially on SD content", but "may lose some subtle details" on
  real HD; "Don't blindly trust numerical test results."
- [O] kohana.fi "mpv for anime" (https://kohana.fi/article/mpv-for-anime):
  recommends ArtCNN_C4F32 for anime, claims it beats madVR NGU; no numbers;
  does not mention RTX VSR.
- [O] mpv PR #14698 thread: one tester found VSR "only marginally superior to
  Lanczos", others valued the artifact reduction even at 1.0x.
- [M] Gap: no source found (mpv wiki, libplacebo issues, ArtCNN, Anime4K,
  Doom9, Artoriuz) with PSNR/SSIM for RTX VSR against any GLSL shader, for
  anime or live action. Every "VSR vs shader" ranking online is [O]. NVIDIA
  publishes no metrics either. The only hard, cross-checkable claim for VSR is
  the artifact-removal purpose and the 360p-1440p -> <=4K envelope.

## 4. RTX Video HDR vs mpv `inverse-tone-mapping`

- [M] mpv/libplacebo `--inverse-tone-mapping`: expands SDR to the configured
  `target-peak` by inverting the selected tone-mapping curve; deterministic,
  documented, works on any GPU/VO=gpu-next
  (https://mpv.io/manual/master/#options-inverse-tone-mapping, libplacebo
  options https://libplacebo.org/options/). When issue #13352 asked for RTX
  Video HDR, maintainer kasper93's first answer was "Have you tried
  inverse-tone-mapping?" (https://github.com/mpv-player/mpv/issues/13352).
- [M] History of the mpv integration: added in commit 6ca3752 (2024). Issue
  #17265 "Nvidia true hdr flag not working" (closed 2026-02-18): Andarwinux
  states in #11390 "RTX Video HDR never worked from the start ... The thing he
  actually thought worked was DXGI-based RTX HDR not D3D11VideoProcessor-based
  RTX Video HDR" (https://github.com/mpv-player/mpv/issues/11390#issuecomment-2708484791).
  kasper93 fixed the output format/colour-space tagging in Feb 2026
  (commits 568522e6, f7ad4a5f); testers then reported the indicator working but
  "still had to manually override primaries and transfer to get the expected
  HDR effect" (https://github.com/mpv-player/mpv/issues/17265).
- [M] Issue #17800 (https://github.com/mpv-player/mpv/issues/17800): with Windows
  HDR off, the filter still reports success, mpv tags the frame as PQ/BT.2020
  and renders it to an SDR swapchain -> wrong colours. Maintainer position:
  "filter is filter ... Use conditional profile"; the merged fix (#18199) only
  skips HDR sources, it does not check the display. The repo's
  `vsr_autocrop.lua` + `hdr-mode.lua` gating on actual display HDR state is
  exactly the mitigation the maintainer prescribes.
- [O] Quality: no measured comparison exists. Community reports range from
  "works better than Plex's SDR->HDR" to "horrible oversaturation" (the latter
  on SDR displays, i.e. the #17800 bug, per the AutoVSR gist
  https://gist.github.com/anthonybaldwin/1e49b28b49babf64f159cb793c506333).
  Coverage describes RTX Video HDR as "AI-powered inverse tone mapping"
  (https://www.guru3d.com/story/nvidia-rtx-video-hdr-enhancing-sdr-content-with-aipowered-hdr-conversion/),
  i.e. the same operation mpv performs, with an undocumented curve.
- [I] Decisive practical difference: mpv's ITM knows the real `target-peak`
  (hdr-mode.lua feeds the measured panel peak) and is stable across mpv
  versions; RTX Video HDR outputs to a hard-coded 1000-nit guess, is gated on
  driver state mpv cannot observe, and its mpv path was broken for ~2 years
  without anyone noticing. Also [M] #17595: the current `nvidia-true-hdr` path
  causes frame drops with SVP on a 5090 (open at time of writing).

## 5. Recommendation for this machine

Reasoning chain: display is 3440x1440, so the upscale ratios in play are
1080p -> 1440p (1.33x), 720p -> 1440p (2x), and 1440p -> native (1x). VSR's
envelope (360p-1440p in, <=4K out) covers all of these [M, section 2]. GLSL
upscalers are size-gated and are no-ops after VSR [I, section 1]. The only
measured quality data ranks the anime CNN shaders far above generic scalers on
anime line art [M, section 3], and there is no measurement of VSR at all.

1. **Anime (local files, Blu-ray/WEB 1080p): GLSL, not VSR.** Use the existing
   `[Ani4k]` (ArtCNN C4F32 i2) profile; `[AniSD]` (i4) for <=576p. This is the
   one case with hard evidence (43 dB vs 36 dB Lanczos on the Artoriuz image;
   ArtCNN top of the CuNNy table). Suppress `@vsr` in this profile; otherwise
   ArtCNN's `WHEN` never fires. For heavily compressed anime WEB rips, dyphire's
   [O] advice is Anime4K Restore before the doubler; the shipped `[Anime4K]`
   profile already does that.
2. **Twitch and YouTube 1080p live action / gaming streams: RTX VSR.** Low-bitrate
   H.264 at 1.33x is where NVIDIA's stated purpose ("removing blocky compression
   artifacts", trained on "gaming to live video") applies and where no shipped
   shader has a de-artifact model trained for live action. Set quality 4 in the
   NVIDIA app: NVIDIA rates xx70-class and up as fine at level 4, and a 3080 Ti
   is above that [M]. Keep `scale` = exact fit as `vsr_autocrop.lua` does; the
   "always 2x" advice is [O].
3. **1440p YouTube (VP9/AV1) at native size: VSR at scale=1 is optional.** The
   filter passes frames through untouched at scale=1 unless something forces a
   blit [M], so native de-artifacting only happens if you force it (e.g.
   `format=` change); the win over mpv's `deband` is unmeasured. Default off;
   enable only for visibly blocky streams.
4. **4K HDR remux: neither.** Source is HDR so `nvidia-true-hdr` is refused
   [M], and 2160p is above VSR's input envelope and is downscaled to 1440p
   anyway. Keep `[4k-Downscaling]` (SSimDownscaler) as configured.
5. **SDR->HDR: prefer mpv `inverse-tone-mapping=yes` with the measured
   `target-peak`; keep `nvidia_true_hdr=false`.** Grounds: the mpv path's
   1000-nit guess, the display-state blind spot (#17800), the 2024-2026 period
   in which it did not work, and the absence of any quality measurement in its
   favour. If you want to A/B it, the repo's gating already makes it safe to
   flip `nvidia_true_hdr=true` on the HDR panel only; treat the result as taste.
6. **Never stack VSR and a GLSL upscaler in the same profile.** Pick one per
   content class via `profile-cond` (anime detection by track title/path is [O]
   heuristics; the `[Ani4k]` manual toggle is the honest fallback).

Unverified for this note: actual GPU-time of VSR level 4 at 1440p on a 3080 Ti,
ArtCNN C4F32 frametime at 1080p60 on a 3080 Ti (the 7.2 ms figure is a 4090 on
an unstated image size; a 3080 Ti at 60 fps has a 16.7 ms budget, so C4F16 may
be needed for 1080p60 anime), and whether `shader stats` confirms the
`WHEN`-skip behaviour described in section 1. All three are measurable locally.

## Addendum: measured on this machine (2026-09-01)

- Both ArtCNN C4F32 shaders on disk (`Ani4Kv2_ArtCNN_C4F32_i2`, `AniSD_ArtCNN_C4F32_i4`) fail on `gpu-api=d3d11` with this build (mpv v0.41.0-923, libplacebo v7.371): the final Conv2D pass binds 16 textures, SPIRV-Cross emits one HLSL cbuffer per texture, and D3D11 has 14 slots. Log: `Too many constant buffers in shader`, `error X4567: maximum cbuffer exceeded. target has 14 slots, manual bind to slot 16 failed`, `Failed executing hook, disabling`. After frame one libplacebo skips the hook (`Skipping hook 0 ... stage 0x2`) and `vo-passes` shows plain ewa_lanczossharp upscaling. Source of the skip logic: `pass_hook()` in libplacebo `src/renderer.c` (disabled_hooks list).
- NNEDI3 nns32/nns64, RAVU-Zoom r3, FSRCNNX 8/16, Anime4K Restore+Clamp+Krig all compile and run on d3d11 at 1080p60 -> 2560x1440 with 0 dropped frames. NNEDI3 nns64 + adaptive-sharpen: ~3.4 ms/frame.
- Consequence for the recommendation: on d3d11 use the ArtCNN **C4F16** variants (not on disk yet) or switch to `gpu-api=vulkan`. Interim: WEB-DL profile uses NNEDI3 nns64.
- Confirmed the WHEN-gate claim empirically: with `@vsr` present, `vo-passes` lists no user-shader pass; with `glsl-shaders` set and vsr_autocrop skipping VSR, the hook dispatches.
