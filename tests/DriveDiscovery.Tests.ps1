#requires -Version 5.1
BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
    foreach ($module in @('Core','Config','Cleanup','UI')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -DisableNameChecking
    }
    function New-OldFile([string]$Path, [int]$Bytes = 128) {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-90)
    }
    function Set-OldTree([string]$Path) {
        Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            $_.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-90)
        }
        (Get-Item -LiteralPath $Path).LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-90)
    }
}

Describe 'Drive discovery and cleanup safety' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $cfg = Get-DefaultConfig
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions { @() }
        Initialize-CleanupState -Config $cfg -ScanRoot @($root) -ExtraExcludePath @()
        Mock -ModuleName Bakunawa.Cleanup Get-ScanDriveRoots { @($root) }
        Mock -ModuleName Bakunawa.Cleanup Get-InstalledApplicationNames { @('Installed Example') }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanExclusions { @() }
        Mock -ModuleName Bakunawa.Cleanup Get-ScanTempRoots { @() }
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $false; $script:BytesFreed = 0L; $script:Errors = @() }
    }

    It 'finds C: fixture caches, including zero-byte folders, with correct subtree sizes' {
        New-OldFile "$root/Apps/cache/sub/data.bin" 2048
        $null = New-Item -ItemType Directory -Path "$root/empty"
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots $root -Refresh)
        $cache = $found | Where-Object Category -eq 'Stale cache folder'
        $cache.Size | Should -Be 2048
        $cache.SafeDelete | Should -BeFalse
        @($found | Where-Object Category -eq 'Stale empty folder').Count | Should -Be 1
    }
    It 'scans all supplied roots and deduplicates overlapping roots and nested findings' {
        New-OldFile "$root/one/cache/sub/stale.tmp" 512
        New-OldFile "$root/two/cache/data.bin" 1024
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots @("$root/one", "$root/one/cache", "$root/two", "$root/two") -Refresh)
        $found.Count | Should -Be 2
        ($found | Measure-Object Size -Sum).Sum | Should -Be 1536
        (Get-OrphanScanReport).Coverage.Count | Should -Be 2
    }
    It 'does not classify an old folder with a recently modified child as stale' {
        New-OldFile "$root/cache/active.bin"
        Set-OldTree $root
        (Get-Item "$root/cache/active.bin").LastWriteTimeUtc = [DateTime]::UtcNow
        @(Find-OrphanFolders -Roots $root -Refresh).Count | Should -Be 0
    }
    It 'keeps personal files and name-only cache matches out of automatic deletion' {
        New-OldFile "$root/essay.docx"
        New-OldFile "$root/old.tmp"
        New-OldFile "$root/cache/work.txt"
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots $root -Refresh)
        @($found | Where-Object SafeDelete).Count | Should -Be 0
        @($found | Where-Object Name -eq 'essay.docx').Count | Should -Be 0
    }
    It 'reports unreadable or missing roots explicitly' {
        $null = Find-OrphanFolders -Roots "$root/missing" -Refresh
        (Get-OrphanScanReport).Issues.Count | Should -BeGreaterThan 0
        (Get-OrphanScanReport).Coverage[0].Status | Should -Not -Be 'Complete within exclusions'
    }
    It 'respects exclusions and never offers their parent as a complete candidate' {
        New-OldFile "$root/cache/keep/work.txt"
        Set-OldTree $root
        Mock -ModuleName Bakunawa.Cleanup Get-ScanExclusions { @("$root/cache/keep") }
        @(Find-OrphanFolders -Roots $root -Refresh).Count | Should -Be 0
        (Get-OrphanScanReport).Issues.Count | Should -Be 1
    }
    It 'rejects relative roots rather than scanning an unintended directory' {
        { Find-OrphanFolders -Roots 'relative' -Refresh } | Should -Throw '*absolute*'
    }
    It 'invalidates its result cache when the scan roots change' {
        New-OldFile "$root/one/a.tmp"
        New-OldFile "$root/two/b.tmp"
        Set-OldTree $root
        $null = Find-OrphanFolders -Roots "$root/one"
        @(Find-OrphanFolders -Roots "$root/two")[0].Name | Should -Be 'b.tmp'
    }
    It 'does not treat a valid shortcut as broken' {
        New-OldFile "$root/exists.exe"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut("$root/valid.lnk")
        $shortcut.TargetPath = "$root/exists.exe"; $shortcut.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        Set-OldTree $root
        @(Find-OrphanFolders -Roots $root -Refresh).Count | Should -Be 0
    }
    It 'finds a verified broken local shortcut as review-only' {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut("$root/broken.lnk")
        $shortcut.TargetPath = "$root/missing.exe"; $shortcut.Save()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots $root -Refresh)
        $found.Count | Should -Be 1
        $found[0].Category | Should -Be 'Broken shortcut'
        $found[0].SafeDelete | Should -BeFalse
    }
    It 'does not traverse junctions and does not delete through them' {
        New-OldFile "$root/outside/important.txt"
        $null = New-Item -ItemType Directory -Path "$root/scan"
        $null = New-Item -ItemType Junction -Path "$root/scan/cache" -Target "$root/outside"
        try {
            $null = Find-OrphanFolders -Roots "$root/scan" -Refresh
            (Get-OrphanScanReport).Issues.Count | Should -Be 1
            { [Bakunawa.Scanner]::Inspect("$root/scan/cache/important.txt", [string[]]@()) } | Should -Throw '*Reparse*'
            Test-Path "$root/outside/important.txt" | Should -BeTrue
        } finally {
            # Remove only the verified junction itself, never its target tree.
            [IO.Directory]::Delete("$root/scan/cache")
        }
    }
    It 'preview measures nonzero bytes without deleting or creating directories' {
        New-OldFile "$root/cache/data.bin" 4096
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
        Measure-AndClear -Path "$root/cache" -Category 'Test' | Should -BeTrue
        Test-Path "$root/cache/data.bin" | Should -BeTrue
        & (Get-Module Bakunawa.Cleanup) { $script:BytesFreed } | Should -Be 4096
        $null = Measure-AndClear -Path "$root/missing" -EnsureDirectory
        Test-Path "$root/missing" | Should -BeFalse
    }
    It 'preview of cached safe temp findings cannot delete them' {
        New-OldFile "$root/cache/a.tmp" 4096
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots $root -Refresh)
        $found[0].SafeDelete = $true
        $found[0].EvidenceRule = 'fixture:verified'
        & (Get-Module Bakunawa.Cleanup) { param($path) $script:OrphanRulePaths[$path] = [pscustomobject]@{Name = 'Fixture'} } $found[0].Path
        Mock -ModuleName Bakunawa.Cleanup Test-OrphanEvidence { [pscustomobject]@{Eligible = $true} }
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
        Clear-CachedOrphans | Should -Be 1
        Test-Path "$root/cache/a.tmp" | Should -BeTrue
    }
    It 'requires a rescan when a selected candidate changes' {
        New-OldFile "$root/old.tmp"
        Set-OldTree $root
        $finding = @(Find-OrphanFolders -Roots $root -Refresh)[0]
        $finding.SafeDelete = $true
        $finding.EvidenceRule = 'fixture:verified'
        & (Get-Module Bakunawa.Cleanup) { param($path) $script:OrphanRulePaths[$path] = [pscustomobject]@{Name = 'Fixture'} } $finding.Path
        Mock -ModuleName Bakunawa.Cleanup Test-OrphanEvidence { [pscustomobject]@{Eligible = $true} }
        [IO.File]::AppendAllText("$root/old.tmp", 'new data')
        { Clear-ReviewedOrphans -Path "$root/old.tmp" } | Should -Throw '*Changed since scan*'
        Test-Path "$root/old.tmp" | Should -BeTrue
    }
    It 'does not report failed or locked deletions as reclaimed space' {
        New-OldFile "$root/cache/locked.bin" 2048
        $handle = [IO.File]::Open("$root/cache/locked.bin", 'Open', 'ReadWrite', 'None')
        try {
            Measure-AndClear -Path "$root/cache" -Category Test | Should -BeFalse
            & (Get-Module Bakunawa.Cleanup) { $script:BytesFreed } | Should -Be 0
            @(Get-CleanupErrorLog).Count | Should -Be 1
        } finally { $handle.Dispose() }
    }
    It 'preserves excluded descendants during ordinary cache cleaning' {
        New-OldFile "$root/cache/keep/data.bin"
        $cfg.exclusions.userCustomExclusions = @("$root/cache/keep")
        Initialize-CleanupState -Config $cfg -ScanRoot @($root)
        Measure-AndClear -Path "$root/cache" -Category Test | Should -BeFalse
        Test-Path "$root/cache/keep/data.bin" | Should -BeTrue
    }
    It 'deletes reviewed candidates permanently and leaves preview untouched' {
        New-OldFile "$root/old.tmp" 4096
        Set-OldTree $root
        $finding = @(Find-OrphanFolders -Roots $root -Refresh)[0]
        $finding.SafeDelete = $true
        $finding.EvidenceRule = 'fixture:verified'
        & (Get-Module Bakunawa.Cleanup) { param($path) $script:OrphanRulePaths[$path] = [pscustomobject]@{Name = 'Fixture'} } $finding.Path
        Mock -ModuleName Bakunawa.Cleanup Test-OrphanEvidence { [pscustomobject]@{Eligible = $true} }
        $null = Clear-ReviewedOrphans -Path "$root/old.tmp" -Preview
        Test-Path "$root/old.tmp" | Should -BeTrue
        $null = Clear-ReviewedOrphans -Path "$root/old.tmp"
        Test-Path "$root/old.tmp" | Should -BeFalse
        # No recovery copy exists anywhere: the delete is final and frees the space.
        Test-Path "$root/recovery" | Should -BeFalse
    }
    It 'resets preview and totals between cleanup runs in the same session' {
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks { @() }
        $preview = Invoke-CleanupRun -Mode Preview -Config $cfg
        $normal = Invoke-CleanupRun -Mode Standard -Config $cfg
        $preview.IsPreview | Should -BeTrue
        $normal.IsPreview | Should -BeFalse
        $normal.BytesFreed | Should -Be 0
    }
    It 'shows an explicit empty result state' {
        $output = Show-OrphanScanResults -ScanResult @{ Findings = @() } 6>&1 | Out-String
        $output | Should -Match 'No candidates found'
    }
    It 'reports an unmatched app data folder for review but retains a matching installed app' {
        Mock -ModuleName Bakunawa.Cleanup Get-EnvPath { $root } -ParameterFilter { $Name -eq 'APPDATA' }
        New-OldFile "$root/RemovedExample/preferences.json"
        New-OldFile "$root/InstalledExample/preferences.json"
        Set-OldTree $root
        $found = @(Find-OrphanFolders -Roots $root -Refresh)
        $found.Count | Should -Be 1
        $found[0].Name | Should -Be 'RemovedExample'
        $found[0].Category | Should -Be 'Possible app leftover'
        $found[0].SafeDelete | Should -BeFalse
    }
    It 'keeps sub-name placeholders constrained to the named cache directory' {
        New-OldFile "$root/cache/a.bin"
        New-OldFile "$root/important/b.bin"
        $paths = @(Expand-WildcardPath -Path "$root/{sub:cache}" -DirectoriesOnly)
        $paths.Count | Should -Be 1
        [IO.Path]::GetFullPath($paths[0]) | Should -Be ([IO.Path]::GetFullPath("$root/cache"))
    }
    It 'expands ordinary wildcard paths to existing directories' {
        New-OldFile "$root/App1/cache/a.bin"
        New-OldFile "$root/App2/cache/b.bin"
        $paths = @(Expand-WildcardPath -Path "$root/App*/cache" -DirectoriesOnly)
        $paths.Count | Should -Be 2
        foreach ($path in $paths) { $path | Should -Not -Match '\*' }
        New-OldFile "$root/App[1]extra/cache/c.bin"
        @(Expand-WildcardPath -Path "$root/App[1]*/cache" -DirectoriesOnly).Count | Should -Be 1
    }
    It 'does not count duplicate cache roots twice during preview' {
        New-OldFile "$root/cache/a.bin" 4096
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
        $null = Measure-AndClear "$root/cache" -Category Test
        $null = Measure-AndClear "$root/cache" -Category Test
        & (Get-Module Bakunawa.Cleanup) { $script:BytesFreed } | Should -Be 4096
    }
    It 'continues to orphan scanning when an earlier cleanup task fails' {
        Mock -ModuleName Bakunawa.Cleanup Get-CleanupTasks {
            @([pscustomobject]@{ Name = 'System Caches'; Parallel = $false }, [pscustomobject]@{ Name = 'Orphan Scan'; Parallel = $false })
        }
        Mock -ModuleName Bakunawa.Cleanup Clear-SystemCaches { throw 'Fixture failure' }
        Mock -ModuleName Bakunawa.Cleanup Find-OrphanFolders { @() }
        $result = Invoke-CleanupRun -Mode Preview -Config $cfg
        @($result.Errors).Count | Should -Be 1
        Should -Invoke -ModuleName Bakunawa.Cleanup Find-OrphanFolders -Times 1 -Exactly
    }
    It 'uses the configured minimum age and supports an explicit override' {
        New-OldFile "$root/old.tmp"
        Set-OldTree $root
        $cfg.scanSettings.minAgeDays = 365
        Initialize-CleanupState -Config $cfg -ScanRoot @($root)
        @(Find-OrphanFolders -Refresh).Count | Should -Be 0
        @(Find-OrphanFolders -OlderThanDays 30 -Refresh).Count | Should -Be 1
    }
    It 'pattern cleanup counts matching files once and preserves excluded siblings in preview' {
        New-OldFile "$root/cache/a.tmp" 256
        New-OldFile "$root/cache/keep/b.tmp" 512
        $cfg.exclusions.userCustomExclusions = @("$root/cache/keep")
        Initialize-CleanupState -Config $cfg -ScanRoot @($root)
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
        Remove-FilesByPattern -Directory "$root/cache" -Patterns @('*.tmp','a.*') | Should -Be 1
        & (Get-Module Bakunawa.Cleanup) { $script:BytesFreed } | Should -Be 256
        Test-Path "$root/cache/a.tmp" | Should -BeTrue
        Test-Path "$root/cache/keep/b.tmp" | Should -BeTrue
    }

    It 'rejects other drives, network paths and drive-relative scan roots' {
        foreach ($path in @('D:\', 'E:\cache', '\\server\share', 'C:cache')) {
            { Find-OrphanFolders -Roots $path -Refresh } | Should -Throw
            [Bakunawa.Scanner]::IsAllowedPath($path) | Should -BeFalse
            { [Bakunawa.Scanner]::Inspect($path, [string[]]@()) } | Should -Throw '*C:*'
            @([Bakunawa.Scanner]::Walk($path, [string[]]@()))[0].Kind | Should -Be 'Skipped'
            @(Expand-WildcardPath "$path\*" -DirectoriesOnly).Count | Should -Be 0
        }
        Measure-AndClear 'D:\cache' -EnsureDirectory | Should -BeFalse
        { Find-OrphanFolders -Roots @($root, 'D:\') -Refresh } | Should -Throw '*C:*'
        $cfg.scanSettings.roots = @('D:\')
        Initialize-CleanupState -Config $cfg -ScanRoot @()
        { Find-OrphanFolders -Refresh } | Should -Throw '*C:*'
    }

    It 'blocks nested junction entry points before discovery, expansion or preview' {
        New-OldFile "$root/outside/cache/keep.bin" 2048
        $null = New-Item -ItemType Junction -Path "$root/link" -Target "$root/outside"
        try {
            [Bakunawa.Scanner]::IsAllowedPath("$root/link/cache") | Should -BeFalse
            $null = Find-OrphanFolders -Roots "$root/link/cache" -Refresh
            (Get-OrphanScanReport).Findings.Count | Should -Be 0
            (Get-OrphanScanReport).Coverage[0].Status | Should -Be 'Unavailable or excluded'
            @(Expand-WildcardPath "$root/*/cache" -DirectoriesOnly) | Should -Not -Contain "$root/link/cache"
            @(Expand-WildcardPath "$root/link/*" -DirectoriesOnly).Count | Should -Be 0
            Measure-AndClear "$root/link/cache" | Should -BeFalse
            Get-DirectorySize "$root/link/cache" | Should -Be 0
            Test-Path "$root/outside/cache/keep.bin" | Should -BeTrue
        } finally { [IO.Directory]::Delete("$root/link") }
    }

    It 'finds recent caches with application evidence without promoting them to automatic deletion' {
        New-OldFile "$root/App/cache/data.bin" 4096
        (Get-Item "$root/App/cache/data.bin").LastWriteTimeUtc = [datetime]::UtcNow
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'Fixture app'; Path = "$root/App/cache"; Process = 'bakunawa-fixture'; SourceFile = 'fixture.json' })
        }
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { $false }
        Initialize-CleanupState -Config $cfg -ScanRoot $root
        $found = @(Find-OrphanFolders -Refresh)
        $found.Count | Should -Be 1
        $found[0].Category | Should -Be 'Known app cache'
        $found[0].Size | Should -Be 4096
        $found[0].Reason | Should -Match 'Fixture app.*fixture.json'
        $found[0].SafeDelete | Should -BeFalse
        Clear-CachedOrphans | Should -Be 0
        Test-Path "$root/App/cache/data.bin" | Should -BeTrue
        Mock -ModuleName Bakunawa.Cleanup Test-AnyProcessRunning { $true }
        { Clear-ReviewedOrphans -Path "$root/App/cache" -Preview } | Should -Throw '*Review-only*'
        Initialize-CleanupState -Config $cfg -ScanRoot $root
        @(Find-OrphanFolders -Refresh).Count | Should -Be 0
        (Get-OrphanScanReport).Issues[0].Reason | Should -Match 'Close the owning app'
    }

    It 'restricts Recycle Bin cleanup to C: and keeps preview non-destructive' {
        Mock -ModuleName Bakunawa.Cleanup Clear-RecycleBin {}
        Clear-RecycleBinSafe | Should -BeTrue
        Should -Invoke -ModuleName Bakunawa.Cleanup Clear-RecycleBin -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'C' }
        & (Get-Module Bakunawa.Cleanup) { $script:IsPreview = $true }
        Clear-RecycleBinSafe | Should -BeTrue
        Should -Invoke -ModuleName Bakunawa.Cleanup Clear-RecycleBin -Times 1 -Exactly
    }

    It 'refuses a deletion whose target resolves outside C:' {
        New-OldFile "$root/old.tmp" 256
        Set-OldTree $root
        $finding = @(Find-OrphanFolders -Roots $root -Refresh)[0]
        $finding.SafeDelete = $true
        $finding.EvidenceRule = 'fixture:verified'
        & (Get-Module Bakunawa.Cleanup) { param($path) $script:OrphanRulePaths[$path] = [pscustomobject]@{Name = 'Fixture'} } $finding.Path
        Mock -ModuleName Bakunawa.Cleanup Test-OrphanEvidence { [pscustomobject]@{Eligible = $true} }
        # A D: target must be refused outright: the cleaner is C:-only.
        # Remove-ItemSafely is a private helper, so it is only reachable inside module scope.
        { InModuleScope Bakunawa.Cleanup { Remove-ItemSafely -Path 'D:\no-such-target' -Reason Test } } | Should -Throw '*C:*'
        Test-Path "$root/old.tmp" | Should -BeTrue
    }

    It 'cleans only Roblox client caches and preserves installed executables' {
        New-OldFile "$root/Roblox/Versions/version-test/ClientCache/data.bin" 1024
        New-OldFile "$root/Roblox/Versions/version-test/RobloxPlayerBeta.exe" 2048
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'Roblox'; Path = "$root/Roblox/Versions/*/ClientCache"; Category = 'Game Caches' })
        }
        Clear-GameCaches | Should -Be 1
        Test-Path "$root/Roblox/Versions/version-test/ClientCache/data.bin" | Should -BeFalse
        Test-Path "$root/Roblox/Versions/version-test/RobloxPlayerBeta.exe" | Should -BeTrue
    }
}

Describe 'Default C: scope and browser data protection' {
    It 'selects only C: without enumerating other drives' {
        @(Get-ScanDriveRoots).Count | Should -Be 1
        @(Get-ScanDriveRoots)[0] | Should -Be 'C:\'
    }
    It 'keeps persistent browser Local Storage out of cleanup definitions' {
        @(Get-AllAppDefinitions -Category 'Browser Caches' | Where-Object { $_.Path -match 'Local Storage' }).Count | Should -Be 0
    }
}
