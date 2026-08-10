# innerjoin — ingestion pipeline research

_Written 2026-08-07. How Unstructured works, what to copy, and the stages they don't have._

> **This doc holds research and rationale.** The build specification — contracts, schema, algorithms, failure handling, build order — lives in **[STAGES.md](STAGES.md)**. Read that one to implement; read this one to understand why.

## Part 0 — What a file actually becomes (the whole data model)

Drop `lease_final.pdf` and you get **one record**:

```
document   lease_final.pdf · sha256 · 8 pages · kept untouched in the vault
  └ record Residential lease — 1247 Fillmore St, Apt 4
      category  Apartment
      body      # Residential lease\n## 1. Parties\n... (markdown of the doc)
      fields    rent $3,200/mo [p3] · ends 2027-03-31 [p1]
                penalty 2 months [p8] · deposit $4,800 [p3]
      links     → M. Osei (person) · → 1247 Fillmore St (place)
```

Four tables, and that is the entire model:

| Table | One row per | Holds |
|---|---|---|
| `documents` | file you dropped | path, hash, type, page count, ingested-at |
| `records` | what innerjoin understood | category, title, markdown body, fields JSON, summary |
| `entities` | person / place / org seen across records | name, kind, merged aliases |
| `links` | relationship | `(src, rel, dst)` — record↔entity, record↔record |

**One document can yield several records.** A lease is one record; a bank statement is one record per transaction, each pointing back to the same document with its own page/row provenance. Keeps the model uniform — everything queryable is a record, every record names its document — and it's what lets the Finances table list transactions without inventing a second concept.

**The citation chain is plain foreign keys.** Every extracted field stores its own provenance stamp, so clicking a cited value walks: `field.page + field.bbox → record.document_id → documents.path` → open the file, jump to the page, draw the box. Nothing clever, and nothing that can drift out of sync.

```
records.document_id  →  documents.id          (many records : one file)
links(src, rel, dst)  →  "record:42" ⟷ "entity:7"   (many : many)
fields JSON           →  { value, page, bbox } per field
```

### The store is ordinary SQLite

One file per workspace. Not a vector database — vectors, when they arrive, are one more index over these same rows.

```sql
documents (id, path, sha256, filetype, pages, ingested_at)
records   (id, document_id, category, title, body_md, fields_json, summary,
           happened_on, amount, created_at)
entities  (id, name, kind, aliases_json)
links     (src, rel, dst)              -- "record:42", "party_to", "entity:7"

-- indexes over the same records, each serving a different surface
records_fts    FTS5(title, body_md, summary)   -- ⌘K keyword search
idx_happened   ON records(happened_on)          -- Today's "coming up"
idx_category   ON records(category)             -- sidebar + tables
embeddings     (record_id, vec BLOB)            -- semantic recall, added later
```

A vector index answers exactly one question well: *what is semantically similar to this?* But most of innerjoin isn't that question. "What expires in the next 90 days" is a date range. "Everything about 1247 Fillmore" is a join. "Total spent this year" is an aggregation. "Sorted by amount" is an ORDER BY. Today, dossiers, and tables are all SQL; only free-text ⌘K wants vectors. Making the vector store primary would mean reimplementing the relational parts badly on top of it.

**Elements are scaffolding, not a layer.** The typed element list from Stage 1 exists so the parser knows *where on the page* each piece of text came from. Its output survives as two things — the markdown body, and a page+bbox stamp on each extracted field — then it's a cached artifact, not a concept the app or the user ever sees. Cache it (re-OCR is expensive), don't model the product around it.

Simple version of the pipeline: **read the file → write the markdown → pull out the facts → link them up.** Stages 0–5 below are just that sentence with the failure modes handled.

## Part 1 — How Unstructured actually works

### The API surface

Two generations exist. The **legacy Partition endpoint** is the one worth modeling: POST a file, get back a flat JSON array of typed elements. Via SDK it's `client.general.partition_async(...)` with a `strategy` parameter; the response is a list of element dicts. The newer **Pipeline/Workflow API** wraps the same partitioner in a hosted job system with connectors (S3, Drive, Sharepoint), scheduling, chunking, embedding, and destination writes — that's the enterprise ETL layer, irrelevant to us.

Key request parameters: `strategy`, `coordinates` (bool — off by default, we always want it on), `chunking_strategy`, `languages`, `split_pdf_page`, `fields_include`, `flatten_metadata`.

### The four partition strategies

This is the most useful idea in their system, and it's a routing decision, not a model:

| Strategy | What it does | Cost |
|---|---|---|
| `fast` | pdfminer text-layer extraction + heuristics. Rule-based, seconds per doc. | ~free |
| `hi_res` | Layout-detection model (Detectron2-class) + table-structure recognition. Understands columns, figures, table cells. | slow, GPU optional, heavy deps |
| `ocr_only` | Straight to Tesseract. For scans with no text layer. | medium |
| `vlm` | Vision-language model reads the page. For image-heavy docs and screenshots. | API cost |
| `auto` | Picks one of the above per document. | — |

Note that **they themselves added a VLM strategy** — meaning "just let a multimodal model read the page" is now a first-class path in their own product. That's direct validation for skipping the layout-model tier.

### The element schema (the part worth stealing)

Every partitioner emits the same shape:

```json
{
  "type": "NarrativeText",
  "element_id": "a7f3c2e1b9d84a5f...",
  "text": "Tenant may terminate this Lease prior to expiration...",
  "metadata": {
    "filename": "lease_final.pdf",
    "file_directory": "/Users/v/Documents",
    "filetype": "application/pdf",
    "last_modified": "2026-03-12T16:41:00",
    "page_number": 8,
    "languages": ["eng"],
    "parent_id": "3d9e...",
    "category_depth": 1,
    "coordinates": {
      "points": [[72.0, 512.4], [72.0, 548.9], [540.0, 548.9], [540.0, 512.4]],
      "system": "PixelSpace",
      "layout_width": 612,
      "layout_height": 792
    }
  }
}
```

**Element types:** `Title`, `NarrativeText`, `ListItem`, `Table`, `Image`, `Header`, `Footer`, `PageNumber`, `PageBreak`, `Address`, `EmailAddress`, `Formula`, `FigureCaption`, `CodeSnippet`, `UncategorizedText`, `CompositeElement` (a chunk of merged elements).

Two fields do the heavy lifting for us: `coordinates` (→ pixel-accurate provenance highlighting) and `parent_id` + `category_depth` (→ document hierarchy, so a clause knows which section it lives under).

### Their chunking stage

After partitioning they group elements into chunks: `basic` (fill to `max_characters`, ignore structure) or `by_title` (start a new chunk at each Title, keeping sections intact). The output is `CompositeElement`s ready for embedding.

**This is where their pipeline ends — and where ours diverges.** Unstructured is a *RAG preprocessor*: its job finishes when text is clean and chunked. It never produces a fact, an entity, or a relation. Copying their workflow verbatim yields an ingredient, not the dish.

---

## Part 2 — The innerjoin pipeline

Stages 0–2 mirror Unstructured. Stages 3–5 are the product.

### Stage 0 · Intake
File arrives (drop or watch folder). SHA-256 hash for dedupe, `stat` for timestamps, UTI/MIME sniff for type. Original copied into the vault, `Document` row written. **Effort: days.**

### Stage 1 · Partition → `[Element]`

Native Swift dispatch by file type, emitting the Unstructured-compatible element schema above.

#### Verified on this machine (macOS 26 SDK, Swift 6.3.3, Command Line Tools — no Xcode needed)

`Vision.RecognizeDocumentsRequest` **replaces most of Unstructured's hi_res tier, on-device, in one call.** Probe run against a synthetic invoice returned:

```
title:       "ACME SUPPLY CO."                    ← title detection
paragraphs:  20                                    ← reading order
tables:      1  → rows=4 cols=4                    ← TABLE STRUCTURE RECOGNITION
  row0: ["Item", "Qty", "Price", "Total"]
  row1: ["Surgical gloves", "12", "$18.00", "$216.00"]
detectedData: 10
  • postalAddress(street: "1247 Fillmore St", city: "San Francisco", state: "CA", postalCode: "94115")
  • calendarEvent(endDate: 2026-09-15)
  • emailAddress("billing@acmesupply.com")
  • moneyAmount(currency: usd, amount: 216)
word[0] bbox: NormalizedRect(x: 0.0786, y: 0.9063, w: 0.1084, h: 0.0333)
```

That is layout detection, table-structure recognition, entity-ish data detection, and word-level coordinates — the exact capabilities that make Unstructured's install multi-gigabyte — free, native, offline. Also verified available: `NLTagger` NER (correctly tagged *M. Osei* → PersonalName, *Alcon Laboratories* → OrganizationName), `NLEmbedding.sentenceEmbedding` (512-dim, on-device — a free local embedding model for Stage 6, no download, no API cost), and `NSAttributedString.DocumentType.officeOpenXML` for DOCX without any third-party ZIP/XML work.

Caveats seen in the probe: OCR misread one character (`Fillmore` → `Filmore`) — real text-layer PDFs avoid this, but scans need the confidence score checked. And `calendarEvent` interpreted "due 2026-09-15" as a *range* starting today, so date detection needs its own normalization pass rather than being trusted raw.

#### Dispatch table

| Input | Technology |
|---|---|
| PDF with text layer | **PDFKit** — `PDFDocument`, `page.string`, `PDFSelection` + `characterBounds(at:)` for coordinates (`fast`) |
| PDF without text layer | **PDFKit** rasterize → `RecognizeDocumentsRequest` (`ocr_only` + `hi_res` in one) |
| Photos, screenshots | **`RecognizeDocumentsRequest`** + **ImageIO** for EXIF (capture date, GPS) |
| Pages that still look wrong | Page image → the user's model (`vlm` escalation) |
| DOCX | **`NSAttributedString(url:options:[.documentType: .officeOpenXML])`** — native |
| RTF / RTFD | **NSAttributedString** — native |
| XLSX | **CoreXLSX** (SPM) → `Table` elements |
| PPTX | **ZIPFoundation** + **XMLParser** |
| HTML | **SwiftSoup** (SPM) for structure-aware parsing |
| Markdown | **swift-markdown** (Apple, SPM) for a real AST |
| EML / EMLX | Hand-rolled MIME parser — headers, multipart boundaries, quoted-printable/base64, charset |
| CSV / TSV | Small quoting-aware parser → `Table` |
| TXT / JSON / XML | Foundation |
| Audio / video | **AVFoundation** to demux → Speech framework or whisper.cpp → timestamped transcript elements |
| `.msg` (Outlook) | OLE compound binary — **defer** |

Supporting cast: **UniformTypeIdentifiers** (`UTType`) for reliable type detection instead of extension sniffing, **CryptoKit** for SHA-256 dedupe, **GRDB.swift** for SQLite.

Routing rule (their `auto`, ours): text layer present and dense → use it; sparse or absent → rasterize and run document recognition; recognition confidence low or layout still ambiguous → escalate that page to the model.

**Third-party dependencies, total: GRDB, CoreXLSX, ZIPFoundation, SwiftSoup, swift-markdown.** Everything else is system frameworks.

**Effort: revised down to ~2 weeks** for PDF + images + text + DOCX, since the hard layout work is now an OS call.

### Format rule: store JSON, render markdown

**Markdown is for models to read; JSON is for programs to parse.** Both appear in this pipeline, at different boundaries:

| Boundary | Format | Why |
|---|---|---|
| Stage 1 → 2 (elements on the wire, on disk, in SQLite) | JSON | Machine-parseable, schema-stable, queryable |
| Stage 2 → 3 (rendition sent *into* the model) | Markdown | 2–3× cheaper in tokens than the same content as JSON; matches the training distribution; tables don't repeat column names per row |
| Stage 3 output (record coming *out of* the model) | JSON | Schema-enforced via structured output; regex-parsing markdown is fragile |
| Retrieved records → ⌘K / chat context | Markdown (YAML-ish header + body) | Same token argument, multiplied by 5–20 records per query |

Nesting is the tell: deeply nested JSON forces the model to track brace depth to know what belongs where, while markdown hierarchy is linear and visual. Tabular data is the extreme case — a 50-row table in JSON repeats every key 50 times.

**Short IDs in renditions.** The model must be able to cite elements, so the rendition carries anchors — but use short sequential ids (`[e12]`), never full hashes. A 16-char hash per element burns tokens and distracts attention; the store maps `e12` → full `element_id` → page + coordinates on the way back. Stage 3's `"source": "el_12"` fields refer to these short ids.

### Stage 2 · Assemble → document rendition
Instead of chunking for embeddings, flatten elements into one clean **markdown rendition** of the document: headings preserved, tables as markdown tables, lists as lists, headers/footers/page numbers dropped. Keep an element-id → character-offset map so any span can be traced back to page + bounding box. This rendition is the agent-ready text — small, ordered, readable. **Effort: ~1 week.**

### Stage 3 · Distill → record + entities + relations ← _Unstructured has no equivalent_
One model call per document. Input: the rendition (plus page images when the doc is visual) and the current taxonomy as a cached prompt prefix. Output:

```json
{
  "category": "Apartment",
  "new_category_proposal": null,
  "record": {
    "type": "lease",
    "title": "Residential lease — 1247 Fillmore St, Apt 4",
    "fields": {
      "rent_monthly":    { "value": 3200,         "unit": "USD", "source": "el_12" },
      "term_end":        { "value": "2027-03-31",                "source": "el_31" },
      "break_penalty":   { "value": "2 months rent",             "source": "el_44" },
      "deposit":         { "value": 4800,         "unit": "USD", "source": "el_18" }
    }
  },
  "entities": [
    { "name": "M. Osei",          "kind": "person", "role": "landlord" },
    { "name": "1247 Fillmore St", "kind": "place",  "role": "premises" }
  ],
  "relations": [
    { "from": "record", "rel": "governs",   "to": "entity:1247 Fillmore St" },
    { "from": "record", "rel": "party_to",  "to": "entity:M. Osei" }
  ],
  "dates": [
    { "kind": "term_end",       "date": "2027-03-31", "source": "el_31" },
    { "kind": "notice_deadline","date": "2026-09-30", "source": "el_44", "derived": true }
  ],
  "summary": "Two-bedroom lease at $3,200/mo running Apr 2024 – Mar 2027..."
}
```

Every value carries a `source` element id, which resolves through Stage 1 metadata to page + coordinates. **That chain is the citation system** — the ⌘K answer, the hover preview, and the dossier fact cards all read from it. **Effort: 1–2 weeks to a working version, then ongoing tuning.**

### Stage 4 · Resolve & link → the knowledge graph builds itself

Every insert grows the graph; there is no separate "build graph" step. Stage 3 already emitted entities and relations for one document — Stage 4 merges that fragment into the global graph.

**Entity resolution**, cheapest test first:
1. Normalize — lowercase, strip punctuation and corporate suffixes (`Inc`, `LLC`, `Ltd`), collapse whitespace.
2. Exact match on the normalized name → merge, record the surface form in `aliases_json`.
3. Fuzzy candidates — trigram similarity or edit distance above threshold → shortlist.
4. Only genuinely ambiguous shortlists go to the model, batched ("are *Alcon Labs* and *Alcon Laboratories, Inc.* the same?"). Most inserts never reach step 4.

**Relation vocabulary** — seeded, not closed. The model may propose new predicates; new ones are kept if they recur.

| record → entity | record → record |
|---|---|
| `mentions` (generic fallback) | `amends`, `supersedes` |
| `party_to`, `issued_by`, `paid_to` | `settles`, `duplicates` |
| `governs`, `covers`, `located_at`, `employed_by` | `references`, `contradicts` |

**Conflict detection** happens here too: when a new record contradicts a fact already on the graph, never overwrite. Write a `contradicts` link, mark the newer as current, and emit a "Worth a look" item. That path is exactly what produced the lease-amendment answer in the mockups. **Effort: 1–2 weeks; entity resolution is the part that needs iteration.**

### Stage 6 · Categories emerge from the graph

Categories are **named clusters of the knowledge graph**, not per-document guesses. A document classified alone is a coin flip; a document classified by what it connects to is usually obvious.

**Mechanism:**
1. **Projection** — two records are adjacent if they share an entity. (`records ⋈ links ⋈ links` — one SQL query, no graph library.)
2. **Community detection** — label propagation over that adjacency. Each record adopts the most common label among its neighbours; iterate until stable. Simple, fast, incremental, ~40 lines. Louvain if modularity ever needs tuning.
3. **Mass threshold** — a community becomes a category only at ≥ 4–5 records. Below that, records sit in *Everything else*. This is the hysteresis requirement, now falling out of the structure instead of being bolted on.
4. **Naming** — one model call per new community, given its top entities and record titles: "Apartment", "Health", "Freelance clients". Cheap and rare.
5. **Maintenance** — communities that fuse merge their categories (the old Bills → Invoices consolidation, now automatic); communities that split propose a split. Runs incrementally on insert (new record joins the community its entities point to) and fully on idle, not per-file.

**The model still gets a vote.** Stage 3's category hint is a prior; the graph is the decider. When they disagree, structure wins — the hint is one document's opinion, the graph is everything the library knows.

**Why this is better than classifying on ingest:** three loose travel receipts stay in *Everything else* until a flight confirmation and a hotel invoice link them through a shared date and vendor — and then *Travel* is born with five members, already correct. Categories reorganize as understanding grows, which is what "dynamic sorting" actually requires. **Effort: ~1 week for label propagation + naming; tuning ongoing.**

### Stage 5 · Index
FTS5 over rendition + record text + summary, structured columns for dates/amounts/category, edges table for traversal. Vectors deferred until a real query fails without them. **Effort: days.**

---

## Part 3 — Copy list

| Copy verbatim | Copy the idea | Don't copy |
|---|---|---|
| Element type taxonomy | Strategy routing (`fast`/`ocr`/`vlm` per document) | Chunking for embeddings — replaced by rendition + distillation |
| Metadata schema, esp. `coordinates`, `parent_id`, `category_depth` | `auto` fallback chain | Layout-detection + table-transformer models (months of work; the VLM path covers it) |
| Stable `element_id` hashing | Per-page splitting for large docs | Python runtime, Tesseract, poppler, ONNX — the multi-GB dependency tail |

**The one-line summary:** Unstructured turns documents into clean text. innerjoin turns clean text into linked facts. Stages 0–2 are theirs and worth copying closely; Stage 3 onward is the actual product and has no counterpart in their system.
