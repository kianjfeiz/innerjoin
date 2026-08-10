# innerjoin — pipeline stages, build specification

_v1 · 2026-08-07. This is the **build spec**: contracts, algorithms, failure handling, order of work._

> **Status: stages 0–6 are built and passing** (131 checks) — see [core/](core/) and its [README](core/README.md).
> Only stage 3 needs a model; everything else runs on-device. Stage 5b (embeddings) is
> deliberately deferred until a real query is shown to fail on full-text search.
>
> Decisions taken during the build, superseding the proposals below:
> - **One document is one record.** The multi-record/ledger split is dropped; line items live inside a record's fields. Simpler schema, no orphan concepts.
> - **Markdown lives on the document row**, not its own table.
> - **Migrations are incremental** — v1 covers only `document`, `element`, and FTS. Later stages add their own tables rather than shipping empty ones.
> - **`DatabasePool`, not `DatabaseQueue`** — the UI must read while ingestion writes.
> - **Checks run as an executable** (`ijcheck`), because swift-testing and XCTest both need a full Xcode install to link. Revisit when Xcode is installed for the app.
> - **Vision's `RecognizeDocumentsRequest` handles table structure natively**, so no table-recognition work is needed.
> - **Audio yes, video no** — Speech framework, one element per utterance, timestamps in place of coordinates.
> - **Entity over-production is gated deterministically** (name must appear in the document, roles and broad places refused, per-document cap, NLTagger corroboration) — see core/README.md.
> - **Relations are a closed enum**, not an open vocabulary; left open, models invent four spellings of one predicate.
> - **Category naming needs no extra call** — the per-document guesses from stage 3 are aggregated as votes by the cluster.
> - **Hub share is 0.6, not 0.4** — a library splits into a few groups, so the entity defining each one legitimately reaches ~50%.
_Companion doc [PIPELINE.md](PIPELINE.md) holds the **research and rationale** — how Unstructured works, what we copy, why SQL over vectors._
_Points marked **⟨DECIDE⟩** need your call before or during implementation._

---

## 0. Principles

1. **Nothing bounces.** Every file that enters produces a `document` row, even if every later stage fails. A file we can't understand is still stored, still listed, still full-text searchable.
2. **Degrade in layers.** Stage failures are survivable: no OCR still gives a file entry; no model call still gives searchable markdown; no entities still gives a record. Each stage adds capability, none is load-bearing for the ones before it.
3. **Idempotent by hash.** Re-ingesting a byte-identical file is a no-op. Re-running a stage replaces that stage's output cleanly.
4. **One model call per document.** Extraction, categorization hint, and entity emission all ride in it. Extra calls are exceptional (ambiguous entity merge, naming a new category).
5. **Provenance is never reconstructed.** Coordinates are captured at parse time, when the parser already knows them, and carried forward. Never inferred later by string search.
6. **Store JSON, render markdown.** Structured on disk; markdown at every boundary that faces a model.

---

## 1. Data model

### 1.1 SQLite schema

```sql
CREATE TABLE documents (
  id           INTEGER PRIMARY KEY,
  path         TEXT NOT NULL,           -- vault-relative
  original_name TEXT NOT NULL,
  sha256       TEXT NOT NULL UNIQUE,    -- dedupe key
  uti          TEXT NOT NULL,           -- com.adobe.pdf
  byte_size    INTEGER NOT NULL,
  page_count   INTEGER,
  created_at   TEXT,                    -- from filesystem/EXIF, not ingest time
  ingested_at  TEXT NOT NULL,
  stage        TEXT NOT NULL,           -- furthest completed: intake|partition|assemble|distill|resolve|index
  status       TEXT NOT NULL,           -- ok | partial | failed
  error        TEXT
);

CREATE TABLE elements (                 -- cache, not a product concept (see §2.2)
  id           INTEGER PRIMARY KEY,
  document_id  INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  seq          INTEGER NOT NULL,        -- reading order
  short_id     TEXT NOT NULL,           -- "e12" — what the model cites
  type         TEXT NOT NULL,
  text         TEXT NOT NULL,
  page         INTEGER,
  bbox         TEXT,                    -- JSON [x,y,w,h] normalized 0–1
  parent_id    INTEGER REFERENCES elements(id),
  depth        INTEGER NOT NULL DEFAULT 0,
  confidence   REAL,
  UNIQUE(document_id, short_id)
);

CREATE TABLE renditions (
  document_id  INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
  markdown     TEXT NOT NULL,
  token_est    INTEGER NOT NULL
);

CREATE TABLE records (
  id           INTEGER PRIMARY KEY,
  document_id  INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
  kind         TEXT,                    -- lease | invoice | policy | transaction | note | ...
  title        TEXT NOT NULL,
  body_md      TEXT,                    -- rendition or the slice of it this record covers
  fields_json  TEXT NOT NULL,           -- see §1.3
  summary      TEXT,
  happened_on  TEXT,                    -- primary date, ISO-8601, for Today + timeline
  amount       REAL,                    -- primary amount, for tables + sums
  currency     TEXT,
  category_id  INTEGER REFERENCES categories(id),
  category_hint TEXT,                   -- the model's guess; graph may override
  created_at   TEXT NOT NULL
);

CREATE TABLE entities (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL,           -- canonical surface form
  norm_name    TEXT NOT NULL,           -- normalized, for matching
  kind         TEXT NOT NULL,           -- person | org | place | product | account
  aliases_json TEXT NOT NULL DEFAULT '[]',
  created_at   TEXT NOT NULL
);
CREATE INDEX idx_entities_norm ON entities(norm_name, kind);

CREATE TABLE links (
  id           INTEGER PRIMARY KEY,
  src          TEXT NOT NULL,           -- "record:42" | "entity:7"
  rel          TEXT NOT NULL,
  dst          TEXT NOT NULL,
  confidence   REAL NOT NULL DEFAULT 1.0,
  document_id  INTEGER REFERENCES documents(id) ON DELETE CASCADE,  -- provenance
  UNIQUE(src, rel, dst)
);
CREATE INDEX idx_links_src ON links(src);
CREATE INDEX idx_links_dst ON links(dst);

CREATE TABLE categories (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL,
  community_id INTEGER,                 -- label from clustering
  member_count INTEGER NOT NULL DEFAULT 0,
  is_holding   INTEGER NOT NULL DEFAULT 0,  -- 1 = "Everything else"
  created_at   TEXT NOT NULL
);

CREATE TABLE dates (                    -- extracted temporal facts → Today's "coming up"
  id           INTEGER PRIMARY KEY,
  record_id    INTEGER NOT NULL REFERENCES records(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL,           -- term_end | expires | due | notice_deadline | renewal
  date         TEXT NOT NULL,           -- ISO-8601
  derived      INTEGER NOT NULL DEFAULT 0,  -- computed (e.g. term_end − 60d) vs stated
  short_id     TEXT                     -- source element
);
CREATE INDEX idx_dates_date ON dates(date);

CREATE VIRTUAL TABLE records_fts USING fts5(
  title, body_md, summary, content='records', content_rowid='id'
);

CREATE TABLE embeddings (               -- Stage 5b, deferred
  record_id    INTEGER PRIMARY KEY REFERENCES records(id) ON DELETE CASCADE,
  vec          BLOB NOT NULL,
  dim          INTEGER NOT NULL,
  model        TEXT NOT NULL
);
```

### 1.2 Swift types

```swift
struct Document: Identifiable, Codable {
    var id: Int64?
    var path: String
    var originalName: String
    var sha256: String
    var uti: UTType
    var byteSize: Int
    var pageCount: Int?
    var createdAt: Date?
    var ingestedAt: Date
    var stage: Stage
    var status: Status
    var error: String?

    enum Stage: String, Codable, CaseIterable {
        case intake, partition, assemble, distill, resolve, index
    }
    enum Status: String, Codable { case ok, partial, failed }
}

enum ElementType: String, Codable {
    case title, narrativeText, listItem, table, image
    case header, footer, pageNumber, address, emailAddress
    case formula, figureCaption, codeSnippet, uncategorized
}

struct Element: Identifiable, Codable {
    var id: Int64?
    var documentID: Int64
    var seq: Int
    var shortID: String          // "e12"
    var type: ElementType
    var text: String
    var page: Int?
    var bbox: BBox?              // normalized 0–1, origin top-left (we flip Vision's)
    var parentID: Int64?
    var depth: Int
    var confidence: Double?
}

struct BBox: Codable, Equatable { var x, y, w, h: Double }

struct Rendition: Codable {
    var documentID: Int64
    var markdown: String
    var tokenEstimate: Int
}

struct FieldValue: Codable {
    var value: JSONValue          // string | number | bool | date
    var unit: String?
    var source: String            // short element id — "e12"
    var page: Int?
    var bbox: BBox?
    var confidence: Double?
}

struct Record: Identifiable, Codable {
    var id: Int64?
    var documentID: Int64
    var kind: String?
    var title: String
    var bodyMD: String?
    var fields: [String: FieldValue]
    var summary: String?
    var happenedOn: Date?
    var amount: Decimal?
    var currency: String?
    var categoryID: Int64?
    var categoryHint: String?
}

struct Entity: Identifiable, Codable {
    var id: Int64?
    var name: String
    var normName: String
    var kind: EntityKind
    var aliases: [String]
    enum EntityKind: String, Codable { case person, org, place, product, account }
}

struct Link: Codable {
    var src: NodeRef             // .record(42) / .entity(7)
    var rel: String
    var dst: NodeRef
    var confidence: Double
    var documentID: Int64?
}
```

### 1.3 `fields_json` shape

```json
{
  "rent_monthly": { "value": 3200, "unit": "USD", "source": "e12", "page": 3,
                    "bbox": [0.12, 0.44, 0.31, 0.03], "confidence": 0.97 },
  "term_end":     { "value": "2027-03-31", "source": "e31", "page": 1,
                    "bbox": [0.55, 0.18, 0.22, 0.02], "confidence": 0.99 }
}
```

Field keys are `snake_case`, model-proposed, and reused across a category as it stabilizes (this is the mechanism behind "each category grows its own schema").

---

## 2. Stages

### Stage 0 · Intake

**Purpose** — get the file into the vault and the database, safely and idempotently.

| | |
|---|---|
| **In** | A file URL (drop, watch folder, or CLI arg) |
| **Out** | One `documents` row, `stage = intake` |
| **Tech** | Foundation, CryptoKit (SHA-256), UniformTypeIdentifiers |

**Steps**
1. Security-scoped resource access; read bytes streaming (don't load 500 MB into memory).
2. SHA-256 over contents. If the hash exists → **stop, return existing document id.** Not an error; report "already have this."
3. Identify type via `UTType(filenameExtension:)` cross-checked against magic bytes — extensions lie.
4. Copy into the vault at `vault/<yyyy>/<sha-prefix>/<original_name>`; never move or modify the user's original.
5. Read filesystem dates; for images, prefer EXIF `DateTimeOriginal` as `created_at`.
6. Insert row.

**Failure modes** — unreadable/permission-denied → `status=failed`, keep the row with the error so it's visible rather than silently dropped. Zero-byte file → failed. Unknown type → proceed anyway; Stage 1 decides.

**Effort** — 2–3 days.

---

### Stage 1 · Partition → elements

**Purpose** — turn any file into an ordered list of typed elements with coordinates.

| | |
|---|---|
| **In** | `documents` row + vault file |
| **Out** | `elements` rows (ordered by `seq`, each with a `short_id`) |
| **Tech** | PDFKit · Vision `RecognizeDocumentsRequest` · NSAttributedString · CoreXLSX · ZIPFoundation · SwiftSoup · swift-markdown · AVFoundation |

**Dispatch** (`Partitioner` protocol, one conformer per family — this is the seam that lets Unstructured's hosted API drop in later):

```swift
protocol Partitioner {
    static func handles(_ uti: UTType) -> Bool
    func partition(_ doc: Document, at url: URL) async throws -> [Element]
}
```

| Family | Implementation notes |
|---|---|
| **PDF, text layer** | `PDFDocument` → per page `page.string`; coordinates via `PDFSelection` + `characterBounds(at:)`. Classify blocks into `title`/`narrativeText`/`listItem` by font size and position relative to page median. |
| **PDF, no text layer** | Rasterize at ~200 dpi (`page.draw(with:to:)`) → `RecognizeDocumentsRequest`. |
| **Images** | `RecognizeDocumentsRequest` directly. ImageIO for EXIF. |
| **DOCX / RTF** | `NSAttributedString(url:options:[.documentType:.officeOpenXML])`; walk paragraph styles for heading levels. No page coordinates available → `page = nil`, `bbox = nil` (see §4.2). |
| **XLSX / CSV / TSV** | One `table` element per sheet; `bbox` unused, cell address recorded in text. |
| **PPTX** | ZIPFoundation + XMLParser; one group per slide. |
| **HTML** | SwiftSoup; map `h1–h6` → `title` with `depth`, `li` → `listItem`, `table` → `table`. |
| **Markdown** | swift-markdown AST → direct element mapping. |
| **EML / EMLX** | Parse headers → an `emailAddress`/`address` element set + `title` from Subject; body by MIME part, preferring `text/plain`, falling back to HTML via SwiftSoup. Attachments recursed as **their own documents**, linked `attached_to`. |
| **TXT / JSON / XML** | Paragraph split on blank lines. |
| **Audio / video** | AVFoundation demux → transcription → one element per utterance, `page = nil`, time offset stored in text prefix. ⟨DECIDE⟩ defer to v0.2? |

**Coordinate normalization.** Vision returns normalized rects with **origin bottom-left**; PDFKit uses a **bottom-left point space**; our `BBox` is **normalized, origin top-left** to match how the UI will draw. Convert at the boundary, once, in each partitioner. Every partitioner is tested for this specifically — it's the classic silent-bug source.

**Short IDs.** Assigned `e0, e1, e2…` in reading order, stable per document. These, not database ids, are what appear in the rendition and in the model's `source` fields.

**Escalation rule** — if a page yields fewer than N characters, or mean OCR confidence is below threshold, mark the page `needs_vlm`. Stage 3 sends that page's image alongside the rendition. ⟨DECIDE⟩ thresholds: suggest 40 chars / 0.5 confidence to start, tune on fixtures.

**Failure modes** — encrypted PDF → `failed` with a clear reason ("password protected"). Corrupt file → failed. Unsupported type → emit a single `uncategorized` element containing filename + type so the document is still searchable and listed.

**Effort** — ~2 weeks for PDF, images, text, Markdown, DOCX, CSV. Another week for XLSX, PPTX, HTML, EML.

---

### Stage 2 · Assemble → rendition

**Purpose** — one clean markdown document per file, plus the anchor map that makes citations work.

| | |
|---|---|
| **In** | `elements` |
| **Out** | `renditions` row |
| **Tech** | pure Swift |

**Rules**
- `title` → `#`/`##`/`###` by `depth`; `narrativeText` → paragraph; `listItem` → `-`; `table` → markdown table; `codeSnippet` → fenced.
- **Drop** `header`, `footer`, `pageNumber` — repeated furniture, pure token waste.
- Insert page markers as HTML comments (`<!-- p3 -->`), invisible to humans, readable by the model.
- Anchor policy: append `[e12]` after elements that carry citable facts — tables, numbers, dates, named entities — **not** after every paragraph. ⟨DECIDE⟩ simplest v1: anchor every element that is a `table`, or whose text matches a number/date/currency regex.
- Token estimate: `chars / 3.7` is close enough for routing decisions.

**Large documents.** If `token_est` exceeds the Stage 3 budget, split at top-level headings into sections; each section is distilled separately and the resulting records merged under the same document. ⟨DECIDE⟩ budget — suggest 60k tokens per call.

**Effort** — ~1 week.

---

### Stage 3 · Distill → records, entities, relations

**Purpose** — the one model call. Turn readable text into structured, sourced facts.

| | |
|---|---|
| **In** | rendition markdown (+ page images for `needs_vlm` pages) + taxonomy prefix |
| **Out** | one or more `records`, plus proposed `entities` / `links` / `dates` |
| **Tech** | user's model via the provider abstraction; structured output enforced |

**Prompt assembly** (order matters for caching — stable parts first):
1. System: role, output contract, provenance rule ("every field must cite a `[eN]` anchor from the document; if you cannot cite it, omit it").
2. **Taxonomy block** — current categories with one-line descriptions + example field keys. Stable across documents ⇒ cached prefix.
3. Few-shot examples drawn from the *hinted* category's accumulated corrections.
4. The rendition.

**Output schema** (enforced, not parsed):

```json
{
  "category_hint": "Apartment",
  "propose_new_category": null,
  "records": [{
    "kind": "lease",
    "title": "Residential lease — 1247 Fillmore St, Apt 4",
    "summary": "Two-bedroom lease at $3,200/mo, Apr 2024 – Mar 2027.",
    "happened_on": "2024-03-14",
    "amount": 3200, "currency": "USD",
    "fields": {
      "rent_monthly": { "value": 3200, "unit": "USD", "source": "e12" },
      "term_end":     { "value": "2027-03-31", "source": "e31" },
      "break_penalty":{ "value": "2 months rent", "source": "e44" }
    },
    "dates": [
      { "kind": "term_end", "date": "2027-03-31", "source": "e31" }
    ],
    "entities": [
      { "name": "M. Osei", "kind": "person", "rel": "party_to", "source": "e7" },
      { "name": "1247 Fillmore St", "kind": "place", "rel": "governs", "source": "e3" }
    ]
  }]
}
```

**Multi-record rule.** ⟨DECIDE⟩ Proposal: emit multiple records when the document is a *ledger of independent, individually-citable events* — bank statements, invoice batches, receipts in one scan. Otherwise one record. Implement as an explicit instruction plus a cap (e.g. 500 records/document) so a runaway parse can't flood the library.

**Validation before write**
- Every `source` must resolve to a real `short_id` on this document; unresolvable → drop the field and log. This is the guard against invented provenance.
- Dates normalized and sanity-checked (reject year < 1900 or > +50y).
- `amount` parsed to `Decimal`, never `Double`.

**Derived dates** are computed *after* the model returns, in Swift, not by the model: `notice_deadline = term_end − notice_period`. Deterministic, testable, no arithmetic asked of an LLM.

**Failure modes** — API error → retry with backoff (3×), then `status=partial`; the document keeps its rendition and stays searchable. Schema violation → one repair retry, then partial. Model returns zero records → create a minimal record from title + summary so it still appears in the library.

**Effort** — 1–2 weeks to working, then continuous prompt tuning.

---

### Stage 4 · Resolve → merge into the knowledge graph

**Purpose** — turn per-document fragments into one graph.

| | |
|---|---|
| **In** | proposed entities + links from Stage 3 |
| **Out** | `entities`, `links` rows; conflict flags |
| **Tech** | Swift + SQL; NLTagger as a cross-check; model only for ambiguous merges |

**Entity resolution ladder** (stop at first hit)
1. **Normalize** — lowercase, strip accents, drop corporate suffixes (`Inc`, `LLC`, `Ltd`, `Co`), collapse whitespace/punctuation.
2. **Exact** `norm_name` + `kind` match → merge, append the surface form to `aliases_json`.
3. **Alias hit** — surface form already in some entity's aliases → merge.
4. **Fuzzy** — trigram similarity ≥ 0.85 *and* same `kind` → candidate shortlist.
5. **Adjudicate** — batch shortlists into one model call per ingest run ("same or different?"). ⟨DECIDE⟩ or auto-merge above 0.95 and only ask between 0.85–0.95.
6. No match → create a new entity.

`NLTagger` runs on the rendition independently; entities the model claimed that NER also saw get confidence 1.0, model-only ones 0.8. Cheap corroboration, no extra call.

**Conflict detection.** When a new record asserts a field that an existing record on the same entity contradicts: never overwrite. Write `record:new —contradicts→ record:old`, mark the newer current by `happened_on`, and queue a "Worth a look" item. ⟨DECIDE⟩ initial scope — compare only same-key fields on records sharing an entity, string/number equality. Anything cleverer is v0.2.

**Effort** — 1–2 weeks; fuzzy thresholds will need real-data tuning.

---

### Stage 5 · Index

**Purpose** — make everything queryable.

| | |
|---|---|
| **In** | records, links |
| **Out** | FTS rows, structured columns populated, counters refreshed |
| **Tech** | SQLite FTS5; later `NLEmbedding` |

- FTS5 external-content table synced by trigger on `records`.
- `happened_on`, `amount`, `category_id` are real columns with indexes — Today and the tables read these directly.
- **5b, deferred:** embeddings via `NLEmbedding.sentenceEmbedding` (512-dim, on-device, free). Brute-force cosine with Accelerate. Gate: build only when a real query is shown to fail on FTS.

**Effort** — 2–3 days (5b: 2 days when triggered).

---

### Stage 6 · Organize → categories from graph structure

**Purpose** — categories that emerge and reorganize, with no user setup.

| | |
|---|---|
| **In** | records + links |
| **Out** | `categories` rows; `records.category_id` assigned |
| **Tech** | SQL projection + label propagation in Swift; one model call to name a new community |

**Algorithm**
1. **Project** — records are adjacent when they share an entity:
   ```sql
   SELECT a.src AS r1, b.src AS r2, COUNT(*) AS weight
   FROM links a JOIN links b ON a.dst = b.dst AND a.src < b.src
   WHERE a.dst LIKE 'entity:%' AND a.src LIKE 'record:%' AND b.src LIKE 'record:%'
   GROUP BY r1, r2;
   ```
2. **Label propagation** — each record adopts the highest-weight label among neighbours; iterate to a fixed point or 20 rounds. Ties broken by lowest record id for determinism (tests depend on this).
3. **Mass threshold** — a community becomes a category at **≥ 5 records**; below that its members sit in the holding category. ⟨DECIDE⟩ 5 is a guess; tune on real libraries.
4. **Name** — one model call given the community's top entities and record titles. Reuse an existing category name if the model says it's the same thing.
5. **Maintain** — communities that fuse merge their categories (keeping the higher-`member_count` name); communities that split above threshold propose a split.

**Scheduling** — incremental on insert (a new record joins the community its entities already point to; no re-clustering). Full pass debounced: on idle, or after 25 new records, whichever first. Never per-file.

**Effort** — ~1 week.

---

## 3. Orchestration

```swift
actor IngestCoordinator {
    // Stages 0–2: CPU-bound, TaskGroup, width = ProcessInfo.activeProcessorCount − 1
    // Stage 3:    network-bound, separate semaphore (default 3 concurrent)
    // Stages 4–6: serialized — they mutate shared graph state
    // All DB writes go through one serialized GRDB DatabaseQueue
}
```

- Each document advances independently; a slow model call never blocks other files' parsing.
- `documents.stage` is the resume point — a crash mid-run continues from the last completed stage.
- Stage 6 is triggered by the coordinator, not by documents.
- ⟨DECIDE⟩ backpressure on a 5,000-file drop: suggest queue with a visible count and process continuously rather than throttling — the UI already has the "Reading N files…" chip.

---

## 4. Cross-cutting

### 4.1 Errors
Retriable (network, rate limit) → exponential backoff, 3 attempts. Terminal (corrupt, encrypted, unsupported) → record and move on. **Never** fail an entire batch because one file failed.

### 4.2 Documents without coordinates
DOCX, EML, CSV, and transcripts have no page geometry. `page`/`bbox` are nil, and citation click-through opens the document scrolled to a text match rather than drawing a box. The UI must handle a nil bbox from day one — plan for it in the mockup, not as an afterthought.

### 4.3 Observability
Per document, log: stage timings, bytes, page count, element count, token estimate, model tokens in/out, cost. This is what tells us whether ingest is too slow or too expensive, and it's the data behind any "advanced" inspector panel later.

### 4.4 Testing
- **Golden files** — `fixtures/<name>.<ext>` + `expected/<name>.elements.json`. Partitioner output must match exactly; diffs are reviewed, not auto-blessed.
- **Coordinate tests** — every partitioner asserts a known element's bbox against a hand-checked value.
- **Stage 3 is mocked** by default; a `--live` flag runs real calls in a separate suite. Tests must never require an API key.
- **Property tests** — every field's `source` resolves; no record without a document; short ids unique per document.
- **Fixture set** — text-layer PDF, scanned PDF, screenshot PNG, multi-column PDF, DOCX, XLSX, EML with attachment, CSV, encrypted PDF (expected failure), zero-byte file (expected failure).

---

## 5. Build order

| # | Deliverable | Proves |
|---|---|---|
| 1 | Package skeleton, types, schema, migrations, `ijparse` CLI shell | it compiles and the DB opens |
| 2 | Stage 0 + Stage 1 (text-layer PDF only) → `ijparse doc.pdf --json` | end-to-end spine on day one |
| 3 | Stage 1 images + scanned PDFs via `RecognizeDocumentsRequest` | the coordinate/OCR path, the riskiest parser work |
| 4 | Stage 2 rendition + anchors → `ijparse doc.pdf --md` | the artifact the model will read |
| 5 | Stage 3 with a **mock** provider, then live | the schema and validation, without burning tokens |
| 6 | Stage 4 + 5 | the graph and search |
| 7 | Stage 6 | categories appear without being configured |
| 8 | Remaining partitioners (DOCX, XLSX, HTML, EML, PPTX) | breadth, once the spine is proven |

Steps 1–4 need no API key and no network — a fully testable preprocessor before a single token is spent.

---

## 6. Open decisions

| # | Question | Proposal |
|---|---|---|
| 1 | Multi-record threshold — when is one file many records? | Ledgers only; cap 500/doc |
| 2 | Anchor density in renditions | Tables + anything matching number/date/currency |
| 3 | Stage 3 token budget per call | 60k, split at headings above it |
| 4 | Entity auto-merge threshold | Auto ≥ 0.95, ask 0.85–0.95 |
| 5 | Category mass threshold | 5 records |
| 6 | VLM escalation thresholds | < 40 chars/page or < 0.5 confidence |
| 7 | Audio/video in v0.1? | Defer to v0.2 |
| 8 | Model tier for extraction | Start with the mid tier; measure quality before spending up |
| 9 | Keep `elements` rows forever, or drop after rendition? | Keep — re-OCR is expensive, and it's a small table |
