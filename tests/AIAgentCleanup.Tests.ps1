#requires -Version 5.1
# Pester v5 tests for the AI Agent cache category and its safety guardrails.
#
# These tests pin the three defects the first implementation of this feature had:
#   1. Clear-AIAgentCaches called Remove-Item directly with no -Preview guard, so a
#      Preview run destroyed real files (it deleted a live 9router install.log).
#   2. 'AI Agent Caches' was never added to Get-CleanupTasks, so the switch case
#      in Invoke-CleanupRun was unreachable dead code.
#   3. The protected-extension list was defined but never consulted, so config
#      files (.json/.yaml/.env/.toml) were one pattern change away from deletion.
#
# Deletion is permanent. Preview is the only dry run and must never mutate.
#
# Run: Invoke-Pester -Path tests/AIAgentCleanup.Tests.ps1 -Output Detailed

BeforeAll {
    $repoRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module "$repoRoot/src/Bakunawa.Core.psm1" -Force
    Import-Module "$repoRoot/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Config.psm1" -Force -DisableNameChecking
    Import-Module "$repoRoot/src/Bakunawa.Cleanup.psm1" -Force -DisableNameChecking

    Mock -ModuleName Bakunawa.Cleanup Write-CommandLog { }

    # 4 days old: past the 3-day guardrail, so age is not what is under test.
    function script:New-OldFile {
        param([string]$Path, [int]$Bytes = 1024)
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $Path).LastWriteTime = (Get-Date).AddDays(-4)
        $Path
    }

    function script:New-AiCacheRoot {
        $root = Join-Path $TestDrive ("ai-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }
}

Describe 'Protected extension guardrails' {
    It 'treats configuration files as protected' {
        foreach ($name in @('config.json', 'settings.yaml', 'settings.yml', '.env', 'data.toml',
                            'app.ini', 'app.cfg', 'app.conf')) {
            Test-ProtectedFileExtension -FileName $name | Should -BeTrue -Because "$name is configuration"
        }
    }

    It 'does not treat temp artifacts as protected' {
        foreach ($name in @('cache.tmp', 'debug.log', 'old.bak', 'blob.cache', 'db.sqlite-wal')) {
            Test-ProtectedFileExtension -FileName $name | Should -BeFalse
        }
    }

    It 'matches only the targeted temp/cache patterns' {
        foreach ($name in @('a.tmp', 'a.log', 'a.bak', 'a.cache', 'a.blob', 'a.sqlite-shm', 'a.sqlite-wal')) {
            Test-TargetedFilePattern -FileName $name | Should -BeTrue
        }
        foreach ($name in @('config.json', '.env', 'data.toml', 'binary.exe', 'notes.txt')) {
            Test-TargetedFilePattern -FileName $name | Should -BeFalse
        }
    }
}

Describe 'AI Agent task registration' {
    It 'registers AI Agent Caches as a runnable task' {
        $names = @(Get-CleanupTasks -Mode 'Standard' | ForEach-Object { $_.Name })
        $names | Should -Contain 'AI Agent Caches' -Because 'Invoke-CleanupRun dispatches by task name'
    }

    It 'registers it in both Standard and Aggressive modes' {
        foreach ($mode in @('Standard', 'Aggressive')) {
            @(Get-CleanupTasks -Mode $mode | ForEach-Object { $_.Name }) |
                Should -Contain 'AI Agent Caches'
        }
    }
}

Describe 'Clear-AIAgentCaches safety' {
    BeforeEach {
        $script:root = New-AiCacheRoot
        # Be explicit: these tests must not inherit preview state from a sibling.
        InModuleScope -ModuleName Bakunawa.Cleanup { $script:IsPreview = $false; $script:Planning = $false }
    }

    It 'deletes nothing in Preview mode' {
        $log = New-OldFile (Join-Path $root 'agent.log')
        $json = New-OldFile (Join-Path $root 'config.json')

        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'FakeAI'; Path = $root; Category = 'AI Agent Caches' })
        }
        # $script:IsPreview is only initialised by Invoke-CleanupRun, so a direct
        # call defaults to a real delete. Set it explicitly, as a Preview run does.
        InModuleScope -ModuleName Bakunawa.Cleanup { $script:IsPreview = $true }
        $null = Clear-AIAgentCaches
        InModuleScope -ModuleName Bakunawa.Cleanup { $script:IsPreview = $false }

        Test-Path -LiteralPath $log | Should -BeTrue -Because 'Preview must not delete'
        Test-Path -LiteralPath $json | Should -BeTrue
    }

    It 'never deletes protected configuration files' {
        foreach ($name in @('config.json', 'settings.yaml', '.env', 'data.toml')) {
            New-OldFile (Join-Path $root $name) | Out-Null
        }
        # Even a log-named file that is also a protected extension must be spared
        # when the extension is protected: .env wins over the *.log match.
        $envLog = New-OldFile (Join-Path $root 'production.env')

        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'FakeAI'; Path = $root; Category = 'AI Agent Caches' })
        }
        $null = Clear-AIAgentCaches

        foreach ($name in @('config.json', 'settings.yaml', '.env', 'data.toml', 'production.env')) {
            Test-Path -LiteralPath (Join-Path $root $name) |
                Should -BeTrue -Because "$name is configuration and must survive"
        }
    }

    It 'keeps files newer than the 3-day guardrail' {
        $fresh = Join-Path $root 'fresh.log'
        New-Item -ItemType File -Path $fresh -Force | Out-Null
        (Get-Item -LiteralPath $fresh).LastWriteTime = (Get-Date).AddHours(-2)

        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'FakeAI'; Path = $root; Category = 'AI Agent Caches' })
        }
        $null = Clear-AIAgentCaches

        Test-Path -LiteralPath $fresh | Should -BeTrue -Because 'an active session must not be broken'
    }

    It 'deletes stale targeted files in Standard mode' {
        $stale = New-OldFile (Join-Path $root 'stale.log')
        $keep = New-OldFile (Join-Path $root 'keep.json')

        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'FakeAI'; Path = $root; Category = 'AI Agent Caches' })
        }
        $null = Clear-AIAgentCaches

        Test-Path -LiteralPath $stale | Should -BeFalse -Because 'stale .log older than 3 days is a target'
        Test-Path -LiteralPath $keep | Should -BeTrue
    }

    It 'leaves untargeted file types alone' {
        $exe = New-OldFile (Join-Path $root 'tool.exe')
        Mock -ModuleName Bakunawa.Cleanup Get-AllAppDefinitions {
            @([pscustomobject]@{ Name = 'FakeAI'; Path = $root; Category = 'AI Agent Caches' })
        }
        $null = Clear-AIAgentCaches
        Test-Path -LiteralPath $exe | Should -BeTrue -Because '.exe is not a targeted pattern'
    }
}
