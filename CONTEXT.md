# innerjoin — project context

_Last updated: 2026-08-07. Single source of truth for product and architecture decisions. Update as decisions land._

> **Ingestion pipeline spec lives in [PIPELINE.md](PIPELINE.md)** — how Unstructured is built, what to copy, and the 6 stages of innerjoin's own pipeline.

## Reframe (2026-08-07) — build it as a craft project

Vahid's call after the competitive-landscape discussion: build it anyway, as a small, beautiful app — personal project first, given to friends, useful if nothing else. The goal is something people *love to look at* (the Dia logic: Chrome does the same thing, people choose Dia for the feel). Success metric = friends genuinely use it and love it, not market share. This dissolves the platform-compression objection; smallness is a feature. Market ambitions can be revisited if love shows up.

- Dropped: arithmetic/reconciliation verification as a pillar (Vahid: "I do not want an application that depends on arithmetic"). Verification shrinks to a detail: flag when sources disagree.
- Core loop unchanged: agent-ready information, dynamic sorting, pre-ready context to query.
- Connectors (GitHub, Drive) are part of the eventual vision but NOT v0.1 — drag-drop first, connector treadmill deferred.

## Non-chat surfaces (exploration 03, 2026-08-07)

Vahid asked what a non-chat-central interface looks like. Core argument: **a chat box requires the user to already know what to ask** — on a 200-file library, that burden falls on the person who dumped the files there precisely because they didn't want to track them. So the front door should surface questions the user didn't know existed. Four surfaces mocked in `design/exploration-03-nonchat.html`:

1. **Today / briefing (home)** — the app talks first. "Coming up" (dates extracted from documents: notice deadlines, warranty/passport expiries, with countdowns), "Worth a look" (conflicts between documents, price jumps, duplicates), "Just read" (recent ingests and what was extracted), and suggested questions seeded by new files. The only surface that pays off a background engine — value accrues while the app is closed.
2. **Entity dossier** — every person/place/org found across files gets an auto-compiled page: fact cards with per-fact provenance, a document timeline, linked entities. This is the join made browsable; the closest thing to the original Obsidian instinct.
3. **Category table** — any category as a sortable/filterable spreadsheet with CSV export. Where "actionable data" gets literal.
4. **⌘K palette** — chat demoted from front door to command bar; answers inline with a source line, plus matching records and documents. No thread required.

Known cost: briefing + dossiers need date extraction, entity resolution, and change detection before they render anything, whereas chat needs only retrieval and a text box. Decision pending on whether v0.1 leads with Today or ships chat-first and grows into it.

## v0.1 — the lovable core

Drop files in → watch them get understood and sorted (sidebar categories bloom — this animation IS the product's magic moment) → browse records → ask questions, get concise cited answers. Nothing else.

Scope cuts for v0.1 (resolves the previously open questions): ingestion = drag-drop only; chat = single simple chat pane (saved chats later); outputs = view/copy only (exports later); auth = paste-a-key in settings (Sign in with Claude later); no connectors, no workspace switcher UI (storage stays multi-ready), no MCP server, no video (PDFs, images, text, Office docs first).

Design direction (settled 2026-08-07, exploration-02 round 3): **clean native macOS, one window**, with restrained creative touches. Inspo: unstructured.io site (sky gradients, black chrome, tight heavy type) + Dia. Rules: sky wash (cyan→white→lemon) as the app's signature light, spread across sidebar/page/drop states/dark-mode aurora; accent gradient #54C7FF→#2E7CF6 — the sky is the accent, **NO pink** (explicitly rejected); gradients on every surface, no flat solids; dense/full layouts, no deadspace; pills for chips/badges; SF Pro + SF Mono metadata; candy dots (blue/amber/green) mark file types only; 200–260ms ease-out motion, no overshoot. Sidebar has character (not a ChatGPT clone): workspace card with ⋈ + stats + gradient strip, record-stack glyphs, per-category volume bars — the sidebar is a picture of the library. "Thinking live" narrated retrieval + hoverable citation pills with passage previews. An earlier neo-brutalist direction (design/exploration-01.html) was REJECTED. Current reference: design/exploration-02.html.

## One-liner

A native Mac app that ingests any file — invoices, contracts, photos, video, whatever — extracts structured records with the user's own AI model, links them into a self-organizing knowledge base, and answers questions through a chat that always shows its receipts.

## Vision & positioning

- **The product is the join, not the chat.** Value = trustworthy structured records extracted from heterogeneous files and linked to each other (invoice ↔ vendor ↔ contract ↔ payment). Chat is the front door, not the identity.
- **Consumer product, explicitly NOT a dev tool.** All harness mechanics (models, prompts, tokens) hidden behind defaults. "A harness in the engine bay, an appliance in the hand."
- **Feels autonomous.** Zero-setup: no schema config, no category setup, no manual review. The system organizes, verifies, and maintains itself.
- Name meaning: the inner join — relational structure discovered across unrelated files.
- **Built for agents first (north star, 2026-08-07).** innerjoin is a platform holding information that is easy, enjoyable, and QUICK for agents to understand. The stored representation is optimized for machine consumption: small, textual, structured, instant to load into context. Raw binaries are never the interface.

## Target user

- v1: single users (prosumers, small-business owners) processing personal/business documents. Vahid is first user (eye care practice paperwork: invoices, receipts, statements — real weekly workflow, QuickBooks endpoint).
- Later: teams/companies (thousands of docs, multi-user). Design decisions must not paint us into single-user corners.

## Settled decisions

### Product & UX
- **Primary surface:** small window; sidebar of categories scoped by workspace/account; main area is a chat that (1) gives concise, structured answers and (2) cites the records it used, with one-click navigation to those records.
- **Record detail:** clicking a citation opens the record — extracted fields, provenance (which page/region of the source each value came from), links to related records.
- **Universal intake from day one.** Any file type accepted; documents-grade quality first, media via transcription.
- **Knowledge graph builds itself on every insert** (2026-08-07). Extraction emits entities + relations per document; Stage 4 resolves them into the global graph (normalize → exact match → fuzzy shortlist → model adjudicates only ambiguous cases). Seeded-but-open relation vocabulary. Contradictions become `contradicts` links rather than overwrites, which is what feeds "Worth a look". See [PIPELINE.md](PIPELINE.md) Stage 4.
- **Categories: fully dynamic, derived from graph structure** (revised 2026-08-07 — supersedes per-document classification). Categories are *named clusters of the knowledge graph*: project records into an adjacency by shared entities, run label propagation, and a community becomes a category only at ≥4–5 records (hysteresis now falls out of the structure instead of being bolted on). One cheap model call names each new community. Fused communities merge categories automatically (the old Bills→Invoices consolidation); split communities propose splits. The extraction call's category guess survives as a *prior* — the graph decides. Rationale: a document classified alone is a coin flip; classified by what it connects to it's usually obvious, and categories reorganize as understanding grows. Still no extra LLM call per document — routing rides in the single extraction call, and clustering is pure SQL + local computation.
  - Each category accretes its own extraction schema + few-shot examples from its documents — this IS the "custom trained agents" concept, born automatically.
- **Workspaces:** multi-workspace storage layout from day one (each workspace = own vault, categories, chats); simple switcher UI in v1. Retrofitting later = painful migration, so built in now.

### Verification — no manual review (important reversal)
- **Rejected:** "fix a field" human review loop. Doesn't scale to thousands of docs, and users don't know the correct values from memory anyway.
- **Principle: don't bank on extraction being perfect — bank on wrong extractions being unable to hide.**
  1. **Arithmetic self-checks** — documents self-verify (line items → subtotal → tax → total). Deterministic, free.
  2. **Cross-document reconciliation** — same fact in multiple docs (invoice ↔ statement ↔ payment) must agree. The join IS the auditor; more documents = more self-verification. Core product story.
  3. **Extraction consensus** — second cheap verify pass on extracted fields; disagreement flags the record.
- Humans see only a **flagged-exceptions queue** (~2%), each flag pinned to the highlighted source region — resolving one is a 5-second glance, no memory of numbers required.

### Architecture
- **Stack: native Swift + SwiftUI** (decided 2026-08-07).
- **Three-layer store — agents never read binaries (decided 2026-08-07):**
  1. **Source layer** — originals (PDFs, photos, video). Kept for provenance click-through and future re-processing only. Cold storage; never in the agent hot path.
  2. **Record layer — the actual product.** Ingestion-time distillation of every file into structured text: extracted fields, entities, relations, a markdown rendition, transcripts for media. Compact and context-ready; this is what chat and agents consume.
  3. **Index layer** — SQLite + FTS (embeddings later) over the record layer for instant retrieval.
- **Model calls happen once per document, at ingestion, in the background.** Query time is pure text/SQL — zero model reads of binaries. Ingestion cost control: local text extraction first (PDFKit text layers are free), model vision only for pages that need it (scans/photos), cheap model tier for routine extraction, Batches API (50% price) for large backlogs.
- **Parsing: OPEN — leaning Apple frameworks + model-native at ingest** (comparison done, decision pending; see Open questions). Note: the parsing choice only affects the ingestion step — every option feeds the same record layer, so the agent-speed concern is resolved by the three-layer design regardless. Whatever is chosen sits behind a `Parser` interface so alternatives (e.g. Unstructured hosted) can slot in later.
- **Agent-native access via local MCP server: a FEATURE, not the identity** (revised 2026-08-07 after Vahid flagged the collision with supermemory). Exposing the record layer over MCP is a cheap, valuable integration ("your other agents can read your vault"), but "the memory layer for all your agents" as a *pitch* is supermemory/Mem0/Zep territory — funded, API-first infrastructure players. innerjoin does not compete there. Identity stays: verified structured records from real-world files, local, consumer.
- Media path (all parsing options): local transcription for video/audio (Apple Speech or whisper.cpp); images via Vision OCR / model vision.
- Provenance: Vision OCR word-level bounding boxes power click-to-source highlighting.
- **Store: plain SQLite via GRDB.swift — not SwiftData/Core Data** (decided 2026-08-07). SQLite *is* a file, which makes the zero-setup + zero-custody storage requirement automatic: one file to back up, sync, or delete, no server or daemon, ships with macOS. Single-user means SQLite's write-concurrency limits never bite, and FTS5 comes free. SwiftData/Core Data rejected because they own the schema opaquely — bad for a product whose pitch is "your data outlives the app" — and fight raw SQL, FTS, and portability. GRDB gives migrations, type-safe queries, and a straight escape hatch to raw SQL. If innerjoin ever goes multi-user/server, the migration is Postgres + pgvector and is mechanical, since it stays SQL either way.
- **Yes, this is still RAG.** ⌘K and chat are retrieval-augmented generation — retrieve, stuff into context, generate a cited answer. The clarification: RAG's retrieval step is not required to be vector search. Here it's SQL + FTS + graph edges (vectors added later), and the retrieval *unit* is a distilled record rather than a raw document chunk — no chunk-boundary damage, provenance built in, more facts per token of context. Note also that Today, dossiers, and tables are NOT RAG: they're queries rendered directly as UI with no generation step. RAG is one feature of the app, not the app's architecture.
- **Retrieval architecture (decided 2026-08-07): one store per workspace, three access paths over the same records. NOT one vector DB per category.**
  - **Partition on workspace, not category.** Each workspace = its own SQLite file + vault (real privacy boundary, never a cross-workspace query). Categories are a *property on a record*, never a container — this is what keeps dynamic sorting free: re-categorizing, merging (Bills → Invoices), or renaming is a field update, not a data migration. Per-category vector DBs would turn every taxonomy change into a migration and every cross-category join (the product's whole point) into an N-store fan-out + re-rank. "Search only Finances" is `WHERE category = 'finances'`, a filter, not a partition. At 10²–10⁵ records there is no scale argument for splitting.
  - **Graph, not tree.** Records and entities are both nodes; typed edges connect them (invoice —issued_by→ vendor, email —amends→ lease §14, payment —settles→ invoice). A tree forces one parent per document, which is exactly the filing-cabinet problem the app exists to kill — an invoice belongs to a vendor *and* a month *and* a project. In SQLite the graph is just an `edges(src, rel, dst)` table; no graph DB needed. Entity nodes are what make the dossier surface possible.
  - **Three access paths, one file:** (1) structured SQL over fields/dates/amounts — powers tables, filters, and most of the Today briefing, which is date arithmetic rather than semantic search; (2) graph traversal over edges — powers dossiers and joins; (3) semantic search over record text — powers ⌘K free-text. Keeping them in one SQLite file means a single hybrid query can filter, traverse, and rank together instead of joining in app code.
  - **Sequencing:** start with FTS5 + structured queries + edges. Add embeddings only when a real query demonstrably fails without them. When they land, embed the distilled *records* (already small and clean), not raw document chunks. At this scale a brute-force cosine pass in Swift via Accelerate/vDSP is genuinely sufficient — a vector extension is optional, not foundational.

### Model access & auth
- **BYO intelligence.** Primary: "Sign in with Claude"-style OAuth (verified Aug 2026: live via the Claude Agent SDK path; users' usage bills to their own Claude account). Fallback: pasted API key for power users, buried in settings.
- **Platform risk noted:** Anthropic changed third-party billing terms twice in mid-2026 (extra-usage-credits pool announced, paused, revised). "Sign in with ChatGPT" (launched 2026-08-02) is identity-only — no subscription compute. Build auth behind an abstraction so terms shifts are a module swap.
- Consumer-grade: no model pickers, prompts, or token meters on the main surface; advanced drawer for the 5%.
- **No key wall on first run** (2026-08-07). Stages 0–2 (intake → parse → markdown) are 100% on-device: PDFKit, Vision, NSAttributedString, pure Swift. So innerjoin is a working, full-text-searchable file library *before* the user connects any model. Onboarding becomes: drop files → they appear and are searchable immediately → "connect a model to unlock understanding" as a second, optional step. Understanding then backfills the existing library. The key is needed only at Stage 3 (distill, ~1 call per document) and rarely at Stage 4 (ambiguous entity merges, batched) and Stage 6 (naming a new category).

### Storage & privacy
- **Local-first, zero custody.** Single-user file vault on the user's Mac for v1. Data never touches our servers; only egress is to the user's chosen model provider.
- Canonical store: file vault per workspace; derived index (SQLite) rebuildable.
- "Accounts" in v1 = local workspaces, not cloud identities. Cloud enters only for multi-device/team later (bring-your-own storage vs managed-encrypted tier — deferred v2 fork; keep a clean storage interface).

### Business
- **Free beta → subscription** (decided 2026-08-07). Marginal costs ~zero (local-first + BYO keys) during validation; introduce subscription once retention is proven.

## Open questions (dismissed mid-session 2026-08-07 — revisit)

1. **Parsing decision** — leaning resolved 2026-08-07 after costing out "copy Unstructured natively." Verdict: **steal the ontology, not the pipeline.**
   - Unstructured OSS is Apache 2.0, so forking is legal — the question is only effort and fit. Its stack splits in two: (a) a format-dispatch layer producing typed Elements (Title, NarrativeText, Table, ListItem, Header…) with metadata (page number, coordinates, parent_id); (b) an ML layout tier (document layout detection, table-structure recognition, reading order for multi-column pages) plus Tesseract OCR — the part that drags in PyTorch/ONNX/poppler and makes the install multi-GB.
   - **(a) is a few weeks in native Swift** and mostly plumbing: PDFKit for text layers, Vision `VNRecognizeTextRequest` for OCR (Live Text quality, word-level bounding boxes — powers provenance highlighting), ZIPFoundation + XMLParser for DOCX/PPTX, CoreXLSX for spreadsheets, MIME parsing for EML, SwiftSoup for HTML, trivial for text/MD/CSV/JSON. `.msg` is the ugly outlier.
   - **(b) is months plus research risk — and is largely redundant here.** Layout models exist to give clean text to systems that can't see a page. innerjoin's extraction model *can* see: send the page image and it handles columns, tables, and reading order natively. Local layout parsing is therefore a token-cost optimization, not a capability requirement — it matters at 10k-page scale, not at craft-app scale.
   - **Copy their element taxonomy + metadata schema** (Title/NarrativeText/Table/ListItem + page/coords/parent_id). That's an afternoon's data-model work and it's the genuinely valuable, portable part — it gives the record layer a clean internal representation and keeps a future swap to Unstructured hosted a drop-in behind the `Parser` interface.
2. **Ingestion methods for v1** — drag-drop / watch folders / menu-bar drop / Share extension (multi-select).
3. **Chat structure** — multiple saved chats vs one persistent conversation vs ephemeral ask bar.
4. **"Actionable data" outputs for v1** — tables + CSV/XLSX export / generated reports / accounting (QuickBooks) export / chat-only.

Other open items (not yet discussed in depth):
- Onboarding flow (first-launch experience; when does Sign in with Claude happen).
- Exact vault file format (plain markdown + frontmatter vs opaque store; earlier leaning: markdown for Obsidian-compat trust story — never finalized).
- Chunking strategy for very large documents (600-page/32MB API limits).
- Beta distribution (TestFlight vs direct notarized download) and first external users.
- Subscription price point and what gates it.

## Competitive landscape (as of Aug 2026)

- **supermemory / Mem0 / Zep / Letta** — the "memory layer for agents" infrastructure category. supermemory: universal memory API, five-layer context stack, memory graph, cloud + self-hostable open-source binary (can run fully local with Ollama). Developer-first — you integrate it with code. **Differentiation: memory vs records.** They store time-annotated semantic traces optimized for *recall* ("help the agent remember context"); nothing in that stack audits whether a recalled number is correct. innerjoin stores typed, *verified* records (arithmetic checks, cross-doc reconciliation, pixel-level provenance) optimized for being *right*, packaged as a consumer appliance. Recall vs reconciliation; context vs ledger.
- **NotebookLM / ChatGPT projects / chat-with-docs** — commoditized; no persistent structured layer, no verification, cloud custody.
- **DEVONthink** — classic local Mac document library; trust + local-first overlap, but no LLM extraction/joins/verification.
- **Positioning sentence:** supermemory remembers what your agents saw; innerjoin verifies what your documents say.

## Known risks

- **Sign in with Claude terms instability** — mitigated by auth abstraction + key fallback.
- **Extraction accuracy on messy scans** — mitigated by verification stack; quality ceiling without Unstructured accepted for v1.
- **Long-tail file formats** — owned by us under Apple+model-native parsing; graceful fallback ("stored, not yet understood") required.
- **Taxonomy drift** — mitigated by hysteresis + self-consolidation; needs real-data testing.

## Next steps

1. Resolve the 4 open questions above.
2. Pipeline spike: ~20 real documents (practice invoices/receipts) → parse → extract → verify; measure flag rate and join quality. This de-risks the core bet before UI work.
3. Mock the main window against real extracted data.
