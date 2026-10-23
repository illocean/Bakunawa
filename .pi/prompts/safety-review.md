# /safety-review [focus]

Review the current diff for permanent-deletion risk. Read-only: report findings, do
not edit files.

## Scope

- `git diff` against the working tree, plus any staged changes.
- `focus` narrows the review to one area (for example `discovery`, `ai-agent`,
  `app-definitions`). Without it, review the whole diff.

## Method

Load the skill `bakunawa-safety-review` and apply its six checks:

1. C:-only
2. No reparse points, ancestors before descendants
3. Children not containers (`mode: entry` for container-held files)
4. Protected extensions consulted on every path
5. Reachability: `Get-CleanupTasks` + `Invoke-CleanupRun` arm + `Get-CleanupPotential`
   measurement arm
6. Exclusions honoured, Preview still a true dry run

## Output

Per finding: file and line, the check it breaks, the concrete failure it allows, and
the smallest fix. Order by severity. Then a short verdict line: safe to run against a
live drive, or what must change first. If a check does not apply to this diff, say so
and why.
