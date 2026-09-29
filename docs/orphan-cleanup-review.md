# Orphan scan and cleanup verification

Reviewed 2026-09-24 against baseline commit `6d715ad`. Finding verdicts below record the pre-change inspection. Implementation now follows the owner decisions recorded below; the baseline gaps section describes the original code, not the final behavior.

## Finding verdicts

| ID | Verdict after module inspection | Evidence and implication |
| --- | --- | --- |
| F1 | Confirmed elevation policy; silent-scan conclusion only partly supported | `Bakunawa.ps1` elevates Menu/Standard/Aggressive, unless `-ForceAdmin` bypasses it. `Scanner.Walk` already emits encountered traversal errors/skips; discovery stores them in `Issues` and `Coverage`. However, skipped paths can still produce `Complete within exclusions`, console output is truncated when a full log exists, and wildcard expansion suppresses enumeration errors. Preview needs equivalent coverage reporting. Changing global error preference alone will not fix this. |
| F2 | Rejected as a missing cleanup connection | `Get-CleanupTasks` includes `Orphan Scan`; `Invoke-CleanupRun` calls `Find-OrphanFolders` then `Clear-CachedOrphans` for both Standard and Aggressive. Cleanup currently requires `SafeDelete`, which discovery assigns to stale known-temp findings. Other findings remain review-only. A disabled saved task setting can prevent the scan. |
| F3 | Rejected for current tree-age implementation; stale configuration concern confirmed | `Scanner.Frame` starts with directory `LastWriteTimeUtc`; `Walk` aggregates the maximum across files and nested directories. `Invoke-OrphanDiscovery` uses that aggregate and rejects incomplete trees. The active threshold is `scanSettings.minAgeDays`, default 30, not root `Bakunawa.json.orphanThresholdDays`. Known app caches can be reported regardless of age, but are review-only. O2 still determines the requested timestamp contract. |
| F4 | Confirmed | Entry-script `IsAggressive`/`VerboseScan` assignments have no setter/parameter connection to cleanup modules. No module consumes `VerboseScan`. Aggressive task selection works through the explicit `Mode` argument; `aggressive.enabled` itself does not control it. Profile fields other than `mode` and the ineffective flag are not applied. |
| F5 | Confirmed unused and incorrect | Repository search finds only definitions of `Test-IsWSL` and `Convert-ToWindowsPath`, with no callers. A host `wsl` process does not identify the script execution environment. Both functions can be removed. |
| F6 | Confirmed behavior; existing documentation found | Both entry-script and interactive JSON export use `Out-File -NoClobber -ErrorAction Stop`. README explicitly preserves existing reports. O5 remains pending; if preservation is retained, provide a clear error and regression test. |
| F7 | Confirmed | Profile loading unconditionally replaces `Mode` without checking `PSBoundParameters`. O4 remains pending despite the explicit-mode-wins requirement in R14. |
| F8 | Confirmed unused legacy file | Runtime defaults come from `Get-DefaultConfig`; saved config comes from `%APPDATA%\Bakunawa\config.json`. No runtime reader of root `Bakunawa.json` was found. README and AGENTS already identify it as legacy. Removing that file and correcting its documentation references is the smallest R17 resolution. |

## Baseline requirement gaps

- **R1:** Findings store `Category`, prose `Reason`, and generic `DetectorName`, but no enforceable evidence-rule identity. `Clear-CachedOrphans` trusts `SafeDelete` and revalidates tree measurements; it does not independently require an accepted evidence rule. Registry read failures are suppressed, so absence from the returned names cannot establish verified application absence. Current app definitions describe cache locations, not proof that their owner was uninstalled. No proposed O1 rule has been adopted.
- **R2:** Recursive newest modification time already exists. Preserve changed-candidate revalidation and incomplete-tree rejection. O2 determines whether directory timestamps remain included and whether access times participate.
- **R3–R4:** Add explicit incomplete status whenever any encountered path is skipped, visited/skipped root records, and consistent denial reporting across scanner, wildcard expansion, and Preview. Never claim to enumerate inaccessible descendants: report the boundary that could not be read. O3 determines elevation behavior.
- **R5–R6:** `Get-ExcludedPaths` constructs conventional profile and OneDrive child paths by name. It does not query Windows known folders, so arbitrary redirection is not protected reliably. Selection and mutation already consult exclusions, but both must use resolved known-folder protections. Preserve conventional folder exclusions as additional protection for the requested decoys.
- **R7:** `IsAllowedPath`, `Walk`, and `Inspect` already reject reparse/offline targets and reparse ancestors. Current policy skips links entirely, which avoids traversing or deleting their targets. Fixture tests cover junction traversal and nested junction entry points.
- **R8:** Orphan cleanup is connected already. Aggressive additionally schedules Prefetch, DISM, and Event Logs + Font Cache; that exceeds the requested age-threshold-only difference. There is no separate active aggressive orphan threshold. The profile's `orphanThresholdDays: 14` is currently ignored.
- **R9:** Roblox definitions exist in `games.json` and `apps.json`; Playwright has no app-definition entry. `Clear-GameCaches` and `Clear-BrowserAutomationCaches` hard-code locations instead of consuming their definition categories. Definition-driven expansion should retain process checks and installed-executable protection. A definition match alone must not become orphan evidence without O1 approval.
- **R10:** `CategorySizes` records processed/estimated bytes; it does not provide identified, acted-on, and unacted-on totals with categorized reasons. `SkippedItems` has paths/reasons without byte counts. Denied contents may have unknown size; represent that explicitly rather than inventing a zero-byte estimate. Quarantine bytes remain allocated and must stay distinct from freed bytes.
- **R11:** Preview uses Standard tasks and mutation helpers avoid deleting/moving targets. However, the command and menu wrappers create automatic log files; explicit logging also writes. This violates literal zero-filesystem-changes. Candidates are discovered while tasks execute, so Standard's earlier deletions can affect later orphan discovery; there is no common immutable candidate list proving Preview/Standard parity.
- **R12–R14:** Provide explicit module context and documented profile semantics after O4 confirmation. Preview must retain Standard candidate selection even when an aggressive profile is present.
- **R15–R17:** Remove unused helpers; implement confirmed export policy consistently in both callers; remove legacy configuration and update references.
- **R18:** All 14 existing `.ps1`/`.psm1` files already begin with the UTF-8 BOM. Preserve this for all subsequent edits and new test files.

## Confirmed owner decisions and implementation

| Decision | Confirmed behavior |
| --- | --- |
| O1 | An explicit app-definition orphan rule is mandatory. Missing uninstall entries and missing executables/shortcuts only corroborate it. Any presence or inconclusive check leaves the finding review-only. |
| O2 | Use newest LastWriteTime throughout the candidate tree; never LastAccessTime. |
| O3 | Scan/Preview remain unelevated and report denied paths as incomplete coverage. |
| O4 | Explicit `-Mode` wins. Without it, `aggressive.enabled: true` selects Aggressive ahead of profile mode. |
| O5 | Preserve existing reports and fail with a readable error naming the path. |

Implemented changes:

- Discovery records rule identity and corroborating checks, carries inconclusive checks into issues, and rechecks evidence before mutation. Missing evidence cannot qualify automatic cleanup or orphan-review quarantine.
- Six personal folders use the Windows known-folder API; conventional personal-folder exclusions remain. Selection, deletion, quarantine, and restore check protection; links are not traversed.
- Scan reports expose visited/skipped roots and an explicit incomplete flag/status. All encountered issues are printed and exported. Wildcard and cleanup enumeration errors are retained with paths.
- Standard and Preview build the same candidate list before mutations. Standard then revalidates each tree and owner. Preview creates no filesystem logs, directories, quarantine, or cleanup changes.
- Category reports distinguish identified, acted-on and unacted-on bytes, reasons, and unknown-size paths. Partial direct-deletion failures are remeasured where possible. Quarantined bytes remain separate from freed bytes.
- Game and browser-automation categories consume app definitions; Roblox and Playwright fixtures exercise those real entries. Game definitions containing application configuration/state were excluded from the newly activated definition path.
- Aggressive uses the same tasks as Standard, with only `scanSettings.aggressiveMinAgeDays` differing (default 14 versus 30). Module switches are explicit. Profiles now contain only supported fields, documented in `profiles/README.md`.
- Unused WSL/path helpers, the unused orphan-removal bypass wrapper, and root `Bakunawa.json` were removed. Both report-export callers preserve existing files. PowerShell files retain UTF-8 BOMs.

## Baseline validation

Windows PowerShell `5.1.19041.6456`, Pester `5.8.0`:

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests\DriveDiscovery.Tests.ps1 -Output None -PassThru
git diff --check
```

Fixture suite: **35 passed, 0 failed, 0 skipped**, 33.3 seconds. Covered existing tree timestamps, exclusions, junctions, changed candidates, Preview target preservation, failed deletions, quarantine/restore, C:-only paths, and Roblox executable preservation. No live cleanup run was performed. This is a baseline result, not evidence that the requested twelve acceptance cases are complete. The full suite was not run during this pre-implementation review.

Byte-level check: **14 PowerShell files, 0 missing BOMs**.

## Acceptance validation

`tests/OrphanRequirements.Tests.ps1` covers all twelve requested acceptance areas using fixtures, including real ACL denial, known-folder resolution mocks, junctions, actual definition expansion, byte totals, profile precedence, repeat entry-point report export, and encoding. No destructive production cleanup is run. Validation completed 2026-09-25 on Windows PowerShell 5.1 and Pester 5.8.0:

- Full suite: **147 passed, 0 failed, 0 skipped** (6 minutes 49.8 seconds).
- Discovery/reporting/acceptance suites after the failure-reporting correction: **91 passed, 0 failed, 0 skipped**.
- Final acceptance rerun after the last reporting adjustments: **28 passed, 0 failed, 0 skipped** (49.0 seconds). One additional acceptance case was added after full-suite discovery; these counts overlap and are not additive.
- All **15** PowerShell source/test files have UTF-8 BOMs and parse successfully.
- All **14** application-definition/profile JSON files parse successfully.
- `git diff --check` passes.

The added failure case verifies that an unreadable or missing remainder after an unsuccessful action produces unknown acted-on/unacted-on totals, not an assumed zero. Confirmed byte totals remain lower bounds when an outcome is unknown. No live Standard or Aggressive cleanup was performed; destructive checks used fixtures.
