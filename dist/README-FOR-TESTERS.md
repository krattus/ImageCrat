# ImageCrat: read me first

Thanks for testing ImageCrat. It's a free, Photoshop-style image editor for the Mac, still in development, so expect bugs. Finding them is the point.

## What you need
- A Mac with Apple Silicon (M1 or newer).
- macOS 15 (Sequoia) or newer.
- About 1 GB of free space for the app. The optional AI models need up to about 7 GB more.

## Install
1. Open the `.dmg` file.
2. Drag **ImageCrat** onto the **Applications** folder.
3. Open ImageCrat from Applications. It's signed and checked by Apple, so it opens like any other app.

## Optional: AI features
- **On-device AI** (object selection, background removal, upscaling, depth and so on): go to **ImageCrat ▸ Preferences… ▸ AI Models** (⌘K) and download the models you want. If you were given an "ImageCrat Models" pack (or an older "Lumen Models" pack), use **Import Models…** in the same place instead.
- **Generative AI** (Generative Fill, Generate Image and so on) needs your own API key from a provider such as fal.ai, entered in **Preferences ▸ Generative AI**. This costs money per image. You can skip these features entirely.

## Reporting a bug
1. Choose **Help ▸ Report a Bug…**
2. Describe what happened, the steps to make it happen again, and what you expected instead.
3. Pick what to attach. System info, crash reports and recent log lines are on by default. A screenshot and your document are off by default, because they show your image.
4. Click **Save Report…** and send the `.zip` it creates. You can also use the **Email…** button.

Nothing is sent anywhere automatically, and your API keys are never included.

If ImageCrat crashes, reopen it and use **Help ▸ Report a Bug…**; the crash report is attached for you. **Help ▸ Open Crash Reports Folder** shows the raw files.

## Coming from Lumen?
ImageCrat used to be called Lumen. The first time you open ImageCrat it carries everything over by itself: your settings, downloaded AI models, brushes, presets, scripts and plugins, recovery files and logs move from `~/Library/Application Support/Lumen` to `~/Library/Application Support/ImageCrat`. A short note in the status bar says so.
- Your `.lumen` documents still open, and **Save** keeps them as `.lumen` files. New documents are saved as `.imagecrat`; use **File ▸ Save As…** to turn an old file into one.
- Generative AI keys are copied to ImageCrat's own keychain entry. macOS may ask once whether ImageCrat may use the key Lumen stored; click **Always Allow**. If you deny it, enter the key again in **Preferences ▸ Generative AI**.
- **File ▸ Open Recent** starts empty: macOS keeps that list per app.
- Droplets made with Lumen still point at Lumen; make them again from ImageCrat if you use them.
- Once you're happy, you can delete the old Lumen app.

## Good bug reports
- One problem per report.
- Exact steps from opening a document, for example: "New document 1920×1080 → Text tool → typed Hello → Layer Style ▸ Drop Shadow → Cancel → shadow still visible."
- What you expected, and what actually happened.
- Whether it happens every time.
- Your document attached, if it's not private and the problem depends on it.

See **Testing Checklist.md** for things to try.
