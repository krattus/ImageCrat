ImageCrat Preview @VERSION@ - technical preview for Windows (@ARCH@)
=====================================================================

ImageCrat is a layered image editor. Its Mac app is complete; this is the first Windows
program built from the same Swift code. It is a VIEWER for testing on Windows PCs:
nothing is edited or saved back.

What it does
------------
* Opens Photoshop documents (.psd and .psb; 8- and 16-bit RGB and grayscale, with
  32-bit, CMYK, Lab, indexed and bitmap files converted more simply):
  shows the flattened composite stored in the file and lists every layer (groups,
  pixel, text, shape, smart object, adjustment and fill layers) with its thumbnail,
  visibility, blend mode, opacity and layer effects.
* Opens PNG images.
* Opens brush files: Photoshop .abr, GIMP .gbr/.gih, Procreate .brush/.brushset,
  Krita .kpp and ImageCrat .icbrushes, and shows every brush tip in a grid.
* Help > Run Self-Check runs a built-in test battery and shows PASS/FAIL.

Using it
--------
* File > Open (Ctrl+O), File > Open Recent, or drag a file onto the window.
* Ctrl + mouse wheel zooms around the pointer; Ctrl+0 fits the picture to the window,
  Ctrl+1 shows 100% (actual pixels); Ctrl++ / Ctrl+- zoom in steps.
  Drag with the mouse (or use the wheel / Shift+wheel / arrow keys) to pan.
* Layers panel: click a layer to outline its bounds on the canvas, double-click it
  (or press Enter) to see only that layer's own pixels, Esc to go back to the
  composite. Click the eye to show or dim the layer's thumbnail (the composite is
  not re-rendered in this preview).
* File > Export Composite as PNG (Ctrl+E) saves the picture you see (for brush files:
  the grid of tips).
* The divider between the picture and the panel can be dragged.

Command line (imagecrat-cli.exe, in the same folder)
-----------------------------------------------------
  imagecrat-cli selfcheck                  run the built-in checks (exit code 0 = pass)
  imagecrat-cli info <file>                document info and the layer tree
  imagecrat-cli composite <psd> <out.png>  write the stored composite as PNG
  imagecrat-cli brushes <file> <outdir>    write every brush tip as PNG
  imagecrat-cli make-samples <dir>         write synthetic test files
  imagecrat-cli --version

Windows SmartScreen
-------------------
This test build is not code-signed yet, so Windows may say "Windows protected your
PC". Click "More info", check that the file is ImageCratPreview-Setup-*.exe (or
ImageCratPreview.exe), then click "Run anyway". Signing comes in a later version.

Known limitations of this preview
---------------------------------
* Viewing only: no painting, editing, filters, AI features or saving of documents.
* The canvas shows the composite Photoshop stored in the file; layers are not
  re-composited (toggling an eye does not change the picture).
* Layer previews and thumbnails show each layer's stored pixels, without masks,
  effects or blend modes.
* CMYK and Lab documents are converted to screen colours with simple formulas
  (no colour profiles).
* Files saved by the ImageCrat Mac app (.imagecrat) can't be opened yet.

Feedback
--------
Please report problems, with the file if you can share it, at
https://github.com/krattus/ImageCrat/issues
If the program ever closes with an "internal error" message, a line is written to
%LOCALAPPDATA%\ImageCrat\Preview\crash.log - please include it.

Licence: free for non-commercial use - PolyForm Noncommercial 1.0.0 (LICENSE.txt).
Copyright 2026 krattus. Built @BUILDDATE@.
