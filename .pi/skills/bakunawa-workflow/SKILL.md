---
name: bakunawa-workflow
description: Read, plan, implement and verify changes to the Bakunawa cleaner. Use for any code-change task in this repo, especially deletion, sizing, discovery or dispatch work.
---

# Bakunawa change workflow

Four phases. Do not skip to implementation on a repo where deletion is permanent.

## 1. Read

- `AGENTS.md` is the map: module load graph, traps, and the load-bearing guards.
- `src/Bakunawa.Scanner.cs` holds `Scanner.PathIssue`, the C:-only / reparse-point /
  ancestor-before-descendant guard. Read it before touching any path handling.
- `src/Bakunawa.Discovery.ps1` is dot-sourced into `Bakunawa.Cleanup.psm1`; scan and
  cleanup share one `$script:` state owner there.
- `src/Bakunawa.Bootstrap.psm1` owns session initialization and mode dispatch.

## 2. Plan

State, in this order:

1. Which module owns the change (see the load graph in `AGENTS.md`).
2. Whether the change adds a **new deletion branch**. If yes, it needs both a
   `Get-CleanupTasks` entry and a matching `Invoke-CleanupRun` arm, or it is dead code.
3. Which invariants below the change could break.

## 3. Implement

- One responsibility per diff. Do not mix a deletion change with a UI restyle.
- Keep PowerShell 5.1 compatible. Four-space indent, `Verb-Noun` names.
- `-LiteralPath` for concrete filesystem targets; `PathType Container` for directories.
- Preserve UTF-8 BOM on scripts that contain Unicode.
- Module `$script:` state is private. Use initialization functions and accessors;
  never assign another module's state from a caller.

## 4. Verify

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
git diff --check
```

- Tests use `$TestDrive` fixtures only. Never point a test at `C:\`.
- Do not assert on a value the code never computes.
- If a change touches deletion, sizing or discovery, run the safety review skill
  (`.pi/skills/bakunawa-safety-review/SKILL.md`) before reporting done.

## Invariants that survive every change

| Invariant | Where it lives |
| --- | --- |
| `C:` only; reparse points and junctions rejected; ancestors checked before descendants | `Scanner.PathIssue` in `src/Bakunawa.Scanner.cs` |
| `Measure-AndClear` is the only error-collection boundary for deletion work; callers must not wrap it in another try/catch | `src/Bakunawa.Cleanup.psm1` |
| `Measure-AndClear` clears a directory's **children**, never the directory itself; container-held files need `mode: entry` locations | `src/Bakunawa.Cleanup.psm1`, `app-definitions/*.json` |
| Protected extensions are consulted on every path in AI-agent and transient cleanup | `src/Bakunawa.Cleanup.psm1` |
| Preview is the only dry run | `Bakunawa.ps1`, `src/Bakunawa.Bootstrap.psm1` |
| Windows event logs and `C:\Windows\Logs` are diagnostics and are deliberately retained | `src/Bakunawa.Cleanup.psm1` |
| Every task in `Get-CleanupTasks` has a measurement arm in `Get-CleanupPotential` | `src/Bakunawa.Cleanup.psm1` |
