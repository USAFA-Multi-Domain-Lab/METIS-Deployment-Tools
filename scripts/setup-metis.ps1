# METIS Application Setup Script
# Downloads, installs, and configures the METIS application

param(
    [string]$InstallPath = "C:\Program Files\METIS",
    [string]$ConfigFile = "$env:TEMP\installer-config.txt"
)

# Colors for output
$Green = "Green"
$Red = "Red"
$Yellow = "Yellow"

Write-Host "[METIS] Starting METIS application setup..." -ForegroundColor $Green

# Read configuration
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match "^(.+)=(.+)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

# Ensure install directory exists
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

# Check if Git is available
$GitAvailable = $false
try {
    $null = Get-Command git -ErrorAction Stop
    $GitAvailable = $true
}
catch {
    Write-Host "[METIS] Git not found. Will attempt to download repository as ZIP." -ForegroundColor $Yellow
}

# Clone or download METIS repository
Write-Host "[METIS] Downloading METIS repository..." -ForegroundColor $Green

$RepoUrl = "https://github.com/salient-usafa-cyber-crew/metis"
$MetisPath = Join-Path $InstallPath "metis"

if ($GitAvailable) {
    try {
        # Clone with Git
        if (Test-Path $MetisPath) {
            Write-Host "[METIS] Existing METIS installation found. Updating..." -ForegroundColor $Yellow
            Set-Location $MetisPath
            & git pull origin main
        }
        else {
            & git clone $RepoUrl $MetisPath
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Git clone failed"
        }
    }
    catch {
        Write-Host "[METIS] Git clone failed: $($_.Exception.Message)" -ForegroundColor $Yellow
        Write-Host "[METIS] Falling back to ZIP download..." -ForegroundColor $Yellow
        $GitAvailable = $false
    }
}

if (-not $GitAvailable) {
    # Download as ZIP
    $ZipUrl = "$RepoUrl/archive/refs/heads/main.zip"
    $ZipPath = "$env:TEMP\metis-main.zip"
    
    try {
        Write-Host "[METIS] Downloading repository ZIP..." -ForegroundColor $Yellow
        Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
        
        # Extract ZIP
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $InstallPath)
        
        # Rename extracted folder
        $ExtractedPath = Join-Path $InstallPath "metis-main"
        if (Test-Path $ExtractedPath) {
            if (Test-Path $MetisPath) {
                Remove-Item $MetisPath -Recurse -Force
            }
            Rename-Item $ExtractedPath $MetisPath
        }
        
        # Clean up
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
        
        Write-Host "[METIS] Repository downloaded and extracted." -ForegroundColor $Green
    }
    catch {
        Write-Host "[METIS] Failed to download repository: $($_.Exception.Message)" -ForegroundColor $Red
        exit 1
    }
}

if (-not (Test-Path $MetisPath)) {
    Write-Host "[METIS] METIS repository not found at $MetisPath" -ForegroundColor $Red
    exit 1
}

# Set location to METIS directory
Set-Location $MetisPath

# Install Node.js dependencies
Write-Host "[METIS] Installing Node.js dependencies..." -ForegroundColor $Green

try {
    & npm install
    if ($LASTEXITCODE -ne 0) {
        throw "npm install failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "[METIS] Dependencies installed successfully." -ForegroundColor $Green
}
catch {
    Write-Host "[METIS] Failed to install dependencies: $($_.Exception.Message)" -ForegroundColor $Red
    exit 1
}

# Build the application
Write-Host "[METIS] Building METIS application..." -ForegroundColor $Green

try {
    & npm run build
    if ($LASTEXITCODE -ne 0) {
        throw "npm run build failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "[METIS] Application built successfully." -ForegroundColor $Green
}
catch {
    Write-Host "[METIS] Failed to build application: $($_.Exception.Message)" -ForegroundColor $Red
    exit 1
}

# Create configuration directory
$ConfigDir = Join-Path $MetisPath "config"
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
}

# Read MongoDB credentials
$CredentialsFile = "C:\ProgramData\METIS\credentials.txt"
$MetisUser = ""
$MetisPass = ""

if (Test-Path $CredentialsFile) {
    $Credentials = Get-Content $CredentialsFile
    foreach ($Line in $Credentials) {
        if ($Line -match "MongoDB Web Username: (.+)") {
            $MetisUser = $matches[1]
        }
        elseif ($Line -match "MongoDB Web Password: (.+)") {
            $MetisPass = $matches[1]
        }
    }
}

# Create production environment file
$ProdEnvFile = Join-Path $ConfigDir "prod.env"
$EnvContent = @"
MONGO_USERNAME=$MetisUser
MONGO_PASSWORD=$MetisPass
MONGO_HOST=localhost
MONGO_PORT=27017
MONGO_DATABASE=metis
NODE_ENV=production
"@

Set-Content -Path $ProdEnvFile -Value $EnvContent -Encoding UTF8

# Set restrictive permissions on environment file
$Acl = Get-Acl $ProdEnvFile
$Acl.SetAccessRuleProtection($true, $false)  # Remove inherited permissions
$AdminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
$SystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")
$Acl.SetAccessRule($AdminRule)
$Acl.SetAccessRule($SystemRule)
Set-Acl -Path $ProdEnvFile -AclObject $Acl

Write-Host "[METIS] Environment configuration saved to $ProdEnvFile" -ForegroundColor $Green

# Make CLI available (if applicable)
$CliScript = Join-Path $MetisPath "cli.sh"
if (Test-Path $CliScript) {
    # Create Windows batch wrapper for CLI
    $CliBatch = Join-Path $MetisPath "metis.bat"
    $BatchContent = "@echo off`nnode `"%~dp0cli.js`" %*"
    Set-Content -Path $CliBatch -Value $BatchContent -Encoding ASCII
    
    Write-Host "[METIS] CLI wrapper created at $CliBatch" -ForegroundColor $Green
}

Write-Host "[METIS] METIS application setup completed." -ForegroundColor $Green