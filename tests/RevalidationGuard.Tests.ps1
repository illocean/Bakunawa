BeforeAll {
    $repo = (Resolve-Path "$PSScriptRoot/..").Path
    foreach ($module in @('Core','Config','Cleanup','UI')) {
        Import-Module "$repo/src/Bakunawa.$module.psm1" -Force -DisableNameChecking
    }
}

Describe 'Revalidation guard: tolerate live caches, refuse unplanned growth' {

    It 'flags a target that grew in size' {
        $before = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01' }
        $after = [pscustomobject]@{ Bytes = 2048L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01' }
        Test-CandidateChanged -Before $before -After $after | Should -BeTrue
    }

    It 'flags a target that gained files at the same size' {
        $before = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01' }
        $after = [pscustomobject]@{ Bytes = 1024L; Files = 2; LatestWriteUtc = [datetime]'2026-01-01' }
        Test-CandidateChanged -Before $before -After $after | Should -BeTrue
    }

    It 'does not flag a newer write timestamp alone' {
        # Live caches (Prefetch, Downloader, browser caches) are rewritten by running
        # services between planning and execution. That is not drift.
        $before = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01T00:00:00.0000001Z' }
        $after = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01T00:00:05.1234567Z' }
        Test-CandidateChanged -Before $before -After $after | Should -BeFalse
    }

    It 'does not flag an unchanged target' {
        $same = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-01' }
        Test-CandidateChanged -Before $same -After $same | Should -BeFalse
    }

    It 'does not flag a target that shrank' {
        $before = [pscustomobject]@{ Bytes = 4096L; Files = 3; LatestWriteUtc = [datetime]'2026-01-01' }
        $after = [pscustomobject]@{ Bytes = 1024L; Files = 1; LatestWriteUtc = [datetime]'2026-01-02' }
        Test-CandidateChanged -Before $before -After $after | Should -BeFalse
    }
}
