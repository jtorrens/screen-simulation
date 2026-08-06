# Native I/O and Metal phase

Status: complete vertical slice on `feature/native-macos-shell`; not the product
cutover.

## One authoritative graph

The native shell has one input and presentation graph:

`AVFoundation / ImageIO / SCREEN patterns -> CVPixelBuffer or encoded texture -> YUV matrix and range -> OCIO IDT -> rgba16Float linear ACEScg texture -> OCIO Display/View or render ODT -> encoder`

AVPlayerItemVideoOutput supplies IOSurface-backed CVPixelBuffers during play.
Exact seeks, frame stepping, scrubbing and render requests use AVAssetReader with
a one-frame time range and `alwaysCopiesSampleData = false`. Both routes use
VideoToolbox through AVFoundation and enter the same StudioColor Metal graph.
There is no FFmpeg path or alternate color backend in the native app. Image
sequences are ordered with Finder's localized standard ordering and request
only their selected frame.

The ACEScg texture is the complete handoff contract for the later physical
models. This phase does not port or implement a physical formula.

## Extracted reusable boundaries

- `packages/StudioColor` remains the exact OCIO 2.5.2 / ACES Studio Config
  extraction from CREDITOS-HDR. This phase adds cached IDT processors on Metal,
  CVMetalTextureCache ingestion, YUV range/matrix conversion, EDR display
  publication and IOSurface writer targets. CPU processing remains the numeric
  oracle and non-IOSurface encoder boundary.
- `packages/StudioMedia` contains the metadata interpretation contract and the
  exact CREDITOS-HDR preset identifiers, H.264/H.265 quality constants and
  output-format matrix. It contains no application UI or destination policy.
- The OpenEXR bridge, DPX packing and AVAssetWriter settings in
  `NativeOutputRenderer` are extracted from the corresponding CREDITOS-HDR
  adapters. They remain local to the candidate until an independent shared
  media package is authorized; no second active route exists.
- The six synthetic choices call `screen-application::diagnostic_signal` or
  the exact three existing 4K PNG assets through the Rust ABI. Swift contains
  no replacement pattern formula.

Native window state, transport bindings, render destinations and queue
progress remain application-local. The independently authorized StudioColor /
StudioMedia repository cut and CREDITOS-HDR migration are still future atomic
changes.

## Output contract

Render Queue processes the complete source or IN/OUT range. Its matrix matches
CREDITOS-HDR: OpenEXR half, DPX RGB 10-bit, TIFF 16-bit, ProRes 4444 / 4444 XQ,
H.264 low/medium/high and H.265 HDR low/medium/high. ProRes and compressed movie
frames are rendered directly into IOSurface-backed writer pixel buffers.
OpenEXR, DPX and TIFF perform one explicit readback at their encoder boundary.
Audio is taken from the selected source range and muxed after video completion
when requested. `Render current frame` is separate and bakes the Mac preview
Display/View into a TIFF.

Peak nits is editable job metadata exactly as in CREDITOS-HDR's current
resolver; it does not silently select a different OCIO view. No graphics-white
control is present.

## Performance observation

Hardware: the development Apple Silicon Mac, 2026-08-06. Source:
CREDITOS-HDR's 3840 x 2160, 25 fps, ProRes 4444, 100-frame sequential benchmark
movie.

- AVPlayerItemVideoOutput playback was visually continuous at authored speed.
- The UI initially reported 0.4 ms for CPU submission of CVPixelBuffer -> YUV ->
  IDT -> ACEScg -> preview on a playback frame. That number did not wait for
  GPU completion and is retained only as a diagnostic.
- The final instrumentation measures from CVPixelBuffer graph submission until
  the preview ODT command buffer completes. This completed end-to-end value is
  displayed live in the contextual inspector and is the value to use for
  performance acceptance.
- An exact H.264 frame request including fresh AVAssetReader setup, decode and
  graph submission measured 75.3 ms. Exact requests deliberately decode only
  the requested time; sequential play reuses AVPlayerItemVideoOutput.

The output smoke test renders three H.264 frames, two OpenEXR frames and a
16-bit current-frame TIFF through the same graph in 0.229 seconds including
writer setup and test overhead.

These are development observations, not a release qualification benchmark.
Long-run dropped-frame, thermal and HDR-display measurements remain cutover
gates.

## Deferred next phase

DeckLink monitoring, icon-based main/settings pages, global preset/test-image
libraries and atomic schema migration are explicitly deferred. DeckLink will
retain an independent monitoring ODT. Global presets will only populate UI;
configured jobs will persist resolved options rather than a preset reference.
