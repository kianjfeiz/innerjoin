# innerjoin-core

The on-device preprocessor: files in, clean markdown and located elements out.
No network, no API key, nothing leaves the Mac.

## Try it

```bash
swift run ijparse add ~/Downloads          # read a folder — no key needed
swift run ijparse list                     # what's in the library
swift run ijparse show 1                   # a document's markdown
swift run ijparse find "lease penalty"     # full-text search
swift run ijcheck                          # run the checks
```

With a model connected, files become records:

```bash
swift run ijparse key set anthropic sk-...  # stored in the keychain
swift run ijparse understand                # everything not yet understood
swift run ijparse record 1                  # fields, dates, links, with pages
swift run ijparse upcoming                  # dates read out of your documents
swift run ijparse who "Osei"                # every file mentioning someone
```

Workspaces live at `~/Library/Application Support/innerjoin/Personal` by default;
`-w <path>` picks another. A workspace is one folder: `innerjoin.sqlite` plus a
`files/` vault of originals.

## What runs

| Stage | Does | Technology | Needs a key |
|---|---|---|---|
| 0 · intake | hash, dedupe, copy into the vault, record the row | Foundation, CryptoKit, UTType | no |
| 1 · partition | file → typed elements in reading order, with coordinates | PDFKit, Vision, Speech, AppKit | no |
| 2 · rendition | elements → one markdown document with `[eN]` anchors | — | no |
| 3 · distill | markdown → a record, its entities, and its dates | the user's model | **yes** |

Stages 0–2 never touch the network, so innerjoin is a searchable library before any
model is connected; understanding backfills later. Stages 4–6 (fuzzy entity
resolution, embeddings, categories from graph clusters) are still to come — see
[../STAGES.md](../STAGES.md).

## Models

Any model, your key. Three ways in:

```bash
IJ_PROVIDER=anthropic  IJ_MODEL=claude-sonnet-5        # Anthropic Messages API
IJ_PROVIDER=openai     IJ_MODEL=gpt-4.1-mini           # OpenAI
IJ_PROVIDER=openai     IJ_BASE_URL=http://localhost:11434/v1  # Ollama, LM Studio, vLLM…
```

The OpenAI-compatible adapter covers most of the world, including fully local models —
so innerjoin can run end to end with nothing leaving the machine at all. Keys are read
from `IJ_API_KEY` or the login keychain, and are never written to the database or the
vault.

## Readers

| Format | How |
|---|---|
| PDF with a text layer | PDFKit — exact text, coordinates from the page itself |
| PDF without one, per page | rasterized at 200 dpi → Vision `RecognizeDocumentsRequest` |
| Images | Vision, plus EXIF capture date |
| DOCX, RTF, HTML | `NSAttributedString` — native, no unzipping |
| Markdown, text, JSON, XML | Foundation |
| CSV, TSV | quote-aware parser → a markdown table |
| Audio (m4a, mp3, wav…) | Speech framework — on-device, one element per utterance, stamped `[m:ss]` |

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
| No reader yet | `.xlsx`, `.pptx`, `.eml`, `.msg`, video. |
| Audio needs a language model | Downloaded on first use; offline afterwards. |
| Entity resolution is exact-match only | "Alcon" and "Alcon Labs" stay separate until Stage 4 adds fuzzy matching. |
