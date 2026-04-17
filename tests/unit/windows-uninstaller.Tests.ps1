#Requires -Modules Pester
# Unit tests for windows-uninstaller.ps1
# Run via: pwsh ./tests/Run-Tests.ps1

BeforeAll {
    $scriptPath = Resolve-Path "$PSScriptRoot/../../windows-uninstaller.ps1"

    # Stub Windows-only cmdlets that do not exist on macOS/Linux so that
    # Pester's Mock can intercept them during tests.
    function global:Get-Service    { param([string]$Name, $ErrorAction) $null }
    function global:Stop-Service   { param([string]$Name, [switch]$Force, $ErrorAction) }
    function global:Get-Process    { param([string]$Name, $ErrorAction) @() }
    function global:Stop-Process   { param([int]$Id, [switch]$Force) }
    function global:Get-Acl        { param([string]$Path) [PSCustomObject]@{} }
    function global:Set-Acl        { param([string]$Path, $AclObject) }
    function global:nssm           { param() }
    function global:sc.exe         { param() }  # defined via alias below
    function global:mongosh        { param() }
    function global:choco                    { param() }
    function global:Get-MongoDBInstallEntry   { param() [PSCustomObject]@{ DisplayName = "MongoDB 7.0.0" } }
    function global:Get-MongoDBChocoPackages  { param() @("mongodb 7.0.0") }
    function global:Get-NodeJSUninstallEntry  { param() $null }

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
# Remove-MongoMetisData
# ---------------------------------------------------------------------------
Describe "Remove-MongoMetisData" {

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

            Remove-MongoMetisData

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "Skipping" }
            Should -Not -Invoke Get-Command
        }
    }

    Context "credentials parsed but mongosh is not installed" {
        It "skips and warns" {
            $script:CREDENTIALS_PARSED = $true
            # Get-Command already returns $null from BeforeEach

            Remove-MongoMetisData

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "mongosh not found" }
            $script:MONGO_DROP_SUCCEEDED | Should -Be $false
        }
    }

    Context "credentials parsed, mongosh present, drop succeeds" {
        BeforeEach {
            $script:CREDENTIALS_PARSED = $true
            $script:ADMIN_USER = "admin"
            $script:ADMIN_PASS = "adminpass"
            $script:METIS_USER = "metis"
            $script:METIS_PASS = "metispass"
            Mock Get-Command { [PSCustomObject]@{ Name = "mongosh" } }
            Mock mongosh {}
        }

        It "sets MONGO_DROP_SUCCEEDED to true" {
            Remove-MongoMetisData
            $script:MONGO_DROP_SUCCEEDED | Should -Be $true
        }

        It "does not add any FAILED_STEPS entries" {
            Remove-MongoMetisData
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "credentials parsed, mongosh present, output contains MongoServerError" {
        BeforeEach {
            $script:CREDENTIALS_PARSED = $true
            $script:ADMIN_USER = "admin"
            $script:ADMIN_PASS = "adminpass"
            $script:METIS_USER = "metis"
            $script:METIS_PASS = "metispass"
            Mock Get-Command { [PSCustomObject]@{ Name = "mongosh" } }
            Mock mongosh { "MongoServerError: Authentication failed" }
        }

        It "does not set MONGO_DROP_SUCCEEDED" {
            Remove-MongoMetisData
            $script:MONGO_DROP_SUCCEEDED | Should -Be $false
        }

        It "emits a warning mentioning MongoServerError" {
            Remove-MongoMetisData
            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "MongoDB reported an error" }
        }
    }

    Context "credentials parsed, mongosh present, mongosh throws" {
        BeforeEach {
            $script:CREDENTIALS_PARSED = $true
            $script:ADMIN_USER = "admin"
            $script:ADMIN_PASS = "adminpass"
            $script:METIS_USER = "metis"
            $script:METIS_PASS = "metispass"
            Mock Get-Command { [PSCustomObject]@{ Name = "mongosh" } }
            Mock mongosh { throw "Connection refused" }
        }

        It "adds a FAILED_STEPS entry for MongoDB user removal" {
            Remove-MongoMetisData
            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "MongoDB user"
        }

        It "does not set MONGO_DROP_SUCCEEDED" {
            Remove-MongoMetisData
            $script:MONGO_DROP_SUCCEEDED | Should -Be $false
        }
    }
}

# ---------------------------------------------------------------------------
# Get-METISService
# ---------------------------------------------------------------------------
Describe "Get-METISService" {

    BeforeEach {
        Reset-ScriptState
    }

    Context "METIS service exists" {
        It "returns the service object" {
            Mock Get-Service { [PSCustomObject]@{ Name = "METIS"; Status = "Running" } }

            $result = Get-METISService

            $result | Should -Not -BeNullOrEmpty
        }
    }

    Context "METIS service does not exist" {
        It "returns null" {
            Mock Get-Service { $null }

            $result = Get-METISService

            $result | Should -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------
# Stop-METISService
# ---------------------------------------------------------------------------
Describe "Stop-METISService" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Stop-Service {}
    }

    Context "service is Running" {
        It "calls Stop-Service once" {
            $service = [PSCustomObject]@{ Status = "Running" }

            Stop-METISService $service

            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq "METIS" }
        }
    }

    Context "service is Stopped" {
        It "does not call Stop-Service" {
            $service = [PSCustomObject]@{ Status = "Stopped" }

            Stop-METISService $service

            Should -Not -Invoke Stop-Service
        }

        It "emits a warning mentioning the current status" {
            $service = [PSCustomObject]@{ Status = "Stopped" }

            Stop-METISService $service

            Should -Invoke Write-MetisWarning -ParameterFilter { "$args" -match "Stopped" }
        }
    }

    Context "Stop-Service throws" {
        It "emits a warning and does not add to FAILED_STEPS" {
            $service = [PSCustomObject]@{ Status = "Running" }
            Mock Stop-Service { throw "Access denied" }

            Stop-METISService $service

            Should -Invoke Write-MetisWarning
            $script:FAILED_STEPS.Count | Should -Be 0
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
        Mock nssm {}
    }

    Context "nssm is available" {
        It "calls nssm to remove the service" {
            Mock Get-Command { [PSCustomObject]@{ Name = "nssm" } }

            Remove-METISService

            Should -Invoke nssm -Times 1
        }
    }

    Context "nssm is not available" {
        It "does not call nssm" {
            Mock Get-Command { $null }

            Remove-METISService

            Should -Not -Invoke nssm
        }
    }

    Context "removal throws an exception" {
        It "adds one entry to FAILED_STEPS mentioning 'service'" {
            Mock Get-Command { [PSCustomObject]@{ Name = "nssm" } }
            Mock nssm { throw "Access denied" }

            Remove-METISService

            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "service"
        }
    }
}

# ---------------------------------------------------------------------------
# Stop-AllNodeProcesses
# ---------------------------------------------------------------------------
Describe "Stop-AllNodeProcesses" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Stop-Process {}
        Mock Start-Sleep {}
    }

    Context "no node processes are running" {
        It "does not call Stop-Process" {
            Mock Get-Process { @() }

            Stop-AllNodeProcesses

            Should -Not -Invoke Stop-Process
        }
    }

    Context "node processes are running" {
        It "stops all of them and waits for them to exit" {
            $script:getProcessCallCount = 0
            $fakeProcess = [PSCustomObject]@{ Id = 1234 }
            Mock Get-Process {
                $script:getProcessCallCount++
                if ($script:getProcessCallCount -eq 1) { @($fakeProcess) } else { @() }
            }

            Stop-AllNodeProcesses

            Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        }
    }

    Context "node processes linger after kill, then exit" {
        It "polls until all processes have exited" {
            $script:getProcessCallCount = 0
            $fakeProcess = [PSCustomObject]@{ Id = 1234 }
            Mock Get-Process {
                $script:getProcessCallCount++
                if ($script:getProcessCallCount -le 3) { @($fakeProcess) } else { @() }
            }

            Stop-AllNodeProcesses

            Should -Invoke Start-Sleep -Times 2
        }
    }
}

# ---------------------------------------------------------------------------
# Stop-MongodProcesses
# ---------------------------------------------------------------------------
Describe "Stop-MongodProcesses" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Stop-Process {}
        Mock Stop-Service {}
        Mock Start-Sleep {}
    }

    Context "no mongod processes are running" {
        It "does not call Stop-Process" {
            Mock Get-Process { @() }

            Stop-MongodProcesses

            Should -Not -Invoke Stop-Process
        }

        It "still calls Stop-Service for the MongoDB service" {
            Mock Get-Process { @() }

            Stop-MongodProcesses

            Should -Invoke Stop-Service -Times 1 -ParameterFilter { $Name -eq "MongoDB" }
        }
    }

    Context "mongod processes are running" {
        It "stops all of them" {
            $script:getProcessCallCount = 0
            $fakeProcess = [PSCustomObject]@{ Id = 5678 }
            Mock Get-Process {
                $script:getProcessCallCount++
                if ($script:getProcessCallCount -eq 1) { @($fakeProcess) } else { @() }
            }

            Stop-MongodProcesses

            Should -Invoke Stop-Process -Times 1 -ParameterFilter { $Id -eq 5678 }
        }
    }

    Context "mongod processes linger after kill, then exit" {
        It "polls until all processes have exited" {
            $script:getProcessCallCount = 0
            $fakeProcess = [PSCustomObject]@{ Id = 5678 }
            Mock Get-Process {
                $script:getProcessCallCount++
                if ($script:getProcessCallCount -le 3) { @($fakeProcess) } else { @() }
            }

            Stop-MongodProcesses

            Should -Invoke Start-Sleep -Times 2
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
        Mock Write-MetisError {}
        Mock Stop-AllNodeProcesses {}
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

    Context "Remove-Item throws a generic error" {
        It "adds one FAILED_STEPS entry" {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Access denied" }

            Remove-METISFiles

            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }

    Context "Remove-Item throws a locked-file error and user confirms kill" {
        It "kills node processes, retries, and succeeds" {
            $script:removeCallCount = 0
            $script:dirExists = $true
            Mock Test-Path { $script:dirExists }
            Mock Read-Host { 'y' }
            Mock Remove-Item {
                $script:removeCallCount++
                if ($script:removeCallCount -eq 1) {
                    throw "The process cannot access the file because it is being used by another process."
                }
                $script:dirExists = $false
            }

            Remove-METISFiles

            Should -Invoke Stop-AllNodeProcesses -Times 1
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "Remove-Item throws a locked-file error and user declines kill" {
        It "adds to FAILED_STEPS without killing node processes" {
            Mock Test-Path { $true }
            Mock Read-Host { 'n' }
            Mock Remove-Item { throw "The process cannot access the file because it is being used by another process." }

            Remove-METISFiles

            Should -Not -Invoke Stop-AllNodeProcesses
            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }

    Context "Remove-Item throws a locked-file error and user confirms kill, retry also fails" {
        It "adds to FAILED_STEPS after retry failure" {
            Mock Test-Path { $true }
            Mock Read-Host { 'y' }
            Mock Remove-Item { throw "The process cannot access the file because it is being used by another process." }

            Remove-METISFiles

            Should -Invoke Stop-AllNodeProcesses -Times 1
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

    Context "Remove-Item throws a generic error" {
        It "adds an error entry to FAILED_STEPS" {
            Mock Test-Path { $true }
            Mock Remove-Item { throw "Access denied" }

            Remove-METISInstallDir

            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "installation directory"
        }
    }

    Context "Remove-Item throws a locked-file error and user confirms kill" {
        It "kills node processes, retries, and succeeds" {
            $script:removeCallCount = 0
            $script:dirExists = $true
            Mock Test-Path { $script:dirExists }
            Mock Read-Host { 'y' }
            Mock Stop-AllNodeProcesses {}
            Mock Remove-Item {
                $script:removeCallCount++
                if ($script:removeCallCount -eq 1) {
                    throw "The process cannot access the file because it is being used by another process."
                }
                $script:dirExists = $false
            }

            Remove-METISInstallDir

            Should -Invoke Stop-AllNodeProcesses -Times 1
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "Remove-Item throws a locked-file error and user declines kill" {
        It "adds to FAILED_STEPS without killing node processes" {
            Mock Test-Path { $true }
            Mock Read-Host { 'n' }
            Mock Stop-AllNodeProcesses {}
            Mock Remove-Item { throw "The process cannot access the file because it is being used by another process." }

            Remove-METISInstallDir

            Should -Not -Invoke Stop-AllNodeProcesses
            $script:FAILED_STEPS.Count | Should -Be 1
        }
    }

    Context "Remove-Item throws a locked-file error and user confirms kill, retry also fails" {
        It "adds to FAILED_STEPS after retry failure" {
            Mock Test-Path { $true }
            Mock Read-Host { 'y' }
            Mock Stop-AllNodeProcesses {}
            Mock Remove-Item { throw "The process cannot access the file because it is being used by another process." }

            Remove-METISInstallDir

            Should -Invoke Stop-AllNodeProcesses -Times 1
            $script:FAILED_STEPS.Count | Should -Be 1
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
# Get-MongoDBInstallEntry
# ---------------------------------------------------------------------------
Describe "Get-MongoDBInstallEntry" {

    Context "a MongoDB registry entry exists" {
        It "returns the entry" {
            Mock Get-ChildItem {
                @([PSCustomObject]@{ PSChildName = "{MONGO-GUID}" })
            }
            Mock Get-ItemProperty {
                [PSCustomObject]@{ DisplayName = "MongoDB 7.0.0"; PSChildName = "{MONGO-GUID}" }
            }

            $result = Get-MongoDBInstallEntry

            $result | Should -Not -BeNullOrEmpty
            $result.DisplayName | Should -Match "MongoDB"
        }
    }

    Context "no MongoDB registry entry exists" {
        It "returns null" {
            Mock Get-ChildItem { @() }

            $result = Get-MongoDBInstallEntry

            $result | Should -BeNullOrEmpty
        }
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
        Mock Stop-MongodProcesses {}
        Mock choco {}
        Mock Remove-Item {}
        Mock Test-Path { $false }
    }

    Context "choco uninstall succeeds" {
        It "calls Stop-MongodProcesses before uninstalling" {
            Invoke-MongoDBUninstall
            Should -Invoke Stop-MongodProcesses -Times 1
        }

        It "calls choco uninstall" {
            Invoke-MongoDBUninstall
            Should -Invoke choco -Times 1
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "only a subset of MongoDB packages are installed via choco (partial install)" {
        BeforeEach {
            # Simulate the scenario where only mongodb.install is registered — not the shell or tools.
            Mock Get-MongoDBChocoPackages { @("mongodb.install 8.0.4") }
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "choco list returns a non-whitelisted mongodb-prefixed package" {
        BeforeEach {
            # mongodb-community-edition is not on the whitelist and must not be uninstalled.
            Mock Get-MongoDBChocoPackages { @("mongodb.install 8.0.4", "mongodb-community-edition 8.0.4") }
        }

        It "does not add any FAILED_STEPS entries" {
            Invoke-MongoDBUninstall
            $script:FAILED_STEPS.Count | Should -Be 0
        }

        It "only passes whitelisted package names to choco" {
            $script:capturedChocoArgs = $null
            Mock choco { $script:capturedChocoArgs = $args }
            Invoke-MongoDBUninstall
            $script:capturedChocoArgs | Should -Not -Contain "mongodb-community-edition"
            $script:capturedChocoArgs | Should -Contain "mongodb.install"
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

# ---------------------------------------------------------------------------
# Invoke-NodeJSUninstall
# ---------------------------------------------------------------------------
Describe "Invoke-NodeJSUninstall" {

    BeforeEach {
        Reset-ScriptState
        Mock Write-Success {}
        Mock Write-MetisWarning {}
        Mock Start-Process { [PSCustomObject]@{ ExitCode = 0 } }
        Mock choco {}
    }

    Context "MSI entry found and msiexec succeeds" {
        It "calls Start-Process with msiexec /x and does not add FAILED_STEPS" {
            $fakeEntry = [PSCustomObject]@{ PSChildName = "{FAKE-GUID-1234}"; DisplayName = "Node.js v22.21.1" }
            Mock Get-NodeJSUninstallEntry { $fakeEntry }
            Invoke-NodeJSUninstall
            Should -Invoke Start-Process -Times 1 -ParameterFilter { $FilePath -eq "msiexec.exe" }
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "MSI entry found but Start-Process throws" {
        It "adds a FAILED_STEPS entry for Node.js uninstall" {
            $fakeEntry = [PSCustomObject]@{ PSChildName = "{FAKE-GUID-1234}"; DisplayName = "Node.js v22.21.1" }
            Mock Get-NodeJSUninstallEntry { $fakeEntry }
            Mock Start-Process { throw "msiexec failed" }
            Invoke-NodeJSUninstall
            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "Node.js uninstall"
        }
    }

    Context "MSI entry not found, choco fallback succeeds" {
        It "calls choco as fallback and does not add FAILED_STEPS" {
            Mock Get-NodeJSUninstallEntry { $null }
            Invoke-NodeJSUninstall
            Should -Invoke choco -Times 1
            $script:FAILED_STEPS.Count | Should -Be 0
        }
    }

    Context "MSI entry not found, choco fallback throws" {
        It "adds a FAILED_STEPS entry for Node.js uninstall" {
            Mock Get-NodeJSUninstallEntry { $null }
            Mock choco { throw "Package not found" }
            Invoke-NodeJSUninstall
            $script:FAILED_STEPS.Count | Should -Be 1
            $script:FAILED_STEPS[0].Step | Should -Match "Node.js uninstall"
        }
    }
}
