# swift-psd-kit

Read Photoshop files and change **what a text layer says** or **what a smart
object shows** — the template fill a designer hands off ("make 50 of these with
these names and photos") — on this machine, with everything not named left
byte for byte as it was.

```swift
import PSDKit

var poster = try PSDDocument(contentsOf: template)
poster.layers.map(\.name)                 // top first: ["Title", "Photo", "Background"]
let report = try poster.setText("Summer Sale", layer: "Title")
report.compositeUpdated                   // will Quick Look show it?
try poster.replaceContents(of: "Photo", with: picture)   // fill, fit or stretch
try poster.write(to: output)              // re-read and checked before it is kept
```

## Writing a layered file (0.3)

```swift
let layers = [
    PSDWriteLayer(name: "background", content: .pixels(background)),
    PSDWriteLayer(name: "label", content: .group([
        PSDWriteLayer(name: "strip", content: .pixels(strip)),
        PSDWriteLayer(name: "title", content: .pixels(title), blendKey: "mul "),
    ]), opacity: 0.9),
]
let data = try PSDWriter.data(width: 3000, height: 3000, layers: layers, composite: flattened, dpi: 300)
```

A new 8-bit RGB PSD from pictures, layers bottom first: each a pixel layer
cropped to its alpha, with its name (Unicode, `luni`), opacity, blend key and
visibility; a group is a Photoshop folder (`lsct` divider and header records);
the flattened picture is the merged image; the resolution is recorded.
**Text arrives as pixels**: an editable type layer needs Photoshop's text-engine
data, which this writer does not make. design (`design … -o cover.psd`) is the
first user. A written file reads back through this library's reader byte for
byte, opens in ImageIO, and psd-tools 1.25 lists the same layers and blends.

The compositor now draws every blend design uses — soft and hard light, colour
dodge and burn, linear burn, exclusion, and the non-separable hue, saturation,
colour and luminosity (the W3C definitions) — in Photoshop's arithmetic. Soft
light is Photoshop's curve, not the W3C/Pegtop one CoreGraphics draws; the two
agree below 50 % grey and differ by up to 0.05 above it.

## The honest part: three readers

A PSD is read three ways, and an edit has to reach each:

1. **Photoshop** reads the layer's own data. The text (both the plain string and
   the text engine's data, with its paragraph and style runs rebuilt to the new
   length) and the embedded file are changed there exactly. For text, the
   document-wide text engine block (`Txt2`) is dropped, so **Photoshop asks to
   update the text layers when the file is opened** — answer *Update* and it
   redraws them itself. This is what ag-psd's `invalidateTextLayers` does; there
   is no silent flag. Not verified in Photoshop here (none installed).
2. **Anything reading layer pixels** (psd-tools, Photopea, this library) sees the
   layer **redrawn**: Core Text for text, the stored corner placement for a
   picture. Measured against Photoshop's own pixels — see below.
3. **Quick Look, ImageIO and the web** read only the merged image. It is rewritten
   inside the changed rectangle, and **only when this library's compositor first
   reproduced the saved merged image there**; otherwise it is left alone and
   `EditReport.compositeNote` says why (layer effects, adjustment layers, or a
   file saved without Maximize Compatibility).

## Measured, on psd-tools' sample files (MIT)

- **Round trip:** 19 of 19 samples (PSD and PSB, 8- and 16-bit, RGB, CMYK,
  grayscale, groups, effects, type and smart-object layers) write back **byte for
  byte**. The first version missed one: an old file with no global-mask field.
- **Text redraw vs Photoshop's pixels** (redrawing the ORIGINAL text):
  ArialMT 13 pt — the same bounding box to the pixel, lines 1 and 3 overlapping
  exactly, line 2 half a pixel off (auto-leading rounding). Faux-bold Arial Black
  62.5 pt — **overlap 0.83–0.96**, boxes within 1–3 px; this needed Photoshop's
  faux bold measured, not guessed: a 2% outline plus **0.026 em more advance per
  glyph**, found by grid search, raised the mean overlap from 0.53 to 0.92 (the
  advance is the part a stroke-only faux bold misses — lines were 13 px short).
  Paragraph (box) text puts the first baseline at the height of a "d", not the
  font's ascent, which had placed Arial 5.6 px low.
- **Picture placement:** the original embedded PNG drawn through its stored
  corners matches Photoshop's layer pixels **exactly** (mean 0.00/255). A
  symmetric payload hid an upside-down render in the first version; the tests now
  use a picture red only in one corner.
- **The compositor** reproduces the saved merged image **exactly** (mean 0.00,
  99th percentile 0.0) on text.psd, placedLayer.psd, group.psd, hidden-layer and
  empty-layer; 0.12 on 2layers. Where Photoshop drew effects it differs by 20–135
  mean and is not trusted; the rewrite threshold (mean ≤ 1.5, p99 ≤ 8) sits well
  clear of both.
- **Independent reader:** psd-tools 1.24 reads every edited file — the new text,
  the engine's runs (19 + 12 for two lines, 31 for the style), the new PNG payload
  — and composites it. ImageIO opens it; Quick Look shows the change.

## Measured, on 102 real Photoshop files (ag-psd's samples, MIT)

Every text and smart-object layer in ag-psd's published test files
(`test/read`, `test/read-write`; used as test input, one shipped as a fixture
under its licence) was edited and the result read back by psd-tools 1.24:

| Edit | Result |
|---|---|
| Smart-object pictures swapped | **76 of 81**; the 5 refused were 3 warped layers (by design) and 2 that found a GROUP of the same name — fixed in 0.2.0, the name now finds the layer the edit needs |
| Text changed, layer's own font | **2 of 20** — the other 18 are set in fonts a Mac lacks without Adobe's apps: Myriad Pro (Photoshop's default), Calibri, Microsoft YaHei, Noto Sans KR, Aachen |
| Text changed, `substituteFont:` (0.2.0) | **18 of 18** — drawn with a stand-in, the file keeps its own font for Photoshop |
| Text changed, `redraw: false` (0.2.0) | **18 of 18** — words changed, pixels byte-identical, Photoshop redraws on open |
| Every output | read back by psd-tools with the new text or PNG payload in place, and composited |

So the font, not the format, is what stops real templates: refusing to draw
in the wrong face is still the default, and the two ways past it are named
choices. Photoshop itself was not available to test the "update text layers"
prompt; ag-psd's documentation and psd-tools agree on the mechanism (the
document's `Txt2` block is omitted).

## Limits, said plainly

- Edits need **8-bit RGB**; other modes and depths are read, not edited.
- A text layer takes its **first style run's look** for all its new text; mixed
  fonts or colours inside one layer become one.
- The **font must be installed** (`PSDError.fontMissing` otherwise) — the layer
  cannot be redrawn in a face this Mac does not have.
- **Warped** text or smart objects (a real warp, not Photoshop's even mesh) and
  **linked** smart objects are refused; change a linked object's file instead.
- Layer **effects** are Photoshop's to draw; they stay attached to the layer, but
  the merged image is not rewritten under them.
- A swapped picture is resized to the smart object's own content size and
  embedded as PNG, so its placement — position, scale, rotation, perspective — is
  untouched.

## Layout

`Core/` PSDDocument, PSDCodec, PSDWriter · `Support/` Descriptor, EngineData, TypeToolBlock
(TySh, SoLd, lnk2), ChannelCodec (raw/PackBits/ZIP), TextRenderer, Compositor,
SmartObjectRenderer, LayerPixels · `Models/` · `Enums/` · `Errors/`.

## Requirements

macOS 26 / iOS 26, Swift 6.2.

## License

MIT — see [LICENSE](LICENSE). Test fixtures are psd-tools' own (MIT, see
`Tests/PSDKitTests/Fixtures/LICENSE-psd-tools`).
