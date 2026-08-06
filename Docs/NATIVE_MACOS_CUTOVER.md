# Native macOS and StudioColor cutover

Status: implementation gate for the isolated replacement candidate.

## Current vertical slice

`apps/screen-native-macos` is the only native macOS replacement candidate. It
uses native SwiftUI/AppKit controls and `HSplitView`, Apple AVFoundation and
ImageIO sample access, an explicitly confirmed IDT, a premultiplied linear
ACEScg buffer, the coarse Rust `PhysicalPipeline(identity)` ABI, StudioColor's
OCIO-generated Metal Display/View transform, and a minimal PNG render queue.

StudioColor is extracted from CREDITOS-HDR commit
`150ef31ffa69fec562a017d2165006f7b2913520`. It retains the exact OCIO 2.5.2 C++
implementation, ACES Studio Config 4.0.0 / ACES 2.0 file, CPU processor, MSL
generation, LUT texture construction, processor/resource caches, alpha
handling, extended-range float behavior, and output catalog. The build checks
the native archive and configuration SHA-256 before packaging. StudioColor
owns no media selection, UI state, IDT inference, render destination, or
application defaults.

## SCREEN-SIMULATION atomic cut

Slint remains the product shell until all of these conditions pass on one
candidate revision:

1. Every current immutable Application request and diagnostic view can be
   presented through the native host without a second evaluator.
2. Media exact/floor/nearest selection, bounded frame cache, cancellation,
   stills, H.264, ProRes and OpenEXR use their canonical owners and tests.
3. StudioColor replaces `screen-color` and the current presentation OCIO code
   in one revision; the retired implementation and dependencies are deleted in
   that same revision. No runtime selector, alias or fallback is introduced.
4. CPU/Metal conformance passes all three current ODTs with a maximum one-code
   difference and at most 0.5% differing channels, including negatives and
   above-one samples.
5. Interactive and Native physical results consume the same Rust Application
   requests; Swift contains no physical formula or duplicated semantics.
6. Persistence, package opening, cancellation, export identity, accessibility,
   window/split restoration, resize behavior, performance and signed `.app`
   packaging pass their owning checks.
7. The native bundle name becomes `Screen Simulation.app`; `screen-desktop`,
   Slint sources/dependencies/attribution and the temporary candidate packaging
   name are removed together. Only one product remains.

## CREDITOS-HDR atomic cut

After StudioColor is hosted in an authorized independent repository, one
CREDITOS-HDR revision will replace the `CreditsColor` OCIO engine, native
bridge binary, configuration resource and Metal Display/View/LUT helpers with
the pinned StudioColor package. Its preview, current-frame render and sequence
render tests must pass unchanged or with explicitly reviewed golden updates.
The old files and build scripts are deleted in that same revision. CREDITOS-HDR
will not keep a backend selector, compatibility import or fallback resource
route.

The independent repository creation and the CREDITOS-HDR mutation both require
separate authorization. Until then this directory is the exact extractable
boundary; its source/build hashes prevent silent divergence.

