# Example $PROFILE integration for tintcd
# Shows tintcd alongside Python venv auto-activation
# (Deliberately simple — enhance for your needs: multiple venv dirs, already-active check, etc.)

# The key insight: tintcd uses prompt-hook, so it works with any cd wrapper.

# 1. Oh-my-posh first (replaces prompt)
oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\agnoster-tintcd.omp.json" | Invoke-Expression

# 2. tintcd hooks into prompt (must be AFTER oh-my-posh)
Import-Module tintcd
Enable-TintcdPromptHook

# 3. Optional: Python venv auto-activation cd wrapper
# This doesn't conflict with tintcd because tintcd uses prompt-hook
function cdd {
    param([string]$Path = $HOME)
    Set-Location $Path

    # Auto-activate venv if present
    $venvPath = Join-Path (Get-Location) ".venv\Scripts\Activate.ps1"
    if (Test-Path $venvPath) {
        & $venvPath
    }
}
Set-Alias cd cdd -Option AllScope

# tintcd still works because it triggers on prompt render, not on cd command
