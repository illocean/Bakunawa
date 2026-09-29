# Bakunawa.Config.psm1
# Configuration management module for Bakunawa cleaner
# Handles user config files, validation, defaults, and integration

using namespace System.Collections.Generic

# Script-scoped variables
$script:ConfigPath = $null
$script:CurrentConfig = $null
$script:DefaultConfig = $null
$script:ConfigSchema = $null

# Define schema validation rules
$script:ConfigSchema = @{
    version = @{ type = 'string'; required = $true; pattern = '^\d+\.\d+$' }
    metadata = @{ type = 'object'; required = $false }
    cleanupMode = @{ type = 'object'; required = $true }
    exclusions = @{ type = 'object'; required = $true }
    taskCategories = @{ type = 'object'; required = $true }
    riskTiers = @{ type = 'object'; required = $true }
    scheduleSettings = @{ type = 'object'; required = $false }
    behaviorSettings = @{ type = 'object'; required = $false }
}

# Private helper to convert PSCustomObject (from ConvertFrom-Json) to hashtable recursively
function ConvertTo-HashtableFromObject {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    # Handle arrays
    if ($InputObject -is [array]) {
        $result = @()
        foreach ($item in $InputObject) {
            $result += ConvertTo-HashtableFromObject -InputObject $item
        }
        # comma preserves single-element arrays from pipeline unwrap
        return , $result
    }

    # Handle PSCustomObject (from ConvertFrom-Json)
    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        $properties = $InputObject | Get-Member -MemberType NoteProperty
        foreach ($prop in $properties) {
            $value = $InputObject.($prop.Name)
            if ($null -eq $value) {
                # PS 5.1 ConvertFrom-Json yields $null for empty JSON arrays ([]);
                # preserve them as empty arrays so schema checks and merges behave
                $result[$prop.Name] = @()
            } else {
                $result[$prop.Name] = ConvertTo-HashtableFromObject -InputObject $value
            }
        }
        return $result
    }

    # Handle hashtables (already in correct form)
    if ($InputObject -is [hashtable]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-HashtableFromObject -InputObject $InputObject[$key]
        }
        return $result
    }

    # Primitives (string, int, bool, etc.)
    return $InputObject
}

function Initialize-ConfigModule {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )
    
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $env:APPDATA 'Bakunawa\config.json'
    }
    
    $script:ConfigPath = $ConfigPath
    Write-Debug "Config module initialized with path: $script:ConfigPath"
}

function Get-DefaultConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    
    $default = @{
        version = "1.0"
        metadata = @{
            lastModified = (Get-Date -Format 'o')
            createdBy = "Bakunawa v2.0"
        }
        cleanupMode = @{
            defaultMode = "Standard"
            previewBeforeDelete = $true
            dryRun = $false
            parallelEnabled = $false
        }
        exclusions = @{
            hardExcluded = @(
                "USERPROFILE:Desktop",
                "USERPROFILE:Documents",
                "USERPROFILE:Downloads",
                "USERPROFILE:Pictures",
                "USERPROFILE:Videos",
                "USERPROFILE:Music",
                "ONEDRIVE:Desktop",
                "ONEDRIVE:Documents",
                "ONEDRIVE:Downloads",
                "ONEDRIVE:Pictures",
                "ONEDRIVE:Videos",
                "ONEDRIVE:Music",
                "ONEDRIVE_COMMERCIAL:Desktop",
                "ONEDRIVE_COMMERCIAL:Documents",
                "ONEDRIVE_COMMERCIAL:Downloads",
                "ONEDRIVE_COMMERCIAL:Pictures",
                "ONEDRIVE_COMMERCIAL:Videos",
                "ONEDRIVE_COMMERCIAL:Music",
                "LOCALAPPDATA:Packages"
            )
            userCustomExclusions = @()
            allowSymlinkBypass = $false
            resolveJunctions = $true
        }
        taskCategories = @{
            "System Caches" = @{ enabled = $true; riskTier = "Safe"; description = "System temporary files and Windows cache" }
            "Browser Caches" = @{ enabled = $true; riskTier = "Safe"; description = "Chrome, Edge, Firefox cache and cookies" }
            "App Caches" = @{ enabled = $true; riskTier = "Safe"; description = "Application-specific cache directories" }
            "Dev Caches" = @{ enabled = $true; riskTier = "Safe"; description = "Development tool caches (git, node, etc)" }
            "Game Caches" = @{ enabled = $true; riskTier = "Safe"; description = "Game platform caches (Roblox, Steam, Epic, Battle.net)" }
            "Browser Automation Caches" = @{ enabled = $true; riskTier = "Moderate"; description = "Playwright, Puppeteer, Selenium downloaded browsers" }
            "Package Manager Caches" = @{ enabled = $true; riskTier = "Safe"; description = "npm, pip, Hugging Face ML model caches" }
            "Cloud Sync" = @{ enabled = $false; riskTier = "Moderate"; description = "OneDrive, Google Drive, Dropbox sync caches" }
            "Creative Apps" = @{ enabled = $false; riskTier = "Moderate"; description = "Adobe, Affinity, Blender app caches" }
            "Productivity" = @{ enabled = $false; riskTier = "Moderate"; description = "Office, Teams, Slack app caches" }
            "DevOps Tools" = @{ enabled = $false; riskTier = "Moderate"; description = "Docker, Kubernetes, Terraform caches" }
            "User Hidden Folders" = @{ enabled = $false; riskTier = "Moderate"; description = "Hidden user config and cache folders" }
            "Scoop Cache" = @{ enabled = $true; riskTier = "Safe"; description = "Scoop package manager cache" }
            "Rust Cargo Cache" = @{ enabled = $true; riskTier = "Safe"; description = "Rust cargo registry cache" }
            "Go Module Cache" = @{ enabled = $true; riskTier = "Safe"; description = "Go modules cache" }
            "Bun Cache" = @{ enabled = $true; riskTier = "Safe"; description = "Bun package manager cache" }
            "GPU/Shell Caches" = @{ enabled = $true; riskTier = "Safe"; description = "GPU driver and shell extension caches" }
            "Recycle Bin" = @{ enabled = $false; riskTier = "Confirm"; description = "Empty recycle bin (requires confirmation)" }
            "Log Files" = @{ enabled = $false; riskTier = "Moderate"; description = "System and application log files" }
            "Empty/Stale Folders" = @{ enabled = $true; riskTier = "Safe"; description = "Remove empty and stale directories" }
            "Orphan Scan" = @{ enabled = $true; riskTier = "Confirm"; description = "Scan C:; clean eligible stale temp items; review caches and possible app leftovers" }
        }
        riskTiers = @{
            "Safe" = @{ requiresConfirmation = $false; requiresPreview = $false; description = "No user data risk; always safe to delete" }
            "Moderate" = @{ requiresConfirmation = $false; requiresPreview = $true; description = "Minimal user data risk; preview recommended" }
            "Confirm" = @{ requiresConfirmation = $true; requiresPreview = $true; description = "User confirmation required before deletion" }
        }
        scheduleSettings = @{
            autoCleanupEnabled = $false
            scheduleType = "Weekly"
            dayOfWeek = "Sunday"
            time = "02:00"
            notifyOnCompletion = $true
            logResults = $true
        }
        scanSettings = @{
            roots = @()
            minAgeDays = 30
            aggressiveMinAgeDays = 14
        }
        behaviorSettings = @{
            verboseLogging = $false
            trackDeletionHistory = $true
        }
    }
    
    return $default
}

function Test-ConfigSchema {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Config
    )
    
    $errors = @()
    
    # Check required top-level keys
    if (-not $Config.version) { $errors += "Missing required field: version" }
    if (-not $Config.cleanupMode) { $errors += "Missing required field: cleanupMode" }
    if (-not $Config.exclusions) { $errors += "Missing required field: exclusions" }
    if (-not $Config.taskCategories) { $errors += "Missing required field: taskCategories" }
    if (-not $Config.riskTiers) { $errors += "Missing required field: riskTiers" }
    
    # Validate version format
    if ($Config.version -and $Config.version -notmatch '^\d+\.\d+$') {
        $errors += "Invalid version format: $($Config.version) (expected X.Y)"
    }
    
    # Validate exclusions structure
    if ($Config.exclusions) {
        if ($Config.exclusions.hardExcluded -and -not ($Config.exclusions.hardExcluded -is [array])) {
            $errors += "hardExcluded must be an array"
        }
        if ($Config.exclusions.userCustomExclusions -and -not ($Config.exclusions.userCustomExclusions -is [array])) {
            $errors += "userCustomExclusions must be an array"
        }
    }
    
    # Validate task categories
    if ($Config.taskCategories) {
        foreach ($taskName in $Config.taskCategories.Keys) {
            $task = $Config.taskCategories[$taskName]
            if ($null -eq $task.enabled) { $errors += "Task '$taskName' missing 'enabled' field" }
            if (-not $task.riskTier) { $errors += "Task '$taskName' missing 'riskTier' field" }
            if ($task.riskTier -and -not $Config.riskTiers.ContainsKey($task.riskTier)) {
                $errors += "Task '$taskName' references unknown riskTier: $($task.riskTier)"
            }
        }
    }
    
    # Validate risk tiers
    if ($Config.scanSettings) {
        $age = 0
        if (-not [int]::TryParse([string]$Config.scanSettings.minAgeDays, [ref]$age) -or $age -lt 1 -or $age -gt 3650) {
            $errors += 'scanSettings.minAgeDays must be between 1 and 3650'
        }
        if ($null -ne $Config.scanSettings.roots -and $Config.scanSettings.roots -isnot [array]) {
            $errors += 'scanSettings.roots must be an array'
        }
        if ($null -ne $Config.scanSettings.aggressiveMinAgeDays -and
            (-not [int]::TryParse([string]$Config.scanSettings.aggressiveMinAgeDays, [ref]$age) -or $age -lt 1 -or $age -gt 3650)) {
            $errors += 'scanSettings.aggressiveMinAgeDays must be between 1 and 3650'
        }
    }
    if ($Config.riskTiers) {
        foreach ($tierName in $Config.riskTiers.Keys) {
            $tier = $Config.riskTiers[$tierName]
            if ($null -eq $tier.requiresConfirmation) { $errors += "RiskTier '$tierName' missing 'requiresConfirmation' field" }
            if ($null -eq $tier.requiresPreview) { $errors += "RiskTier '$tierName' missing 'requiresPreview' field" }
        }
    }
    
    return @{
        IsValid = $errors.Count -eq 0
        Errors = $errors
    }
}

function Get-UserConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$UseDefault
    )
    
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }
    
    # Return cached config if available (cache is set by every successful load/save;
    # -UseDefault bypasses both cache and file so callers always get pristine defaults)
    if ($script:CurrentConfig -and -not $UseDefault) {
        return $script:CurrentConfig
    }
    
    # Get default config
    $script:DefaultConfig = Get-DefaultConfig
    
    if ($UseDefault) {
        $script:CurrentConfig = $script:DefaultConfig
        return $script:CurrentConfig
    }
    
    # Try to load user config file
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        # Uninitialized module: degrade to defaults, never throw (empty LiteralPath guard)
        Write-Verbose 'Get-UserConfig: no config path configured, using defaults'
        $script:CurrentConfig = $script:DefaultConfig
        return $script:CurrentConfig
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Debug "Config file not found at $ConfigPath, using defaults"
        $script:CurrentConfig = $script:DefaultConfig
        return $script:CurrentConfig
    }
    
    try {
        $json = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        # PS 5.1: ConvertFrom-Json has no -AsHashtable; convert PSCustomObject graph manually
        $config = ConvertTo-HashtableFromObject -InputObject ($json | ConvertFrom-Json)
        
        # Validate schema
        $validation = Test-ConfigSchema $config
        if (-not $validation.IsValid) {
            Write-Warning "Config file validation failed:`n$($validation.Errors -join "`n")`nUsing defaults."
            $script:CurrentConfig = $script:DefaultConfig
            return $script:CurrentConfig
        }
        
        # Merge with defaults (user config overrides defaults)
        $merged = Merge-ConfigWithDefaults $config $script:DefaultConfig
        $script:CurrentConfig = $merged
        return $merged
        
    } catch {
        Write-Warning "Failed to load config file: $($_.Exception.Message). Using defaults."
        $script:CurrentConfig = $script:DefaultConfig
        return $script:CurrentConfig
    }
}

function Merge-ConfigWithDefaults {
    [CmdletBinding()]
    param(
        [ValidateNotNull()][hashtable]$UserConfig,
        [ValidateNotNull()][hashtable]$DefaultConfig
    )
    
    $merged = @{}
    
    # Copy all default keys first
    foreach ($key in $DefaultConfig.Keys) {
        if ($DefaultConfig[$key] -is [hashtable]) {
            $merged[$key] = @{}
            foreach ($subKey in $DefaultConfig[$key].Keys) {
                $merged[$key][$subKey] = $DefaultConfig[$key][$subKey]
            }
        } else {
            $merged[$key] = $DefaultConfig[$key]
        }
    }
    
    # Override with user config
    # NOTE: arrays are replaced wholesale by the user value (no union) — intentional:
    # exclusion lists and task maps must match exactly what the user configured.
    foreach ($key in $UserConfig.Keys) {
        if ($UserConfig[$key] -is [hashtable] -and $merged[$key] -is [hashtable]) {
            # Recursively merge hashtables
            foreach ($subKey in $UserConfig[$key].Keys) {
                $merged[$key][$subKey] = $UserConfig[$key][$subKey]
            }
        } else {
            $merged[$key] = $UserConfig[$key]
        }
    }
    
    return $merged
}

function Set-UserConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()][hashtable]$Config,
        [string]$ConfigPath,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw 'Set-UserConfig: no config path provided or initialized. Call Initialize-ConfigModule first.'
    }
    # (error message kept in sync with Reset-UserConfig)
    
    # Validate config schema
    $validation = Test-ConfigSchema $Config
    if (-not $validation.IsValid) {
        throw "Config validation failed:`n$($validation.Errors -join "`n")"
    }
    
    # Update metadata
    $Config.metadata = @{
        lastModified = (Get-Date -Format 'o')
        createdBy = "Bakunawa v2.0"
    }
    
    # Ensure directory exists
    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    
    # Check if file exists and backup if needed
    if ((Test-Path -LiteralPath $ConfigPath -PathType Leaf) -and -not $Force) {
        $backupPath = "$ConfigPath.backup"
        Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
        Write-Debug "Backed up existing config to $backupPath"
    }
    
    # Write config file
    try {
        $json = $Config | ConvertTo-Json -Depth 10
        # Use Out-File for better encoding support in PowerShell 5.1
        $json | Out-File -LiteralPath $ConfigPath -Encoding UTF8 -Force
        Write-Debug "Config saved to $ConfigPath"
        
        # Update cached config
        $script:CurrentConfig = $Config
        return $true
    } catch {
        throw "Failed to save config: $($_.Exception.Message)"
    }
}

function Get-EnabledTasks {
    [CmdletBinding()]
    param([ValidateNotNull()][hashtable]$Config)
    
    if (-not $Config.taskCategories) {
        return @()
    }
    
    $enabled = @()
    foreach ($taskName in $Config.taskCategories.Keys) {
        if ($Config.taskCategories[$taskName].enabled -eq $true) {
            $enabled += $taskName
        }
    }
    
    return $enabled
}

function Get-TasksByRiskTier {
    [CmdletBinding()]
    param(
        [ValidateNotNull()][hashtable]$Config,
        [Parameter(Mandatory = $true)][ValidateSet('Safe', 'Moderate', 'Confirm')][string]$RiskTier
    )
    
    if (-not $Config.taskCategories) {
        return @()
    }
    
    $tasks = @()
    foreach ($taskName in $Config.taskCategories.Keys) {
        if ($Config.taskCategories[$taskName].riskTier -eq $RiskTier) {
            $tasks += $taskName
        }
    }
    
    return $tasks
}

function Get-CustomExclusions {
    [CmdletBinding()]
    param([ValidateNotNull()][hashtable]$Config)
    
    $exclusions = @()
    
    if ($Config.exclusions.hardExcluded) {
        $exclusions += $Config.exclusions.hardExcluded
    }
    
    if ($Config.exclusions.userCustomExclusions) {
        $exclusions += $Config.exclusions.userCustomExclusions
    }
    
    return $exclusions
}

function Add-CustomExclusion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [hashtable]$Config,
        [switch]$Persistent
    )
    
    if (-not $Config) {
        $Config = Get-UserConfig
    }
    
    if ($Config.exclusions.userCustomExclusions -notcontains $Path) {
        $Config.exclusions.userCustomExclusions += $Path
        
        if ($Persistent) {
            Set-UserConfig -Config $Config -Force
        }
    }
    
    return $Config
}

function Remove-CustomExclusion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path,
        [hashtable]$Config,
        [switch]$Persistent
    )
    
    if (-not $Config) {
        $Config = Get-UserConfig
    }
    
    $Config.exclusions.userCustomExclusions = @($Config.exclusions.userCustomExclusions | Where-Object { $_ -ne $Path })
    
    if ($Persistent) {
        Set-UserConfig -Config $Config -Force
    }
    
    return $Config
}

function Set-TaskEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TaskName,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [hashtable]$Config,
        [switch]$Persistent
    )
    
    if (-not $Config) {
        $Config = Get-UserConfig
    }
    
    if ($Config.taskCategories.ContainsKey($TaskName)) {
        $Config.taskCategories[$TaskName].enabled = $Enabled
        
        if ($Persistent) {
            Set-UserConfig -Config $Config -Force
        }
    } else {
        throw "Unknown task: $TaskName"
    }
    
    return $Config
}

function Export-ConfigTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$OutputPath
    )

    $default = Get-DefaultConfig
    $json = $default | ConvertTo-Json -Depth 10

    try {
        $json | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force -ErrorAction Stop
        Write-Host "Config template exported to: $OutputPath"
    } catch {
        throw "Export-ConfigTemplate failed: $($_.Exception.Message)"
    }
}

function Reset-UserConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = $script:ConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw 'Reset-UserConfig: no config path provided or initialized. Call Initialize-ConfigModule first.'
    }

    if ((Test-Path -LiteralPath $ConfigPath) -and -not $Force) {
        throw "Config file exists. Use -Force to overwrite."
    }

    $default = Get-DefaultConfig
    Set-UserConfig -Config $default -ConfigPath $ConfigPath -Force
}

# Export public functions
Export-ModuleMember -Function @(
    'Initialize-ConfigModule',
    'Get-DefaultConfig',
    'Get-UserConfig',
    'Set-UserConfig',
    'Test-ConfigSchema',
    'Get-EnabledTasks',
    'Get-TasksByRiskTier',
    'Get-CustomExclusions',
    'Add-CustomExclusion',
    'Remove-CustomExclusion',
    'Set-TaskEnabled',
    'Export-ConfigTemplate',
    'Reset-UserConfig',
    'Merge-ConfigWithDefaults'
)
