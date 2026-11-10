BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
    foreach ($module in @('Core','Config','Cleanup','UI')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -DisableNameChecking
    }
}

Describe 'Cleanup truthfulness: reported bytes match what was deleted' {

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        InModuleScope Bakunawa.Cleanup {
            $script:IsPreview = $false
            $script:Planning = $false
            $script:ProcessedCacheRoots = New-TrackedSet
            $script:BusyCachePaths = [Collections.Generic.List[string]]::new()
            $script:TaskBytes = 0L
            $script:TaskCleared = 0
            $script:TaskSkipped = 0
        }
    }

    It 'raises an error instead of reporting success when a file cannot be deleted' {
        $path = Join-Path $root 'locked.bin'
        [IO.File]::WriteAllBytes($path, (New-Object byte[] 4096))

        $handle = [IO.File]::Open($path, 'Open', 'Read', 'None')
        try {
            { Remove-ItemSafely -Path $path -Reason 'Probe' } | Should -Throw
            Test-Path -LiteralPath $path | Should -BeTrue -Because 'the open handle blocks deletion'
        } finally { $handle.Dispose() }
    }

    It 'reclaims nothing and reports nothing when a cache root is empty' {
        $cache = Join-Path $root 'empty'
        $null = New-Item -ItemType Directory -Path $cache -Force

        Measure-AndClear -Path $cache -Category 'Probe' | Should -BeFalse
        InModuleScope Bakunawa.Cleanup { $script:TaskBytes } | Should -Be 0
        InModuleScope Bakunawa.Cleanup { $script:TaskCleared } | Should -Be 0
    }

    It 'reclaims the measured size of a cache root it actually clears' {
        $cache = Join-Path $root 'real'
        $null = New-Item -ItemType Directory -Path $cache -Force
        [IO.File]::WriteAllBytes((Join-Path $cache 'a.bin'), (New-Object byte[] 2048))
        [IO.File]::WriteAllBytes((Join-Path $cache 'b.bin'), (New-Object byte[] 1024))

        Measure-AndClear -Path $cache -Category 'Probe' | Should -BeTrue
        InModuleScope Bakunawa.Cleanup { $script:TaskBytes } | Should -Be 3072
        @(Get-ChildItem -LiteralPath $cache -Force).Count | Should -Be 0
    }
}
