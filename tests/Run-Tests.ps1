# METIS Test Runner
# Runs all Pester unit tests and exits with a non-zero code on any failure.
# Usage: pwsh ./tests/Run-Tests.ps1

$ErrorActionPreference = "Stop"

Import-Module Pester -MinimumVersion 5.0

$config = New-PesterConfiguration
$config.Run.Path          = "$PSScriptRoot/unit"
$config.Output.Verbosity  = "Detailed"
$config.Run.Exit          = $true   # exit 1 on failure (useful for CI)

Invoke-Pester -Configuration $config
