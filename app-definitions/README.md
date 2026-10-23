# Cache definitions and orphan evidence

Existing cache entries retain `name`, `process` (string or array), `category`, and `locations` (`env`/`path`). Game and browser-automation cleanup consume those definitions. Cache cleanup preserves the cache root and skips running owners. Downloaded Playwright browsers are recoverable cache data; deleting them requires downloading them again.

## Location modes

`locations[].mode` selects how a location is cleaned. It defaults to `contents`, so every existing definition keeps its current behaviour: the location is treated as a cache root whose **children** are cleared while the root's own files are preserved.

`entry` marks a location that holds disposable leftovers beside files that must survive. The cleaner removes only the matching entries themselves and never clears the container. This is required for install-staging leftovers, which live next to a tool's own files — the npm prefix holds its shims, and `.vscode\extensions` holds installed extensions.

| Field | Values | Default | Meaning |
| --- | --- | --- | --- |
| `mode` | `contents`, `entry` | `contents` | Clear the location's children, or delete only the matching entries inside it |
| `entryPatterns` | wildcard strings | `[]` | Entry names to match when `mode` is `entry` |
| `entryType` | `any`, `file`, `directory` | `any` | Restrict matches by kind |
| `minAgeDays` | integer | `0` | Age gate for matched entries; `0` reuses the configured scan age |

```json
{
  "name": "npm-staging-temps",
  "process": null,
  "category": "Dev Caches",
  "locations": [
    { "env": "APPDATA", "path": "npm", "mode": "entry",
      "entryPatterns": [".omniroute-*", ".opencode-ai-*", ".*-????????"] }
  ]
}
```

`entry` locations never reach the contents-clear routine, so a container's own files cannot be removed by accident. `entryPatterns` matches names only and never descends into subdirectories, and a missing location is reported as absent rather than as an error. Matched entries newer than the age gate are recorded as skipped, not removed, because an install may still be running.

A wildcard in the **last** path segment is resolved against the filesystem when the definitions load, so a location can name an installed build without pinning its version:

```json
{ "env": "LOCALAPPDATA", "path": "ms-playwright/chromium-*" }
```

That keeps Playwright's `chromium-<revision>` and `chromium_headless_shell-<revision>` installs targeted while the shared `ms-playwright` parent (`ffmpeg`, `daemon`, `winldd`) is never cleared. If the parent directory is absent the pattern is returned unchanged and cleanup expands it later.

## Special-case targets

Two Dev Caches targets are not plain cache roots and are handled in `src/Bakunawa.Cleanup.psm1` instead of by clearing a location:

- `Maven Repository` (`.m2\repository`) is a dependency store, not a cache. `Clear-MavenPartialArtifacts` reclaims only incomplete downloads (`*.part`, `*.lastUpdated`), and only while no `java` process is running; the repository itself is never cleared.
- Bun scratch files (`.bun-<pid>-<hash>.node`/`.dll` in the temp root) are matched directly by `Clear-DevCaches`, aged-only, and only while no `bun` process is running.

An optional `orphanRule` supplies the required orphan gate for the entry's exact expanded locations:

```json
"orphanRule": {
  "id": "application-cache-owner-absent",
  "uninstallNames": ["Application*"],
  "executables": [{ "env": "LOCALAPPDATA", "path": "Application/Versions/*/Application.exe" }],
  "shortcutNames": ["Application*"]
}
```

The rule must declare uninstall display-name patterns, executable locations, Start Menu shortcut-name patterns, and the entry must declare owner processes. All checks must finish successfully and confirm absence; any presence, unreadable boundary, missing rule field, unresolved environment variable, or running owner makes the finding review-only. The candidate tree must also be fully readable, outside protected locations, and old enough.

The candidate records `EvidenceRule` as `source-file:rule-id` plus completed `EvidenceChecks`. A cache-definition match without an explicit orphan rule does not establish an orphan. Name-only folders, stale temp items, and absent uninstall entries cannot qualify by themselves. Routine cache tasks remain separate from orphan qualification.

Evidence and tree measurements are rechecked before automatic cleanup or a review quarantine move. Review-only findings cannot be moved through orphan review; they remain informational until an accepted rule and every required check pass. No rule is inferred from age or folder name.

Known personal folders are resolved using Windows `SHGetKnownFolderPath` with `KF_FLAG_DONT_VERIFY`, preserving redirection without creating folders. See [Microsoft's flag documentation](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/ne-shlobj_core-known_folder_flag).
