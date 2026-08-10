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
swift run ijparse key set anthropic         # paste when prompted — never in your history
swift run ijparse understand                # everything not yet understood
swift run ijparse record 1                  # fields, dates, links, with pages
swift run ijparse upcoming                  # dates read out of your documents
swift run ijparse who "Osei"                # every file mentioning someone
swift run ijparse tidy                      # merge duplicates, flag disagreements
swift run ijparse sort                      # re-derive categories from the graph
swift run ijparse name                      # what each file is now called, and why
swift run ijparse graph                     # is the graph healthy or bloating?
```

## Names

A file arrives called `scan_0001.pdf` or `Kian Feiz - ES COE Fall 2026.pdf`. Once it's
understood, the record already holds everything a filing clerk would have written on
the folder, so the library relabels it:

```
26-27 STEPS-BEFORE-ARRIVING-UC3M-EPS.pdf   →  Steps before arriving UC3M.pdf
inv_0042.pdf                               →  2026-03-01 Invoice — Alcon Supply.pdf
```

Shape is `date · subject · other party`, each part dropped when it's missing or already
said. No model call — it's a pure function of the record, so it's free and gives the
same answer twice. Three rules it holds to:

- **The arrival name is kept.** It's provenance; someone will look for the file by the
  name they gave it. `ijparse name` shows both.
- **Nothing on disk moves.** The original is the user's and the vault copy is addressed
  by content. `ijparse name --export <folder>` writes *copies* under the new names.
- **Nothing is invented.** No date unless the document states one; no name at all when
  extraction had nothing to say, in which case the file keeps what it arrived with.

## How the library learns from itself

No weights are fine-tuned — that isn't what a BYO-key app can do. What it does instead
is read each document with the benefit of every document read before it:

1. **Vocabulary feedback.** A category's field names are handed back to the model on
   the next document of that kind. Left to itself a model calls the same fact
   `rent_monthly`, then `monthly_rent`, then `rent_amount` — three columns where there
   should be one, and a table that can never be summed.
2. **A worked example.** One prior record from the same category is shown rather than
   described. It teaches more about what a good reading of *this kind of document*
   looks like than another paragraph of rules.
3. **A settling pass.** The first document of a kind was read with nothing to go on, so
   by the tenth it's the odd one out. `Refine` finds records whose field names disagree
   with their peers and reads them again in light of what the category has since
   settled on. It converges, and stops when nothing diverges.

Measured on the eval corpus, as a share of field uses landing on one agreed name:

| | nothing fed back | vocabulary fed back | after settling |
|---|---|---|---|
| coherence | 67% | 97% | 97% |

Settling runs automatically at the end of ingestion — it only re-reads the minority
that disagree, so it's a small fraction of extra calls. `ijparse settle` runs it by hand.

## Measuring it

```bash
swift run ijcheck    # 242 checks, deterministic, no key
swift run ijeval     # score the pipeline against a known-truth corpus
```

`ijeval` builds twenty-two documents across four areas of a life, in six formats,
plus three deliberately broken files — then runs them through a *simulated* model at
0%, 40% and 90% error. The point isn't the score with a perfect model; it's how
gently the numbers fall as the model gets worse, because that decay is the part we
control.

| | 0% error | 40% | 90% |
|---|---|---|---|
| files read | 100% | 100% | 100% |
| facts preserved | 100% | 100% | 100% |
| entities found | 100% | 100% | 100% |
| scenery kept out | yes | yes | yes |
| category purity | 94% | 94% | 93% |
| schema coherence | 97% | 97% | 97% |
| citations valid | 100% | 100% | 100% |
| named from contents | 100% | 100% | 100% |

Citation validity is the one held at 100%: a wrong category is a nuisance someone can
see and fix, but a citation that opens nothing is the app lying about where a fact
came from.

Four real defects came out of building this — role nouns formed by suffix
(*policyholder*) and paperwork words (*Deposit*, *Balance*) becoming entities; short
forms under four characters never merging, leaving 20% of entities as singletons; and
clustering counting one shared name once per group member, so raising the bar for
joining a category did nothing at all.

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
| 3b · name | record → a filename that says what the document is | — | no |
| 4 · consolidate | merge duplicate entities, flag records that disagree | NaturalLanguage | no |
| 5 · index | FTS5 over both the text and what was understood | SQLite | no |
| 6 · organize | categories from graph clusters, named by extraction's own votes | — | no |
| refine | re-read the documents that describe things unlike their peers | the user's model | **yes** |

Stages 0–2 never touch the network, so innerjoin is a searchable library before any
model is connected; understanding backfills later. Everything after Stage 3 is
arithmetic and SQL over what's already stored — see [../STAGES.md](../STAGES.md).
Embeddings (5b) are deliberately not built: they're gated on a query that demonstrably
fails full-text search.

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
| Email `.eml` / `.emlx` | MIME multipart, quoted-printable and encoded-word decoding; quoted replies dropped, attachments named |
| Spreadsheets `.xlsx` | Built-in zip reader, shared strings resolved, column gaps preserved |
| Slides `.pptx` | Built-in zip reader, slides ordered numerically |
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

## Keeping the graph clean

Models over-produce entities. Asked for people, organizations, and places, they hand
back the notary, the city, the state, the bank in the footer, and the word "Tenant" —
and each becomes a node that dilutes the graph. It matters more than it sounds:
categories will be derived from graph structure, so one hub entity attached to
everything collapses clustering into a single blob.

Five defences, none of which asks a model anything:

1. **The name must appear in the document.** A name absent from the text was invented.
   This catches fabrication outright.
2. **Roles are refused** — tenant, landlord, buyer, notary. Every lease has a tenant;
   naming one identifies nobody.
3. **Broad places are refused** — a city or state is a hub waiting to happen. A name
   containing a number survives, which is what makes a street address a real subject.
4. **A per-document cap** of 15, dropping lowest-confidence first. A document naming
   thirty parties is describing scenery.
5. **On-device recognition corroborates.** `NLTagger` reads the document independently;
   entities it also saw get confidence 1.0, model-only ones 0.75.

Relations are a **closed enum** in the schema. Left open, models invent `party_to`,
`is_party`, and `signatory_of` for one relationship and the graph stops being queryable.

Refusals are reported, never silent — `understand --verbose` lists each one with its
reason, because a rising refusal count is how you notice a prompt going wrong.

```bash
swift run ijparse graph        # is the graph healthy or bloating?
```

Two numbers matter. **Singletons** (entities touching exactly one record) are the
signature of over-production: a real entity eventually recurs, an invented one never
does. **Hubs** are the opposite failure — an entity attached to most of the library
carries no information, the way a stopword carries none in a search index. The command
warns above six entities per record, or when most entities are singletons.

## Known limits

Measured, not guessed — each of these was found by running adversarial documents.

| Limit | Effect |
|---|---|
| Multi-column pages: one paragraph may straddle the gutter | Reading order is correct — the gutter is found and each column read in turn — but PDFKit hands back an entire column glued to the first line of the next, and its glyph bounds are too unreliable to split on. |
| Résumé-style header rows merge | "Flex · San Jose, CA · Software Engineering Intern · May 2026" is a two-column row; company, location, title and dates come out as one line. |
| A shared organization can pull a document into the wrong category | A car registration and a health policy naming the same insurer look connected. Requiring two shared entities fixes it but strands a third of the library in "Everything else", which is worse. |
| Vision occasionally drops a table cell | Seen on both a rendered receipt and a text-layer table — one `Qty` cell came back empty. |
| OCR misreads happen | "Fillmore" → "Filmore" on a rendered page. Text-layer PDFs are unaffected. |
| Rotated pages ignore `page.rotation` | Coordinates would be wrong on a rotated scan. |
| DOCX tables flatten | `NSAttributedString` doesn't expose table structure; needs real XML parsing. |
| CSV: 500-row preview, no embedded newlines | Rows are split before quotes are parsed, so a quoted field containing a newline breaks. |
| No reader yet | `.msg`, video. |
| Audio needs a language model | Downloaded on first use; offline afterwards. |
| Entity resolution is exact-match only | "Alcon" and "Alcon Labs" stay separate until Stage 4 adds fuzzy matching. |
| A derived name carries day precision even when the document gave only a year | `Dates.parse` turns "2026" into 1 January, so a name could claim a day the document never stated. In practice documents that give only a year are undated things — handbooks, résumés — where extraction leaves the date empty anyway. |
