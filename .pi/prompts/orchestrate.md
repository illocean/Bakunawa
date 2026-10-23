# /orchestrate <task>

Run the full Bakunawa workflow in one shot: read, plan, implement, verify.

## 1. Read

- Read `AGENTS.md` for the module load graph, the traps, and the load-bearing guards.
- Load the skill `bakunawa-workflow` and follow its phases.
- Read the files the task touches before changing them. Do not guess the current
  behaviour; the code is the source of truth.

## 2. Plan

State before you change anything:

- The files you will edit and why each one is the right owner.
- Whether the change adds a new deletion branch (then it needs a `Get-CleanupTasks`
  entry, an `Invoke-CleanupRun` arm and a `Get-CleanupPotential` measurement arm).
- The invariants at risk, taken from the workflow skill.

Keep the diff to one responsibility. If the task needs two responsibilities, do the
first, verify it, then do the second.

## 3. Implement

- Smallest change that fully solves the task. Reuse before you add.
- PowerShell 5.1 compatible, four-space indent, `Verb-Noun` names, `-LiteralPath` for
  concrete targets.
- Do not touch unrelated files, user data, or work in progress in the working tree.

## 4. Verify

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path .\tests -Output Detailed
git diff --check
```

- Never claim a check passed unless it actually ran.
- For deletion, sizing or discovery changes, load `bakunawa-safety-review` and apply
  the six checks to the diff before reporting done.

## 5. Report

What changed, what each change fixes, which checks ran and their real result, and
anything left undone.
