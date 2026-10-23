<#
Bakunawa v4.0 - Self-Contained System Cleaner
Modular architecture with separate modules in src/
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Standard', 'Aggressive', 'Preview', 'Scan', 'Health', 'Benchmark')]
    [string]$Mode = 'Menu',
    [switch]$NoPause,
    [switch]$VerboseScan,
    [string[]]$ExtraExcludePath,
    [string]$LogFile,
    [string]$Profile,
    [switch]$SkipBootstrap,
    [switch]$ForceAdmin,
    [switch]$NoAnimations,
    [string[]]$ScanRoot,
    [string]$ReportPath
)

Set-Variable -Name ErrorActionPreference -Value 'Continue' -Scope Script
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Import modules from src/
$moduleDir = Join-Path $PSScriptRoot 'src'
Import-Module (Join-Path $moduleDir 'Bakunawa.Core.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Config.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.Cleanup.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
Import-Module (Join-Path $moduleDir 'Bakunawa.UI.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue
# The bootstrap module owns the session: mode resolution, session setup, dispatch.
Import-Module (Join-Path $moduleDir 'Bakunawa.Bootstrap.psm1') -Force -Scope Global -ErrorAction Stop -WarningAction SilentlyContinue

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LegacyConsole {
    # The host process that owns our console is the PARENT of this PowerShell
    # process, not this process itself (we are always powershell.exe/pwsh.exe).
    $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if (-not $self -or -not $self.ParentProcessId) { return $false }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($self.ParentProcessId)" -ErrorAction SilentlyContinue
    if (-not $parent) { return $false }
    return ($parent.Name -eq 'conhost.exe')
}

function Get-ElevationShell {
    # pwsh preferred when installed; Windows PowerShell 5.1 is the always-present fallback.
    $pwsh = Get-Command pwsh.exe -ErrorAction Ignore
    if ($pwsh) { return $pwsh.Source }
    $winPs = Get-Command powershell.exe -ErrorAction Ignore
    if ($winPs) { return $winPs.Source }
    return $null
}

function Restart-ModernTerminal {
    param([string]$SelectedMode)
    # One modern-relaunch attempt per process: a failed or cancelled UAC prompt
    # must not queue a second one from the Restart-Elevated fallback below.
    if ($script:ModernLaunchTried) { return $false }
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    $shell = Get-ElevationShell
    if (-not $wt -or -not $shell) {
        Write-Host 'Windows Terminal (wt.exe) not available for relaunch.' -ForegroundColor Yellow
        return $false
    }
    # Use the WindowsApps execution alias ($wt.Source), never the packaged binary
    # under C:\Program Files\WindowsApps: launching that payload directly starts
    # no terminal and no child, so elevation would silently do nothing.
    $entry = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'Bakunawa.ps1' }
    # ForceAdmin breaks the relaunch loop: the child is already elevated by -Verb RunAs,
    # so it must not try to detect the console or elevate again.
    $forward = @{ Mode = $SelectedMode; ForceAdmin = $true }
    foreach ($name in @('NoAnimations','VerboseScan','NoPause')) {
        if (Get-Variable -Name $name -ValueOnly) { $forward[$name] = $true }
    }
    foreach ($name in @('ExtraExcludePath','LogFile','ScanRoot','ReportPath','Profile')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($value) { $forward[$name] = $value }
    }
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($forward)))
    # The child acknowledges the launch by creating $ack. wt.exe is a GUI app and
    # can die without an exception, which would leave the user staring at a
    # vanished console with no fallback triggered.
    $ack = Join-Path ([IO.Path]::GetTempPath()) ('bakunawa-elevated-{0}.txt' -f $PID)
    $body = '$ack = ''{0}''; try {{ Set-Content -LiteralPath $ack -Value ''ok'' -ErrorAction Stop }} catch {{}}; $forward = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{1}''))); & ''{2}'' @forward' -f $ack.Replace("'", "''"), $data, $entry.Replace("'", "''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $cmd = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $script:ModernLaunchTried = $true
    Write-Host ''
    Write-Host 'Relaunching in Windows Terminal as Administrator...' -ForegroundColor Cyan
    $launched = $false
    try {
        # Quote the directory and shell paths: user profile paths can contain spaces.
        Start-Process -FilePath $wt.Source -ArgumentList '-d', ('"{0}"' -f (Split-Path -Parent $entry)), ('"{0}"' -f $shell), $cmd -Verb RunAs | Out-Null
        $launched = $true
    } catch {
        Write-Host "Windows Terminal launch failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    if ($launched) {
        for ($i = 0; $i -lt 20 -and -not (Test-Path -LiteralPath $ack); $i++) { Start-Sleep -Milliseconds 300 }
        if (Test-Path -LiteralPath $ack) {
            Remove-Item -LiteralPath $ack -Force -ErrorAction SilentlyContinue
            return $true
        }
        Write-Host 'Windows Terminal did not take over the session.' -ForegroundColor Yellow
    }
    Remove-Item -LiteralPath $ack -Force -ErrorAction SilentlyContinue
    return $false
}

function Restart-Elevated {
    param([string]$SelectedMode)
    # Elevate into Windows Terminal when it is installed; the bare
    # powershell.exe window below is only the fallback for machines without wt.exe.
    if (Restart-ModernTerminal -SelectedMode $SelectedMode) { return $true }
    $hostExe = Get-ElevationShell
    if (-not $hostExe) {
        Write-Host 'PowerShell executable not found. Elevation requires powershell.exe or pwsh.exe.' -ForegroundColor Red
        return $false
    }
    $entry = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $PSScriptRoot 'Bakunawa.ps1' }
    # Serialize arguments as data so arrays, spaces, apostrophes and dollar signs survive elevation.
    $forward = @{ Mode = $SelectedMode }
    foreach ($name in @('ForceAdmin','NoAnimations','VerboseScan','NoPause')) {
        if (Get-Variable -Name $name -ValueOnly) { $forward[$name] = $true }
    }
    foreach ($name in @('ExtraExcludePath','LogFile','ScanRoot','ReportPath','Profile')) {
        $value = Get-Variable -Name $name -ValueOnly
        if ($value) { $forward[$name] = $value }
    }
    $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($forward)))
    $body = '$forward = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{0}''))); & ''{1}'' @forward' -f $data, $entry.Replace("'", "''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $cmd = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    Write-Host ''
    Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $cmd | Out-Null
        return $true
    } catch {
        Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

if (-not $SkipBootstrap) {
    # Mode resolution and profile handling live in the bootstrap module so they
    # can be tested without launching the cleaner.
    $resolution = Resolve-BakunawaMode -Mode $Mode -Profile $Profile -ProfileRoot $PSScriptRoot `
        -ModeWasSpecified:$PSBoundParameters.ContainsKey('Mode')
    if ($resolution.Error) {
        Write-Host $resolution.Error -ForegroundColor Red
        exit 1
    }
    if ($resolution.Warning) { Write-Host $resolution.Warning -ForegroundColor Yellow }
    $Mode = $resolution.Mode

    # Modern Terminal relaunch: detect legacy conhost and relaunch via wt.exe
    if ((Test-LegacyConsole) -and -not $ForceAdmin) {
        if (Restart-ModernTerminal -SelectedMode $Mode) { exit 0 }
    }

    # Admin check for modes that require it (Menu requires admin for cleanup actions)
    $needsAdmin = $Mode -in @('Menu','Standard','Aggressive') -and -not (Test-IsAdministrator) -and -not $ForceAdmin
    if ($needsAdmin) {
        Write-Host "$Mode mode requires administrator privileges for full system access." -ForegroundColor Yellow
        if (-not (Restart-Elevated -SelectedMode $Mode)) {
            Write-Host ''
            Write-Host 'Automatic elevation failed. Without admin rights, system-level cleanup fails with "Access is denied".' -ForegroundColor Red
            Write-Host 'Fix: right-click PowerShell, choose "Run as administrator", then run Bakunawa again.' -ForegroundColor Yellow
            Write-Host '      (Your account must be in the local Administrators group and UAC must be enabled.)' -ForegroundColor Yellow
            exit 1
        }
        exit 0
    }
}

# The session is always prepared: config, logging and the cleanup scope decide
# what a run is allowed to touch. Only the pre-flight above is skipped.
try {
    $null = Initialize-BakunawaSession -Mode $Mode -ScanRoot $ScanRoot -ExtraExcludePath $ExtraExcludePath `
        -VerboseScan:$VerboseScan -NoAnimations:$NoAnimations -LogFile $LogFile
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Invoke-BakunawaMode -Mode $Mode -ReportPath $ReportPath

if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
