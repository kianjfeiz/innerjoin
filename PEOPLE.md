# dunes — people, and remembering them

_v1 · 2026-08-10. The build spec for identity, memory, and recall._

Everything else in dunes reads documents. This reads *people* out of them, and keeps
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
- **nickname** — a public table of 1,423 short forms. One-to-many and noisy, so it
  proposes and never decides.
- **surname** — a lone word the other name contains: `Gandhi` for `Mahatma Gandhi`.
  Documents refer to people this way constantly ("per Ms. Ramirez"), and refusing it was
  the single largest source of missed matches — 40% → 61% recall on real name variants.
  Confined to people: turned loose on organizations and places it reached "Fillmore" for
  "1247 Fillmore St" and cost 19 points of category purity. Proposes, never decides.
- **typo** — one word misspelt, every other word identical.
- **similar** — Jaro-Winkler ≥ 0.92 over the whole name, *and* ≥ 0.82 over what's left
  once the shared words are set aside. The second test exists because the first is
  dominated by whatever the two names have in common, and Jaro-Winkler's prefix bonus
  doubles down on it — "Mohammad Hatta" and "Mohammad Ahsan" scored as near-identical on
  the strength of the word identifying neither.

**And three rules about what *can't* match**, each found by measurement rather than
reasoning, and each the same shape: the part of a name doing the identifying is the part
the fuzzy rungs treat as noise.

- **generations and reigns** — `Robert Feiz Jr` is not `Robert Feiz Sr`; `Gordian II` is
  not `Gordian III`. Only when both names carry a mark, so a surname that happens to be a
  Roman numeral ("Li", "Vi") can't be misread as one.
- **numbers** — the same rule where the numeral is a digit and there are no spaces to find
  it between: Japanese writes Gordian III as `ゴルディアヌス3世`. Compared position by
  position, because a number that *adds* isn't a number that *contradicts*: "1247 Fillmore
  St, Apt 4" elaborates on "1247 Fillmore St".
- **middle initials** — when both names state them and they differ. `George W. Bush` is a
  literal subsequence of `George H. W. Bush`, and the ladder merged a father into his son.
  Silence isn't disagreement: `Kian Feiz` against `Kian J. Feiz` still matches.

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

Extended `duneseval`, scored like everything else:

- **person recall** — one person in five surface forms across seven documents resolves to
  one identity
- **no wrong merges** — two different people who share a surname stay apart
- **current employer correct** — the newer document wins
- **assertion provenance** — every assertion resolves to a real anchor

---

## 7. Measured

### Against real names, from every naming system

`duneseval --names` scores the matcher against names drawn from Wikidata, where the truth is
real rather than invented: a differing Q-number is a different person, and an `altLabel` is
a name the same person is genuinely known by. 753,083 pairs across eleven naming systems —
Han, kana, Cyrillic, Arabic, Spanish double surnames, Icelandic patronymics, Dutch
particles, Indonesian mononyms, Vietnamese surname-first.

Every corpus before this one was Anglo-American, and so was every rule in the ladder.

| | before | after |
|---|---|---|
| wrong merges, all systems | 105 | **31** |
| Han (no spaces) | 6 | **0** |
| kana | 7 | **1** |
| Vietnamese | 1 (24.6 per 10k) | **0** |
| Indonesian | 1 | **0** |
| Spanish | 56 | **16** |
| alias recall (reachable) | 42% | **61%** |
| FEBRL recall | 58% | 55% |

The one number that moved the wrong way is FEBRL's, and it is worth being plain about:
three points of recall on a synthetic single-culture benchmark bought a two-thirds
reduction in wrong merges on real names from eleven cultures. FEBRL's errors are
substitutions inside a word, which is the one thing the distinguishing-word floor makes
harder to accept.

**What the misses look like now.** The remaining recall gap is mostly not reachable by any
string algorithm: `Mahatma Gandhi` ↛ `M. K. Gandhi`, because "Mahatma" is an honorific and
his given name was Mohandas. Knowing that is world knowledge, not string comparison.

### Two things that looked obviously right and weren't

Both were tried, measured over four runs each, and reverted. They are recorded because the
reasoning behind each still looks sound, and the next person to have the idea should get
the measurement for free.

**Closing the category vocabulary.** Relations and predicates are closed enums, and closing
them stopped them fragmenting; categories were the last open vocabulary. Pinning them in
the schema made it *worse* — purity fell from a mean of 75% to 64%, and the spread across
four runs widened from 14 points to 43. The difference is where the vocabulary comes from:
relations are a fixed list written once, categories are learned from whatever has been
filed so far, and documents are read in parallel. Closing a *learned* list hands whichever
documents finish first the power to define the shelves and forces every later document to
choose among them — amplifying the ordering noise rather than damping it.

**Refusing a category that repeats the document's type.** A shelf called "Statements"
collects one document type from every corner of a life, and the eval showed exactly that.
Refusing it raised purity's mean 75% → 80%, but the bands overlapped almost entirely
([67–81] against [67–85]), coverage clearly fell 84% → 79%, and answer accuracy lost the
perfect stability it had held over four runs. By the standard set above — believe it when
the bands separate — purity didn't move and coverage did.

Chasing that one down did find a real bug, in a place I'd spent a while blaming the model
for. The impure shelves were not proposed by the model at all: when a cluster's vote fails,
`Organize.name(for:)` falls back to the document type, and it built that label as
`kind + "s"`. `"policy" + "s"` is **"Policys"** — the misspelt shelf I had been attributing
to a careless reading was written in Swift, by me.

### On measurement itself

The pipeline's numbers move between runs that are byte-identical in every input, and it
took a wasted afternoon in a previous session to stop attributing that to code.

`temperature: 0` and a fixed `seed` do **not** make this model reproducible. Tested
directly: the same request three times returned replies of 2347, 2366 and 2368 characters.
A one-line question does come back identical, which is what makes the promise so easy to
believe. The provider returns no `system_fingerprint`, so there isn't even a way to notice
when the machine underneath changes.

So a single run is one sample. `duneseval --real --repeat N` reports mean and spread, and a
change is only believable when the bands separate. Across four runs of the corpus, ten of
eleven metrics were pinned at 100% with zero spread; **category purity was the only
unstable one**, at 67–81%. That is where the variance lives, and knowing that is worth
more than any single run's number.

The deterministic benchmarks — `--names`, `--linkage`, `dunescheck` — have none of this
problem, which is exactly why the resolver work is measured there and the numbers above
are exact.

### Against the identity corpus


`duneseval --people` runs a corpus built to break resolution: one person in four spellings,
a second person sharing her surname, a nickname, a job change, and a known relation per
document. Ingested one file at a time, in order, because order is part of what's tested.

| | before | after |
|---|---|---|
| person recall | 100% | 100% (71–100% across runs) |
| **wrong merges** | 0 | **0 — every run, without exception** |
| current employer | 100% | 100% |
| history kept | 100% | 100% |
| relations correct | **0%** | **100%** |

Five defects came out of it, each found by a number moving rather than by inspection:

1. **Every relation was `mentions`.** `relation` wasn't in the schema's `required` list, so
   the model omitted it and the code defaulted. The graph knew who appeared near what and
   nothing else. Requiring the field and defining the vocabulary took it to 100%.
2. **An abbreviated node absorbed anyone.** When one document failed, the only Ramirez in
   the library was literally "J. Ramirez" — and Jose merged into Joanna. Expanding an
   abbreviation needs something to expand it *to*; the distinction is *skipping* an
   initial ("Kian Feiz" vs "Kian J. Feiz", safe) versus *expanding* one (not safe).
3. **Truncated replies, intermittently.** A router fans one model across several upstream
   providers and they don't all honour the same parameters — most runs disabled reasoning
   as asked, one in four ignored it, spent the whole token budget thinking, and returned
   an object cut off mid-field. `require_parameters` made routing match the request.
   Output tokens went from swinging 1,689–9,624 to a stable 1,800–1,987.
4. **The nickname table was 41% wrong.** Replaced my thirty hand-written entries with a
   public dataset of 2,823 — and discovered that 41% of real short forms stand for more
   than one name. "Jo" is Joan, Joann, Joanna, Joanne, Jocelyn *and* Jody. The dataset is
   also noisy in a dangerous direction: it lists `robert` as a short form of `bill`. So
   nicknames became evidence rather than proof — they resolve only with corroboration.
5. **Corroboration depended on list order.** "Jo Ramirez confirmed the Acme renewal"
   corroborates Jo through Acme, but only if Acme resolved first. One pass made that a
   coin flip on the order the model listed names in, and cost 29% of person recall while
   the evidence sat two lines further down the same document. Resolution now runs in two
   passes: settle the certain names, then use them as context for the rest.

### Against the published benchmark

`duneseval --linkage` scores name matching on **FEBRL**, the standard public test set for
person record linkage — synthetic people carrying the errors real data carries, with
ground-truth duplicates. 5,792 labelled pairs, half of the negatives sharing a surname so
the test isn't trivial. The comparison is fair on information: FEBRL's own labels use
address and date of birth, so no name-only matcher can reach full recall, and the baseline
sees exactly what the ladder sees.

| | precision | recall | F1 | same-surname people wrongly merged |
|---|---|---|---|---|
| the ladder, before | 98% | **36%** | 53% | 14 |
| the ladder, with graded similarity | 99% | **58%** | 73% | 18 |
| Jaro-Winkler ≥ 0.90 (the baseline) | 98% | 59% | 74% | 21 |
| Jaro-Winkler ≥ 0.95 | 99% | 50% | 67% | 9 |

Two things came out of running it, neither of which introspection would have found.

**The strongest rung fired on none of it.** FEBRL's errors are substitutions and
transpositions — the corruption real names actually suffer — not truncations or initials.
So rung 4, the only rung allowed to decide alone, matched zero duplicates, and every
correct match came through rungs that demand corroboration.

**The published algorithm beat the ladder outright**, 59% recall against 36% at the same
precision. Adding graded similarity as a last, weakest rung closed the gap. The threshold
is 0.92 rather than the 0.90 the literature favours, because the costs here aren't
symmetric: a split is visible and gets fixed, a wrong merge is silent and poisons every
answer about both people.

### Rarity, and the question that looked like a product decision

Corroboration was binary: a weak resemblance needed a shared identifier or a shared
context, full stop. That capped recall, and loosening it looked like a trade against the
wrong-merge rate — a judgement call rather than an engineering one.

It isn't. Fellegi-Sunter's central idea is that evidence is *weighted by rarity*, and a
shared surname is not one quantity of evidence: "Ramirez" in a library holding one
Ramirez nearly identifies a person, while "Smith" among twelve narrows almost nothing.
Demanding the same corroboration for both refuses the safe cases along with the dangerous
ones.

Measured on FEBRL, letting a weak match stand where the surname is rare recovers **21% of
recall at 99% precision, and wrongly merges exactly as many same-surname people as
refusing every weak match — seven, either way.** Free recall.

One flaw the checks caught immediately: rarity is a statistic, and over three people it
means nothing — every surname looks rare and the test licenses everything, so `Jan Smith`
merged with `Jon Smith`. It now requires a population of at least twelve before it counts
for anything; below that, corroboration is still required.

### Against the published approaches

Splink, dedupe and fastLink all implement **Fellegi-Sunter**: score each field's agreement
by how often it agrees between true matches versus random pairs, sum the log-likelihoods,
compare to a threshold. The shape here is the same — score, then cluster — with two
deliberate differences. The ladder is *ordered* rather than summed, so every decision can
be traced to the rule that made it; and where those tools tune a threshold to trade
precision against recall, this refuses outright when more than one candidate fits. That
suits a personal library, where a split is visible and a wrong merge is not.

Two things they have that this doesn't, both noted below.

## 7. Built so far

Layers 1–3 and the resolution ladder are built, wired into ingestion, and covered by
checks. Verified against a real model on real documents: `Kian J. Feiz` now resolves to
`Kian Feiz` on the **unambiguous** rung and keeps the spelling as an alias, where before
it minted a second person.

**What's left, in order of value.**

- **Transitive closure.** Resolution is greedy in ingest order, so A=B and B=C don't force
  A=C. `Consolidate` mops up afterwards, which is the weak version. Scoring pairs into a
  graph and taking connected components would also make the result independent of the
  order files arrived in — which it currently isn't.
- **Rarity weighting, the Fellegi-Sunter idea.** A shared "Smith" is weak evidence and a
  shared "Ramirez" is strong, and the ladder treats them alike. The library's own name
  frequencies are enough to weight this; no external table needed.
- **Blocking.** Every candidate is compared against every entity. Fine at 5,000 people,
  quadratic past that.
- **Human correction.** No rule set is ever right. The mention layer already makes a
  merge a re-pointing operation, so this is a UI job rather than an engine one.

**The bottleneck has moved.** Every remaining failure in the measurements is the *model*
wobbling on a single document — one run in three loses a relation or an assertion — not
the resolver getting identity wrong. Further engine tuning would be polishing the part
that already works.

## 8. Order of work

1. Mention layer + backfill from existing links _(no behaviour change; foundation)_
2. Resolution ladder replacing exact-match-only
3. Assertions on the existing call
4. Owner node, relationship inference with confirmation
5. Profiles in `who` and in `Ask`
6. Merge and split by hand — needs UI, and is non-negotiable. No rule set is ever right;
   what makes a memory feel good is fixing it once and never being asked again.
