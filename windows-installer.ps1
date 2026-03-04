# METIS Provisioning Script for Windows
# This script automates the installation based on the METIS setup instructions.

# Requires Administrator privileges
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Success     { Write-Host "[METIS] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Green }
function Write-MetisError  { Write-Host "[METIS][ERROR] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Red }
function Write-MetisWarning { Write-Host "[METIS][WARN] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Yellow }

# Default directory (using 8.3 short path to avoid issues with spaces)
$METIS_INSTALL_DIR = "C:\PROGRA~1\METIS"

# Store the starting directory to return to it at the end
$STARTING_DIR = Get-Location

$CREDENTIALS_FILE = "$env:PROGRAMDATA\.metis-credentials.txt"
$script:CREDENTIALS_FOUND = $false
$script:THIRD_PARTY_ADMIN = $false

Write-Success "Starting installation and provisioning..."

# Global credential variables
$script:ADMIN_USER = ""
$script:ADMIN_PASS = ""
$script:METIS_USER = ""
$script:METIS_PASS = ""
$script:METIS_PORT = 8080

# Generates random usernames and passwords
# for the MongoDB admin and web users.
function Generate-Credentials {
    Write-Success "Generating MongoDB credentials..."

    # Generate random usernames and passwords (exclude double quotes)
    $adminRand = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object {[char]$_})
    $metisRand = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object {[char]$_})
    
    $script:ADMIN_USER = "admin_$adminRand"
    
    # Generate random passwords
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $adminBytes = New-Object byte[] 16
    $metisBytes = New-Object byte[] 16
    $rng.GetBytes($adminBytes)
    $rng.GetBytes($metisBytes)
    $rng.Dispose()
    
    $script:ADMIN_PASS = [Convert]::ToBase64String($adminBytes)
    $script:METIS_USER = "metis_$metisRand"
    $script:METIS_PASS = [Convert]::ToBase64String($metisBytes)

    # Remove problematic characters
    $script:ADMIN_PASS = $script:ADMIN_PASS -replace '"',''
    $script:METIS_PASS = $script:METIS_PASS -replace '"',''

    # Check if MongoDB is installed with auth enabled
    $authCheck = ""
    try {
        $authCheck = & mongosh --quiet --eval "db.getSiblingDB('admin').system.users.find()" 2>&1
    } catch {}

    # Override randomly generated credentials if a METIS credentials file already exists
    if (Test-Path $CREDENTIALS_FILE) {
        Write-MetisWarning "Existing credentials found at $CREDENTIALS_FILE. Loading..."
        $credentials = Get-Content $CREDENTIALS_FILE
        $script:ADMIN_USER = "$($credentials | Select-String 'MongoDB Admin Username:' | ForEach-Object { $_ -replace 'MongoDB Admin Username: ', '' })".Trim()
        $script:ADMIN_PASS = "$($credentials | Select-String 'MongoDB Admin Password:' | ForEach-Object { $_ -replace 'MongoDB Admin Password: ', '' })".Trim()
        $script:METIS_USER = "$($credentials | Select-String 'MongoDB Web Username:'   | ForEach-Object { $_ -replace 'MongoDB Web Username: ',   '' })".Trim()
        $script:METIS_PASS = "$($credentials | Select-String 'MongoDB Web Password:'   | ForEach-Object { $_ -replace 'MongoDB Web Password: ',   '' })".Trim()
        $script:CREDENTIALS_FOUND = $true
    }
    # Handle case where MongoDB was installed prior to METIS installation
    elseif ($authCheck -match "MongoServerError") {
        Write-MetisWarning "An existing MongoDB instance with auth enabled. In order to install METIS, a dedicated DB user is needed in order for the web server to connect to the database. Please enter the credentials for the existing admin user to proceed."
        $script:ADMIN_USER = Read-Host "Enter existing MongoDB admin username"
        $securePass = Read-Host "Enter existing MongoDB admin password" -AsSecureString
        $script:ADMIN_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
        $script:THIRD_PARTY_ADMIN = $true
    }
}

# Database Server Setup
function Install-MongoDB {
    Write-Success "Installing MongoDB..."

    # Check if Chocolatey is installed (needed for all MongoDB components)
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Success "Installing Chocolatey package manager..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    # Install MongoDB Community Edition if not present
    if (-not (Get-Command mongod -ErrorAction SilentlyContinue)) {
        Write-Success "Installing MongoDB Community Edition 8.0.4..."
        choco install mongodb --version=8.0.4 -y
    } else {
        Write-MetisWarning "MongoDB already installed. Skipping..."
    }

    # Install MongoDB Shell if not present
    if (-not (Get-Command mongosh -ErrorAction SilentlyContinue)) {
        Write-Success "Installing MongoDB Shell..."
        choco install mongodb-shell -y
    } else {
        Write-MetisWarning "MongoDB Shell already installed. Skipping..."
    }

    # Install MongoDB Database Tools if not present
    if (-not (Get-Command mongodump -ErrorAction SilentlyContinue)) {
        Write-Success "Installing MongoDB Database Tools..."
        choco install mongodb-database-tools -y
    } else {
        Write-MetisWarning "MongoDB Database Tools already installed. Skipping..."
    }

    # Refresh environment variables to pick up MongoDB in PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Success "MongoDB installation completed."
}

function Configure-MongoDB {
    Write-Success "Configuring MongoDB..."
    $configFile = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.cfg"

    # Ensure the MongoDB configuration file exists
    if (-not (Test-Path $configFile)) {
        Write-MetisError "MongoDB configuration file not found: $configFile."
        exit 1
    }

    # Read the configuration file
    $config = Get-Content $configFile -Raw

    # Handle security block configuration
    if ($config -match "#security:") {
        $config = $config -replace "#security:", "security:`r`n  authorization: enabled"
        Write-Success "Uncommented and updated 'security' configuration in mongod.cfg."
    } elseif ($config -match "security:" -and $config -notmatch "authorization: enabled") {
        $config = $config -replace "security:", "security:`r`n  authorization: enabled"
        Write-Success "Added 'authorization: enabled' under existing 'security' configuration."
    } elseif ($config -match "authorization: enabled") {
        Write-MetisWarning "'authorization: enabled' is already set in mongod.cfg."
    } else {
        $config += "`r`n`r`nsecurity:`r`n  authorization: enabled"
        Write-Success "Added 'security' block to mongod.cfg."
    }

    # Save the configuration
    Set-Content -Path $configFile -Value $config

    # Restart MongoDB service to apply changes
    Write-Success "Restarting MongoDB service to apply configuration changes..."
    Restart-Service MongoDB
    Set-Service -Name MongoDB -StartupType Automatic
    Write-Success "MongoDB configured and restarted."
}

function Test-MongoDBInstallation {
    Write-Success "Checking MongoDB installation..."

    # Refresh PATH to ensure MongoDB binaries are accessible
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Check if MongoDB data directory exists (read path from config rather than hardcoding)
    $configFile = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.cfg"
    $dataDirConfig = Get-Content $configFile -Raw
    if ($dataDirConfig -match "dbPath:\s*(.+)") {
        $dataDir = $Matches[1].Trim()
    } else {
        $dataDir = "C:\Program Files\MongoDB\Server\8.0\data"
    }
    if (Test-Path $dataDir) {
        Write-Success "MongoDB data directory found at $dataDir."
    } else {
        Write-MetisWarning "MongoDB data directory not found at $dataDir."
    }

    # Verify configuration
    $config = $dataDirConfig
    if ($config -match "authorization: enabled") {
        Write-Success "MongoDB configuration verified."
    } else {
        Write-MetisError "MongoDB authorization not enabled. Please check $configFile."
        exit 1
    }

    # Check MongoDB binary presence - try direct path first
    $mongodPath = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.exe"
    if (Test-Path $mongodPath) {
        Write-Success "MongoDB binary found at $mongodPath"
    } elseif (-not (Get-Command mongod -ErrorAction SilentlyContinue)) {
        Write-MetisError "MongoDB binary not found. Installation might be incomplete."
        exit 1
    }

    # Check MongoDB version
    try {
        if (Test-Path $mongodPath) {
            $version = & $mongodPath --version 2>&1
        } else {
            $version = & mongod --version 2>&1
        }
        if ($version -match "db version") {
            Write-Success "MongoDB version: $($version[0])"
        }
    } catch {
        Write-MetisError "MongoDB version check failed."
        exit 1
    }

    # Check if MongoDB service is running
    $service = Get-Service -Name MongoDB -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-Success "MongoDB service is running."
    } else {
        Write-MetisError "MongoDB service is not running. Check logs for errors."
        exit 1
    }
}

function Setup-MongoDBAuth {
    Write-Success "Setting up MongoDB authentication..."

    # Wait for MongoDB to become fully operational
    Write-Success "Waiting for MongoDB to start..."
    $retries = 5
    for ($i = 1; $i -le $retries; $i++) {
        Start-Sleep -Seconds 3
        try {
            $null = & mongosh --eval "db.runCommand({ connectionStatus: 1 })" 2>&1
            Write-Success "MongoDB is operational."
            break
        } catch {
            if ($i -eq $retries) {
                Write-MetisError "MongoDB failed to start. Exiting."
                exit 1
            }
            Write-MetisWarning "MongoDB is not ready. Retrying in 10 seconds..."
            Start-Sleep -Seconds 7
        }
    }

    if ($script:CREDENTIALS_FOUND -or $script:THIRD_PARTY_ADMIN) {
        Write-MetisWarning "Skipping admin user creation; admin user already exists."
        return
    }

    # Create admin user
    $createAdminScript = @"
use admin
db.createUser({
  user: "$($script:ADMIN_USER)",
  pwd: "$($script:ADMIN_PASS)",
  roles: [
    { role: "userAdminAnyDatabase", db: "admin" },
    { role: "readWriteAnyDatabase",  db: "admin" },
    { role: "dbAdminAnyDatabase",     db: "admin" }
  ]
})
"@

    try {
        $output = $createAdminScript | & mongosh 2>&1
        if ($output -match "MongoServerError") {
            Write-MetisError "Failed to create admin user. MongoDB error detected:"
            Write-Host $output
            exit 1
        }
        Write-Success "Admin user created successfully."
    } catch {
        Write-MetisError "Failed to create admin user."
        exit 1
    }

    # Restart MongoDB to apply authentication settings
    Write-Success "Restarting MongoDB to apply security settings..."
    Restart-Service MongoDB
    Write-Success "MongoDB authentication setup completed."
}

function New-WebUser {
    Write-Success "Creating web server user..."

    # Wait for MongoDB to become fully operational
    Write-Success "Waiting for MongoDB to start..."
    $retries = 5
    for ($i = 1; $i -le $retries; $i++) {
        Start-Sleep -Seconds 3
        try {
            $null = & mongosh -u "$($script:ADMIN_USER)" -p "$($script:ADMIN_PASS)" --authenticationDatabase admin --eval "db.runCommand({ connectionStatus: 1 })" 2>&1
            Write-Success "MongoDB is operational."
            break
        } catch {
            if ($i -eq $retries) {
                Write-MetisError "MongoDB failed to start. Exiting."
                exit 1
            }
            Write-MetisWarning "MongoDB is not ready for web user creation. Retrying in 10 seconds..."
            Start-Sleep -Seconds 7
        }
    }

    if ($script:CREDENTIALS_FOUND) {
        Write-MetisWarning "Skipping web server user creation; web server user already exists."
        return
    }

    # Create web server user
    $createWebScript = @"
use metis
db.createUser({
  user: "$($script:METIS_USER)",
  pwd: "$($script:METIS_PASS)",
  roles: [ { role: "readWrite", db: "metis" } ]
})
"@

    try {
        $output = $createWebScript | & mongosh -u "$($script:ADMIN_USER)" -p "$($script:ADMIN_PASS)" --authenticationDatabase admin 2>&1
        if ($output -match "MongoServerError") {
            Write-MetisError "Failed to create web server user. MongoDB error detected:"
            Write-Host $output
            exit 1
        }
        Write-Success "Web server user created successfully."
    } catch {
        Write-MetisError "Failed to create web server user."
        exit 1
    }
}

# Web Server Setup
function Install-NodeJS {
    Write-Success "Installing NodeJS..."

    # Check current Node.js version if installed
    $nodeVersion = $null
    $needsReinstall = $false
    
    if (Get-Command node -ErrorAction SilentlyContinue) {
        try {
            $nodeVersionOutput = & node --version 2>&1 | Out-String
            if ($nodeVersionOutput -match 'v(\d+)\.(\d+)\.') {
                $nodeMajorVersion = [int]$matches[1]
                $nodeMinorVersion = [int]$matches[2]
                $nodeVersion = $nodeVersionOutput.Trim()
                Write-Host "[METIS] Current Node.js version: $nodeVersion" -ForegroundColor Gray
                
                # Check if it's not v22.12+
                $isCompatible = ($nodeMajorVersion -eq 22 -and $nodeMinorVersion -ge 12) -or ($nodeMajorVersion -gt 22)
                if (-not $isCompatible) {
                    Write-MetisWarning "Node.js $nodeVersion detected."
                    Write-MetisWarning "METIS requires Node.js v22.12+ or higher. Your current version may cause compatibility issues."
                    Write-Host ""
                    $response = Read-Host "Therefore, would you like to install Node.js v22.21.1? (Y/n)"
                    if ($response -eq "" -or $response -eq "Y" -or $response -eq "y") {
                        $needsReinstall = $true
                    } else {
                        Write-MetisWarning "Continuing with Node.js $nodeVersion. If you encounter issues, consider reinstalling with v22.21.1."
                    }
                }
            }
        } catch {
            $needsReinstall = $true
        }
    }

    # Check if npm is working properly by testing actual execution
    $npmWorking = $false
    if (Get-Command node -ErrorAction SilentlyContinue) {
        try {
            $npmTest = & npm --version 2>&1 | Out-String
            # If npm runs without error and returns a version, it's working
            if ($LASTEXITCODE -eq 0 -and $npmTest -match '^\d+\.\d+\.\d+') {
                $npmWorking = $true
            }
        } catch {
            $npmWorking = $false
        }
    }

    # If Node.js needs reinstall or npm is broken, reinstall
    if ($needsReinstall -or ((Get-Command node -ErrorAction SilentlyContinue) -and -not $npmWorking)) {
        if (-not $npmWorking) {
            Write-MetisWarning "Node.js is installed but npm is not working properly. Reinstalling..."
        }
        
        # Uninstall existing Node.js installation (suppress errors for non-existent packages)
        Write-Host "[METIS] Removing old Node.js installations..." -ForegroundColor Gray
        choco uninstall nodejs -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        choco uninstall nodejs.install -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        choco uninstall nodejs-lts -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        Write-Success "Old Node.js installations removed."
        
        # Clean up PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } elseif ($npmWorking -and -not $needsReinstall) {
        Write-Success "Node.js v22.12+ and npm are already installed and working."
        return
    }

    # Install Node.js 22.x LTS using official installer
    $targetNodeVersion = "22.21.1"
    Write-Success "Installing Node.js v$targetNodeVersion..."
    
    $nodeInstallerUrl = "https://nodejs.org/dist/v$targetNodeVersion/node-v$targetNodeVersion-x64.msi"
    $installerPath = "$env:TEMP\node-v$targetNodeVersion-x64.msi"
    
    Write-Host "[METIS] Downloading Node.js installer..." -ForegroundColor Gray
    Invoke-WebRequest -Uri $nodeInstallerUrl -OutFile $installerPath
    
    Write-Host "[METIS] Running Node.js installer..." -ForegroundColor Gray
    Start-Process msiexec.exe -ArgumentList "/i `"$installerPath`" /quiet /norestart" -Wait -NoNewWindow
    
    # Clean up installer
    Remove-Item $installerPath -Force
    
    Write-Success "Node.js installation completed."

    # Refresh environment variables
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Verify npm is available
    $npmCheck = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCheck) {
        Write-MetisWarning "npm not found in PATH after installation. Trying direct path..."
        $env:Path = "C:\Program Files\nodejs;" + $env:Path
    }

    Write-Success "NodeJS installed."
}

function Setup-METIS {
    Write-Success "Setting up METIS..."

    if (Test-Path $METIS_INSTALL_DIR) {
        Write-MetisWarning "Existing METIS installation detected in $METIS_INSTALL_DIR. Skipping clone..."
        
        # Set directory permissions
        Write-Success "Setting permissions for $METIS_INSTALL_DIR..."
        icacls $METIS_INSTALL_DIR /grant "Users:(OI)(CI)F" /T | Out-Null

        Set-Location $METIS_INSTALL_DIR
    } else {
        # Create directory
        New-Item -ItemType Directory -Path $METIS_INSTALL_DIR -Force | Out-Null
        
        # Set directory permissions
        Write-Success "Setting permissions for $METIS_INSTALL_DIR..."
        icacls $METIS_INSTALL_DIR /grant "Users:(OI)(CI)F" /T | Out-Null

        # Clone the repository
        Write-Success "Cloning METIS repository to $METIS_INSTALL_DIR..."
        
        # Check if git is installed
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Success "Installing Git..."
            choco install git -y
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }

        git clone -b cli-dev https://github.com/USAFA-Multi-Domain-Lab/METIS-Modular-Effects-based-Transmitter-for-Integrated-Simulations.git $METIS_INSTALL_DIR
        if ($LASTEXITCODE -ne 0) {
            Write-MetisError "Failed to clone repository"
            exit 1
        }

        Set-Location $METIS_INSTALL_DIR
    }

    # Create CLI wrapper batch file dynamically if cli/loader.cjs exists
    if (Test-Path "$METIS_INSTALL_DIR\cli\loader.cjs") {
        Write-Success "Creating CLI wrapper..."
        $cliWrapper = "C:\Windows\System32\metis.bat"
        $cliContent = "@echo off`r`nREM METIS CLI Wrapper`r`nnode `"$METIS_INSTALL_DIR\cli\loader.cjs`" %*"
        Set-Content -Path $cliWrapper -Value $cliContent
        Write-Success "CLI installed as 'metis' command."
    }

    # Install dependencies and build the application
    Write-Success "Installing dependencies and building the application..."
    
    # Verify npm is available
    $npmPath = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmPath) {
        Write-MetisWarning "npm command not found. Refreshing environment and retrying..."
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $npmPath = Get-Command npm -ErrorAction SilentlyContinue
    }
    
    if ($npmPath) {
        & npm install
        if ($LASTEXITCODE -ne 0) {
            Write-MetisError "npm install failed. Please run 'npm install' manually in $METIS_INSTALL_DIR"
            exit 1
        }
        & npm run build
        if ($LASTEXITCODE -ne 0) {
            Write-MetisError "npm run build failed. Please run 'npm run build' manually in $METIS_INSTALL_DIR"
            exit 1
        }
    } else {
        Write-MetisError "npm not found. Please install Node.js and run the installer again."
        exit 1
    }

    Write-Success "METIS setup completed."
}

function Set-METISEnvironment {
    Write-Success "Configuring METIS environment..."
    $configDir = Join-Path $METIS_INSTALL_DIR "config"
    $prodEnvFile = Join-Path $configDir "prod.env"
    
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    # Auto-assign a free port starting from 8080
    $candidate = 8080
    while (Get-NetTCPConnection -LocalPort $candidate -ErrorAction SilentlyContinue) {
        $candidate++
    }
    $script:METIS_PORT = $candidate
    Write-Success "Auto-assigned port $script:METIS_PORT for METIS."

    $envContent = @"
MONGO_USERNAME="$($script:METIS_USER)"
MONGO_PASSWORD="$($script:METIS_PASS)"
PORT=$($script:METIS_PORT)
"@

    Set-Content -Path $prodEnvFile -Value $envContent
    
    # Set file permissions (read-only for non-administrators)
    $acl = Get-Acl $prodEnvFile
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $prodEnvFile -AclObject $acl

    Write-Success "Environment configuration saved to $prodEnvFile."
}

function New-METISService {
    Write-Success "Creating Windows service for METIS..."

    # Check if NSSM is installed
    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Success "Installing NSSM (Non-Sucking Service Manager)..."
        choco install nssm -y
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }

    # Create a startup batch file in ProgramData (outside the Git repository)
    $serviceDataDir = "$env:PROGRAMDATA\METIS"
    if (-not (Test-Path $serviceDataDir)) {
        New-Item -ItemType Directory -Path $serviceDataDir -Force | Out-Null
    }
    $startupBatch = Join-Path $serviceDataDir "start-metis-service.bat"
    $nodeDir = try { (Get-Command node -ErrorAction Stop).Source | Split-Path -Parent } catch { "$env:ProgramFiles\nodejs" }
    $batchContent = @"
@echo off
REM METIS Service Startup Script
cd /d "$METIS_INSTALL_DIR"
SET NODE_ENV=production
SET "PATH=$nodeDir;%PATH%"
npm run start
"@
    Set-Content -Path $startupBatch -Value $batchContent
    Write-Success "Created service startup script at $startupBatch"

    # Remove existing service if it exists
    $service = Get-Service -Name "METIS" -ErrorAction SilentlyContinue
    if ($service) {
        Write-MetisWarning "Existing METIS service found. Removing..."
        & nssm stop METIS
        & nssm remove METIS confirm
    }

    # Install the service using cmd.exe to run the batch file
    & nssm install METIS cmd.exe
    & nssm set METIS AppParameters "/c `"$startupBatch`""
    & nssm set METIS AppDirectory $METIS_INSTALL_DIR
    & nssm set METIS DisplayName "METIS Web Service"
    & nssm set METIS Description "METIS Modular Effects-based Transmitter for Integrated Simulations"
    & nssm set METIS Start SERVICE_AUTO_START
    
    # Set up logging in proper Windows location
    $logDir = "$env:PROGRAMDATA\METIS\logs"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    & nssm set METIS AppStdout (Join-Path $logDir "metis-service.log")
    & nssm set METIS AppStderr (Join-Path $logDir "metis-service-error.log")
    
    # Rotate logs to prevent them from growing too large
    & nssm set METIS AppStdoutCreationDisposition 4
    & nssm set METIS AppStderrCreationDisposition 4

    Write-Success "METIS service created and enabled to start on boot."
    Write-Success "Service logs will be written to $logDir"
}

function Save-Credentials {
    # Skip saving if credentials already exist
    if ($script:CREDENTIALS_FOUND) {
        Write-MetisWarning "Credentials already exist. Skipping save."
        return
    }

    $credContent = @"
MongoDB Admin Username: $($script:ADMIN_USER)
MongoDB Admin Password: $($script:ADMIN_PASS)
MongoDB Web Username: $($script:METIS_USER)
MongoDB Web Password: $($script:METIS_PASS)
"@

    Set-Content -Path $CREDENTIALS_FILE -Value $credContent

    # Set file permissions (administrators only)
    $acl = Get-Acl $CREDENTIALS_FILE
    $acl.SetAccessRuleProtection($true, $false)
    $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","Allow")
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")
    $acl.AddAccessRule($adminRule)
    $acl.AddAccessRule($systemRule)
    Set-Acl -Path $CREDENTIALS_FILE -AclObject $acl

    Write-Success "Credentials saved to $CREDENTIALS_FILE (administrators only)."
}

function Start-METISService {
    Write-Success "Starting METIS service..."
    try {
        Start-Service METIS -ErrorAction Stop
        Get-Service METIS
    } catch {
        Write-MetisWarning "Failed to start METIS service automatically."
        Write-MetisWarning "This may be due to npm not being fully configured."
        Write-MetisWarning "Please restart your computer and then run: Start-Service METIS"
        Write-Host ""
        Write-Host "To start the service manually after restart, run:"
        Write-Host "  Start-Service METIS" -ForegroundColor Cyan
        Write-Host "Or to run METIS manually:"
        Write-Host "  cd $METIS_INSTALL_DIR" -ForegroundColor Cyan
        Write-Host "  npm start" -ForegroundColor Cyan
    }
}

function Stop-ExistingMETISService {
    $existingService = Get-Service -Name "METIS" -ErrorAction SilentlyContinue
    if ($existingService -and $existingService.Status -eq 'Running') {
        Write-MetisWarning "Existing METIS service is running. Stopping it before reinstall..."
        Stop-Service -Name "METIS" -Force -ErrorAction SilentlyContinue
        Write-Success "METIS service stopped."
    }
}

# Main execution
# ===============
if ($MyInvocation.InvocationName -ne '.') {
Stop-ExistingMETISService
Generate-Credentials
Install-MongoDB
Configure-MongoDB
Test-MongoDBInstallation
Setup-MongoDBAuth
New-WebUser
Save-Credentials
Install-NodeJS
Setup-METIS
Set-METISEnvironment
New-METISService
Start-METISService

# Return to the starting directory
Set-Location $STARTING_DIR

Write-Host ""
Write-Success "Installation and provisioning completed!"
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "METIS Service" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "METIS is running and will start up automatically on boot." -ForegroundColor White
Write-Host ""
Write-Host "Accessible at: http://localhost:$script:METIS_PORT" -ForegroundColor Cyan
Write-Host ""
Write-Host "To change the port, edit the PORT value in:" -ForegroundColor White
Write-Host "   $METIS_INSTALL_DIR\config\prod.env" -ForegroundColor Green
Write-Host "Then run: metis restart" -ForegroundColor White
Write-Host ""
Write-Host "To manage the METIS service, use:" -ForegroundColor White
Write-Host "   metis start" -ForegroundColor Green
Write-Host "   metis stop" -ForegroundColor Green
Write-Host "   metis restart" -ForegroundColor Green
Write-Host "   metis status" -ForegroundColor Green
Write-Host ""
Write-Host "MongoDB credentials are saved in:" -ForegroundColor White
Write-Host "   $CREDENTIALS_FILE" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan

} # end if not dot-sourced

# NOTES
# - This script requires Administrator privileges to run
# - Uses Chocolatey package manager for installing dependencies
# - Uses NSSM (Non-Sucking Service Manager) to create Windows services
# - MongoDB configuration path may vary depending on installation
# - Firewall rules may need to be configured manually for external access
