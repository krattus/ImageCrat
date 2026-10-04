# ImageCrat testing checklist

Work through whatever you have time for. Things you'd normally do in Photoshop matter most. If something feels wrong, confusing or slow, report it, even if it isn't strictly broken.

For each feature, try this:
- Apply it, then Undo (⌘Z) and Redo (⇧⌘Z). Does the image go back exactly?
- Open its dialog and press Cancel. Is nothing left behind?
- Try it on different layer types: a photo, text, a shape, a smart object, a group.
- Try silly values: 0, negative numbers, very large numbers.

## 1. Basics
- [ ] Create a new document (⌘N), open some of your own photos (⌘O), and drag images into the window.
- [ ] Zoom using the field at the bottom left: type a number, try the menu, ⌘0 (fit) and ⌘1 (100%). Also pinch and scroll.
- [ ] Save as `.imagecrat`, close it, and reopen it. Is everything still the same?
- [ ] If you have documents from Lumen: open a `.lumen` file, change it and save. It should open again as before.
- [ ] Export PNG and JPEG, and File ▸ Export ▸ Smallest for Web.

## 2. Layers
- [ ] Add, duplicate, delete, group and ungroup layers. Use the triangle (and ⌥-click on it) to expand and collapse groups.
- [ ] Change blend modes, opacity and fill. Lock layers and check that editing them is blocked.
- [ ] Add a layer style (fx), hide individual effects with their eyes, and turn them back on.
- [ ] Masks: add one, paint on it, and disable it.
- [ ] With the Move tool, click things on the canvas. The right layer should get selected, and hovering should outline it.

## 3. Tools
- [ ] Brush, eraser, selections (marquee, lasso, magic wand, quick selection, object selection).
- [ ] Press **Q** for Quick Mask, paint, then press Q again. Your painting should become a selection, not paint on the image.
- [ ] Crop, the type tool, shapes (try Stroke Options and dashed lines), gradients, fill.
- [ ] Free Transform (⌘T): scale, rotate, warp. Then run another command before pressing Return.

## 4. Filters and adjustments
- [ ] Try a few filters (Blur, Sharpen, Distort) on a normal layer and on a smart object (Layer ▸ Smart Objects ▸ Convert).
- [ ] Image ▸ Adjustments, and adjustment layers (the half-circle icon in the Layers panel).

## 5. Files from other apps
- [ ] Open PSD files from Photoshop. Is text still editable? Are layers in the right place? Any missing fonts?
- [ ] Open SVG, PDF and Illustrator (.ai) files. Choose "Editable Layers".
- [ ] Save a PSD from ImageCrat and open it in Photoshop, if you have it.

## 6. Artboards
- [ ] File ▸ New, tick "Artboards". Add artboards with the "+" buttons, then right-click an artboard to duplicate, rename or change its colour.
- [ ] Export with File ▸ Export ▸ Artboards to Files.

## 7. Panels and workspace
- [ ] Drag panel tabs to rearrange them, drag them out to float, and drag them back. Resize columns.
- [ ] Window ▸ Workspace: switch workspaces and reset.

## 8. ImageCrat extras
- [ ] Particles menu, Filter ▸ Render ▸ Textures, Layer ▸ New ▸ Recipe Layer.
- [ ] Edit ▸ Command Palette (⇧⌘P): type a command name, or `opacity 50`.
- [ ] Window ▸ History Tree, Versions, Preflight, Components, Clipboard History.
- [ ] Image ▸ Suggest Crops, Describe Image, Analyze. Select ▸ Text in Image (these need the AI models).

## 9. Stability
- [ ] Work for a longer stretch with big images and many layers. Does it get slow, use lots of memory, or crash?
- [ ] Quit and reopen. If ImageCrat offers to recover documents, does that work?

When something goes wrong, use **Help ▸ Report a Bug…** straight away. The details are freshest then.
