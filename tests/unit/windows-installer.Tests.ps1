#Requires -Modules Pester
# Unit tests for windows-installer.ps1
# Run via: pwsh ./tests/Run-Tests.ps1

BeforeAll {
    $scriptPath = Resolve-Path "$PSScriptRoot/../../windows-installer.ps1"

    # Stub Windows-only cmdlets that don't exist on macOS/Linux
    function global:Get-Service       { param([string]$Name, $ErrorAction) $null }
    function global:Stop-Service      { param([string]$Name, [switch]$Force, $ErrorAction) }
    function global:Start-Service     { param([string]$Name, $ErrorAction) }
    function global:Restart-Service   { param([string]$Name) }
    function global:Set-Service       { param([string]$Name, $StartupType) }
    function global:Get-Acl           { param([string]$Path)
        $obj = [PSCustomObject]@{}
        $obj | Add-Member -MemberType ScriptMethod -Name SetAccessRuleProtection -Value { param($a,$b) } -Force
        $obj | Add-Member -MemberType ScriptMethod -Name AddAccessRule            -Value { param($a) }   -Force
        $obj
    }
    function global:Set-Acl           { param([string]$Path, $AclObject) }
    function global:Get-NetTCPConnection { param([int]$LocalPort, $ErrorAction) $null }
    function global:nssm              { param() }
    function global:choco             { param() }
    function global:mongosh           { param() }
    function global:mongod            { param() }
    function global:git               { param() }
    function global:icacls            { param() }

    # Stub New-Object for Windows ACL types (returns no-op objects)
    $origNewObject = Get-Item Function:New-Object -ErrorAction SilentlyContinue
    function global:New-Object {
        param([string]$TypeName, [object[]]$ArgumentList)
        if ($TypeName -match "FileSystemAccessRule|AccessRule") {
            return [PSCustomObject]@{ TypeName = $TypeName }
        }
        # Fall through to real New-Object for everything else
        Microsoft.PowerShell.Utility\New-Object @PSBoundParameters
    }

    # Dot-source the script — main block is skipped because InvocationName is '.'
    . $scriptPath

    function Reset-ScriptState {
        $script:ADMIN_USER        = ""
        $script:ADMIN_PASS        = ""
        $script:METIS_USER        = ""
        $script:METIS_PASS        = ""
        $script:METIS_PORT        = 8080
        $script:CREDENTIALS_FOUND = $false
        $script:THIRD_PARTY_ADMIN = $false
    }
}

# ---------------------------------------------------------------------------
# Generate-Credentials
# ---------------------------------------------------------------------------
Describe "Generate-Credentials" {

    BeforeEach { Reset-ScriptState }

    Context "fresh install — no credentials file, MongoDB has no auth" {
        BeforeEach {
            Mock Test-Path { $false }
            Mock Write-Success {}
            Mock Write-MetisWarning {}
            # mongosh returns clean output (no MongoServerError) on open connection
            Mock mongosh { "" }
        }

        It "generates ADMIN_USER with 'admin_' prefix followed by 8 hex chars" {
            Generate-Credentials
            $script:ADMIN_USER | Should -Match "^admin_[0-9a-f]{8}$"
        }

        It "generates METIS_USER with 'metis_' prefix followed by 8 hex chars" {
            Generate-Credentials
            $script:METIS_USER | Should -Match "^metis_[0-9a-f]{8}$"
        }

        It "generates passwords that are non-empty" {
            Generate-Credentials
            $script:ADMIN_PASS | Should -Not -BeNullOrEmpty
            $script:METIS_PASS | Should -Not -BeNullOrEmpty
        }

        It "strips double-quote characters from passwords" {
            Generate-Credentials
            $script:ADMIN_PASS | Should -Not -Match '"'
            $script:METIS_PASS | Should -Not -Match '"'
        }

        It "leaves CREDENTIALS_FOUND as false" {
            Generate-Credentials
            $script:CREDENTIALS_FOUND | Should -Be $false
        }

        It "leaves THIRD_PARTY_ADMIN as false" {
            Generate-Credentials
            $script:THIRD_PARTY_ADMIN | Should -Be $false
        }

        It "generates unique passwords on each call" {
            Generate-Credentials
            $pass1 = $script:ADMIN_PASS
            Reset-ScriptState
            Generate-Credentials
            $pass2 = $script:ADMIN_PASS
            $pass1 | Should -Not -Be $pass2
        }
    }

    Context "METIS credentials file already exists" {
        BeforeEach {
            Mock Test-Path { $true }
            Mock Get-Content {
                @(
                    "MongoDB Admin Username: admin_saved01",
                    "MongoDB Admin Password: SavedAdminPass",
                    "MongoDB Web Username: metis_saved02",
                    "MongoDB Web Password: SavedMetisPass"
                )
            }
            Mock Write-Success {}
            Mock Write-MetisWarning {}
            Mock mongosh { "" }
        }

        It "loads ADMIN_USER from file" {
            Generate-Credentials
            $script:ADMIN_USER | Should -Be "admin_saved01"
        }

        It "loads ADMIN_PASS from file" {
            Generate-Credentials
            $script:ADMIN_PASS | Should -Be "SavedAdminPass"
        }

        It "loads METIS_USER from file" {
            Generate-Credentials
            $script:METIS_USER | Should -Be "metis_saved02"
        }

        It "loads METIS_PASS from file" {
            Generate-Credentials
            $script:METIS_PASS | Should -Be "SavedMetisPass"
        }

        It "sets CREDENTIALS_FOUND to true" {
            Generate-Credentials
            $script:CREDENTIALS_FOUND | Should -Be $true
        }
    }

    Context "MongoDB already has auth enabled (pre-existing instance)" {
        BeforeEach {
            Mock Test-Path { $false }
            Mock Write-Success {}
            Mock Write-MetisWarning {}
            Mock Write-Host {}
            # mongosh open connection returns auth error
            Mock mongosh { "MongoServerError: command find requires authentication" }
            # Both Read-Host calls must return a SecureString because the second
            # uses -AsSecureString and passes the result into SecureStringToBSTR.
            Mock Read-Host { ConvertTo-SecureString "test_value" -AsPlainText -Force }
        }

        It "sets THIRD_PARTY_ADMIN to true" {
            Generate-Credentials
            $script:THIRD_PARTY_ADMIN | Should -Be $true
        }

        It "prompts for the existing admin username" {
            Generate-Credentials
            Should -Invoke Read-Host -Times 1
        }
    }
}

# ---------------------------------------------------------------------------
# Save-Credentials
# ---------------------------------------------------------------------------
Describe "Save-Credentials" {

    BeforeEach {
        Reset-ScriptState
        $script:ADMIN_USER = "admin_abc"
        $script:ADMIN_PASS = "adminpass"
        $script:METIS_USER = "metis_xyz"
        $script:METIS_PASS = "metispass"
        Mock Set-Content {}
        Mock Get-Acl {
            $acl = [PSCustomObject]@{}
            $acl | Add-Member ScriptMethod SetAccessRuleProtection { } -Force
            $acl | Add-Member ScriptMethod AddAccessRule { } -Force
            $acl
        }
        Mock Set-Acl {}
        Mock Write-Success {}
        Mock Write-MetisWarning {}
    }

    Context "new install (CREDENTIALS_FOUND is false)" {
        It "writes the admin username to the credentials file" {
            Save-Credentials
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MongoDB Admin Username: admin_abc" }
        }

        It "writes the admin password to the credentials file" {
            Save-Credentials
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MongoDB Admin Password: adminpass" }
        }

        It "writes the web username to the credentials file" {
            Save-Credentials
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MongoDB Web Username: metis_xyz" }
        }

        It "writes the web password to the credentials file" {
            Save-Credentials
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MongoDB Web Password: metispass" }
        }
    }

    Context "re-run with CREDENTIALS_FOUND = true" {
        It "skips writing and emits a warning" {
            $script:CREDENTIALS_FOUND = $true

            Save-Credentials

            Should -Not -Invoke Set-Content
            Should -Invoke Write-MetisWarning -Times 1
        }
    }
}

# ---------------------------------------------------------------------------
# Set-METISEnvironment
# ---------------------------------------------------------------------------
Describe "Set-METISEnvironment" {

    BeforeAll {
        # Override the Windows install path with a macOS-compatible temp path
        $script:METIS_INSTALL_DIR_ORIG = $METIS_INSTALL_DIR
        $METIS_INSTALL_DIR = (Join-Path ([System.IO.Path]::GetTempPath()) "test-metis")
    }

    AfterAll {
        $METIS_INSTALL_DIR = $script:METIS_INSTALL_DIR_ORIG
    }

    BeforeEach {
        Reset-ScriptState
        $script:METIS_USER = "metis_testuser"
        $script:METIS_PASS = "testpass123"
        Mock Write-Success {}
        Mock New-Item {}
        Mock Set-Acl {}
        Mock Set-Content {}
        Mock Test-Path { $true }
        Mock Get-Acl {
            $acl = [PSCustomObject]@{}
            $acl | Add-Member ScriptMethod SetAccessRuleProtection { } -Force
            $acl | Add-Member ScriptMethod AddAccessRule { }            -Force
            $acl
        }
    }

    Context "port 8080 is free" {
        It "assigns port 8080" {
            Mock Get-NetTCPConnection { $null }

            Set-METISEnvironment

            $script:METIS_PORT | Should -Be 8080
        }
    }

    Context "port 8080 is in use, 8081 is free" {
        It "assigns port 8081" {
            # Mock checks the actual $LocalPort parameter: 8080 is occupied, 8081 is free
            Mock Get-NetTCPConnection {
                if ($LocalPort -eq 8080) { return [PSCustomObject]@{ LocalPort = 8080 } }
                return $null
            }

            Set-METISEnvironment

            $script:METIS_PORT | Should -Be 8081
        }
    }

    Context "env file content" {
        BeforeEach {
            Mock Get-NetTCPConnection { $null }
        }

        It "includes MONGO_USERNAME in the written content" {
            Set-METISEnvironment
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MONGO_USERNAME" }
        }

        It "includes MONGO_PASSWORD in the written content" {
            Set-METISEnvironment
            Should -Invoke Set-Content -ParameterFilter { $Value -match "MONGO_PASSWORD" }
        }

        It "includes PORT= in the written content" {
            Set-METISEnvironment
            Should -Invoke Set-Content -ParameterFilter { $Value -match "PORT=" }
        }
    }
}

# ---------------------------------------------------------------------------
# Stop-ExistingMETISService
# ---------------------------------------------------------------------------
Describe "Stop-ExistingMETISService" {

    BeforeEach {
        # Stub Stop-Service so Should -Not -Invoke is valid in every Context
        Mock Stop-Service {}
        Mock Write-MetisWarning {}
        Mock Write-Success {}
    }

    Context "service is Running" {
        It "calls Stop-Service" {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running' } }

            Stop-ExistingMETISService

            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq "METIS" }
        }
    }

    Context "service is Stopped" {
        It "does not call Stop-Service" {
            Mock Get-Service { [PSCustomObject]@{ Status = 'Stopped' } }

            Stop-ExistingMETISService

            Should -Not -Invoke Stop-Service
        }
    }

    Context "service does not exist" {
        It "does nothing without throwing" {
            Mock Get-Service { $null }

            { Stop-ExistingMETISService } | Should -Not -Throw
            Should -Not -Invoke Stop-Service
        }
    }
}
