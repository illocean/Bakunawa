# Bakunawa

![Bakunawa preview](bakunawapreview.png)

Windows PowerShell 5.1 cleaner for **local disk C: only**, with cleanup previews and application-aware cache and orphan review.

> **Nothing is deleted without a preview first.** Preview plans the same candidates Standard would act on and touches no file. Deletion is permanent: there is no recovery copy.

## How a run flows

```mermaid
%%{init: {'themeVariables': {'fontSize': '15px'}}}%%
flowchart LR
    start(["Bakunawa.ps1"]) --> mode{{"Resolve mode"}}
    mode --> branch{"Mode?"}
    branch -- "Preview" --> plan[["Build candidates<br/>estimate only"]]
    branch -- "Standard / Aggressive" --> plan
    branch -- "Scan" --> walk[["Read-only C: walk"]]
    plan --> reval{"Revalidate<br/>each target"}
    reval -- "changed / busy / protected" --> skip[["Record skipped<br/>+ reason"]]
    reval -- "still valid" --> del[["Remove-ItemSafely<br/>permanent"]]
    walk --> report[["Report + evidence"]]
    del --> report
    skip --> report
    plan -. "estimated bytes" .-> report

    start e1@--> mode
    mode e2@--> branch
    branch e3@--> plan
    branch e4@--> walk
    plan e5@--> reval
    reval e6@--> skip
    reval e7@--> del
    walk e8@--> report
    del e9@--> report
    skip e10@--> report

    classDef anim stroke-dashoffset: 900;
    class e1,e2,e3,e4,e5,e6,e7,e8,e9,e10 anim
```

*Edges animate where the renderer supports it (Mermaid 11.5+ or any viewer with the `animation` class applied); elsewhere the same diagram renders statically.*

## What cleanup touches

```mermaid
flowchart TB
    run{{"Invoke-CleanupRun"}} --> cats["Category tasks"]
    cats --> appc["App caches"]
    cats --> sysc["System caches"]
    cats --> dev["Dev caches"]
    cats --> browser["Browser automation<br/>chromium builds only"]
    cats --> entry["Entry-mode locations<br/>named files, never containers"]
    cats --> orphan["Orphan scan<br/>evidence + age + registry"]
    appc --> guard{"Guardrails"}
    sysc --> guard
    dev --> guard
    browser --> guard
    entry --> guard
    orphan --> guard
    guard -- "C: only, not reparse" --> ok["<b>Pass</b>"]
    guard -- "protected ext / age / busy" --> no["<b>Skip + reason</b>"]
    ok --> gone[["Deleted permanently"]]
    no --> kept[["Kept, logged"]]

    guard e0@--> ok
    ok e1@--> gone
    guard e2@--> no
    no e3@--> kept
    classDef anim stroke-dashoffset: 900;
    class e0,e1,e2,e3 anim
```

## Orphan review, step by step

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant B as Bakunawa
    participant S as Scanner
    participant R as Review
    participant F as Filesystem
    U->>B: Scan C: or a subdir
    B->>S: Walk tree once
    S->>F: Enumerate, aggregate size + mtime
    F-->>S: Descendants or access error
    S-->>B: Findings + issues + coverage
    B->>R: Summary, then candidates
    R->>U: Age, size, reason, eligible vs review
    U->>R: Item numbers, N/P, E, I, Q
    R->>U: Framed confirmation, type DELETE
    U->>R: DELETE
    R->>F: Remove-ItemSafely, revalidate first
    F-->>R: Gone or locked
    R-->>U: Outcome per path + category totals
```

## Discovery safety net

```mermaid
flowchart TD
    p[["Path candidate"]] --> c1{"Starts with C:?"}
    c1 -- "no" --> x1["<b>Reject</b><br/>outside boundary"]
    c1 -- "yes" --> c2{"Reparse point<br/>or junction?"}
    c2 -- "yes" --> x2["<b>Reject</b><br/>no traversal"]
    c2 -- "no" --> c3{"Protected user folder,<br/>Windows, installed root,<br/>VCS metadata, exclusion?"}
    c3 -- "yes" --> x3["<b>Reject</b><br/>recorded exclusion"]
    c3 -- "no" --> c4{"Ancestor already<br/>visited?"}
    c4 -- "yes" --> x4["<b>Deduplicate</b>"]
    c4 -- "no" --> walk["Walk descendants"]
    walk --> agg["Aggregate bytes<br/>+ newest mtime"]
    agg --> out[["Finding"]]

    p e1@--> c1
    c1 e2@--> c2
    c2 e3@--> c3
    c3 e4@--> c4
    c4 e5@--> walk
    walk e6@--> agg
    agg e7@--> out
    classDef anim stroke-dashoffset: 900;
    class e1,e2,e3,e4,e5,e6,e7 anim
```

