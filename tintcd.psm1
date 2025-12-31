# tintcd.psm1 — Directory-aware terminal theming
# https://github.com/ymyke/tintcd

#region Configuration

$script:DefaultConfig = @{
    BackgroundLightness = @(0.08, 0.14)   # L range for dark backgrounds
    AccentLightness     = @(0.45, 0.65)   # L range for bright accents
    Saturation          = @(0.35, 0.55)   # S range
    DefaultBackground   = "1e1e1e"        # Reset color (dark gray)
    Enabled             = $true
}

$script:ConfigCache = $null
$script:ConfigPath = $null

# Prompt hook state
$script:TintcdHookEnabled = $false
$script:LastTintcdPath = $null
$script:OriginalPrompt = $null
$script:SkipTintOnce = $false

function Get-TintcdConfig {
    [CmdletBinding()]
    param()

    $configPath = if ($env:TINTCD_CONFIG) { $env:TINTCD_CONFIG } else { Join-Path $HOME ".tintcd.json" }

    # Return cache if path unchanged
    if ($script:ConfigCache -and $script:ConfigPath -eq $configPath) {
        return $script:ConfigCache
    }

    if (Test-Path $configPath) {
        try {
            $userConfig = Get-Content $configPath -Raw | ConvertFrom-Json -AsHashtable
            # Merge with defaults (fill missing keys)
            $config = $script:DefaultConfig.Clone()
            foreach ($key in $userConfig.Keys) {
                if ($script:DefaultConfig.ContainsKey($key)) {
                    $config[$key] = $userConfig[$key]
                }
            }
            # Validate and clamp config values
            $config = Assert-TintcdConfig $config
            $script:ConfigCache = $config
            $script:ConfigPath = $configPath
            return $config
        }
        catch {
            Write-Warning "tintcd: Failed to parse config at $configPath, using defaults"
        }
    }

    $script:ConfigCache = $script:DefaultConfig.Clone()
    $script:ConfigPath = $configPath
    return $script:ConfigCache
}

function Assert-TintcdConfig {
    param([hashtable]$Config)

    # Validate DefaultBackground: must be 6-char hex (with or without #)
    $bg = $Config.DefaultBackground -replace '^#', ''
    if ($bg -notmatch '^[0-9a-fA-F]{6}$') {
        Write-Warning "tintcd: Invalid DefaultBackground '$($Config.DefaultBackground)', using default"
        $bg = $script:DefaultConfig.DefaultBackground
    }
    $Config.DefaultBackground = $bg.ToLower()

    # Validate ranges: must be 2-element arrays with numeric values 0-1, min < max
    foreach ($key in @('BackgroundLightness', 'AccentLightness', 'Saturation')) {
        $range = $Config[$key]
        $valid = $false
        if ($range -is [array] -and $range.Count -eq 2) {
            # Accept any numeric type (double, int, decimal, etc.) and cast to double
            try {
                $v0 = [double]$range[0]
                $v1 = [double]$range[1]
                $valid = $v0 -ge 0 -and $v0 -le 1 -and $v1 -ge 0 -and $v1 -le 1 -and $v0 -lt $v1
                if ($valid) {
                    $Config[$key] = @($v0, $v1)  # Normalize to double
                }
            }
            catch {
                $valid = $false
            }
        }
        if (-not $valid) {
            Write-Warning "tintcd: Invalid $key range, using default"
            $Config[$key] = $script:DefaultConfig[$key]
        }
    }

    return $Config
}

#endregion

#region Color Math

function Get-PathHash {
    [CmdletBinding()]
    param([string]$Path = (Get-Location).Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return @(0, 0, 0) }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        # Case-insensitive on Windows only; use culture-invariant lowercase
        $hashPath = if ($IsWindows) { $Path.ToLowerInvariant() } else { $Path }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($hashPath)
        $hash = $sha.ComputeHash($bytes)
        return $hash[0..2]  # First 3 bytes (decorrelated: H, S, L)
    }
    finally {
        $sha.Dispose()
    }
}

function Convert-HslToRgb {
    param(
        [double]$H,  # 0-360
        [double]$S,  # 0-1
        [double]$L   # 0-1
    )

    $H = $H / 360.0
    if ($S -eq 0) {
        $r = $g = $b = [int]($L * 255)
    }
    else {
        $q = if ($L -lt 0.5) { $L * (1 + $S) } else { $L + $S - $L * $S }
        $p = 2 * $L - $q

        $h2r = {
            param($p, $q, $t)
            if ($t -lt 0) { $t += 1 }
            if ($t -gt 1) { $t -= 1 }
            if ($t -lt 1 / 6) { return $p + ($q - $p) * 6 * $t }
            if ($t -lt 1 / 2) { return $q }
            if ($t -lt 2 / 3) { return $p + ($q - $p) * (2 / 3 - $t) * 6 }
            return $p
        }

        $r = [int]([Math]::Round((&$h2r $p $q ($H + 1 / 3)) * 255))
        $g = [int]([Math]::Round((&$h2r $p $q $H) * 255))
        $b = [int]([Math]::Round((&$h2r $p $q ($H - 1 / 3)) * 255))
    }

    # Clamp to 0-255
    $r = [Math]::Max(0, [Math]::Min(255, $r))
    $g = [Math]::Max(0, [Math]::Min(255, $g))
    $b = [Math]::Max(0, [Math]::Min(255, $b))

    return @{ R = $r; G = $g; B = $b }
}

function Get-DirColors {
    [CmdletBinding()]
    param([string]$Path = (Get-Location).Path)

    $config = Get-TintcdConfig
    $hash = Get-PathHash -Path $Path

    # Decorrelated mapping: each byte controls one HSL dimension
    $hue = ($hash[0] / 255.0) * 360.0
    $satFactor = $hash[1] / 255.0
    $lightFactor = $hash[2] / 255.0

    # lerp(range, t) = min + (max - min) * t
    $sat = $config.Saturation[0] + ($config.Saturation[1] - $config.Saturation[0]) * $satFactor

    # Background: dark
    $bgL = $config.BackgroundLightness[0] +
    ($config.BackgroundLightness[1] - $config.BackgroundLightness[0]) * $lightFactor
    $bgRgb = Convert-HslToRgb -H $hue -S $sat -L $bgL
    $bgHex = "#{0:X2}{1:X2}{2:X2}" -f $bgRgb.R, $bgRgb.G, $bgRgb.B

    # Accent: bright (slightly boosted saturation)
    $accentL = $config.AccentLightness[0] +
    ($config.AccentLightness[1] - $config.AccentLightness[0]) * $lightFactor
    $accentSat = [Math]::Min(1.0, $sat + 0.1)
    $accentRgb = Convert-HslToRgb -H $hue -S $accentSat -L $accentL
    $accentHex = "#{0:X2}{1:X2}{2:X2}" -f $accentRgb.R, $accentRgb.G, $accentRgb.B

    return @{
        Background = $bgHex
        Accent     = $accentHex
        Hue        = [Math]::Round($hue, 1)
    }
}

#endregion

#region Terminal Control

function Test-OscSupported {
    # Windows Terminal sets WT_SESSION, VS Code sets TERM_PROGRAM
    return ($null -ne $env:WT_SESSION) -or ($env:TERM_PROGRAM -like 'vscode*')
}

function Set-TerminalBackground {
    [CmdletBinding()]
    param([string]$Hex6)

    if (-not (Test-OscSupported)) { return }
    if ([Console]::IsOutputRedirected) { return }

    # OSC 11 with #RRGGBB format and BEL terminator
    try { [Console]::Write("$([char]27)]11;$Hex6$([char]7)") } catch { }
}

function Reset-TerminalBackground {
    [CmdletBinding()]
    param()

    if (-not (Test-OscSupported)) { return }
    if ([Console]::IsOutputRedirected) { return }

    $config = Get-TintcdConfig
    try { [Console]::Write("$([char]27)]11;#$($config.DefaultBackground)$([char]7)") } catch { }
}

#endregion

#region Prompt Hook

function Invoke-TintcdPromptCheck {
    # Internal: Called by prompt hook. Runs in module scope so $script: resolves correctly.
    try {
        $currentPath = (Get-Location).Path
    }
    catch {
        # Path unavailable (network drive dropped, etc.) - silently skip, don't crash prompt
        return
    }

    if ($script:SkipTintOnce) {
        $script:SkipTintOnce = $false
        $script:LastTintcdPath = $currentPath
        return
    }

    # Case-insensitive compare on Windows (path case can vary)
    $comparePath = if ($IsWindows) { $currentPath.ToLowerInvariant() } else { $currentPath }
    $lastPath = if ($IsWindows -and $script:LastTintcdPath) { $script:LastTintcdPath.ToLowerInvariant() } else { $script:LastTintcdPath }

    if ($comparePath -ne $lastPath) {
        Set-Tintcd -Path $currentPath
        $script:LastTintcdPath = $currentPath
    }
}

function Test-TintcdPromptHook {
    # Internal: Check if prompt hook is active via AST (string literal survives better than comments)
    $promptInfo = Get-Item function:prompt -ErrorAction SilentlyContinue
    return $promptInfo -and $promptInfo.ScriptBlock -and ($promptInfo.ScriptBlock.Ast.Extent.Text -match 'TINTCD_PROMPT_HOOK')
}

function Enable-TintcdPromptHook {
    <#
    .SYNOPSIS
        Enable automatic tinting on directory change by hooking into the prompt.
    .DESCRIPTION
        Wraps the current prompt function to check for directory changes.
        Must be called AFTER oh-my-posh init if using oh-my-posh.
        Safe to call multiple times (idempotent).
    .EXAMPLE
        Enable-TintcdPromptHook
    #>
    [CmdletBinding()]
    param()

    # Idempotent: don't double-wrap (prevents recursion)
    if (Test-TintcdPromptHook) {
        Write-Verbose "tintcd: Prompt hook already active"
        return
    }

    # Capture CURRENT prompt *now* (should be oh-my-posh if already initialized)
    # Use function:prompt (not function:global:prompt) for reliable access
    $currentPromptInfo = Get-Item function:prompt -ErrorAction SilentlyContinue
    if ($currentPromptInfo -and $currentPromptInfo.ScriptBlock) {
        $script:OriginalPrompt = $currentPromptInfo.ScriptBlock
    }
    else {
        $script:OriginalPrompt = { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }

    # Store in global scope (no closures needed - avoids oh-my-posh context issues)
    $global:__TintcdModule = $ExecutionContext.SessionState.Module
    $global:__TintcdOriginalPrompt = $script:OriginalPrompt

    $script:TintcdHookEnabled = $true
    $script:SkipTintOnce = $false
    $script:LastTintcdPath = (Get-Location).Path

    # Define new prompt - no closure, uses global vars for reliable resolution
    Set-Item function:prompt -Value {
        # String literal marker for AST-based detection (survives better than comments)
        $null = 'TINTCD_PROMPT_HOOK'

        # Run tintcd check, suppress output, swallow errors (prompt must never throw)
        try {
            & $global:__TintcdModule { Invoke-TintcdPromptCheck } | Out-Null
        }
        catch { }

        # Run original prompt with error handling
        try {
            $p = $global:__TintcdOriginalPrompt.InvokeReturnAsIs()
            if ($null -eq $p) { throw "null" }
            $p
        }
        catch {
            "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
        }
    }

    # Apply tint for current directory immediately
    Set-Tintcd
}

function Show-TintcdStatus {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "  tintcd setup check" -ForegroundColor Cyan
    Write-Host "  ══════════════════" -ForegroundColor DarkGray
    Write-Host ""

    # Module loaded (always true if this runs)
    Write-Host "  ✓ Module loaded" -ForegroundColor Green

    # Config check
    $configPath = if ($env:TINTCD_CONFIG) { $env:TINTCD_CONFIG } else { Join-Path $HOME ".tintcd.json" }
    if (Test-Path $configPath) {
        try {
            $null = Get-Content $configPath -Raw | ConvertFrom-Json
            Write-Host "  ✓ Config valid ($configPath)" -ForegroundColor Green
        }
        catch {
            Write-Host "  ✗ Config invalid ($configPath)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "  ○ Config not found, using defaults" -ForegroundColor DarkGray
    }

    # Prompt hook check
    if (Test-TintcdPromptHook) {
        Write-Host "  ✓ Prompt hook active" -ForegroundColor Green
    }
    else {
        Write-Host "  ✗ Prompt hook not active — run 'tintcd -Hook'" -ForegroundColor Red
        Write-Host "    (If using oh-my-posh, ensure tintcd inits AFTER it)" -ForegroundColor Yellow
    }

    # Terminal detection
    if ($env:WT_SESSION) {
        Write-Host "  ✓ Windows Terminal detected (WT_SESSION)" -ForegroundColor Green
    }
    elseif ($env:TERM_PROGRAM -like 'vscode*') {
        Write-Host "  ✓ VS Code terminal detected (TERM_PROGRAM)" -ForegroundColor Green
    }
    else {
        Write-Host "  ○ Supported terminal not detected — OSC 11 disabled" -ForegroundColor Yellow
        Write-Host "    (TINTCD_ACCENT still works for prompt integration)" -ForegroundColor DarkGray
    }

    # Current state
    if ($env:TINTCD_ACCENT) {
        Write-Host "  ✓ TINTCD_ACCENT set ($env:TINTCD_ACCENT)" -ForegroundColor Green
    }
    else {
        Write-Host "  ○ TINTCD_ACCENT not set" -ForegroundColor DarkGray
    }

    if ($env:TINTCD_DISABLED) {
        Write-Host "  ⚠ TINTCD_DISABLED is set — tinting disabled for session" -ForegroundColor Yellow
    }

    Write-Host ""
}

#endregion

#region Internal Functions

function Set-Tintcd {
    # Apply tintcd colors for current directory. Called by prompt hook and Invoke-Tintcd.
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path
    )

    if ($env:TINTCD_DISABLED) { return }

    # Reset colors for non-FileSystem providers (HKCU:\, Env:\, etc.)
    if ((Get-Location).Provider.Name -ne 'FileSystem') {
        Reset-TerminalBackground
        $env:TINTCD_ACCENT = $null
        return
    }

    $config = Get-TintcdConfig
    if (-not $config.Enabled) {
        $env:TINTCD_ACCENT = $null
        return
    }

    $colors = Get-DirColors -Path $Path
    Set-TerminalBackground -Hex6 $colors.Background
    $env:TINTCD_ACCENT = $colors.Accent
}

#endregion

#region Public Functions

function Reset-Tintcd {
    [CmdletBinding()]
    param(
        [switch]$DisableSession,
        [switch]$UnhookPrompt
    )

    Reset-TerminalBackground
    $env:TINTCD_ACCENT = $null

    if ($UnhookPrompt -and (Test-TintcdPromptHook)) {
        if ($script:OriginalPrompt) {
            Set-Item function:prompt -Value $script:OriginalPrompt
        }
        # Clean up global variables used by prompt hook
        Remove-Variable __TintcdModule, __TintcdOriginalPrompt -Scope Global -ErrorAction SilentlyContinue
        $script:TintcdHookEnabled = $false
        $script:LastTintcdPath = $null
        $script:SkipTintOnce = $false
        Write-Host "tintcd prompt hook removed." -ForegroundColor Yellow
    }

    if ($DisableSession) {
        $env:TINTCD_DISABLED = "1"
        # Only show message in interactive sessions
        if ([Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
            Write-Host "tintcd disabled for this session. Run 'Remove-Item env:TINTCD_DISABLED' to re-enable." -ForegroundColor Yellow
        }
    }
}

function Invoke-Tintcd {
    <#
    .SYNOPSIS
        Unified tintcd command - navigate, configure, and control terminal theming.
    .DESCRIPTION
        Main entry point for tintcd. Modes:
        - Navigate: cd to path + apply tint (default)
        - Reload: reload config + re-apply tint
        - Preview: show color preview
        - Hook/Unhook: install/remove prompt hook
        - Enable/Disable: toggle tinting for session
    .PARAMETER Path
        Target directory. If omitted, goes to $HOME (like cd).
    .PARAMETER NoTint
        Skip applying colors for this navigation only.
    .PARAMETER Reload
        Reload config and re-apply tint for current directory.
    .PARAMETER Preview
        Show color preview for sample directories.
    .PARAMETER Paths
        Specific paths to preview (with -Preview).
    .PARAMETER Hook
        Install prompt hook for automatic tinting.
    .PARAMETER Unhook
        Remove prompt hook, restore original prompt.
    .PARAMETER Disable
        Disable tinting for this session.
    .PARAMETER Enable
        Re-enable tinting after -Disable.
    .PARAMETER Status
        Show tintcd status and diagnose setup issues.
    .EXAMPLE
        tintcd C:\projects\myapp
    .EXAMPLE
        tintcd -Reload
    .EXAMPLE
        tintcd -Preview
    .EXAMPLE
        tintcd -Hook
    .EXAMPLE
        tintcd -Status
    #>
    [CmdletBinding(DefaultParameterSetName = 'Navigate')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Navigate')]
        [string]$Path,
        [Parameter(ParameterSetName = 'Navigate')]
        [switch]$NoTint,

        [Parameter(Mandatory, ParameterSetName = 'Reload')]
        [switch]$Reload,

        [Parameter(Mandatory, ParameterSetName = 'Preview')]
        [switch]$Preview,
        [Parameter(Position = 0, ParameterSetName = 'Preview')]
        [string[]]$Paths,

        [Parameter(Mandatory, ParameterSetName = 'Hook')]
        [switch]$Hook,

        [Parameter(Mandatory, ParameterSetName = 'Unhook')]
        [switch]$Unhook,

        [Parameter(Mandatory, ParameterSetName = 'Disable')]
        [switch]$Disable,

        [Parameter(Mandatory, ParameterSetName = 'Enable')]
        [switch]$Enable,

        [Parameter(Mandatory, ParameterSetName = 'Status')]
        [switch]$Status
    )

    switch ($PSCmdlet.ParameterSetName) {
        'Navigate' {
            # Mirror cd: no path means go home
            if (-not $Path) { $Path = $HOME }

            # Set skip-once flag BEFORE Set-Location
            if ($NoTint) {
                $script:SkipTintOnce = $true
            }

            try {
                Microsoft.PowerShell.Management\Set-Location -Path $Path -ErrorAction Stop
            }
            catch {
                $script:SkipTintOnce = $false
                $PSCmdlet.WriteError($_)
                return
            }

            # Only tint if not -NoTint and not disabled
            if (-not $NoTint -and -not $env:TINTCD_DISABLED) {
                Set-Tintcd
                $script:LastTintcdPath = (Get-Location).Path
            }
            elseif ($NoTint) {
                # -NoTint means reset to default, not keep stale color
                Reset-TerminalBackground
                $env:TINTCD_ACCENT = $null
                $script:LastTintcdPath = (Get-Location).Path
            }
        }

        'Reload' {
            $script:ConfigCache = $null
            $script:LastTintcdPath = $null
            if (-not $env:TINTCD_DISABLED) {
                Set-Tintcd
                $script:LastTintcdPath = (Get-Location).Path
            }
        }

        'Preview' {
            Show-TintcdPreview -Paths $Paths
        }

        'Hook' {
            # Hook implies enable
            $env:TINTCD_DISABLED = $null
            Enable-TintcdPromptHook
        }

        'Unhook' {
            if (Test-TintcdPromptHook) {
                if ($script:OriginalPrompt) {
                    Set-Item function:prompt -Value $script:OriginalPrompt
                }
                Remove-Variable __TintcdModule, __TintcdOriginalPrompt -Scope Global -ErrorAction SilentlyContinue
                $script:TintcdHookEnabled = $false
                $script:LastTintcdPath = $null
            }
            Reset-TerminalBackground
            $env:TINTCD_ACCENT = $null
        }

        'Disable' {
            $env:TINTCD_DISABLED = "1"
            Reset-TerminalBackground
            $env:TINTCD_ACCENT = $null
        }

        'Enable' {
            $env:TINTCD_DISABLED = $null
            if (Test-TintcdPromptHook) {
                Set-Tintcd
                $script:LastTintcdPath = (Get-Location).Path
            }
        }

        'Status' {
            Show-TintcdStatus
        }
    }
}

function Show-TintcdPreview {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string[]]$Paths
    )

    if (-not $Paths) {
        $Paths = @(
            $HOME,
            (Join-Path $HOME "Documents"),
            (Join-Path $HOME "projects"),
            (Join-Path $HOME "projects" "alpha"),
            (Join-Path $HOME "projects" "beta")
        )
        if ($IsWindows) {
            $Paths += @("C:\Windows", "C:\temp")
        }
    }

    Write-Host ""
    Write-Host "  tintcd color preview" -ForegroundColor Cyan
    Write-Host "  ════════════════════" -ForegroundColor DarkGray
    Write-Host ""

    foreach ($p in $Paths) {
        $colors = Get-DirColors -Path $p
        $bg = $colors.Background
        $accent = $colors.Accent

        # Show ANSI color swatches only if output supports it
        if (-not [Console]::IsOutputRedirected) {
            $bgR = [Convert]::ToInt32($bg.Substring(1, 2), 16)
            $bgG = [Convert]::ToInt32($bg.Substring(3, 2), 16)
            $bgB = [Convert]::ToInt32($bg.Substring(5, 2), 16)
            $bgSwatch = "$([char]27)[48;2;$bgR;$bgG;${bgB}m    $([char]27)[0m"

            $acR = [Convert]::ToInt32($accent.Substring(1, 2), 16)
            $acG = [Convert]::ToInt32($accent.Substring(3, 2), 16)
            $acB = [Convert]::ToInt32($accent.Substring(5, 2), 16)
            $accentSwatch = "$([char]27)[48;2;$acR;$acG;${acB}m    $([char]27)[0m"

            Write-Host "  $bgSwatch $accentSwatch " -NoNewline
        }
        else {
            Write-Host "  " -NoNewline
        }
        Write-Host "bg:$bg  accent:$accent  " -NoNewline
        Write-Host $p
    }

    Write-Host ""
}

#endregion

#region Aliases

Set-Alias -Name tintcd -Value Invoke-Tintcd

#endregion

#region Module Export

Export-ModuleMember -Function @(
    'Invoke-Tintcd',
    'Enable-TintcdPromptHook',
    'Get-TintcdConfig'
) -Alias @(
    'tintcd'
)

# Cleanup on module unload
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    try {
        # Only restore if our hook is still the active prompt (don't clobber later changes)
        $promptInfo = Get-Item function:prompt -ErrorAction SilentlyContinue
        if ($promptInfo -and $promptInfo.ScriptBlock -and $promptInfo.ScriptBlock.Ast.Extent.Text -match 'TINTCD_PROMPT_HOOK' -and $script:OriginalPrompt) {
            Set-Item function:prompt -Value $script:OriginalPrompt
        }

        # Clean up global variables used by prompt hook
        Remove-Variable __TintcdModule, __TintcdOriginalPrompt -Scope Global -ErrorAction SilentlyContinue

        # Clean up env var and reset background (best effort)
        $env:TINTCD_ACCENT = $null
        if (-not [Console]::IsOutputRedirected -and (($null -ne $env:WT_SESSION) -or ($env:TERM_PROGRAM -like 'vscode*'))) {
            [Console]::Write("$([char]27)]11;#$($script:DefaultConfig.DefaultBackground)$([char]7)")
        }
    }
    catch {
        # Silently ignore - module unload must not fail
    }
}

#endregion
