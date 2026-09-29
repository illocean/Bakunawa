# Profile schema

Profiles contain only these supported fields:

| Field | Type | Effect |
| --- | --- | --- |
| `mode` | string | One of Menu, Standard, Aggressive, Preview, Scan, Health, Benchmark. Used only when the caller omits `-Mode`. |
| `aggressive.enabled` | boolean | When true and `-Mode` is omitted, selects Aggressive, taking precedence over profile `mode`. When false, leaves profile `mode` unchanged. |

An explicitly supplied `-Mode` always wins, including Preview. Preview always plans Standard candidates. `-VerboseScan` is passed explicitly into discovery and prints each visited scanner entry.

Standard and Aggressive use the same task categories and safety/evidence checks. Their sole difference is the orphan age threshold in the active user configuration: `scanSettings.minAgeDays` (default 30) versus `scanSettings.aggressiveMinAgeDays` (default 14). Both use the newest UTC LastWriteTime across files and directories in the candidate tree. Neither uses LastAccessTime.

Other old profile fields were unused and have been removed from the bundled profiles. Task switches and exclusions remain in `%APPDATA%\Bakunawa\config.json`.
