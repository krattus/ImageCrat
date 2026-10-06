# ImageCrat — Estonian glossary (eesti keele sõnastik)

The terms below are used the same way everywhere in the app. When you change one, search the CSV for the other
places that use it (Localization/README.md explains the CSV round trip). Notes on the choices are in *italics*.

Põhimõtted / principles

- **Commands are imperatives** (menüükäsud käskivas kõneviisis): *Ava…*, *Salvesta*, *Kopeeri*, *Rakenda*.
- **Filter, adjustment, tool and panel names are nouns**: *Gaussi hägustus*, *Kõverad*, *Pintslitööriist*, *Kihid*.
- **Sentence case** after the first word (Estonian does not capitalise every word): *Uus korrigeerimiskiht*,
  not *Uus Korrigeerimiskiht*. Proper names (ImageCrat, Photoshop, macOS) stay as they are.
- **"…"** stays at the end of commands that open a dialog. **Keyboard shortcuts never change** (⌘, ⌥, ⇧, ⌃ + key).
- **Values in sentences** (%@): put the value where Estonian grammar allows it without case endings, often after a
  colon: *New %@ Layer* → *Uus kiht: %@*; counts as *Kihte: %@* (avoids singular/plural forms).
- **Short labels in narrow panels**: prefer the shorter synonym (*Läbip.* is not used — choose a shorter word instead).
- Units stay international: px, pt, cm, mm, in, %, °, ppi, MP, MB.
- Single letters (R, G, B, C, M, Y, K, X, Y, W, H), file formats (PNG, JPEG, PSD, TIFF …) and product names stay English
  (Localization/allowlist.txt).

## Menüüd / menus

| English | Eesti | Note |
|---|---|---|
| File | Fail | |
| Edit | Redigeerimine | *menu title as a noun (like LibreOffice); the verb "Edit …" is* Redigeeri |
| Image | Pilt | |
| Layer | Kiht | |
| Type | Tekst | *Photoshop's "Type" = text* |
| Select | Valik | *menu title; the command "Select …" is* Vali |
| Filter | Filter | |
| View | Vaade | |
| Window | Aken | |
| Help | Abi | |
| Plugins | Pluginad | |
| Particles | Osakesed | |
| Language | Keel | |
| Integrations (Preferences) | Integratsioonid | |
| System Default | Süsteemi vaikimisi | |

## Üldised käsud / common commands

| English | Eesti |
|---|---|
| New… / Open… / Open Recent | Uus… / Ava… / Ava hiljutine |
| Close / Save / Save As… | Sulge / Salvesta / Salvesta nimega… |
| Export / Export As… / Quick Export as PNG | Ekspordi / Ekspordi kui… / Kiireksport PNG-na |
| Place Embedded… / Place Linked… | Paiguta manustatuna… / Paiguta lingituna… |
| Undo / Redo / Step Backward | Võta tagasi / Tee uuesti / Samm tagasi |
| Cut / Copy / Paste | Lõika / Kopeeri / Kleebi |
| Copy Merged / Paste in Place | Kopeeri ühendatult / Kleebi samale kohale |
| Clear | Tühjenda |
| Delete / Remove | Kustuta / Eemalda |
| Duplicate | Dubleeri |
| Rename | Nimeta ümber |
| OK / Cancel / Apply / Reset / Done | OK / Loobu / Rakenda / Lähtesta / Valmis |
| Preferences / Settings | Eelistused / Seaded |
| Show / Hide | Näita / Peida |
| Enable / Disable (a thing) | Luba / Keela |
| On / Off | Sees / Väljas |
| Default (preset) / Custom | Vaikimisi / Kohandatud |
| Preset | Eelseade |
| Import / Load | Impordi / Laadi |
| Quit ImageCrat / Hide ImageCrat | Lõpeta ImageCrat / Peida ImageCrat |

## Kihid / layers

| English | Eesti |
|---|---|
| layer / Layers (panel) | kiht / Kihid |
| layer mask / vector mask / clipping mask | kihimask / vektormask / lõikemask |
| layer style / effects | kihi stiil / efektid |
| blending options / blend mode | segamisvalikud / segamisrežiim |
| opacity / fill (opacity) | läbipaistmatus / täide |
| group / ungroup | grupp / lõhu grupp (*Group Layers* → Grupeeri kihid) |
| merge down / merge visible / flatten image | ühenda alla / ühenda nähtavad / lamenda pilt |
| stamp visible | tempelda nähtavad |
| link layers | lingi kihid |
| lock: transparent pixels / image pixels / position / all | lukusta: läbipaistvad pikslid / pildipikslid / asukoht / kõik |
| adjustment / adjustment layer | korrigeerimine / korrigeerimiskiht |
| fill layer | täitekiht |
| smart object / smart filter | nutiobjekt / nutifilter |
| rasterize | rasterda |
| embedded / linked | manustatud / lingitud |
| artboard | joonistusala |
| background (colour / layer) | taust (*the layer named "Background" is user content and keeps its name*) |
| foreground / background colour | esiplaani värv / tausta värv |

Blend modes / segamisrežiimid: Normal → Tavaline, Dissolve → Hajumine, Darken → Tumendamine, Multiply → Korrutamine,
Color Burn → Värvi põletamine, Linear Burn → Lineaarne põletamine, Darker Color → Tumedam värv, Lighten → Helendamine,
Screen → Ekraan, Color Dodge → Värvi helestamine, Linear Dodge (Add) → Lineaarne helestamine (liitmine),
Lighter Color → Heledam värv, Overlay → Ülekate, Soft Light → Pehme valgus, Hard Light → Kõva valgus,
Vivid Light → Ere valgus, Linear Light → Lineaarne valgus, Pin Light → Punktvalgus, Hard Mix → Kõva segu,
Difference → Erinevus, Exclusion → Välistamine, Subtract → Lahutamine, Divide → Jagamine, Hue → Toon,
Saturation → Küllastus, Color → Värv, Luminosity → Heledus, Pass Through → Läbiv.
*"Dodge" = helestamine, "Burn" = põletamine (as in GIMP's Estonian translation).*

Layer style effects / kihi stiili efektid: Drop Shadow → Langev vari, Inner Shadow → Sisemine vari,
Outer Glow → Väline kuma, Inner Glow → Sisemine kuma, Bevel & Emboss → Faas ja reljeef, Satin → Satään,
Color Overlay → Värvikate, Gradient Overlay → Üleminekukate, Pattern Overlay → Mustrikate, Stroke → Kontuurjoon.

## Tööriistad / tools

| English | Eesti |
|---|---|
| tool / Tools | tööriist / Tööriistad |
| Move Tool | Teisaldustööriist |
| Rectangular / Elliptical Marquee Tool | Ristkülikvaliku / Ellipsvaliku tööriist |
| Lasso / Polygonal / Magnetic Lasso Tool | Lasso / Hulknurklasso / Magnetlasso tööriist |
| Quick Selection / Magic Wand / Object Selection | Kiirvalik / Võlukepp / Objektivalik |
| Crop Tool | Kärpimistööriist |
| Eyedropper | Pipett |
| Brush / Pencil / Mixer Brush | Pintsel / Pliiats / Segamispintsel |
| Eraser | Kustukumm |
| Clone Stamp | Kloonitempel |
| Healing Brush / Spot Healing Brush / Patch | Parandav pintsel / Punktparanduspintsel / Paik |
| Gradient Tool / Paint Bucket | Üleminekutööriist / Värvipott |
| Blur / Sharpen / Smudge (tools) | Hägustaja / Teravustaja / Hõõruja |
| Dodge / Burn / Sponge | Helestamine / Põletamine / Käsn (*tools:* Helestamistööriist …) |
| Pen Tool | Sulepea |
| Type Tool | Tekstitööriist |
| Hand / Zoom / Rotate View | Käsi / Suum / Vaate pööramine |
| Rectangle / Ellipse / Polygon / Line / Custom Shape | Ristkülik / Ellips / Hulknurk / Joon / Kohandatud kujund |
| shape / path / work path | kujund / rada / töörada |
| anchor point | ankurpunkt |

## Valik / selection

| English | Eesti |
|---|---|
| selection / select | valik / vali |
| All / Deselect / Reselect / Inverse | Kõik / Tühista valik / Vali uuesti / Pööra valik |
| Subject / Sky / Focus Area | Objekt / Taevas / Fookusala |
| Select and Mask | Vali ja maskeeri |
| Color Range | Värvivahemik |
| Modify: Border / Smooth / Expand / Contract / Feather | Muuda: Ääris / Silu / Laienda / Ahenda / Pehmenda servi |
| Grow / Similar | Kasvata / Sarnased |
| Quick Mask | Kiirmask |
| feather (radius) | servade pehmendus |
| anti-alias / anti-aliased | servade silumine / silutud servadega |

## Pilt, teisendus / image, transform

| English | Eesti |
|---|---|
| canvas | lõuend |
| Image Size / Canvas Size | Pildi suurus / Lõuendi suurus |
| Image Rotation / Flip Horizontal / Vertical | Pildi pööramine / Peegelda horisontaalselt / vertikaalselt |
| 90° Clockwise / Counter Clockwise | 90° päripäeva / vastupäeva |
| Crop / Trim / Reveal All | Kärbi / Kärbi servad / Näita kõike |
| transform / Free Transform | teisendus / Vaba teisendus |
| Warp / Puppet Warp / Perspective Warp | Väänamine / Nukuväänamine / Perspektiivi väänamine |
| Content-Aware Fill / Scale | Sisutundlik täitmine / skaleerimine |
| Fill / Stroke (Edit menu) | Täida / Kontuuri |
| resolution / resample | eraldusvõime / ümberproovimine |
| mode (colour mode) / bits per channel | režiim / bitti kanali kohta |

## Korrigeerimised / adjustments

Brightness/Contrast → Heledus/kontrast, Levels → Tasemed, Curves → Kõverad, Exposure → Säritus, Vibrance → Erksus,
Hue/Saturation → Toon/küllastus, Color Balance → Värvitasakaal, Black & White → Must-valge, Photo Filter → Fotofilter,
Channel Mixer → Kanalimikser, Color Lookup → Värvitabel, Invert → Inverteeri, Posterize → Posteriseeri,
Threshold → Lävi, Gradient Map → Üleminekukaart, Selective Color → Valikuline värv,
Shadows/Highlights → Varju-/heleduspiirkonnad, HDR Toning → HDR-toonimine, Desaturate → Eemalda küllastus,
Match Color → Sobita värv, Replace Color → Asenda värv, Equalize → Ühtlusta, Auto Tone / Contrast / Color →
Automaatne toon / kontrast / värv.
Shadows / Midtones / Highlights → Varjud / Keskmised toonid / Heledad toonid. Whites / Blacks → Valged / Mustad.

## Filtrid / filters

| English | Eesti |
|---|---|
| Blur / Gaussian Blur / Motion Blur / Box Blur | Hägustus / Gaussi hägustus / Liikumishägustus / Kasthägustus |
| Radial / Lens / Surface / Smart Blur | Radiaalhägustus / Objektiivihägustus / Pinnahägustus / Nutikas hägustus |
| Field / Iris / Tilt-Shift / Path / Spin Blur | Väljahägustus / Iirishägustus / Kallutus-nihe / Rajahägustus / Pöörlemishägustus |
| Blur Gallery | Hägustusgalerii |
| Sharpen / Unsharp Mask / Smart Sharpen | Teravustamine / Teravustusmask / Nutikas teravustamine |
| Distort / Twirl / Pinch / Spherize / Ripple / Wave | Moonutus / Keeris / Näpistus / Sfäärilisus / Virvendus / Laine |
| Polar Coordinates / Displace | Polaarkoordinaadid / Nihutus |
| Noise / Add Noise / Reduce Noise / Median / Dust & Scratches | Müra / Lisa müra / Vähenda müra / Mediaan / Tolm ja kriimud |
| Pixelate / Mosaic / Crystallize / Pointillize | Pikseldus / Mosaiik / Kristalliseeri / Punktiseeri |
| Render / Clouds / Lens Flare | Renderdus / Pilved / Objektiivi peegeldus |
| Stylize / Emboss / Find Edges / Solarize | Stiliseerimine / Reljeef / Leia servad / Solarisatsioon |
| Liquify | Vedeldamine (*command:* Vedelda…) |
| Lens Correction / Camera Raw Filter | Objektiivi korrigeerimine / Camera Raw' filter |
| Filter Gallery / Last Filter | Filtrigalerii / Viimane filter |
| Convert for Smart Filters | Teisenda nutifiltrite jaoks |
| radius / amount / threshold / angle / distance | raadius / hulk / lävi / nurk / kaugus |
| strength / intensity / softness / detail | tugevus / intensiivsus / pehmus / detailsus |

## Paneelid / panels

Layers → Kihid, Channels → Kanalid, Paths → Rajad, History → Ajalugu, Properties → Atribuudid,
Adjustments → Korrigeerimised, Color → Värv, Swatches → Värvinäidised, Gradients → Üleminekud, Patterns → Mustrid,
Character → Märk, Paragraph → Lõik, Navigator → Navigaator, Histogram → Histogramm, Info → Teave, Brushes → Pintslid,
Brush Settings → Pintsli seaded, Layer Comps → Kihikompositsioonid, Timeline → Ajatelg, Actions → Toimingud,
Glyphs → Glüüfid, Tool Presets → Tööriista eelseaded, Clone Source → Kloonimisallikas.
Workspace → Tööala, Panel → Paneel, Float in Window → Ava eraldi aknas, Collapse to Icons → Ahenda ikoonideks.

## Vaade / view

Zoom In / Zoom Out → Suurenda / Vähenda, Fit on Screen → Mahuta ekraanile, 100% → 100%, Actual Pixels → Tegelikud pikslid,
Rulers → Joonlauad, Grid → Ruudustik, Guides → Juhtjooned, Pixel Grid → Pikslivõrk, Snap → Haakumine,
Proof Colors → Värvide proovivaade, Gamut Warning → Gamuti hoiatus, Selection Edges → Valiku servad.

## Tekst / type

text / type layer → tekst / tekstikiht, font → font, font size → fondi suurus, style → stiil, leading → reavahe,
tracking → märgivahe, kerning → paarisvahe, baseline shift → alusjoone nihe, paragraph → lõik,
align left / center / right / justify → joonda vasakule / keskele / paremale / rööpjoonda, warp text → väänatud tekst.

## Pintslid / brushes

brush tip → pintsli ots, size / hardness / spacing / flow / smoothing → suurus / kõvadus / samm / voog / silumine,
pressure / tilt → surve / kalle, jitter → värin, scattering → hajutus, texture → tekstuur, dual brush → topeltpintsel,
color dynamics → värvidünaamika, wet edges → märjad servad, airbrush → pihusti.
Brush library folders: General → Üldine, Dry Media → Kuivtehnikad, Wet Media → Märgtehnikad,
Special Effects → Eriefektid, Favorites → Lemmikud, Recent → Hiljutised, Custom → Kohandatud.

## Generatiivne tehisintellekt / generative AI

Generative AI → Generatiivne tehisintellekt (lühidalt *generatiivne TI*), Generative Fill → Generatiivne täitmine,
Generative Expand → Generatiivne laiendus, prompt → päring (*kirjeldus*), provider → teenusepakkuja,
API key → API-võti, credit / balance → krediit / saldo, variation → variant.

## Muu / other

| English | Eesti |
|---|---|
| document / Untitled | dokument / Nimetu |
| recovery / autosave | taastamine / automaatsalvestus |
| snapshot | hetktõmmis |
| action (recorded) | toiming |
| script | skript |
| slice | lõige |
| timeline / frame / keyframe | ajatelg / kaader / võtmekaader |
| unsaved changes | salvestamata muudatused |
| tool tip | kohtspikker |
| Command Palette | Käsupalett |
| Report a Bug… | Teata veast… |
| token (MCP) / client / port | tõend / klient / port |
