# METIS Provisioning Script for Windows
# This script automates the installation based on the METIS setup instructions.

# Requires Administrator privileges
#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# Colors for output
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Error { Write-Host $args -ForegroundColor Red }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }

# Default directory
$METIS_INSTALL_DIR = "C:\metis"

$CREDENTIALS_FILE = "$env:PROGRAMDATA\metis-credentials.txt"
$CREDENTIALS_EXIST = $false
$THIRD_PARTY_ADMIN = $false

Write-Success "[METIS] Starting installation and provisioning..."

# Global credential variables
$script:ADMIN_USER = ""
$script:ADMIN_PASS = ""
$script:METIS_USER = ""
$script:METIS_PASS = ""

# Generates random usernames and passwords
# for the MongoDB admin and web users.
function Generate-Credentials {
    Write-Success "[METIS] Generating MongoDB credentials..."

    # Generate random usernames and passwords (exclude double quotes)
    $adminRand = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object {[char]$_})
    $metisRand = -join ((48..57) + (97..102) | Get-Random -Count 8 | ForEach-Object {[char]$_})
    
    $script:ADMIN_USER = "admin_$adminRand"
    
    # Generate random passwords using RNGCryptoServiceProvider
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
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
        Write-Warning "[METIS] Existing credentials found at $CREDENTIALS_FILE. Loading..."
        $credentials = Get-Content $CREDENTIALS_FILE
        $script:ADMIN_USER = ($credentials | Select-String "MongoDB Admin Username:" | ForEach-Object { $_ -replace "MongoDB Admin Username: ", "" }).Trim()
        $script:ADMIN_PASS = ($credentials | Select-String "MongoDB Admin Password:" | ForEach-Object { $_ -replace "MongoDB Admin Password: ", "" }).Trim()
        $script:METIS_USER = ($credentials | Select-String "MongoDB Web Username:" | ForEach-Object { $_ -replace "MongoDB Web Username: ", "" }).Trim()
        $script:METIS_PASS = ($credentials | Select-String "MongoDB Web Password:" | ForEach-Object { $_ -replace "MongoDB Web Password: ", "" }).Trim()
        $script:CREDENTIALS_EXIST = $true
    }
    # Handle case where MongoDB was installed prior to METIS installation
    elseif ($authCheck -match "MongoServerError") {
        Write-Warning "[METIS] An existing MongoDB instance with auth enabled. In order to install METIS, a dedicated DB user is needed in order for the web server to connect to the database. Please enter the credentials for the existing admin user to proceed."
        $script:ADMIN_USER = Read-Host "Enter existing MongoDB admin username"
        $securePass = Read-Host "Enter existing MongoDB admin password" -AsSecureString
        $script:ADMIN_PASS = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
        $script:THIRD_PARTY_ADMIN = $true
    }
}

# Database Server Setup
function Install-MongoDB {
    Write-Success "[METIS] Installing MongoDB..."

    # Check if MongoDB is already installed
    if (Get-Command mongod -ErrorAction SilentlyContinue) {
        Write-Warning "[METIS] MongoDB appears to be already installed. Skipping installation..."
        return
    }

    # Check if Chocolatey is installed
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Success "[METIS] Installing Chocolatey package manager..."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }

    # Install MongoDB Community Edition
    Write-Success "[METIS] Installing MongoDB Community Edition 8.0.4..."
    choco install mongodb --version=8.0.4 -y

    # Install MongoDB Shell
    Write-Success "[METIS] Installing MongoDB Shell..."
    choco install mongodb-shell -y

    # Refresh environment variables to pick up MongoDB in PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Success "[METIS] MongoDB installed."
}

function Configure-MongoDB {
    Write-Success "[METIS] Configuring MongoDB..."
    $configFile = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.cfg"

    # Ensure the MongoDB configuration file exists
    if (-not (Test-Path $configFile)) {
        Write-Error "[METIS][ERROR] MongoDB configuration file not found: $configFile."
        exit 1
    }

    # Read the configuration file
    $config = Get-Content $configFile -Raw

    # Update the bindIp to allow external connections
    if ($config -match "bindIp: 127\.0\.0\.1") {
        $config = $config -replace "bindIp: 127\.0\.0\.1", "bindIp: 0.0.0.0"
        Write-Success "[METIS] Updated bindIp to 0.0.0.0 in mongod.cfg."
    } else {
        Write-Warning "[METIS][WARN] bindIp is already set to 0.0.0.0 or missing."
    }

    # Handle security block configuration
    if ($config -match "#security:") {
        $config = $config -replace "#security:", "security:`r`n  authorization: enabled"
        Write-Success "[METIS] Uncommented and updated 'security' configuration in mongod.cfg."
    } elseif ($config -match "security:" -and $config -notmatch "authorization: enabled") {
        $config = $config -replace "security:", "security:`r`n  authorization: enabled"
        Write-Success "[METIS] Added 'authorization: enabled' under existing 'security' configuration."
    } elseif ($config -match "authorization: enabled") {
        Write-Warning "[METIS][WARN] 'authorization: enabled' is already set in mongod.cfg."
    } else {
        $config += "`r`n`r`nsecurity:`r`n  authorization: enabled"
        Write-Success "[METIS] Added 'security' block to mongod.cfg."
    }

    # Save the configuration
    Set-Content -Path $configFile -Value $config

    # Restart MongoDB service to apply changes
    Write-Success "[METIS] Restarting MongoDB service to apply configuration changes..."
    Restart-Service MongoDB
    Set-Service -Name MongoDB -StartupType Automatic
    Write-Success "[METIS] MongoDB configured and restarted."
}

function Test-MongoDBInstallation {
    Write-Success "[METIS] Checking MongoDB installation..."

    # Refresh PATH to ensure MongoDB binaries are accessible
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

    # Check if MongoDB data directory exists
    $dataDir = "C:\Program Files\MongoDB\Server\8.0\data"
    if (Test-Path $dataDir) {
        Write-Success "[METIS] MongoDB data directory found."
    } else {
        Write-Warning "[METIS][WARN] MongoDB data directory not found at default location."
    }

    # Verify configuration
    $configFile = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.cfg"
    $config = Get-Content $configFile -Raw
    if ($config -match "bindIp: 0\.0\.0\.0") {
        Write-Success "[METIS] MongoDB configuration verified."
    } else {
        Write-Error "[METIS] MongoDB configuration update failed. Please check $configFile."
        exit 1
    }

    # Check MongoDB binary presence - try direct path first
    $mongodPath = "C:\Program Files\MongoDB\Server\8.0\bin\mongod.exe"
    if (Test-Path $mongodPath) {
        Write-Success "[METIS] MongoDB binary found at $mongodPath"
    } elseif (-not (Get-Command mongod -ErrorAction SilentlyContinue)) {
        Write-Error "[METIS] MongoDB binary not found. Installation might be incomplete."
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
            Write-Success "[METIS] MongoDB version: $($version[0])"
        }
    } catch {
        Write-Error "[METIS] MongoDB version check failed."
        exit 1
    }

    # Check if MongoDB service is running
    $service = Get-Service -Name MongoDB -ErrorAction SilentlyContinue
    if ($service -and $service.Status -eq 'Running') {
        Write-Success "[METIS] MongoDB service is running."
    } else {
        Write-Error "[METIS] MongoDB service is not running. Check logs for errors."
        exit 1
    }
}

function Setup-MongoDBAuth {
    Write-Success "[METIS] Setting up MongoDB authentication..."

    # Wait for MongoDB to become fully operational
    Write-Success "[METIS] Waiting for MongoDB to start..."
    $retries = 5
    for ($i = 1; $i -le $retries; $i++) {
        Start-Sleep -Seconds 3
        try {
            $null = & mongosh --eval "db.runCommand({ connectionStatus: 1 })" 2>&1
            Write-Success "[METIS] MongoDB is operational."
            break
        } catch {
            if ($i -eq $retries) {
                Write-Error "[METIS][ERROR] MongoDB failed to start. Exiting."
                exit 1
            }
            Write-Warning "[METIS][WARN] MongoDB is not ready. Retrying in 10 seconds..."
            Start-Sleep -Seconds 7
        }
    }

    if ($script:CREDENTIALS_EXIST -or $script:THIRD_PARTY_ADMIN) {
        Write-Warning "[METIS] Skipping admin user creation; admin user already exists."
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
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
"@

    try {
        $output = $createAdminScript | & mongosh 2>&1
        if ($output -match "MongoServerError") {
            Write-Error "[METIS][ERROR] Failed to create admin user. MongoDB error detected:"
            Write-Host $output
            exit 1
        }
        Write-Success "[METIS] Admin user created successfully."
    } catch {
        Write-Error "[METIS][ERROR] Failed to create admin user."
        exit 1
    }

    # Restart MongoDB to apply authentication settings
    Write-Success "[METIS] Restarting MongoDB to apply security settings..."
    Restart-Service MongoDB
    Write-Success "[METIS] MongoDB authentication setup completed."
}

function New-WebUser {
    Write-Success "[METIS] Creating web server user..."

    # Wait for MongoDB to become fully operational
    Write-Success "[METIS] Waiting for MongoDB to start..."
    $retries = 5
    for ($i = 1; $i -le $retries; $i++) {
        Start-Sleep -Seconds 3
        try {
            $null = & mongosh -u "$($script:ADMIN_USER)" -p "$($script:ADMIN_PASS)" --authenticationDatabase admin --eval "db.runCommand({ connectionStatus: 1 })" 2>&1
            Write-Success "[METIS] MongoDB is operational."
            break
        } catch {
            if ($i -eq $retries) {
                Write-Error "[METIS][ERROR] MongoDB failed to start. Exiting."
                exit 1
            }
            Write-Warning "[METIS][WARN] MongoDB is not ready for web user creation. Retrying in 10 seconds..."
            Start-Sleep -Seconds 7
        }
    }

    if ($script:CREDENTIALS_EXIST) {
        Write-Warning "[METIS] Skipping web server user creation; web server user already exists."
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
            Write-Error "[METIS][ERROR] Failed to create web server user. MongoDB error detected:"
            Write-Host $output
            exit 1
        }
        Write-Success "[METIS] Web server user created successfully."
    } catch {
        Write-Error "[METIS][ERROR] Failed to create web server user."
        exit 1
    }
}

# Web Server Setup
function Install-NodeJS {
    Write-Success "[METIS] Installing NodeJS..."

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

    # If Node.js is installed but npm is broken, reinstall
    if ((Get-Command node -ErrorAction SilentlyContinue) -and -not $npmWorking) {
        Write-Warning "[METIS] Node.js is installed but npm is not working properly. Reinstalling..."
        
        # Uninstall broken Node.js installation (suppress errors for non-existent packages)
        Write-Host "[METIS] Removing old Node.js installations..." -ForegroundColor Gray
        choco uninstall nodejs -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        choco uninstall nodejs.install -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        choco uninstall nodejs-lts -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        Write-Success "[METIS] Old Node.js installations removed."
        
        # Clean up PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    } elseif ($npmWorking) {
        Write-Success "[METIS] Node.js and npm are already installed and working."
        return
    }

    # Install Node.js LTS using Chocolatey (includes npm)
    Write-Success "[METIS] Installing Node.js LTS..."
    choco install nodejs-lts -y

    # Refresh environment variables
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    # Verify npm is available
    $npmCheck = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmCheck) {
        Write-Warning "[METIS][WARN] npm not found in PATH after installation. Trying direct path..."
        $env:Path = "C:\Program Files\nodejs;" + $env:Path
    }

    Write-Success "[METIS] NodeJS installed."
}

function Setup-METIS {
    Write-Success "[METIS] Setting up METIS..."

    if (Test-Path $METIS_INSTALL_DIR) {
        Write-Warning "[METIS][WARN] Existing METIS installation detected in $METIS_INSTALL_DIR. Skipping clone..."
        
        # Set directory permissions
        Write-Success "[METIS] Setting permissions for $METIS_INSTALL_DIR..."
        icacls $METIS_INSTALL_DIR /grant "Users:(OI)(CI)F" /T | Out-Null

        Set-Location $METIS_INSTALL_DIR
    } else {
        # Create directory
        New-Item -ItemType Directory -Path $METIS_INSTALL_DIR -Force | Out-Null
        
        # Set directory permissions
        Write-Success "[METIS] Setting permissions for $METIS_INSTALL_DIR..."
        icacls $METIS_INSTALL_DIR /grant "Users:(OI)(CI)F" /T | Out-Null

        # Clone the repository
        Write-Success "[METIS] Cloning METIS repository to $METIS_INSTALL_DIR..."
        
        # Check if git is installed
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Success "[METIS] Installing Git..."
            choco install git -y
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        }

        git clone https://github.com/USAFA-Multi-Domain-Lab/METIS-Modular-Effects-based-Transmitter-for-Integrated-Simulations.git $METIS_INSTALL_DIR
        if ($LASTEXITCODE -ne 0) {
            Write-Error "[ERROR] Failed to clone repository"
            exit 1
        }

        Set-Location $METIS_INSTALL_DIR
    }

    # Make CLI accessible (create a wrapper batch file)
    if (Test-Path "$METIS_INSTALL_DIR\cli.sh") {
        $cliWrapper = "C:\Windows\System32\metis.bat"
        $cliContent = "@echo off`r`nbash `"$METIS_INSTALL_DIR\cli.sh`" %*"
        Set-Content -Path $cliWrapper -Value $cliContent
        Write-Success "[METIS] CLI installed as 'metis' in PATH."
    }

    # Install dependencies and build the application
    Write-Success "[METIS] Installing dependencies and building the application..."
    
    # Verify npm is available
    $npmPath = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npmPath) {
        Write-Warning "[METIS][WARN] npm command not found. Refreshing environment and retrying..."
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $npmPath = Get-Command npm -ErrorAction SilentlyContinue
    }
    
    if ($npmPath) {
        & npm install
        if ($LASTEXITCODE -eq 0) {
            & npm run build
        } else {
            Write-Error "[METIS][ERROR] npm install failed. Please run 'npm install' manually in $METIS_INSTALL_DIR"
        }
    } else {
        Write-Error "[METIS][ERROR] npm not found. Please install Node.js and run the installer again."
        exit 1
    }

    Write-Success "[METIS] METIS setup completed."
}

function Set-METISEnvironment {
    Write-Success "[METIS] Configuring METIS environment..."
    $configDir = Join-Path $METIS_INSTALL_DIR "config"
    $prodEnvFile = Join-Path $configDir "prod.env"
    
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $envContent = @"
MONGO_USERNAME="$($script:METIS_USER)"
MONGO_PASSWORD="$($script:METIS_PASS)"
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

    Write-Success "[METIS] Environment configuration saved to $prodEnvFile."
}

function New-METISService {
    Write-Success "[METIS] Creating Windows service for METIS..."

    # Check if NSSM is installed
    if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
        Write-Success "[METIS] Installing NSSM (Non-Sucking Service Manager)..."
        choco install nssm -y
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    }

    # Remove existing service if it exists
    $service = Get-Service -Name "METIS" -ErrorAction SilentlyContinue
    if ($service) {
        Write-Warning "[METIS] Existing METIS service found. Removing..."
        & nssm stop METIS
        & nssm remove METIS confirm
    }

    # Install the service
    $npmPath = (Get-Command npm).Source
    & nssm install METIS $npmPath
    & nssm set METIS AppParameters "start"
    & nssm set METIS AppDirectory $METIS_INSTALL_DIR
    & nssm set METIS AppEnvironmentExtra "NODE_ENV=production"
    & nssm set METIS DisplayName "METIS Web Service"
    & nssm set METIS Description "METIS Modular Effects-based Transmitter for Integrated Simulations"
    & nssm set METIS Start SERVICE_AUTO_START

    Write-Success "[METIS] METIS service created and enabled to start on boot."
}

function Save-Credentials {
    # Skip saving if credentials already exist
    if ($script:CREDENTIALS_EXIST) {
        Write-Warning "[METIS] Credentials already exist. Skipping save."
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

    Write-Success "[METIS] Credentials saved to $CREDENTIALS_FILE (administrators only)."
}

function Start-METISService {
    Write-Success "[METIS] Starting METIS service..."
    try {
        Start-Service METIS -ErrorAction Stop
        Get-Service METIS
    } catch {
        Write-Warning "[METIS][WARN] Failed to start METIS service automatically."
        Write-Warning "[METIS][WARN] This may be due to npm not being fully configured."
        Write-Warning "[METIS][WARN] Please restart your computer and then run: Start-Service METIS"
        Write-Host ""
        Write-Host "To start the service manually after restart, run:"
        Write-Host "  Start-Service METIS" -ForegroundColor Cyan
        Write-Host "Or to run METIS manually:"
        Write-Host "  cd $METIS_INSTALL_DIR" -ForegroundColor Cyan
        Write-Host "  npm start" -ForegroundColor Cyan
    }
}

function Stop-METISService {
    Write-Success "[METIS] Stopping METIS service..."
    Stop-Service METIS
    Get-Service METIS
}

function Get-METISServiceStatus {
    Get-Service METIS
}

# Main execution
# ===============
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

Write-Host ""
Write-Success "[METIS] Installation and provisioning completed!"
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "1. Restart your computer to complete the installation" -ForegroundColor White
Write-Host "2. After restart, start the METIS service with:" -ForegroundColor White
Write-Host "   Start-Service METIS" -ForegroundColor Green
Write-Host ""
Write-Host "Or run METIS manually without the service:" -ForegroundColor White
Write-Host "   cd $METIS_INSTALL_DIR" -ForegroundColor Green
Write-Host "   npm start" -ForegroundColor Green
Write-Host ""
Write-Host "MongoDB credentials are saved in:" -ForegroundColor White
Write-Host "   $CREDENTIALS_FILE" -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Cyan

# NOTES
# - This script requires Administrator privileges to run
# - Uses Chocolatey package manager for installing dependencies
# - Uses NSSM (Non-Sucking Service Manager) to create Windows services
# - MongoDB configuration path may vary depending on installation
# - Firewall rules may need to be configured manually for external access
