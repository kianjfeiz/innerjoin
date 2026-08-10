# innerjoin-core

The on-device preprocessor: files in, clean markdown and located elements out.
No network, no API key, nothing leaves the Mac.

## Try it

```bash
swift run ijparse add ~/Downloads          # read a folder
swift run ijparse list                     # what's in the library
swift run ijparse show 1                   # a document's markdown
swift run ijparse show 1 --json            # its elements, with coordinates
swift run ijparse find "lease penalty"     # full-text search
swift run ijcheck                          # run the checks
```

Workspaces live at `~/Library/Application Support/innerjoin/Personal` by default;
`-w <path>` picks another. A workspace is one folder: `innerjoin.sqlite` plus a
`files/` vault of originals.

## What runs

| Stage | Does | Technology |
|---|---|---|
| 0 · intake | hash, dedupe, copy into the vault, record the row | Foundation, CryptoKit, UTType |
| 1 · partition | file → typed elements in reading order, with coordinates | PDFKit, Vision, AppKit |
| 2 · rendition | elements → one markdown document with `[eN]` anchors | — |

Stage 3 (turning markdown into records, entities, and relations) is the first step
that needs a model, and isn't built yet. See [../STAGES.md](../STAGES.md).

## Readers

| Format | How |
|---|---|
| PDF with a text layer | PDFKit — exact text, coordinates from the page itself |
| PDF without one, per page | rasterized at 200 dpi → Vision `RecognizeDocumentsRequest` |
| Images | Vision, plus EXIF capture date |
| DOCX, RTF, HTML | `NSAttributedString` — native, no unzipping |
| Markdown, text, JSON, XML | Foundation |
| CSV, TSV | quote-aware parser → a markdown table |

The text-layer decision is made **per page**, so a scanned page inside a digital
document still gets read.

## Shape of the data

One file is one `document` row. Elements are parser scaffolding — they exist so a
fact can point back at the spot on the page it came from, and they're cached because
re-running recognition is expensive.

```
document   id · name · sha256 · type · pages · markdown · stage · status
element    documentID · position · tag ("e12") · kind · text · page · box · depth
```

Boxes are normalized `0...1` with a **top-left origin**. Vision reports bottom-left
and PDFKit works in points; both convert inside their own reader, so nothing
downstream has to think about it.

## Things worth knowing

- **Nothing bounces.** A file that can't be read still gets a row, with a plain-language
  reason in `problem`. It stays listed and findable rather than vanishing.
- **Adding is idempotent.** Re-adding identical bytes returns the existing document.
- **Headings beat numbering.** "14. Early Termination" set larger than body text is a
  heading, not a list item — contracts number their sections, and getting this backwards
  flattens a document's structure.
- **Body size is measured by character volume across the whole document**, not per page.
  A page that's mostly headings would otherwise decide heading size was normal.
- **Anchors go on facts**, not every paragraph: tables, and text containing a date,
  amount, or number. Anchoring everything wastes tokens and dilutes attention.
- **Checks run as an executable** (`swift run ijcheck`) rather than a test target,
  because swift-testing and XCTest both need a full Xcode install to link. Worth
  revisiting once Xcode is installed for the app.

## Redundancy

There is exactly one second pass, and it exists because the two PDF readers have
opposite strengths: PDFKit gives exact characters but knows nothing about tables;
Vision reconstructs table structure but can misread characters. So when a page
*looks* tabular, it's rasterized and read again, and only the table structure is
taken from that pass — text everywhere else still comes from the text layer.

Detecting "looks tabular" is geometric and cheap: PDFKit signals a column boundary by
stretching the last glyph of a cell so its bounds run to the next column (the "m" in a
header's "Item" comes back 204pt wide). Three rows sharing a boundary is a table.

Everything else is a single pass. Running each reader twice would cost double and
return the same answer — the failures worth defending against are logic errors and
junk input, not flakiness. What guards those instead:

- **Garbage text layers** (broken font encodings produce confident nonsense) are
  detected and sent to recognition instead.
- **Anchors are validated** — every `[eN]` in a rendition must resolve to a real element.
- **Recognition confidence is recorded** per element, ready for a low-confidence
  escalation once there's real data to set the threshold against.

## Known limits

Measured, not guessed — each of these was found by running adversarial documents.

| Limit | Effect |
|---|---|
| **Multi-column pages** merge into one block | Reading order usually survives, paragraph boundaries don't. Needs column detection. |
| Vision occasionally drops a table cell | Seen on both a rendered receipt and a text-layer table — one `Qty` cell came back empty. |
| OCR misreads happen | "Fillmore" → "Filmore" on a rendered page. Text-layer PDFs are unaffected. |
| Rotated pages ignore `page.rotation` | Coordinates would be wrong on a rotated scan. |
| DOCX tables flatten | `NSAttributedString` doesn't expose table structure; needs real XML parsing. |
| CSV: 500-row preview, no embedded newlines | Rows are split before quotes are parsed, so a quoted field containing a newline breaks. |
| No reader yet | `.xlsx`, `.pptx`, `.eml`, `.msg`, audio, video. |
