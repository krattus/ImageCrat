# ImageCrat

A native macOS layered image editor modelled on Photoshop. Swift + AppKit/SwiftUI, with a
non-destructive Core Image / Metal compositing engine.

## Download

A signed and notarized build for macOS 15+ (Apple Silicon) is on the
[Releases page](https://github.com/krattus/ImageCrat/releases). Open the DMG and drag ImageCrat to Applications.
On-device AI models download inside the app the first time you use a feature that needs one; generative features use your own
fal.ai key, stored in the macOS Keychain.

## Build & run

Requires macOS 15+ and Xcode 16+ (tested with Xcode 26, Swift 6.3).

```bash
./scripts/build_app.sh          # release build → build/ImageCrat.app
open build/ImageCrat.app
```

`swift build && .build/debug/Lumen` runs a debug build directly (the Swift package, module and source folder keep
the internal name `Lumen`; the app is ImageCrat, bundle ID `app.imagecrat.editor`). Copy `build/ImageCrat.app` to
`/Applications` to keep it. Headless render tests: `.build/debug/Lumen --selftest /tmp/imagecrat-tests`
(writes PNGs of effects, blend modes, filters, adjustments, PSD/native round-trips);
`--perftest` times painting on a 24 MP document.

## Features

**Layers** – pixel, type, shape (vector), smart object (embedded or **linked** – auto-updates when
the file changes), fill (solid / gradient / pattern), adjustment layers, groups (pass-through or
isolated) and **artboards** (own bounds and background, export Artboards to Files). 28 blend
modes, opacity & fill opacity, clipping masks, layer & vector masks, locks, color labels,
**linked layers**, **layer search/filter** (kind, name, effect, mode, attribute, color),
**Layer Comps** (visibility / position / appearance, export to files), merge, stamp, flatten,
align & distribute.

**Blending options** – Blend If (this layer / underlying, split sliders, per channel), knockout
(shallow/deep), channel restriction, blend interior effects / clipped layers as group, layer and
vector mask hides effects, Global Light.

**Layer styles** – multiple instances of drop shadow, inner shadow, color/gradient overlay and
stroke; outer/inner glow (softer/precise, gradient fill, range, jitter, noise), bevel & emboss
(gloss contour, contour, texture), satin, pattern overlay. Contour editor with presets. Styles
stay **editable in PSD** files (lfx2 read/write).

**Adjustments** (as layers or destructive) – brightness/contrast, levels & curves (with black /
gray / white **eyedroppers**, auto), exposure, vibrance, **hue/saturation per colour range**,
color balance, black & white, photo filter, channel mixer, color lookup, invert, posterize,
threshold, gradient map, selective color, shadows/highlights, **HDR Toning**, **Match Color**,
**Replace Color**, desaturate, equalize, auto tone/contrast/color.

**Filters** (~70) – blur (incl. **Blur Gallery**: field / iris / path blur with on-canvas pins,
surface blur), sharpen / unsharp / **Smart Sharpen**, noise / dust & scratches, distort (incl.
**Displace**, **Lens Correction**), pixelate, stylize, render (clouds, flare, lighting),
**Filter Gallery** (47 artistic looks, stackable), **Camera Raw Filter**, **Liquify** (warp,
twirl, pucker, bloat, reconstruct, smooth, **freeze/thaw mask**, **Face-Aware** eye / nose /
mouth / face-shape sliders via Vision).

**Transform** – free transform (scale, rotate, skew, distort, perspective), **Warp** (presets +
custom mesh), **Puppet Warp**, **Perspective Warp**, **Content-Aware Scale**, transform selection,
rotate canvas view (R).

**Retouching** – PatchMatch **Content-Aware Fill**, spot healing (content-aware), healing, **Patch**,
**Content-Aware Move**, **Remove tool**, **Red Eye**, clone stamp, history brush.

**Painting** – brush with a full **Brush Settings** panel: shape dynamics (size/angle/roundness
jitter by pressure, tilt, direction, fade), scattering, texture, **dual brush**, color dynamics,
transfer, **wet edges**, build-up, noise; **ABR import**; pencil, eraser, **Mixer Brush**,
**Color Replacement**, gradient, bucket, blur/sharpen/smudge, dodge/burn/sponge.

**Selections** – marquees, lasso, polygonal & **magnetic lasso**, magic wand, quick selection,
**Object Selection**, Select Subject, **Select Sky**, **Focus Area**, **Select and Mask** (edge
detection, smart radius, decontaminate), color range, similar, grow, modify, alpha channels,
quick mask.

**Type** – point & paragraph text, **mixed styling within a layer**, **vertical type**,
**type on a path**, **Warp Text**, **Paragraph panel** (indents, spacing, hyphenation, justify
variants), **OpenType features** (ligatures, old-style figures, small caps, fractions, ordinals,
swash, stylistic alternates), convert to shape / work path.

**Vectors** – pen tools, path & direct selection, shapes, **live Boolean path operations**
(combine / subtract / intersect / exclude, merge components), **custom shape library**, shapes
keep live properties after perspective/distort.

**Colour** – RGB / Grayscale / CMYK / Lab modes (ink and Lab channel views), 8/16/32 bits per
channel export (16-bit PNG/TIFF/PSD, 32-bit float TIFF and OpenEXR), **ICC Assign / Convert to
Profile** (all installed profiles), **Proof Setup, Proof Colors (⌘Y), Gamut Warning (⇧⌘Y)**,
CMYK JPEG/TIFF export, Info panel CMYK/Lab readouts, **Camera RAW** open (DNG, CR2/CR3, NEF,
ARW, RAF, ORF, RW2…).

**Workflow** – **Actions** (record, play, per-step toggles, stops, save/load sets), **Batch**
processing of folders, **Timeline** frame animation (tweening, loop), export **Animated GIF** and
**MP4**, import video frames to layers, **Print** (⌘P), **Tool Presets**.

**Interface** – panels can be re-arranged, **floated in their own windows**, moved between
columns and closed; **Workspaces** (Essentials, Painting, Photography, Graphic and Web, save your
own); **Preferences** (⌘K: history states, colour theme, cursors, checkerboard, guide/grid colours
and spacing, ruler & type units – px, in, cm, mm, pt, %, large-document cache).

**Performance** – large layers (≥ 6 MP) live in persistent GPU textures and only changed 512 px
tiles are re-uploaded while painting (≈6 ms per stroke frame on a 24 MP document);
large composites are cached between edits.

**Files** – native `.imagecrat` (fully editable; `.lumen` files from before the rename open and save too), layered PSD import/export (groups, masks, blend
modes, opacity, editable layer styles), open PNG/JPEG/TIFF/HEIC/GIF/BMP/WebP/RAW, export
PNG/JPEG/TIFF/HEIC/BMP/GIF/EXR with scale & quality and embedded ICC profile, clipboard,
drag & drop.
**Editable import** – PSD/PSB keep type, shapes, vector masks, adjustment and fill layers and smart
objects live (8/16/32-bit, CMYK/Lab/Gray/Indexed); SVG (open, place, paste from Figma/Illustrator/
Sketch) and PDF / Illustrator `.ai` (Editable Layers or Flattened Image; Illustrator layers become
named groups) arrive as shape, type, image and group layers. Anything without an ImageCrat equivalent is
rasterized in place; File ▸ Import ▸ … Import Report lists what stayed editable. Placed vector
documents stay sharp when enlarged.

**On-device AI** (models download on first use into `~/Library/Application Support/ImageCrat/Models`;
manage them in Preferences ▸ AI Models) – **Object Selection** rebuilt on SAM 2.1 (box, lasso,
click to add/subtract, hover Object Finder, Show All Objects), Select Subject (fast / high quality),
**Select People**, **Mask All Objects**, **Refine Hair** (BiRefNet), **Select by Description**
(Florence-2, optional SAM 3.1), sky masks; **Neural Filters** (skin smoothing, colorize, depth
blur, Super Zoom, JPEG artifact removal, photo restoration, style transfer, harmonization, colour
transfer), **Remove tool** with on-device LaMa and Find Distractions (people, wires),
**Sky Replacement**, AI Denoise / Deblur / Upscale (NAFNet, Real-ESRGAN, MetalFX).

**Generative AI (cloud, optional)** – add an API key in Preferences ▸ Generative AI (stored in
the macOS Keychain) for fal.ai, Stability AI, Google Gemini, OpenAI, Replicate or Black Forest
Labs, with per-feature routing: Generative Fill, Generative Expand (also in the Crop tool),
Remove with AI, Generate Image / Similar / Background, Edit with Prompt, reference-image fill,
Harmonize, Generative Upscale, AI Denoise/Sharpen, generative sky. Results arrive as new layers
with switchable variations; pixels outside the selection are never changed. Generative History
panel with cost estimates.

**More tools** – Artboard, Selection Brush, Perspective Crop & Straighten, Slice / Slice Select,
Frame, Color Sampler, Ruler, Note, Count, Pattern Stamp, Art History Brush, Background Eraser,
Curvature Pen, Add / Delete / Convert Anchor Point, Triangle, line arrowheads, Type Mask tools;
**symmetry painting**, **Smart Guides**, spring-loaded tool shortcuts, customisable toolbar,
**Contextual Task Bar**, History snapshots, measurement scale & log, Match Zoom/Location.

**More editing** – Color (temperature/tint), Clarity, Dehaze, Grain and Light adjustment layers,
adjustment presets, Defringe / matte removal, Color Range skin tones & tonal ranges,
**Content-Aware Fill workspace**, Clone Source panel, **Vanishing Point**, Split & Cylindrical
Warp, Image Size resampling methods (Preserve Details 2.0 with AI upscalers), **Adaptive Wide
Angle**, lens profiles.

**More imaging** – Bitmap, Indexed, Duotone and Multichannel modes, spot channels, .aco/.ase
swatch libraries, Pattern Preview, **Photomerge** and 360° panoramas, **Auto-Align / Auto-Blend**
(focus stacking), Load Files into Stack, smart-object stack modes, **Merge to HDR Pro**.

**More type** – bulleted & numbered lists, area type inside shapes, variable-font axes, Glyphs
panel & on-canvas alternates, emoji, **Match Font**, Dynamic Text (fit to box), right-to-left and
complex scripts.

**More files & automation** – **PSB**, Photoshop PDF export/import and PDF Presentation, Layers
to Files, Save for Web, **DICOM**, **video timeline** with keyframes and video layers, Render
Video / image sequences, droplets, Image Processor, variables & data sets, **JavaScript
scripting** with a console and HTML-panel **plugins**, Content Credentials (C2PA).

**Beyond Photoshop** – features Photoshop does not have:
- *Layout*: **Arrange on Shape** (circle, square, triangle, polygon, star, spiral, grid, custom shape,
  path), **Live Repeater** (grid / radial / along a shape / mirror / scatter arrays that stay live),
  Tidy Up and on-canvas spacing handles, Pack into Shape, Auto Collage, **Select Similar Layers**,
  document-wide **Find and Replace** (text, colours, fonts), **Smart Resize** to social formats with
  safe-zone overlays, per-layer **Constraints**, **Rename Layers** (templates, find/replace, numbering).
- *Particles*: a top-level **Particles** menu – 54 presets (weather, fire & energy, light, smoke &
  fluids, celebration, abstract) on a GPU particle system with on-canvas emitter handles,
  re-editable smart-object output and animation to the timeline.
- *Artist & colour*: **Reference Board**, **radial quick menu** (hold `), **drawing guides** with
  assisted strokes (perspective, isometric, rulers), colour harmony, palette from image, **global
  colours**, Recolour Artwork, WCAG contrast checker, colour-blindness simulation, Flip Canvas View,
  lazy-rope stabiliser, wrap-around tile painting and Make Seamless.
- *Editing comfort*: pending transforms are applied automatically before other commands, feather
  **Inside / Centered / Outside**, smart object **Reset to Original Size**, ⌥-drag / ⌘⌥-drag duplicate,
  generative **variation switching** on the canvas task bar, **AI Usage** panel with live fal.ai
  balance (admin-scope key), budgets and cost estimates.

Automated runs (`--selftest`, `--perftest`, menu fuzzing, command-line modes) never see the real
API keys in the Keychain; generative code is tested against `scripts/genai_mock_server.py`.

**Limitations** – layer pixels are stored at 8 bits per channel; 16/32-bit documents gain
precision in compositing, adjustments and export, but not in stored paint strokes. CMYK and Lab
documents are edited in RGB and converted for display, channels and export.

Keyboard shortcuts follow Photoshop (V, M, L, W, C, I, J, B, S, Y, E, G, R, O, P, T, A, U, H, Z,
[ ], D, X, Q, ⌘T, ⌘J, ⌘G, ⌥⌘G, ⌘L, ⌘M, ⌘U …). See Help ▸ Keyboard Shortcuts.

## Code map

```
Sources/Lumen/
  Core/        document model, layers, pixel buffers, selections, vector paths, transforms
  Render/      Core Image compositor, layer effects, text & shape rasterizers, custom kernels
  Adjustments/ adjustment settings and LUT/curve engine
  Filters/     filter catalog, Liquify
  Tools/       canvas tools (brush engine, transform, selection, vector, type…)
  Canvas/      Metal-backed canvas view and overlay (rulers, guides, marching ants)
  UI/          SwiftUI panels, options bar, dialogs
  IO/          native format, PSD reader/writer, import/export
  App/         app entry, menus, command layer (AppActions), self tests, module registry
  ToolsModule/ Edits/ Imaging/ Files/   feature modules (extra tools, editing, modes/merging, formats/automation)
  GenAI/       generative-AI providers, routing, Keychain, features
  ML/          on-device models: Segmentation (SAM, BiRefNet, Florence-2), Neural filters
```

Feature modules register their menus, dialogs, panels and tests through `App/Extensions.swift`.
The product identity (name, bundle ID, document type, support folder, Keychain service) lives in `App/Brand.swift`;
`App/LegacyMigration.swift` carries a Lumen installation's folder, preferences and API keys over on first launch.
Third-party: sam31-swift / mlx-swift (MIT), c2pa-swift (MIT/Apache-2.0); models keep their own
licences (SAM 2.1 Apache-2.0, SAM 3.1 SAM License, BiRefNet MIT, Florence-2 MIT, LaMa Apache-2.0,
Real-ESRGAN BSD-3, Depth Anything V2 Small Apache-2.0, DDColor Apache-2.0, NAFNet MIT, GFPGAN
Apache-2.0 with non-commercial StyleGAN2 components; lens data from lensfun, CC-BY-SA 3.0).

## Windows

A Windows version is being prepared: the platform-independent core lives in `Sources/ImageCratCore` (Foundation
only, checked by `scripts/check_core_portable.sh`, unit-tested with `swift test`). See
[docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md) for the plan.

## Licence

ImageCrat is free for personal, educational, research and other **non-commercial** use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use (selling it, or using it in a commercial product
or service) is not permitted. Third-party components and models keep their own licences (listed above); the lens
correction data derived from lensfun remains under CC-BY-SA 3.0.
