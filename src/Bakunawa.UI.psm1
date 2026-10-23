# Bakunawa.UI.psm1 -- Terminal rendering engine

if ($null -eq $script:TotalSteps) { $script:TotalSteps = 0 }
if ($null -eq $script:StepIndex)  { $script:StepIndex = 0 }

# NOTE: $script:LogFilePath is owned by THIS module. Set it only via Initialize-UiLogging -
# assigning it from outside (e.g. Bakunawa.ps1 script scope) silently does nothing.

function Initialize-UiLogging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Path
    )
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $dir = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
        }
        $script:LogFilePath = $full
        return $full
    } catch {
        throw "Initialize-UiLogging failed: $($_.Exception.Message)"
    }
}

function Test-VT100Supported {
    [CmdletBinding()]
    param()
    try { return $Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Get-ModeColor {
    [CmdletBinding()]
    param([string]$Mode)
    switch ($Mode) {
        'Standard'   { 'Green' }
        'Aggressive' { 'Yellow' }
        'Preview'    { 'DarkGray' }
        default      { 'DarkCyan' }
    }
}

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERR','CMD','STEP','SIZE','SCAN')][string]$Level='INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $color = switch($Level) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red' }
        'CMD'  { 'DarkGray' }
        'STEP' { 'Cyan' }
        'SIZE' { 'Magenta' }
        'SCAN' { 'Cyan' }
        default{ 'Gray' }
    }
    # Minimal console line: no timestamp, no glyph. Full detail goes to the file log.
    Write-ReviewLine ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function Write-CommandLog {
    [CmdletBinding()]
    param([string]$Verb,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { Write-Log $Verb 'CMD'; return }
    Write-Log "$Verb $Target" 'CMD'
}

# ── WIDTH-AWARE LAYOUT ──
# One place decides how much room the UI has, so every element agrees.
# `Content` is always Columns-2: the layout can never claim a column it does
# not own, which is what broke the old framed panels below ~95 columns.
#   full     (content >= 80) the 78-column block logo
#   compact  (content >= 42) short serpent mark, same wording
#   narrow   (anything less) minimal mark, tagline dropped
function Get-UiLayout {
    [CmdletBinding()]
    param([int]$Width = 0)
    $columns = if ($Width -gt 0) { $Width } else { Get-ConsoleWidth }
    if ($columns -lt 20) { $columns = 20 }
    $content = $columns - 2
    $band = 'narrow'
    if ($content -ge 80) { $band = 'full' }
    elseif ($content -ge 42) { $band = 'compact' }
    [PSCustomObject]@{ Columns = $columns; Content = $content; Band = $band }
}

# Free space is the one number the menu leads with, so it gets the only
# threshold-based colour in the UI. A 13% disk must not look like a 60% disk.
# High is good for every caller, but a 20% score is not a 20% disk, so the
# thresholds move: free space is healthy above 20%, a score above 70.
function Get-UiSeverityColor {
    [CmdletBinding()]
    param([double]$Percent, [double]$Warn = 10, [double]$Good = 20)
    if ($Percent -ge $Good) { return 'Green' }
    if ($Percent -ge $Warn) { return 'Yellow' }
    return 'Red'
}

function Get-UiBarChars {
    if (Test-VT100Supported) { return @{ Full = [string][char]0x2588; Empty = [string][char]0x2591 } }
    return @{ Full = '#'; Empty = '.' }
}

# One gutter for the whole status band. Every label column in the interface
# starts here and is this wide, so no two rows can disagree about where a
# value begins -- the defect the old free-form fields had.
$script:UiGutter = 2
$script:UiLabelWidth = 11

function Get-UiValueWidth {
    [CmdletBinding()]
    param([int]$Columns = 0, [int]$LabelWidth = 0)
    if ($LabelWidth -le 0) { $LabelWidth = $script:UiLabelWidth }
    $layout = Get-UiLayout $Columns
    [Math]::Max(6, $layout.Content - $script:UiGutter - $LabelWidth - 2)
}

# Writes "  <label>  <bar>  <readout>" as one line. The bar carries the
# severity colour; the readout stays readable white so the numbers are legible
# even when the bar is red.
function Write-UiBar {
    [CmdletBinding()]
    param(
        [string]$Label,
        [int]$Percent,
        [int]$Width,
        [string]$Readout = '',
        [double]$Warn = 10,
        [double]$Good = 20,
        [int]$LabelWidth = 0
    )
    if ($LabelWidth -le 0) { $LabelWidth = $script:UiLabelWidth }
    $chars = Get-UiBarChars
    $pct = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int][Math]::Round($Width * $pct / 100.0)
    $color = Get-UiSeverityColor $pct $Warn $Good
    $label = if ($Label.Length -gt $LabelWidth) { $Label.Substring(0, $LabelWidth) } else { $Label }
    $lead = ' ' * $script:UiGutter + $label.PadRight($LabelWidth) + '  '
    # The bar shrinks before the readout does: the number is the point.
    $avail = Get-UiValueWidth 0 $LabelWidth
    if ($Width + $Readout.Length -gt $avail) {
        $Width = [Math]::Max(4, $avail - $Readout.Length - 1)
        $filled = [int][Math]::Round($Width * $pct / 100.0)
    }
    Write-Host $lead -ForegroundColor 'DarkGray' -NoNewline
    Write-Host ($chars.Full * $filled) -ForegroundColor $color -NoNewline
    Write-Host ($chars.Empty * ($Width - $filled)) -ForegroundColor 'DarkGray' -NoNewline
    if ($Readout) { Write-Host $Readout -ForegroundColor 'White' }
    else { Write-Host '' }
}

# Left-aligned "  Label  Value", with an optional dimmed suffix. The value is
# clamped so the row can never wrap into the next one.
function Write-UiField {
    [CmdletBinding()]
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = 'White',
        [ConsoleColor]$LabelColor = 'DarkGray',
        [string]$Suffix = '',
        [ConsoleColor]$SuffixColor = 'DarkGray',
        [int]$LabelWidth = 0
    )
    if ($LabelWidth -le 0) { $LabelWidth = $script:UiLabelWidth }
    $label = if ($Label.Length -gt $LabelWidth) { $Label.Substring(0, $LabelWidth) } else { $Label }
    $available = [Math]::Max(4, (Get-UiValueWidth 0 $LabelWidth) - $Suffix.Length)
    Write-Host (' ' * $script:UiGutter + $label.PadRight($LabelWidth) + '  ') -ForegroundColor $LabelColor -NoNewline
    Write-Host (Get-DisplayText $Value $available) -ForegroundColor $ValueColor -NoNewline
    if ($Suffix) { Write-Host $Suffix -ForegroundColor $SuffixColor }
    else { Write-Host '' }
}

# Prose, not a table cell. Wraps to the content width with a hanging indent so
# a safety statement is never sliced in half at the right edge.
function Write-UiNote {
    [CmdletBinding()]
    param([string]$Text, [ConsoleColor]$Color = 'DarkGray', [int]$Indent = 2)
    $lead = ' ' * $Indent
    $hang = ' ' * ($Indent + 2)
    $width = [Math]::Max(16, (Get-UiLayout).Content - $Indent)
    while ($Text.Length -gt $width) {
        $break = $Text.LastIndexOf(' ', $width)
        if ($break -lt [int]($width / 2)) { $break = $width }
        Write-Host ($lead + $Text.Substring(0, $break)) -ForegroundColor $Color
        $Text = $Text.Substring($break).TrimStart(' ')
        $lead = $hang
    }
    if ($Text) { Write-Host ($lead + $Text) -ForegroundColor $Color }
}

# A transient status line that is erased once the work it describes is done.
# The old screens left their progress text on the console for the rest of the
# run, which read as broken output rather than as a finished step.
$script:UiProgressLength = 0

function Write-UiProgress {
    [CmdletBinding()]
    param([string]$Text)
    # A redirected run has no cursor to move, so a transient line is just noise
    # in the captured output and in the log.
    if ([Console]::IsOutputRedirected) { return }
    $text = "[$Text]"
    Write-Host $text -ForegroundColor 'DarkCyan' -NoNewline
    $script:UiProgressLength = $text.Length
}

function Clear-UiProgress {
    [CmdletBinding()]
    param()
    if ($script:UiProgressLength -le 0) { return }
    Write-Host ("`r" + (' ' * $script:UiProgressLength) + "`r") -NoNewline
    $script:UiProgressLength = 0
}

# A hairline that stops at Content. Replaces the stacked box borders. -Width 0
# runs the full content width (a real division between two halves of a screen);
# a fixed width turns it into a section heading instead of a full-bleed divider.
function Write-UiRule {
    [CmdletBinding()]
    param([string]$Text = '', [ConsoleColor]$Color = 'DarkGray', [int]$Width = 0)
    $layout = Get-UiLayout
    $indent = ' ' * $script:UiGutter
    $total = if ($Width -gt 0) { [Math]::Min($Width, $layout.Content) } else { $layout.Content }
    $width = $total - $script:UiGutter
    if ($Text) {
        $prefix = " $Text "
        $width = $width - $prefix.Length
        Write-Host ($indent + $prefix) -ForegroundColor $Color -NoNewline
    }
    if ($width -gt 0) { Write-Host (('─' * $width)) -ForegroundColor $Color }
}

function Write-CenteredLine {
    [CmdletBinding()]
    param([string]$Text,[string]$ForegroundColor='White')
    $cw = Get-ConsoleWidth
    $rt = Get-DisplayText $Text $cw
    $pad = [Math]::Max(0,[int](($cw-$rt.Length)/2))
    Write-Host ((' '*$pad)+$rt) -ForegroundColor $ForegroundColor
}

function Write-Panel {
    [CmdletBinding()]
    param([string[]]$Lines,[string]$BorderColor='DarkCyan',[string]$TextColor='White',[int]$MinWidth=60,[int]$MaxWidth=92)
    $cw = Get-ConsoleWidth
    if ($cw -lt 8) { foreach ($line in $Lines) { Write-ReviewLine $line }; return }
    $longest = [int](($Lines | Measure-Object Length -Maximum).Maximum)
    $pw = [Math]::Min($cw - 2, [Math]::Min($MaxWidth, [Math]::Max($MinWidth, $longest + 4)))
    $iw = [Math]::Max(1, $pw - 4)
    $indent = ' ' * [Math]::Max(0, [int](($cw - $pw) / 2))
    $border = $indent + '+' + ('-' * ($pw - 2)) + '+'
    Write-Host $border -ForegroundColor $BorderColor
    foreach ($line in $Lines) {
        $remaining = [string]$line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F\x7F]', ' '
        while ($remaining.Length -gt $iw) {
            $split = $remaining.LastIndexOf(' ', $iw)
            if ($split -lt [Math]::Max(1, [int]($iw / 2))) { $split = $iw }
            Write-Host ($indent + '| ' + $remaining.Substring(0, $split).PadRight($iw) + ' |') -ForegroundColor $TextColor
            $remaining = $remaining.Substring($split).TrimStart(' ')
        }
        Write-Host ($indent + '| ' + $remaining.PadRight($iw) + ' |') -ForegroundColor $TextColor
    }
    Write-Host $border -ForegroundColor $BorderColor
}

# The single frame in the whole interface, reserved for the one step where
# something is destroyed. The width is hard-capped at Content so it cannot
# overrun a narrow terminal the way the old menu panels did. -Colors is
# positional with -Lines; a missing entry renders white.
function Write-ConfirmFrame {
    [CmdletBinding()]
    param([string[]]$Lines, [ConsoleColor[]]$Colors, [string]$BorderColor = 'Yellow')
    $layout = Get-UiLayout
    $longest = 0
    foreach ($line in $Lines) { if ($line.Length -gt $longest) { $longest = $line.Length } }
    $pw = [Math]::Min($layout.Content, [Math]::Max(30, $longest + 6))
    $iw = [Math]::Max(1, $pw - 4)
    $indent = ' ' * [Math]::Max(0, [int](($layout.Columns - $pw) / 2))
    $border = $indent + '+' + ('-' * ($pw - 2)) + '+'
    Write-Host $border -ForegroundColor $BorderColor
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $color = if ($i -lt $Colors.Count) { $Colors[$i] } else { 'White' }
        $remaining = $Lines[$i] -replace '\x1B\[[0-?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F\x7F]', ' '
        while ($remaining.Length -gt $iw) {
            $split = $remaining.LastIndexOf(' ', $iw)
            if ($split -lt [Math]::Max(1, [int]($iw / 2))) { $split = $iw }
            Write-Host ($indent + '| ' + $remaining.Substring(0, $split).PadRight($iw) + ' |') -ForegroundColor $color
            $remaining = $remaining.Substring($split).TrimStart(' ')
        }
        Write-Host ($indent + '| ' + $remaining.PadRight($iw) + ' |') -ForegroundColor $color
    }
    Write-Host $border -ForegroundColor $BorderColor
}

function Show-AppLogo {
    [CmdletBinding()]
    param()
    $layout = Get-UiLayout
    if ($layout.Band -ne 'full') { Show-CompactMark $layout; return }
    $logo = @(
        '▀█████████▄     ▄████████    ▄█   ▄█▄ ███    █▄  ███▄▄▄▄      ▄████████  ▄█     █▄     ▄████████'
        ' ███    ███   ███    ███   ███ ▄███▀ ███    ███ ███▀▀▀██▄   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███▐██▀   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ▄███▄▄▄██▀    ███    ███  ▄█████▀    ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        '▀▀███▀▀▀██▄  ▀███████████ ▀▀█████▄    ███    ███ ███   ███ ▀███████████ ███     ███ ▀███████████'
        ' ███    ██▄   ███    ███   ███▐██▄   ███    ███ ███   ███   ███    ███ ███     ███   ███    ███'
        ' ███    ███   ███    ███   ███ ▀███▄ ███    ███ ███   ███   ███    ███ ███ ▄█▄ ███   ███    ███'
        ' ▄█████████▀    ███    █▀    ███   ▀█▀ ████████▀   ▀█   █▀    ███    █▀   ▀███▀███▀    ███    █▀ '
        '                            ▀                                                                   '
        '                     D E V O U R   Y O U R   D I G I T A L   W A S T E'
    )
    for ($index = 0; $index -lt $logo.Count; $index++) {
        Write-CenteredLine $logo[$index] 'White'
    }
}

# The block logo is a fixed 78 columns and cannot be abbreviated, so terminals
# below the full band get a wave mark instead of a clipped one. The ramp reads
# as the serpent and as a rising storage bar at the same time. Same name, same
# tagline, seven rows saved.
function Show-CompactMark {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Layout)
    $mark = if ((Get-UiBarChars).Full -eq '#') { '_/=\_=' } else { "$([char]0x2582)$([char]0x2584)$([char]0x2586)$([char]0x2588)$([char]0x2586)$([char]0x2584)$([char]0x2582)" }
    if ($Layout.Content -ge 34) {
        Write-CenteredLine (' ' + $mark + '   B A K U N A W A') 'White'
        Write-CenteredLine '   devour your digital waste' 'DarkCyan'
    } else {
        Write-CenteredLine (' ' + $mark + ' BAKUNAWA') 'White'
    }
}

# ── GLYPHS ──
# Monochrome glyph helpers for headers and status lines. The serpent animation
# engine was removed with the minimal-UI redesign; these survive because live
# rendering still uses them.

function Get-ThemedGlyph {
    [CmdletBinding()]
    param([ValidateSet('Step','Ok','Warn','Err','Cmd','Scan','Size','Info','Serp','Flame')][string]$Kind)
    switch ($Kind) {
        'Step'  { return '>>' }
        'Ok'    { return '[+]' }
        'Warn'  { return '[!]' }
        'Err'   { return '[X]' }
        'Cmd'   { return '>' }
        'Scan'  { return '[S]' }
        'Size'  { return 'vv' }
        'Info'  { return '[i]' }
        'Serp'  { return '~' }
        'Flame' { return '*' }
        default { return '#' }
    }
}

function Reset-CleanupProgress {
    $script:StepIndex = 0
    $script:TotalSteps = 0
}

function Set-UiContext {
    param([string]$Mode, $Result)
    if ($Mode) { $script:CurrentModeName = $Mode }
    $script:ExcludedPaths = @(Get-CoreExcludedPaths)
    $script:RunningProcesses = Get-RunningProcessNames
    if ($Result) {
        $script:LastRunSummary = @{ Mode = $Result.Mode; DurationSeconds = $Result.DurationSec; TotalFreed = $Result.BytesFreed; IsPreview = $Result.IsPreview }
    }
}

function Start-Step {
    [CmdletBinding()]
    param([string]$Name, [int]$Total = 0)
    $script:StepIndex++
    if ($Total -gt 0) { $script:TotalSteps = $Total }
    elseif (-not $script:TotalSteps -or $script:TotalSteps -le 0) { $script:TotalSteps = $script:StepIndex }
    Write-Host ''
    $stepTag = if ($script:TotalSteps -gt 0) { '[{0:D2}/{1:D2}]' -f $script:StepIndex, $script:TotalSteps } else { '[--/--]' }
    Write-ReviewLine ("{0} {1}" -f $stepTag, $Name)
    $script:StepWatch = [Diagnostics.Stopwatch]::StartNew()
    if (-not $script:NoAnimations) {
        Write-Progress -Id 1 -Activity 'Bakunawa / categories' -Status "$stepTag $Name" -PercentComplete ([int](100 * ($script:StepIndex - 1) / $script:TotalSteps))
    }
    try { $Host.UI.RawUI.WindowTitle = "Bakunawa $($script:StepIndex)/$($script:TotalSteps) $Name" } catch {}
}

function Finish-Step {
    [CmdletBinding()]
    param([string]$Summary)
    if ($Summary) {
        Write-ReviewLine ("  Done in {0} | {1}" -f (Format-ReportDuration $script:StepWatch.Elapsed.TotalSeconds), $Summary) -ForegroundColor Gray
    }
    if ($script:StepIndex -ge $script:TotalSteps -and $script:TotalSteps -gt 0) {
        Write-Progress -Activity 'Bakunawa' -Completed -Id 1
        try { $Host.UI.RawUI.WindowTitle = 'Bakunawa - done' } catch {}
    }
}

# ── RECLAIMABLE TOTAL (measured in the background) ──
# Get-CleanupPotential -Mode Standard costs ~27s and the menu redraws on every
# loop iteration, so it can never run inline. It runs once in a detached
# runspace; the menu polls IsCompleted and fills the number in when it lands.
# Deliberately fire-and-forget: one handle, one result, cached for the session.
$script:ReclaimPending = $null
$script:ReclaimShell   = $null
$script:ReclaimResult  = $null
$script:ReclaimFailed  = $false

function Get-ReclaimMeasureScript {
    # The child runspace gets its own module instances, so this measurement
    # cannot disturb the live run's $script: state in Bakunawa.Cleanup.
    $dir = $PSScriptRoot
    @"
`$ErrorActionPreference = 'SilentlyContinue'
foreach (`$m in @('Core','Config','Cleanup','UI')) {
    Import-Module (Join-Path '$dir' "Bakunawa.`$m.psm1") -Force -WarningAction SilentlyContinue
}
`$cfgPath = Join-Path `$env:APPDATA 'Bakunawa\config.json'
try { Initialize-ConfigModule -ConfigPath `$cfgPath } catch { }
try { Initialize-CleanupState -Config (Get-UserConfig -ConfigPath `$cfgPath) } catch { }
`$items = @(Get-CleanupPotential -Mode 'Standard')
# Count only categories a Standard run would clean: disabled tasks
# (taskCategories.*.enabled = false) would inflate the menu's estimate.
`$cfg = `$null
try { `$cfg = Get-UserConfig -ConfigPath `$cfgPath } catch { }
if (`$cfg -and `$cfg.taskCategories) {
    `$items = @(`$items | Where-Object {
        `$e = `$cfg.taskCategories[`$_.Task].enabled
        `$null -eq `$e -or `$e
    })
}
[PSCustomObject]@{
    Bytes = [long]((`$items | Measure-Object -Property EstimatedBytes -Sum).Sum)
    Tasks = @(`$items).Count
}
"@
}

function Start-ReclaimableMeasure {
    [CmdletBinding()]
    param()
    if ($script:ReclaimPending -or $script:ReclaimResult -or $script:ReclaimFailed) { return }
    try {
        $shell = [PowerShell]::Create()
        [void]$shell.AddScript((Get-ReclaimMeasureScript))
        $script:ReclaimShell   = $shell
        $script:ReclaimPending = $shell.BeginInvoke()
    } catch {
        $script:ReclaimPending = $null
        $script:ReclaimFailed  = $true
    }
}

# Non-blocking. Returns the cached result, or $null while still measuring.
function Update-ReclaimableTotal {
    [CmdletBinding()]
    param()
    if ($script:ReclaimResult) { return $script:ReclaimResult }
    if (-not $script:ReclaimPending) { return $null }
    if (-not $script:ReclaimPending.IsCompleted) { return $null }
    try {
        $output = $script:ReclaimShell.EndInvoke($script:ReclaimPending)
        $last = @($output)[-1]
        # A runspace that died mid-walk can still return streams. Anything
        # without a numeric Bytes means "not measured", not "zero".
        if ($last -and $last.PSObject.Properties['Bytes']) { $script:ReclaimResult = $last }
        else { $script:ReclaimFailed = $true }
    } catch {
        $script:ReclaimFailed = $true
    } finally {
        $script:ReclaimPending = $null
        if ($script:ReclaimShell) { $script:ReclaimShell.Dispose(); $script:ReclaimShell = $null }
    }
    $script:ReclaimResult
}

function Get-ReclaimableLabel {
    [CmdletBinding()]
    param()
    $layout = Get-UiLayout
    $result = Update-ReclaimableTotal
    if ($result) { return (Format-FileSize $result.Bytes) }
    if ($script:ReclaimFailed -or -not $script:ReclaimPending) { return 'not measured' }
    $short = if ($layout.Band -eq 'narrow') { 'measuring' } else { 'measuring in background' }
    "$short..."
}

function Show-StatusBand {
    [CmdletBinding()]
    param()
    $layout = Get-UiLayout
    $free = Get-FreeSpaceInfo
    $pct = if ($free.TotalMB -gt 0) { [Math]::Round(100.0 * $free.MB / $free.TotalMB) } else { 0 }
    $barWidth = if ($layout.Band -eq 'full') { 24 } elseif ($layout.Band -eq 'compact') { 14 } else { 8 }
    $amount = Format-FileSize ($free.MB * 1MB)

    # The headline: how much room is left. Richest readout that still fits.
    $readout = "  $amount"
    foreach ($candidate in @(
            "  $amount of $(Format-FileSize ($free.TotalMB * 1MB))   $pct% free",
            "  $amount free")) {
        if ($barWidth + $candidate.Length -le (Get-UiValueWidth 0)) { $readout = $candidate; break }
    }
    Write-UiBar -Label 'FREE' -Percent $pct -Width $barWidth -Readout $readout
    Write-UiField 'Scope' 'Local disk C: only' -ValueColor 'Gray'
    if ($layout.Content -ge 46) {
        Write-UiField 'Protected' (Format-CompactList -Items ($script:ExcludedPaths | Sort-Object) -MaxItems 3) -ValueColor 'Gray'
    }
    Write-UiRule
}

function Show-Header {
    [CmdletBinding()]
    param()
    if (-not $script:CurrentModeName) { $script:CurrentModeName = 'Menu' }
    Clear-Host; Write-Host ''; Show-AppLogo; Write-Host ''
    Show-StatusBand
    Write-Host ''
}

# The menu is data, not markup: one row per action, so the renderer can align
# columns, colour the verdict, and drop the description entirely on a narrow
# terminal instead of wrapping into a ragged block.
$script:MenuActions = @(
    [PSCustomObject]@{ Key='1'; Alt='S'; Label='Standard';   Desc='temp, browsers, apps, orphans';  Tag='';         TagColor='DarkGray'; Mode='Standard' }
    [PSCustomObject]@{ Key='2'; Alt='A'; Label='Aggressive'; Desc='+ Windows components, prefetch'; Tag='more';     TagColor='Yellow';   Mode='Aggressive' }
    [PSCustomObject]@{ Key='3'; Alt='V'; Label='Preview';    Desc='dry run, deletes nothing';      Tag='safe';     TagColor='Green';    Mode='Preview' }
    [PSCustomObject]@{ Key='4'; Alt='C'; Label='Scan C:';    Desc='caches, leftovers, orphans';   Tag='review';   TagColor='Yellow';   Mode='Scan' }
    [PSCustomObject]@{ Key='5'; Alt='H'; Label='Health';     Desc='storage score, temp estimate'; Tag='read only'; TagColor='DarkCyan'; Mode='Health' }
    [PSCustomObject]@{ Key='Q'; Alt='';  Label='Quit';       Desc='';                              Tag='';         TagColor='DarkGray'; Mode=$null }
)

function Get-RunningAppLabels {
    [CmdletBinding()]
    param()
    if (-not $script:RunningProcesses) { return @() }
    $labels = @{
        'chrome' = 'Chrome'; 'msedge' = 'Edge'; 'brave' = 'Brave'; 'firefox' = 'Firefox'
        'discord' = 'Discord'; 'slack' = 'Slack'; 'teams' = 'Teams'; 'spotify' = 'Spotify'
        'Code' = 'VS Code'
    }
    @('chrome','msedge','brave','firefox','discord','slack','teams','spotify','Code') |
        Where-Object { $script:RunningProcesses.Contains($_) } |
        ForEach-Object { $labels[$_] }
}

# Draws the action list as three aligned columns: the key, the name, and a
# short colour-coded verdict. The description is a fourth column that survives
# only while there is room for it in full -- a sliced sentence tells the user
# nothing, so on a narrow terminal it is dropped instead.
function Write-MenuRows {
    [CmdletBinding()]
    param()
    $layout = Get-UiLayout
    $labelWidth = 12
    $tagWidth = 10
    $fixed = $script:UiGutter + 4 + 2 + $labelWidth + 2 + $tagWidth + 2
    # All six descriptions or none: a column where one row is cut mid-word reads
    # as a rendering fault, not as a tight layout.
    $longest = ($script:MenuActions | ForEach-Object { $_.Desc.Length } | Measure-Object -Maximum).Maximum
    $showDesc = $layout.Content - $fixed -ge $longest + 1
    foreach ($action in $script:MenuActions) {
        # "1/S" rather than "1 S": side by side, the two keys read as the number
        # fifteen. Same width either way, so the column maths below still holds.
        $lead = ' ' * $script:UiGutter + $action.Key
        if ($action.Alt) { $lead += '/' + $action.Alt } else { $lead += ' ' }
        $lead += '  ' + $action.Label.PadRight($labelWidth) + '  '
        Write-Host $lead -ForegroundColor 'White' -NoNewline
        Write-Host $action.Tag.PadRight($tagWidth) -ForegroundColor $action.TagColor -NoNewline
        if ($showDesc) { Write-Host $action.Desc -ForegroundColor 'DarkGray' }
        else { Write-Host '' }
    }
}

function Show-Menu {
    [CmdletBinding()]
    param()
    Start-ReclaimableMeasure
    while ($true) {
        $script:CurrentModeName = 'Menu'
        Show-Header
        # Reclaimable total, sitting directly under the band rule so it reads as
        # the answer the band was setting up, not as a fourth field.
        $reclaim = Update-ReclaimableTotal
        if ($reclaim) {
            $suffix = ''
            if ((Get-UiLayout).Content -ge 52) { $suffix = "  across $($reclaim.Tasks) categories" }
            Write-UiField 'Reclaimable' (Format-FileSize $reclaim.Bytes) -ValueColor 'Green' -Suffix $suffix
        } else {
            Write-UiField 'Reclaimable' (Get-ReclaimableLabel) -ValueColor 'DarkGray'
        }
        Write-Host ''

        Write-MenuRows
        Write-Host ''

        # Footer hints replace the centred prompt. Every safety statement the
        # framed panel used to carry has to survive somewhere the user reads it.
        Write-UiNote 'Start with 3 (Preview) -- it shows the plan and deletes nothing.' 'White'
        Write-UiNote 'Deletion is permanent. Other drives and busy app caches are skipped.'
        $running = Get-RunningAppLabels
        if ($running.Count -gt 0) {
            Write-UiNote "Running, so these caches are skipped: $($running -join ', ')"
        }
        if ((Get-UiLayout).Content -ge 46) {
            Write-UiNote 'Keys: 1-5 or S A V C H. Q quits.'
        }
        Write-Host ''
        $choice = Read-Host 'Selection'
        if (-not $choice) { continue }
        $choice = $choice.Trim().ToUpperInvariant()
        $action = $script:MenuActions | Where-Object { $_.Key -eq $choice -or $_.Alt -eq $choice } | Select-Object -First 1
        if (-not $action) {
            Write-Host "  '$choice' is not on the list. Press 1-5, or a letter, or Q." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 500
            continue
        }
        if (-not $action.Mode) { return }
        switch ($action.Mode) {
            'Standard'   { Invoke-LoggedOperation -Mode Standard   -Action { Show-CleanupResult (Invoke-CleanupRun 'Standard') } }
            'Aggressive' { Invoke-LoggedOperation -Mode Aggressive -Action { Show-CleanupResult (Invoke-CleanupRun 'Aggressive') } }
            'Preview'    { Invoke-LoggedOperation -Mode Preview    -Action { Show-CleanupResult (Invoke-CleanupRun 'Preview') } }
            'Scan'       { Invoke-LoggedOperation -Mode Scan       -Action { Initialize-CleanupState -ModeName 'Scan'; $null = Find-OrphanFolders -Refresh; Show-OrphanScanResults -ScanResult (Get-OrphanScanReport) -Interactive } }
            'Health'     { Invoke-LoggedOperation -Mode Health     -Action { Show-HealthDetail } }
        }
        [void](Read-Host '  [Press Enter to return to the menu]')
    }
}

. (Join-Path $PSScriptRoot 'Bakunawa.Reporting.ps1')
. (Join-Path $PSScriptRoot 'Bakunawa.Review.ps1')


function Show-HealthDetail {
    [CmdletBinding()]
    param()
    Write-Host ''
    # The scan is slow enough to need a progress line, but leaving it on screen
    # above the result reads as leftover chrome. Carriage return, blank, rewrite.
    Write-UiProgress 'Measuring temporary data and reading drive capacity...'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $health = Get-HealthScore
    Clear-UiProgress
    # The score is the point of this screen, so it wears the severity colour the
    # free-space bar does -- on score thresholds, not on free-space ones.
    $layout = Get-UiLayout
    $score = [int]$health.Score
    $labelWidth = 13
    $barWidth = if ($layout.Content -ge 60) { 24 } else { 12 }
    Write-Host ''
    Write-UiRule -Text 'STORAGE HEALTH' -Color 'Cyan' -Width 60
    Write-UiBar -Label 'SCORE' -Percent $score -Width $barWidth -LabelWidth $labelWidth `
        -Readout ("  $score / 100   $($health.Grade)") -Warn 40 -Good 70
    Write-UiField 'C: free space' ("{0}%" -f $health.DiskPct) -ValueColor (Get-UiSeverityColor $health.DiskPct) -LabelWidth $labelWidth
    Write-UiField 'Temp data' (Format-FileSize ($health.TempMB * 1MB)) -ValueColor 'Gray' -LabelWidth $labelWidth
    Write-UiField 'Measured in' (Format-ReportDuration $watch.Elapsed.TotalSeconds) -ValueColor 'Gray' -LabelWidth $labelWidth
    Write-Host ''
    Write-UiNote 'This score is a cleanup estimate, not a disk hardware diagnostic.' 'Gray'
    Write-UiNote 'Health measurements do not establish complete filesystem coverage.'
    Write-Host ''
    Write-UiRule -Text 'DRIVES' -Color 'Cyan' -Width 60
    foreach ($root in @(Get-ScanDriveRoots)) {
        try {
            $drive = [IO.DriveInfo]::new($root)
            if ($drive.IsReady) {
                Write-UiField $root ("{0} available of {1}" -f (Format-FileSize $drive.AvailableFreeSpace), (Format-FileSize $drive.TotalSize)) -ValueColor 'Gray' -LabelWidth $labelWidth
            } else { Write-UiField $root 'unavailable' -ValueColor 'Yellow' -LabelWidth $labelWidth }
        } catch { Write-UiField $root "could not be read: $($_.Exception.Message)" -ValueColor 'Yellow' -LabelWidth $labelWidth }
    }
    Write-Host ''
}

Export-ModuleMember -Function @(
    'Invoke-LoggedOperation',
    'Get-ScanLogPath',
    'Set-UiOptions',
    'Write-ScanLogText',
    'Write-ScanReportLog',
    'Write-ScanProgress',
    'Format-Count',
    'Write-ReportRow',
    'Write-ReportTitle',
    # Discovery.ps1 runs inside the Cleanup module, so the transient status pair
    # has to be exported for a scan to report progress at all.
    'Write-UiProgress',
    'Clear-UiProgress',
    'Format-ReportDuration',
    'Initialize-UiLogging',
    'Write-Log',
    'Write-CommandLog',
    'Write-CenteredLine',
    'Write-Panel',
    'Write-ConfirmFrame',
    'Get-UiLayout',
    'Get-UiSeverityColor',
    'Start-ReclaimableMeasure',
    'Update-ReclaimableTotal',
    'Show-AppLogo',
    'Get-ThemedGlyph',
    'Start-Step',
    'Reset-CleanupProgress',
    'Set-UiContext',
    'Finish-Step',
    'Show-Header',
    'Show-Menu',
    'Export-ScanReport',
    'Show-OrphanScanResults',
    'Show-CleanupResult',
    'Write-ReviewLine',
    'Show-HealthDetail',
    'Test-VT100Supported',
    'Get-ModeColor'
)
