#Requires -Modules Pester
# Unit tests for windows-uninstaller.ps1
# Run via: pwsh ./tests/Run-Tests.ps1

BeforeAll {
    $scriptPath = Resolve-Path "$PSScriptRoot/../../windows-uninstaller.ps1"

    # Stub Windows-only cmdlets that do not exist on macOS/Linux so that
    # Pester's Mock can intercept them during tests.
    function global:Get-Service    { param([string]$Name, $ErrorAction) $null }
    function global:Stop-Service   { param([string]$Name, [switch]$Force, $ErrorAction) }
    function global:Get-Acl        { param([string]$Path) [PSCustomObject]@{} }
    function global:Set-Acl        { param([string]$Path, $AclObject) }
    function global:nssm           { param() }
    function global:sc.exe         { param() }  # defined via alias below
    function global:mongosh        { param() }
    function global:choco          { param() }

    # sc.exe has a dot — register it on the Function: drive
    Set-Item -Path "Function:global:Invoke-ScExe" -Value { }

    # Dot-source the script — main block is skipped because InvocationName is '.'
    . $scriptPath

    # Helper: reset all script-level state between tests
    function Reset-ScriptState {
        $script:ADMIN_USER           = ""
        $script:ADMIN_PASS           = ""
        $script:METIS_USER           = ""
        $script:METIS_PASS           = ""
        $script:CREDENTIALS_PARSED   = $false
        $script:MONGO_DROP_SUCCEEDED = $false
        $script:FAILED_STEPS         = [System.Collections.ArrayList]@()
    }
}

# ---------------------------------------------------------------------------
# Read-METISCredentials
# ---------------------------------------------------------------------------
Describe "Read-METISCredentials" {

    BeforeEach { Reset-ScriptState }

    Context "credentials file does not exist" {
        BeforeEach {
            Mock Test-Path { $false }
            Mock Write-MetisWarning {}
            Mock Get-Content {}
        }

        It "leaves CREDENTIALS_PARSED as false" {
            Read-METISCredentials
            $script:CREDENTIALS_PARSED | Should -Be $false
        }

        It "emits exactly one warning" {
            Read-METISCredentials
            Should -Invoke Write-MetisWarning -Times 1
        }

        It "does not try to read file contents" {
            Read-METISCredentials
            Should -Not -Invoke Get-Content
        }
    }

    Context "credentials file exists and is fully parseable" {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-Content {
                @(
                    "MongoDB Admin Username: admin_abc123",
                    "MongoDB Admin Password: AdminPass456",
                    "MongoDB Web Username: metis_xyz789",
                    "MongoDB Web Password: MetisPass012"
                )
            }
            Mock Write-Success {}
        }

        It "sets CREDENTIALS_PARSED to true" {
            Read-METISCredentials
            $script:CREDENTIALS_PARSED | Should -Be $true
        }

        It "loads ADMIN_USER correctly" {
            Read-METISCredentials
            $script:ADMIN_USER | Should -Be "admin_abc123"
        }

        It "loads ADMIN_PASS correctly" {
            Read-METISCredentials
            $script:ADMIN_PASS | Should -Be "AdminPass456"
        }

        It "loads METIS_USER correctly" {
            Read-METISCredentials
            $script:METIS_USER | Should -Be "metis_xyz789"
        }

        It "loads METIS_PASS correctly" {
            Read-METISCredentials
            $script:METIS_PASS | Should -Be "MetisPass012"
        }
    }

    Context "credentials file exists but only has one field" {
        It "leaves CREDENTIALS_PARSED as false" {
            Mock Test-Path { $true }
            Mock Get-Content { @("MongoDB Admin Username: admin_abc123") }
            Mock Write-MetisWarning {}
            Mock Write-Host {}

            Read-METISCredentials

            $script:CREDENTIALS_PARSED | Should -Be $false
        }

        It "emits a warning mentioning 'could not be fully parsed'" {
            Mock Test-Path { $true }
            Mock Get-Content { @("MongoDB Admin Username: admin_abc123") }
            Mock Write-MetisWarning {}
            Mock Write-Host {}

            Read-METISCredentials

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "could not be fully parsed" }
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISCredentials
# ---------------------------------------------------------------------------
Describe "Remove-METISCredentials" {

    BeforeEach {
        Reset-ScriptState
        # Stub Remove-Item at Describe level so Should -Not -Invoke is valid in every Context
        Mock Remove-Item {}
        Mock Write-MetisWarning {}
        Mock Write-MetisError {}
        Mock Write-Success {}
    }

    Context "credentials were parsed but MongoDB drop failed" {
        BeforeEach {
            $script:CREDENTIALS_PARSED   = $true
            $script:MONGO_DROP_SUCCEEDED = $false
        }

        It "does NOT delete the credentials file" {
            Remove-METISCredentials
            Should -Not -Invoke Remove-Item
        }

        It "adds one entry to FAILED_STEPS" {
            Remove-METISCredentials
            $script:FAILED_STEPS.Count | Should -Be 1
        }

        It "FAILED_STEPS entry mentions 'credentials'" {
            Remove-METISCredentials
            $script:FAILED_STEPS[0].Step | Should -Match "credentials"
        }
    }

    Context "credentials were never parsed and MongoDB drop did not run" {
        BeforeEach {
            $script:CREDENTIALS_PARSED   = $false
            $script:MONGO_DROP_SUCCEEDED = $false
        }

        It "attempts to delete the file if it exists" {
            Mock Test-Path { $true }

            Remove-METISCredentials

            Should -Invoke Remove-Item -Times 1
        }

        It "warns and skips if the file does not exist" {
            Mock Test-Path { $false }

            Remove-METISCredentials

            Should -Not -Invoke Remove-Item
        }
    }

    Context "credentials were parsed and MongoDB drop succeeded" {
        BeforeEach {
            $script:CREDENTIALS_PARSED   = $true
            $script:MONGO_DROP_SUCCEEDED = $true
            Mock Test-Path { $true }
        }

        It "removes the credentials file" {
            Remove-METISCredentials
            Should -Invoke Remove-Item -Times 1
        }

        It "does not add any FAILED_STEPS entries" {
            Remove-METISCredentials
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "Remove-Item throws" {
        BeforeEach {
            $script:CREDENTIALS_PARSED   = $true
            $script:MONGO_DROP_SUCCEEDED = $true
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Access denied" }
        }

        It "adds an error entry to FAILED_STEPS" {
            Remove-METISCredentials
            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISMongoUser
# ---------------------------------------------------------------------------
Describe "Remove-METISMongoUser" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-MetisWarning {}
        Mock Write-Success {}
        Mock Write-Host {}
        # Stub Get-Command so Should -Not -Invoke is valid in every Context
        Mock Get-Command { $null }
    }

    Context "credentials were not parsed" {
        It "skips and warns without calling Get-Command" {
            $script:CREDENTIALS_PARSED = $false

            Remove-METISMongoUser

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "Skipping" }
            Should -Not -Invoke Get-Command
        }
    }

    Context "credentials parsed but mongosh is not installed" {
        It "skips and warns" {
            $script:CREDENTIALS_PARSED = $true
            # Get-Command already returns $null from BeforeEach

            Remove-METISMongoUser

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "mongosh not found" }
            $script:MONGO_DROP_SUCCEEDED | Should -Be $false
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISService
# ---------------------------------------------------------------------------
Describe "Remove-METISService" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Write-MetisError {}
        # Stub Stop-Service so Should -Not -Invoke is valid in every Context
        Mock Stop-Service {}
        Mock nssm {}
    }

    Context "METIS service does not exist" {
        It "emits a warning and returns without stopping or removing" {
            Mock Get-Service { $null }

            Remove-METISService

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "not found" }
            Should -Not -Invoke Stop-Service
        }
    }

    Context "service exists and is Running" {
        It "calls Stop-Service before removal" {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running' } }
            Mock Get-Command { [PSCustomObject]@{ Name = "nssm" } }

            Remove-METISService

            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq "METIS" }
        }
    }

    Context "service exists and is Stopped" {
        It "does not call Stop-Service" {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Stopped' } }
            Mock Get-Command { [PSCustomObject]@{ Name = "nssm" } }

            Remove-METISService

            Should -Not -Invoke Stop-Service
        }
    }

    Context "removal throws an exception" {
        It "adds an entry to FAILED_STEPS" {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Stopped' } }
            Mock Get-Command { [PSCustomObject]@{ Name = "nssm" } }
            Mock nssm { throw "Access denied" }

            Remove-METISService

            $script:FAILED_STEPS.Count | Should -BeGreaterThan 0
            $script:FAILED_STEPS[0].Step | Should -Match "service"
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISFiles
# ---------------------------------------------------------------------------
Describe "Remove-METISFiles" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Remove-Item {}
    }

    Context "service data directory exists" {
        It "removes it with -Recurse -Force" {
            Mock Test-Path { $true }

            Remove-METISFiles

            Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Recurse -eq $true -and $Force -eq $true }
        }
    }

    Context "service data directory does not exist" {
        It "warns and does not call Remove-Item" {
            Mock Test-Path { $false }

            Remove-METISFiles

            Should -Not -Invoke Remove-Item
        }
    }

    Context "Remove-Item throws" {
        It "adds one FAILED_STEPS entry" {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Locked" }

            Remove-METISFiles

            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISCLIWrapper
# ---------------------------------------------------------------------------
Describe "Remove-METISCLIWrapper" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Remove-Item {}
    }

    Context "CLI wrapper exists" {
        It "removes it" {
            Mock Test-Path { $true }

            Remove-METISCLIWrapper

            Should -Invoke Remove-Item -Times 1
        }
    }

    Context "CLI wrapper does not exist" {
        It "warns without adding to FAILED_STEPS" {
            Mock Test-Path { $false }

            Remove-METISCLIWrapper

            $script:FAILED_STEPS.Count | Should -Be 0
            Should -Not -Invoke Remove-Item
        }
    }

    Context "Remove-Item throws" {
        It "adds one FAILED_STEPS entry" {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Access denied" }

            Remove-METISCLIWrapper

            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }
}

# ---------------------------------------------------------------------------
# Remove-METISInstallDir
# ---------------------------------------------------------------------------
Describe "Remove-METISInstallDir" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Write-MetisError {}
        Mock Remove-Item {}
    }

    Context "install directory exists" {
        It "removes it with -Recurse -Force" {
            Mock Test-Path { $true }

            Remove-METISInstallDir

            Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Recurse -eq $true -and $Force -eq $true }
        }
    }

    Context "install directory does not exist" {
        It "warns and skips" {
            Mock Test-Path { $false }

            Remove-METISInstallDir

            Should -Not -Invoke Remove-Item
        }
    }

    Context "Remove-Item throws" {
        It "adds an error entry to FAILED_STEPS" {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Access denied" }

            Remove-METISInstallDir

            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "installation directory"
        }
    }
}

# ---------------------------------------------------------------------------
# FAILED_STEPS accumulation across multiple failures
# ---------------------------------------------------------------------------
Describe "FAILED_STEPS accumulation" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Write-MetisError {}
        Mock Test-Path { $true }
        Mock Remove-Item { throw "Access denied" }
    }

    It "records one entry per failing step" {
        Remove-METISFiles
        Remove-METISCLIWrapper
        Remove-METISInstallDir

        $script:FAILED_STEPS.Count | Should -Be 3
    }

    It "each entry has a non-empty NextSteps hint" {
        Remove-METISFiles

        $script:FAILED_STEPS[0].NextSteps | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Invoke-MongoDBUninstall
# ---------------------------------------------------------------------------
Describe "Invoke-MongoDBUninstall" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock choco {}
        Mock Remove-Item {}
        # Default: data dir does not exist
        Mock Test-Path { $false }
    }

    Context "choco uninstall succeeds" {
        It "calls choco uninstall" {
            Invoke-MongoDBUninstall
            Should -Invoke choco -Times 1
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "choco uninstall throws" {
        BeforeEach {
            Mock choco { throw "Package not found" }
        }

        It "adds a FAILED_STEPS entry for the MongoDB uninstall" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -BeGreaterThan 0
            $script:FAILED_STEPS[0].Step | Should -Match "MongoDB uninstall"
        }

        It "FAILED_STEPS entry has a non-empty NextSteps hint" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS[0].NextSteps | Should -Not -BeNullOrEmpty
        }
    }

    Context "MongoDB data directory exists and Remove-Item succeeds" {
        BeforeEach {
            Mock Test-Path { $true }
        }

        It "removes the data directory with -Recurse -Force" {
            Invoke-MongoDBUninstall
            Should -Invoke Remove-Item -Times 1 -ParameterFilter { $Recurse -eq $true -and $Force -eq $true }
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "MongoDB data directory exists but Remove-Item throws" {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Locked" }
        }

        It "adds a FAILED_STEPS entry for the data directory" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS | Where-Object { $_.Step -match "MongoDB data directory" } | Should -Not -BeNullOrEmpty
        }

        It "FAILED_STEPS entry NextSteps mentions manual deletion" {
            Invoke-MongoDBUninstall
            $entry = $script:FAILED_STEPS | Where-Object { $_.Step -match "MongoDB data directory" }
            $entry.NextSteps | Should -Match "Manually delete"
        }
    }

    Context "MongoDB data directory does not exist" {
        It "does not attempt to remove the data directory" {
            Invoke-MongoDBUninstall
            Should -Not -Invoke Remove-Item
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }
}
