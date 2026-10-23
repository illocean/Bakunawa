---
name: bakunawa-safety-review
description: Review a Bakunawa diff for permanent-deletion risk. Use on any deletion, sizing, or discovery change, and before running Standard or Aggressive against a live drive.
---

# Bakunawa safety review

Deletion here is permanent and immediate. This review is read-only: report findings,
do not edit files unless the user asks for fixes.

## The six checks

1. **C:-only.** Every new target must sit under `C:\`. `Scanner.PathIssue` rejects
   anything else; a path that reaches a delete call without passing `PathIssue` is a
   defect, not a shortcut.
2. **No reparse points.** Junctions and symlinks must be rejected, and ancestors must
   be checked before descendants. Loosening `PathIssue` is a safety regression, not a
   feature.
3. **Children, not containers.** `Measure-AndClear` clears a directory's children and
   never the directory itself. A file that lives inside a container is only reachable
   with `mode: entry` locations in `app-definitions/*.json`.
4. **Protected extensions.** AI-agent and transient cleanup protect config files by
   extension. That list must be consulted on every path, including new ones.
5. **Reachability.** A new deletion branch must appear in `Get-CleanupTasks` **and**
   have a matching `Invoke-CleanupRun` arm, and a matching measurement arm in
   `Get-CleanupPotential`. A branch that is not reachable from all three is dead code
   that will be mistaken for protection.
6. **Exclusions and dry run.** Exclusions must still be honoured, and Preview must stay
   a true dry run: no delete path may run when `IsPreview` is set.

## Review output

For each finding: the file and line, which of the six checks it breaks, the concrete
failure it allows, and the smallest fix. Order by severity. Say plainly when a check
does not apply and why.

## Escalation

Never run Standard or Aggressive against a live drive without explicit approval.
Preview and Scan are the safe ways to see what a change would do.
