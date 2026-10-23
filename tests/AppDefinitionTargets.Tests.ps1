#requires -Version 5.1
# Pester v5 tests for the targeted-cache definitions added for this cleanup objective.
#
# These tests pin the wiring (not the live drive): the new app-definition entries load,
# the decoy/over-broad targets stay out, Preview remains the only dry run, a cache
# whose owning process is running is skipped by Measure-AndClear (the process gate),
# and the Dev Caches special cases (Maven partials, bun scratch files, Bakunawa log
# retention) never touch a live drive.
#
# Deletion is permanent and Preview is the only dry run. Nothing here touches a live drive:
# every behavioural case runs on a $TestDrive fixture and asserts the SKIP REASON so it can
# never pass for the wrong reason (e.g. an unrelated IsAllowedPath block).
#
# Run: Invoke-Pester -Path tests/AppDefinitionTargets.Tests.ps1 -Output Detailed

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking

    Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($TestDrive) }
    Mock -ModuleName Bakunawa.Cleanup Write-CommandLog { }

    function script:New-FixtureFile {
        param([string]$Path, [int]$Bytes = 512)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        return $Path
    }

    function script:New-FixtureDir {
        param([string]$Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    # Baseline module state: preview on, no planning. Never deletes.
    function script:Reset-CleanupState {
        & (Get-Module Bakunawa.Cleanup) {
            $script:IsPreview = $true
            $script:Planning = $false
            $script:ActiveCategory = $null
            $script:BytesFreed = 0L
            $script:TaskCleared = 0
            $script:TaskBytes = 0L
            $script:TaskSkipped = 0
            $script:CategorySizes = @{}
            $script:Errors = @()
            $script:SkippedItems = @()
            $script:CandidateRecords = [Collections.Generic.List[object]]::new()
            $script:ProcessedCacheRoots = New-TrackedSet
            $script:BusyCachePaths = [Collections.Generic.List[string]]::new()
            $script:ExcludedPaths = $null
            $script:CleanupConfig = $null
            $script:IsAggressive = $false
        }
    }

    function script:Enable-RealDeletion {
        & (Get-Module Bakunawa.Cleanup) {
            $script:IsPreview = $false
            $script:Planning = $false
        }
    }

    # Register-SkippedItem is defined in Core, so skip records live in the Core module's
    # $script:SkippedItems (Cleanup's own store is only touched when $script:Planning is set).
    function script:Get-CleanupSkipRecords {
        & (Get-Module Bakunawa.Core) { $script:SkippedItems }
    }
}

AfterAll {
    Remove-Module Bakunawa.Cleanup -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.UI -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Core -ErrorAction SilentlyContinue
    Remove-Module Bakunawa.Config -ErrorAction SilentlyContinue
}

Describe 'Objective targets are wired into the app definitions' {

    It 'adds the npm content-addressable cache as a disposable Dev Cache' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'npm-_cacache' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Category | Should -Be 'Dev Caches'
        $def[0].Env | Should -Be 'LOCALAPPDATA'
        $def[0].Path | Should -Match '\.npm[\\/]_cacache$'
    }

    It 'adds the Maven repository, gated on the JVM that runs Maven' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'Maven Repository' })
        $def | Should -Not -BeNullOrEmpty
        $def[0].Category | Should -Be 'Dev Caches'
        $def[0].Process | Should -Be 'java' -Because 'Maven has no unique process name; mvn runs on the JVM, so an active java is treated as a possible build'
        $def[0].Path | Should -Match '\.m2[\\/]repository$'
    }

    It 'targets only the Playwright chromium installs, never the shared tooling parent' {
        $pw = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'Playwright' })
        $pw | Should -Not -BeNullOrEmpty
        $paths = @($pw | ForEach-Object { $_.Path })
        @($paths | Where-Object { $_ -match 'ms-playwright$' }) |
            Should -BeNullOrEmpty -Because 'the whole ms-playwright parent also holds ffmpeg/daemon/winldd and must not be a clear target'
        @($paths | Where-Object { $_ -match 'chromium-1228$' }) | Should -Not -BeNullOrEmpty
        @($paths | Where-Object { $_ -match 'chromium_headless_shell-1228$' }) | Should -Not -BeNullOrEmpty
    }

    It 'keeps the browser-automation caches process-gated on the owning runtime' {
        $pw = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'Playwright' })
        @($pw[0].Process) | Should -Contain 'node'
        $pp = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'Puppeteer' })
        $pp | Should -Not -BeNullOrEmpty
        @($pp[0].Process) | Should -Contain 'node'
    }

    It 'adds the temporary test artifact as its own exact path' {
        $def = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'jtest2-temps' })
        $def | Should -Not -BeNullOrEmpty
        # The definition exists so the path cleans if it appears; it is Test-Path-gated,
        # so a missing directory is a no-op and is never created.
        $def[0].Env | Should -Be 'TEMP'
        $def[0].Path | Should -Match 'jtest2$'
    }

    It 'treats bun scratch files as entries in code, not as a JSON clear target' {
        @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'bun-temps' }) |
            Should -BeNullOrEmpty -Because 'the .bun-* files sit directly in %TEMP%, which no directory definition may clear wholesale; Clear-DevCaches removes them per entry'
    }
}

Describe 'Decoy and over-broad targets stay out of the definitions' {

    It 'does not target the Brave-Browser base (the decoy path)' {
        $brave = @(Get-AllAppDefinitions | Where-Object { $_.Path -match 'Brave-Browser[\\/]User Data' })
        $brave | Should -Not -BeNullOrEmpty -Because 'the real Brave profile lives under BraveSoftware'
        @($brave | Where-Object { $_.Path -notmatch 'BraveSoftware' }) |
            Should -BeNullOrEmpty -Because 'Brave-Browser without the BraveSoftware base is a decoy and must never be added'
    }

    It 'targets Brave Service Worker/CacheStorage, never the whole Service Worker directory' {
        $sw = @(Get-AllAppDefinitions | Where-Object { $_.Name -eq 'Brave' -and $_.Path -match 'Service Worker' })
        $sw | Should -Not -BeNullOrEmpty
        @($sw | Where-Object { $_.Path -match 'Service Worker$' }) |
            Should -BeNullOrEmpty -Because 'whole Service Worker holds Database (IndexedDB session state); only CacheStorage is safe'
        @($sw | Where-Object { $_.Path -match 'Service Worker[\\/]CacheStorage$' }) | Should -Not -BeNullOrEmpty
    }

    It 'never adds the OmniRoute temp source repo as a clear target' {
        $omni = @(Get-AllAppDefinitions | Where-Object { $_.Path -match 'opencode[\\/]OmniRoute$' })
        $omni | Should -BeNullOrEmpty -Because 'the OmniRoute temp repo is excluded at the scanner level (Get-ExcludedPaths), not cleared'
    }
}

Describe 'Preview is the only dry run and a busy path is protected' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ("defn_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:root | Out-Null
        Reset-CleanupState
        # Register-SkippedItem logs against the Core module store; reset it so the busy-gate
        # assertion can't match a record from a prior case.
        & (Get-Module Bakunawa.Core) { $script:SkippedItems = @() }
    }

    It 'leaves a fixture intact in preview mode' {
        New-FixtureFile (Join-Path $script:root 'cache.bin') | Out-Null

        $null = Measure-AndClear -Path $script:root -Category 'Dev Caches'

        Test-Path -LiteralPath (Join-Path $script:root 'cache.bin') |
            Should -Be $true -Because 'Preview is the only dry run and must never delete'
        Test-Path -LiteralPath $script:root -PathType Container | Should -Be $true -Because 'the cache root itself is preserved'
    }

    It 'clears an idle fixture on a real run, so the busy-skip below is meaningful' {
        New-FixtureFile (Join-Path $script:root 'cache.bin') | Out-Null
        Enable-RealDeletion

        $null = Measure-AndClear -Path $script:root -Category 'Dev Caches'

        Test-Path -LiteralPath (Join-Path $script:root 'cache.bin') |
            Should -Be $false -Because 'with no owning process running, a stale cache is cleared'
        Test-Path -LiteralPath $script:root -PathType Container | Should -Be $true -Because 'the cache root itself is never removed by Measure-AndClear'
    }

    It 'skips a path whose owning process is running, with a reason' {
        New-FixtureFile (Join-Path $script:root 'cache.bin') | Out-Null
        $full = [IO.Path]::GetFullPath($script:root).TrimEnd('\')
        & (Get-Module Bakunawa.Cleanup) { param($p) [void]$script:BusyCachePaths.Add($p) } $full
        Enable-RealDeletion

        $null = Measure-AndClear -Path $script:root -Category 'Dev Caches'

        Test-Path -LiteralPath (Join-Path $script:root 'cache.bin') |
            Should -Be $true -Because 'a cache whose owning process is running must be skipped'
        @((Get-CleanupSkipRecords) | Where-Object { $_.Reason -match 'owning app' }) |
            Should -Not -BeNullOrEmpty -Because 'the busy-process gate must fire, not an unrelated path guard'
    }
}

Describe 'Maven special case: incomplete downloads only, never the store' {

    BeforeEach {
        $script:repo = Join-Path $TestDrive ("m2repo_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir (Join-Path $script:repo 'org/apache/maven') | Out-Null
        $script:jar = New-FixtureFile (Join-Path $script:repo 'org/apache/maven/artifact-1.0.jar') 4096
        $script:pom = New-FixtureFile (Join-Path $script:repo 'org/apache/maven/artifact-1.0.pom') 2048
        $script:part = New-FixtureFile (Join-Path $script:repo 'org/apache/maven/artifact-1.0.jar.part') 1024
        $script:lastUpdated = New-FixtureFile (Join-Path $script:repo 'org/apache/maven/artifact-1.0.jar.lastUpdated') 256
        $script:nested = New-FixtureFile (Join-Path $script:repo 'com/example/deep/nested-2.0.jar.part') 512
        Reset-CleanupState
        & (Get-Module Bakunawa.Core) { $script:SkippedItems = @() }
    }

    It 'removes *.part and *.lastUpdated recursively and keeps every resolved artifact' {
        Enable-RealDeletion

        # Clear-MavenPartialArtifacts is a module-private helper; invoke it in module scope.
        $removed = & (Get-Module Bakunawa.Cleanup) { param($repo) Clear-MavenPartialArtifacts -RepositoryPath $repo } $script:repo

        $removed | Should -Be 3
        Test-Path -LiteralPath $script:part | Should -Be $false -Because 'an unfinished download is junk'
        Test-Path -LiteralPath $script:lastUpdated | Should -Be $false -Because 'a fetch-failure marker is rewritten on the next resolve'
        Test-Path -LiteralPath $script:nested | Should -Be $false -Because 'partials can appear at any repository depth'
        Test-Path -LiteralPath $script:jar | Should -Be $true -Because 'resolved artifacts serve offline builds and must never be removed'
        Test-Path -LiteralPath $script:pom | Should -Be $true
        Test-Path -LiteralPath $script:repo -PathType Container | Should -Be $true -Because 'the repository itself is never a clear target'
    }

    It 'leaves the partials in place in preview mode' {
        $null = & (Get-Module Bakunawa.Cleanup) { param($repo) Clear-MavenPartialArtifacts -RepositoryPath $repo } $script:repo

        Test-Path -LiteralPath $script:part | Should -Be $true -Because 'Preview is the only dry run'
        Test-Path -LiteralPath $script:lastUpdated | Should -Be $true
    }

    It 'skips the whole repository when the owning java process is treated as busy' {
        $full = [IO.Path]::GetFullPath($script:repo).TrimEnd('\')
        & (Get-Module Bakunawa.Cleanup) { param($p) [void]$script:BusyCachePaths.Add($p) } $full
        Enable-RealDeletion

        $removed = & (Get-Module Bakunawa.Cleanup) { param($repo) Clear-MavenPartialArtifacts -RepositoryPath $repo } $script:repo

        $removed | Should -Be 0
        Test-Path -LiteralPath $script:part | Should -Be $true -Because 'a build may be mid-resolve while the JVM runs'
        @((Get-CleanupSkipRecords) | Where-Object { $_.Reason -match 'owning app' }) |
            Should -Not -BeNullOrEmpty -Because 'the skip must be the process gate, not an unrelated path guard'
    }
}

Describe 'Clear-DevCaches dispatches the Maven definition away from Measure-AndClear' {

    BeforeEach {
        $script:repo = Join-Path $TestDrive ("m2dispatch_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:repo | Out-Null
        Reset-CleanupState
        $script:mavenCalls = [Collections.Generic.List[string]]::new()
        $script:measureCalls = [Collections.Generic.List[string]]::new()
        # Hermetic: no dev-dir or temp-root lookup from the real machine reaches this arm.
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath { return $null }
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { return $true }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            param([string]$Category)
            @([PSCustomObject]@{
                Name = 'Maven Repository'; Path = $script:repo; Env = 'USERPROFILE'; Process = 'java'
                Category = 'Dev Caches'; SourceFile = 'devtools-extended.json'
                Mode = $null; EntryPatterns = $null; EntryType = $null; MinAgeDays = 0
            })
        }
        Mock -ModuleName Bakunawa.Cleanup Measure-AndClear {
            param([string]$Path, [switch]$EnsureDirectory, [string]$Category)
            $script:measureCalls.Add($Path)
            return $true
        }
        Mock -ModuleName Bakunawa.Cleanup Clear-MavenPartialArtifacts {
            param([string]$RepositoryPath, [string]$Category)
            $script:mavenCalls.Add($RepositoryPath)
            return 2
        }
    }

    It 'routes the repository to the partial-artifact path and never to Measure-AndClear' {
        $n = Clear-DevCaches

        $n | Should -Be 2 -Because 'the Maven branch must be the one reporting the reclaim'
        $script:mavenCalls.Count | Should -Be 1
        $script:mavenCalls[0] | Should -Be $script:repo
        @($script:measureCalls | Where-Object {
                [Bakunawa.Scanner]::Within($_, $script:repo) -or [Bakunawa.Scanner]::Within($script:repo, $_)
            }).Count | Should -Be 0 -Because 'clearing the store would empty a dependency repository'
    }
}

Describe 'Bun scratch files under the temp root' {

    BeforeEach {
        $script:tempRoot = Join-Path $TestDrive ("temp_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:tempRoot | Out-Null
        Reset-CleanupState
        & (Get-Module Bakunawa.Core) { $script:SkippedItems = @() }
        # Redirect only the Cleanup module's temp-root lookup; every other lookup returns
        # nothing so the real machine's temp root and dev caches are never scanned here.
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath {
            param($Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath)
            if ($Name -eq 'LOCALAPPDATA' -and $ChildPath -and $ChildPath.Count -eq 1 -and $ChildPath[0] -eq 'Temp') {
                return $script:tempRoot
            }
            return $null
        }
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { return @() }
    }

    It 'removes aged .bun-* scratch files, keeps recent ones, and spares unrelated siblings' {
        $stale = New-FixtureFile (Join-Path $script:tempRoot '.bun-2004236387-3cba9b8dc4fa4e45.node') 65536
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-5)
        $fresh = New-FixtureFile (Join-Path $script:tempRoot '.bun-2004236387-e1cd43857cefa531.dll') 32768
        $other = New-FixtureFile (Join-Path $script:tempRoot 'unrelated.tmp') 1024
        (Get-Item -LiteralPath $other).LastWriteTime = (Get-Date).AddDays(-30)
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { return $false }
        Enable-RealDeletion

        $n = Clear-DevCaches

        $n | Should -Be 1
        Test-Path -LiteralPath $stale | Should -Be $false -Because 'an idle bun leaves pid-scoped scratch behind'
        Test-Path -LiteralPath $fresh | Should -Be $true -Because 'a live run may have written it; the age gate protects it'
        Test-Path -LiteralPath $other | Should -Be $true -Because 'only the .bun-* pattern is matched'
        Test-Path -LiteralPath $script:tempRoot -PathType Container | Should -Be $true
    }

    It 'skips every .bun-* file while bun is running, even an aged one' {
        $stale = New-FixtureFile (Join-Path $script:tempRoot '.bun-2004236387-3cba9b8dc4fa4e45.node') 65536
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-5)
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { return $true }
        Enable-RealDeletion

        $n = Clear-DevCaches

        $n | Should -Be 0
        Test-Path -LiteralPath $stale | Should -Be $true -Because 'bun may be using its own scratch files right now'
    }
}

Describe 'Bakunawa log retention: individual files only, older than 24 hours' {

    BeforeEach {
        $script:logDir = Join-Path $TestDrive ("logs_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:logDir | Out-Null
        Reset-CleanupState
        # Redirect only the own-logs lookup; the WebCache/IECompatCache lookups return
        # nothing, so this arm can never measure (let alone clear) a real cache.
        Mock -ModuleName Bakunawa.Cleanup Join-EnvPath {
            param($Name, [Parameter(ValueFromRemainingArguments = $true)][string[]]$ChildPath)
            if ($Name -eq 'LOCALAPPDATA' -and $ChildPath -and $ChildPath.Count -eq 2 -and
                $ChildPath[0] -eq 'Bakunawa' -and $ChildPath[1] -eq 'Logs') {
                return $script:logDir
            }
            return $null
        }
    }

    It 'removes only .txt logs older than 24 hours, keeping recent files, other files and the folder' {
        $stale = New-FixtureFile (Join-Path $script:logDir '20261001-090000-000-Standard-aaaaaaaa.txt') 4096
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-3)
        $fresh = New-FixtureFile (Join-Path $script:logDir '20261017-120000-000-Standard-bbbbbbbb.txt') 2048
        $other = New-FixtureFile (Join-Path $script:logDir 'retained.dat') 1024
        (Get-Item -LiteralPath $other).LastWriteTime = (Get-Date).AddDays(-90)
        Enable-RealDeletion

        $n = Clear-SystemLogFiles

        $n | Should -Be 1
        Test-Path -LiteralPath $stale | Should -Be $false -Because 'only files past the 24-hour cutoff are removable'
        Test-Path -LiteralPath $fresh | Should -Be $true -Because 'the run in progress writes inside the retention window'
        Test-Path -LiteralPath $other | Should -Be $true -Because 'the pattern is *.txt, not the whole folder'
        Test-Path -LiteralPath $script:logDir -PathType Container | Should -Be $true -Because 'the log directory itself is never removed'
    }

    It 'keeps a locked log file and records the failure instead of forcing it' {
        $locked = New-FixtureFile (Join-Path $script:logDir '20261001-000000-000-Aggressive-cccccccc.txt') 8192
        (Get-Item -LiteralPath $locked).LastWriteTime = (Get-Date).AddDays(-5)
        $handle = [IO.File]::Open($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            Enable-RealDeletion

            $null = Clear-SystemLogFiles

            Test-Path -LiteralPath $locked | Should -Be $true -Because 'a locked file is skipped, never forced open'
            @((Get-CleanupErrorLog) | Where-Object { $_.Path -eq $locked }) |
                Should -Not -BeNullOrEmpty -Because 'the failed delete must be reported'
        } finally { $handle.Dispose() }
    }
}

Describe 'A task is measured exactly once' {

    BeforeEach {
        $script:root = Join-Path $TestDrive ("measure_$([guid]::NewGuid().ToString('N'))")
        New-FixtureDir $script:root | Out-Null
        Reset-CleanupState
    }

    # A switch runs every matching arm, so a category with two matching arms would
    # count the same location twice and over-report the estimate for that task.
    It 'counts a browser automation cache location once' {
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'fixture'; Category = 'Browser Automation Caches'; Path = $script:root; Mode = $null; MinAgeDays = 0 })
        }
        Mock -ModuleName Bakunawa.Cleanup Get-DirectorySize { 1024 }

        $p = Get-CleanupPotential -Mode 'Standard' -TaskName 'Browser Automation Caches'

        $p.EstimatedBytes | Should -Be 1024 -Because 'a second matching measurement arm would count the same location again'
        $p.FileCount | Should -Be 1
    }

    It 'counts a game cache location once' {
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'fixture'; Category = 'Game Caches'; Path = $script:root; Mode = $null; MinAgeDays = 0 })
        }
        Mock -ModuleName Bakunawa.Cleanup Get-DirectorySize { 2048 }

        $p = Get-CleanupPotential -Mode 'Standard' -TaskName 'Game Caches'

        $p.EstimatedBytes | Should -Be 2048 -Because 'a second matching measurement arm would count the same location again'
        $p.FileCount | Should -Be 1
    }

    It 'measures the AI agent caches task instead of reporting it as unmeasured' {
        $p = Get-CleanupPotential -Mode 'Standard' -TaskName 'AI Agent Caches'

        $p.Status | Should -Be 'ok' -Because 'a task without a measurement arm used to report zero bytes as if nothing were there'
    }
}
