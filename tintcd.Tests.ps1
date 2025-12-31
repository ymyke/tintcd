BeforeAll {
    $script:configPath = Join-Path $HOME ".tintcd.json"
    $script:configBackup = $null
    if (Test-Path $script:configPath) {
        $script:configBackup = Get-Content $script:configPath -Raw
    }
    Import-Module $PSScriptRoot/tintcd.psd1 -Force
}

AfterAll {
    Remove-Module tintcd -ErrorAction SilentlyContinue
    if ($script:configBackup) {
        $script:configBackup | Set-Content $script:configPath
    } elseif (Test-Path $script:configPath) {
        Remove-Item $script:configPath
    }
}

Describe "Get-TintcdConfig" {
    BeforeEach {
        # Clear config cache between tests
        Import-Module $PSScriptRoot/tintcd.psd1 -Force
    }

    AfterEach {
        $configPath = Join-Path $HOME ".tintcd.json"
        if (Test-Path $configPath) { Remove-Item $configPath }
    }

    Context "No config file" {
        It "returns defaults silently" {
            $cfg = Get-TintcdConfig
            $cfg.BackgroundLightness | Should -Be @(0.08, 0.14)
            $cfg.DefaultBackground | Should -Be "1e1e1e"
            $cfg.Enabled | Should -BeTrue
        }
    }

    Context "Valid config" {
        It "merges with defaults" {
            @'
{
  "BackgroundLightness": [0.05, 0.10],
  "DefaultBackground": "2d2d2d"
}
'@ | Set-Content (Join-Path $HOME ".tintcd.json")

            $cfg = Get-TintcdConfig
            $cfg.BackgroundLightness | Should -Be @(0.05, 0.10)
            $cfg.DefaultBackground | Should -Be "2d2d2d"
            # Unspecified values use defaults
            $cfg.Saturation | Should -Be @(0.35, 0.55)
        }
    }

    Context "Empty config" {
        It "returns all defaults" {
            '{}' | Set-Content (Join-Path $HOME ".tintcd.json")
            $cfg = Get-TintcdConfig
            $cfg.BackgroundLightness | Should -Be @(0.08, 0.14)
            $cfg.DefaultBackground | Should -Be "1e1e1e"
        }
    }

    Context "Invalid DefaultBackground" {
        It "warns and uses default" {
            '{ "DefaultBackground": "not-a-color" }' | Set-Content (Join-Path $HOME ".tintcd.json")

            $cfg = Get-TintcdConfig 3>&1
            $warns = $cfg | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $result = $cfg | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }

            $warns.Message | Should -BeLike "*Invalid DefaultBackground*"
            $result.DefaultBackground | Should -Be "1e1e1e"
        }
    }

    Context "Invalid range (min > max)" {
        It "warns and uses default" {
            '{ "BackgroundLightness": [0.20, 0.10] }' | Set-Content (Join-Path $HOME ".tintcd.json")

            $cfg = Get-TintcdConfig 3>&1
            $warns = $cfg | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $result = $cfg | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }

            $warns.Message | Should -BeLike "*Invalid BackgroundLightness*"
            $result.BackgroundLightness | Should -Be @(0.08, 0.14)
        }
    }

    Context "Multiple invalid values" {
        It "warns for each invalid value" {
            @'
{
  "DefaultBackground": "xyz",
  "BackgroundLightness": [0.5, 0.3],
  "Saturation": "not-an-array"
}
'@ | Set-Content (Join-Path $HOME ".tintcd.json")

            $cfg = Get-TintcdConfig 3>&1
            $warns = $cfg | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

            @($warns).Count | Should -Be 3
            @($warns.Message -like "*DefaultBackground*").Count | Should -Be 1
            @($warns.Message -like "*BackgroundLightness*").Count | Should -Be 1
            @($warns.Message -like "*Saturation*").Count | Should -Be 1
        }
    }

    Context "Malformed JSON" {
        It "warns and uses all defaults" {
            '{ broken json' | Set-Content (Join-Path $HOME ".tintcd.json")

            $cfg = Get-TintcdConfig 3>&1
            $warns = $cfg | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
            $result = $cfg | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }

            $warns.Message | Should -BeLike "*Failed to parse*"
            $result.BackgroundLightness | Should -Be @(0.08, 0.14)
            $result.DefaultBackground | Should -Be "1e1e1e"
        }
    }
}
