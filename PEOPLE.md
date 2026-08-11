# innerjoin — people, and remembering them

_v1 · 2026-08-10. The build spec for identity, memory, and recall._

Everything else in innerjoin reads documents. This reads *people* out of them, and keeps
what it learns.

The test: **"Joanna" and "J. Ramirez" and "Joanna R." are one person, she works at Acme,
she's the landlord, and asking about her returns all of it with receipts.**

---

## 0. What's wrong today

The current system conflates a **mention** with an **identity**. A document names
"Kian J. Feiz"; resolution looks for an entity whose normalized name matches exactly,
finds none, and creates one. The name *is* the identity.

Consequences, all observed in a real run of three documents:

- `Kian Feiz` and `Kian J. Feiz` are two separate people. A middle initial split the
  owner of the library in half.
- All nine links say `mentions`. Not one says `employed_by`, though one document is a
  résumé. The graph knows Flex appears near him; it does not know he worked there.
- Nothing is stored *about* anyone. An entity row is a name, a normalized name, a kind,
  and a created-at. There is no answer to "who is this".
- `project` is not a kind, so projects are unrepresentable.
- There is no node for the user, so nothing can be "mine".

The merge failure has a precise cause. `Consolidate.sameThing` tests whether the short
name is a **prefix** of the long one:

```swift
Array(longWords.prefix(shortWords.count)) == shortWords
```

`["kian","feiz"]` versus the first two words of `["kian","j","feiz"]` — no match. A middle
initial is an *insertion*, and the rule only understands *truncation*.

---

## 1. Three layers

| layer | is | lifetime |
|---|---|---|
| **Mention** | a name exactly as written, in one document, at one anchor | immutable evidence |
| **Identity** | the person, organization, place, or project | survives re-reads |
| **Assertion** | a claim about an identity, with provenance and a date | accumulates |

The mention layer is the unlock, and not for tidiness:

- **Merges become reversible.** A merge re-points mentions; a split re-points them back.
  Today a merge destroys the alternative.
- **Re-extraction stops being destructive.** Re-reading a document produces new mentions.
  Identity decisions — especially the user's — survive it.
- **Every claim has receipts.** "Joanna works at Acme" resolves to specific anchors on
  specific pages.
- **Ambiguity becomes representable.** A mention may be *unresolved*. That is a legitimate
  state, and better than a confident wrong merge.

### 1.1 Schema

```sql
CREATE TABLE mention (
  id          INTEGER PRIMARY KEY,
  documentID  INTEGER NOT NULL REFERENCES document(id) ON DELETE CASCADE,
  elementTag  TEXT,                -- where on the page, when the model cited it
  surface     TEXT NOT NULL,       -- exactly as written: "J. Ramirez"
  normalized  TEXT NOT NULL,
  kind        TEXT NOT NULL,
  entityID    INTEGER REFERENCES entity(id) ON DELETE SET NULL,   -- nullable: unresolved is legal
  resolvedBy  TEXT,                -- exact | identifier | subsequence | initials | nickname | context | user
  confidence  REAL NOT NULL DEFAULT 1.0,
  UNIQUE(documentID, elementTag, normalized)
);

CREATE TABLE assertion (
  id             INTEGER PRIMARY KEY,
  subjectID      INTEGER NOT NULL REFERENCES entity(id) ON DELETE CASCADE,
  predicate      TEXT NOT NULL,
  objectEntityID INTEGER REFERENCES entity(id) ON DELETE CASCADE,
  objectValue    TEXT,             -- literal, when the object isn't an entity
  documentID     INTEGER REFERENCES document(id) ON DELETE CASCADE,
  elementTag     TEXT,
  assertedOn     DATETIME,         -- the DOCUMENT's date, not ingest time
  confidence     REAL NOT NULL DEFAULT 1.0,
  UNIQUE(subjectID, predicate, objectKey, documentID)
);
```

`entity` gains `firstSeenOn`, `lastSeenOn`, `isOwner`, and `pinnedName` (a user-chosen
display name that no re-read may overwrite). Mention counts are **not** stored — they're a
`COUNT(*)`, and a denormalized counter is a bug waiting to drift.

---

## 2. The resolution ladder

Cheapest and most certain first. All deterministic Swift — **no model calls**. A mention
resolves at the first rung that fires, and records which one.

| # | rung | rule |
|---|---|---|
| 1 | **exact** | same normalized name, same kind |
| 2 | **identifier** | shares an email or phone with a known identity — decisive regardless of spelling |
| 3 | **context** | name-compatible *and* co-occurs with an entity the candidate already knows |
| 4 | **unambiguous** | name-compatible *and* exactly one candidate in the whole library fits |
| 5 | — | otherwise leave unresolved, and offer it as "possibly the same" |

**Name compatibility** means any of:

- **subsequence** — `kian feiz` ⊆ `kian j feiz` (in order). Fixes the split; generalizes it.
- **initials** — `j. ramirez` matches `joanna ramirez` when the surname matches and the
  initial matches the given name's first letter.
- **nickname** — a small table: Bob/Robert, Jo/Joanna, Kate/Katherine.

Rung 4 is the safety rail and the most important rule here. Merge "J. Ramirez" into
"Joanna Ramirez" **only if she is the only Ramirez it could be.** If a Jose Ramirez also
exists, refuse. Most entity systems merge greedily and quietly corrupt themselves; the
discipline that makes this trustworthy is refusing to guess when the answer is genuinely
ambiguous.

Identifiers (rung 2) are the biggest cheap win available. An email address is a globally
unique key for a person, Vision already extracts them as detected data, and today they're
thrown away.

---

## 3. Assertions

Closed predicate list, for the same reason relations are closed: left open, a model
invents four spellings of "employer" and the graph becomes unqueryable.

| predicate | object | example |
|---|---|---|
| `works_at` | entity | Joanna → Acme |
| `role` | literal | Joanna → "Operations Lead" |
| `email` / `phone` | literal | also feeds rung 2 |
| `located_in` | entity | Acme → Madrid |
| `related_to` | entity | me → Joanna (qualified by `role`) |
| `owns` / `member_of` | entity | |

Rules:

- Assertions ride the **existing** Stage 3 call as one more array. No extra call, no extra
  cost.
- Gated like entities: the subject must be an admitted entity, the predicate must be in
  the list, and a literal object must appear in the document.
- `assertedOn` is the **document's** date. Which means the current answer is
  `ORDER BY assertedOn DESC LIMIT 1` and the history is free. People change jobs; a memory
  that can't represent that is a memory that lies.

---

## 4. The owner

There is no *you* in the graph today — worse, hub suppression deliberately deletes you, so
you don't fuse every category into one. That's right for clustering and wrong for
everything else: every relationship worth remembering is relative to you.

So: one identity flagged `isOwner`. Still excluded from clustering. Present for
relationships, which makes "my landlord" expressible as a path.

Relationship *type* is inferred and then **confirmed, never assumed**. Lessor on a lease →
landlord. Recurring work correspondence → colleague. Friend is not inferable from
paperwork, and being confidently wrong about how you know someone is the kind of error
that makes a person close the app for good.

---

## 5. Recall

`who "joanna"` stops being a file list:

```
Joanna Ramirez            person · 11 documents · Mar 2024 – Aug 2026
  works at    Acme Corporation        since 2026-03 [d14:e7]
              Globex                  2024-01 – 2026-02 [d3:e11]
  role        Operations Lead              [d14:e9]
  email       joanna@acme.com              [d14:e2]
  known as    Joanna R. · J. Ramirez · Joanna
  how I know  landlord (confirmed)
```

Every line opens the page it came from. `Ask` injects this profile when a question names
a person, so identity is resolved *before* retrieval runs.

---

## 6. What gets measured

Extended `ijeval`, scored like everything else:

- **person recall** — one person in five surface forms across seven documents resolves to
  one identity
- **no wrong merges** — two different people who share a surname stay apart
- **current employer correct** — the newer document wins
- **assertion provenance** — every assertion resolves to a real anchor

---

## 7. Built so far

Layers 1–3 and the resolution ladder are built, wired into ingestion, and covered by
checks. Verified against a real model on real documents: `Kian J. Feiz` now resolves to
`Kian Feiz` on the **unambiguous** rung and keeps the spelling as an alias, where before
it minted a second person.

**Known weakness, measured not guessed.** Assertion output is inconsistent across runs of
`deepseek-v4-flash`: the same résumé yields two facts on one run and none on the next.
Entities and fields don't wobble like this, so it's the newness of the instruction rather
than the model — assertions ask for something no other part of the prompt asks for. Worth
an exemplar in the prompt the way field names get one, and worth scoring in `ijeval`
before tuning further, which is the next piece of work.

## 8. Order of work

1. Mention layer + backfill from existing links _(no behaviour change; foundation)_
2. Resolution ladder replacing exact-match-only
3. Assertions on the existing call
4. Owner node, relationship inference with confirmation
5. Profiles in `who` and in `Ask`
6. Merge and split by hand — needs UI, and is non-negotiable. No rule set is ever right;
   what makes a memory feel good is fixing it once and never being asked again.
