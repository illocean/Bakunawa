#requires -Version 5.1
BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/../").Path
    Import-Module "$repo/src/Bakunawa.Core.psm1" -Force -DisableNameChecking
    Import-Module "$repo/src/Bakunawa.UI.psm1" -Force -DisableNameChecking
    function In-Ui([scriptblock]$Script) { & (Get-Module Bakunawa.UI) $Script }
}

Describe 'Scan status line' {
    It 'carries root, elapsed, entries and candidates on one line' {
        $line = In-Ui { Format-ScanStatus -Root 'C:\' -RootIndex 1 -RootCount 1 -Visited 148302 -Candidates 12 -Seconds 42 }
        $line | Should -Match '148,302 entries'
        $line | Should -Match '12 candidates'
        $line | Should -Match '00:42'
    }

    It 'counts roots only when more than one is walked' {
        In-Ui { Format-ScanStatus -Root 'C:\Users\me' -RootCount 1 } | Should -Not -Match 'root'
        In-Ui { Format-ScanStatus -Root 'C:\Users\me' -RootIndex 2 -RootCount 3 } | Should -Match 'root 2/3'
    }

    It 'surfaces errors and truncates rather than wrapping' {
        $line = In-Ui { Format-ScanStatus -Root 'C:\' -Visited 5 -Errors 2 -Seconds 1 -CurrentPath 'C:\Users\fixture\AppData\Local\Temp\deep\folder\file.bin' -Width 60 }
        $line | Should -Match '2 errors'
        $line.Length | Should -BeLessOrEqual 60
    }
}

Describe 'Path tail' {
    It 'keeps the last segments and marks the cut' {
        In-Ui { Get-PathTail 'C:\Users\me\AppData\Local\Temp\x' 3 } | Should -Be '…\Local\Temp\x'
    }

    It 'leaves a short path whole' {
        In-Ui { Get-PathTail 'C:\Temp' 3 } | Should -Be 'C:\Temp'
    }
}

Describe 'Storage comparison' {
    AfterEach { In-Ui { $script:StorageBaseline = $null } }

    It 'returns nothing when no run baseline exists' {
        In-Ui { $script:StorageBaseline = $null } | Out-Null
        In-Ui { Get-StorageComparison } | Should -BeNullOrEmpty
    }

    It 'measures the change from the baseline to the drive' {
        Mock -ModuleName Bakunawa.UI Get-FreeSpaceInfo { [pscustomobject]@{ FreeBytes = [long]157286400 } }
        In-Ui { $script:StorageBaseline = [pscustomobject]@{ FreeBytes = [long]104857600; Started = Get-Date } }
        $comparison = In-Ui { Get-StorageComparison 'Free space' }
        $comparison.Before | Should -Be 104857600
        $comparison.After | Should -Be 157286400
        $comparison.Change | Should -Be 52428800
    }

    It 'reports an unchanged drive as no change' {
        Mock -ModuleName Bakunawa.UI Get-FreeSpaceInfo { [pscustomobject]@{ FreeBytes = [long]104857600 } }
        In-Ui { $script:StorageBaseline = [pscustomobject]@{ FreeBytes = [long]104857600; Started = Get-Date } }
        (In-Ui { Get-StorageComparison }).Change | Should -Be 0
    }

    It 'prints one before and after row with the note' {
        Mock -ModuleName Bakunawa.UI Get-FreeSpaceInfo { [pscustomobject]@{ FreeBytes = [long]157286400 } }
        In-Ui { $script:StorageBaseline = [pscustomobject]@{ FreeBytes = [long]104857600; Started = Get-Date } }
        $text = In-Ui { Write-StorageLine (Get-StorageComparison) -Note 'unchanged - read-only run' } 6>&1 | Out-String
        $text | Should -Match 'Free space'
        $text | Should -Match '100\.0 MB → 150\.0 MB'
        $text | Should -Match 'unchanged - read-only run'
    }
}