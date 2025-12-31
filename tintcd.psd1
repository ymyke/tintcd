@{
    RootModule = 'tintcd.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'dc35c081-cc53-4d67-8bc2-515058f233f2'
    Author = 'ymyke'
    CompanyName = 'N/A'
    Copyright = '(c) 2025. MIT License.'
    Description = 'Directory-aware terminal theming. cd, but colorful.'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @(
        'Invoke-Tintcd',
        'Enable-TintcdPromptHook',
        'Get-TintcdConfig'
    )
    AliasesToExport = @('tintcd')
    PrivateData = @{
        PSData = @{
            Tags = @('terminal', 'colors', 'theming', 'windows-terminal', 'oh-my-posh')
            LicenseUri = 'https://github.com/ymyke/tintcd/blob/main/LICENSE'
            ProjectUri = 'https://github.com/ymyke/tintcd'
        }
    }
}
