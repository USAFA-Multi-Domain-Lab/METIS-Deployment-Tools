# METIS Windows Installer Build Script (PowerShell)
# This script builds the METIS Windows installer using Inno Setup

param(
    [switch]$Clean,
    [switch]$Test
)

$Green = "Green"
$Red = "Red"  
$Yellow = "Yellow"

Write-Host "[METIS] Building Windows Installer..." -ForegroundColor $Green

# Check for Inno Setup installation
$InnoSetupPaths = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 5\ISCC.exe",
    "${env:ProgramFiles}\Inno Setup 5\ISCC.exe"
)

$InnoSetupPath = $null
foreach ($Path in $InnoSetupPaths) {
    if (Test-Path $Path) {
        $InnoSetupPath = $Path
        break
    }
}

if (-not $InnoSetupPath) {
    Write-Host "[ERROR] Inno Setup not found. Please install from: https://jrsoftware.org/isdl.php" -ForegroundColor $Red
    Write-Host "Expected locations:" -ForegroundColor $Yellow
    foreach ($Path in $InnoSetupPaths) {
        Write-Host "  $Path" -ForegroundColor $Yellow
    }
    exit 1
}

Write-Host "[METIS] Found Inno Setup at: $InnoSetupPath" -ForegroundColor $Green

# Clean previous build if requested
if ($Clean -and (Test-Path "output")) {
    Write-Host "[METIS] Cleaning previous build..." -ForegroundColor $Yellow
    Remove-Item "output" -Recurse -Force
}

# Create output directory if it doesn't exist
if (-not (Test-Path "output")) {
    New-Item -ItemType Directory -Path "output" | Out-Null
}

# Check if the main installer script exists
if (-not (Test-Path "windows-installer.iss")) {
    Write-Host "[ERROR] windows-installer.iss not found in current directory" -ForegroundColor $Red
    exit 1
}

# Validate PowerShell scripts exist
$RequiredScripts = @(
    "scripts\install-prerequisites.ps1",
    "scripts\setup-mongodb.ps1", 
    "scripts\setup-metis.ps1",
    "scripts\create-service.ps1"
)

$MissingScripts = @()
foreach ($Script in $RequiredScripts) {
    if (-not (Test-Path $Script)) {
        $MissingScripts += $Script
    }
}

if ($MissingScripts.Count -gt 0) {
    Write-Host "[ERROR] Missing required PowerShell scripts:" -ForegroundColor $Red
    foreach ($Script in $MissingScripts) {
        Write-Host "  $Script" -ForegroundColor $Red
    }
    exit 1
}

Write-Host "[METIS] All required scripts found." -ForegroundColor $Green

# Build the installer
Write-Host "[METIS] Compiling installer..." -ForegroundColor $Green

try {
    $Process = Start-Process -FilePath $InnoSetupPath -ArgumentList "windows-installer.iss" -Wait -PassThru -NoNewWindow
    
    if ($Process.ExitCode -eq 0) {
        Write-Host "[METIS] Installer built successfully!" -ForegroundColor $Green
        
        $InstallerPath = "output\METIS-Installer.exe"
        if (Test-Path $InstallerPath) {
            $FileInfo = Get-Item $InstallerPath
            Write-Host "[METIS] Output location: $InstallerPath" -ForegroundColor $Green
            Write-Host "[METIS] File size: $([math]::Round($FileInfo.Length / 1MB, 2)) MB" -ForegroundColor $Green
            Write-Host "[METIS] Created: $($FileInfo.CreationTime)" -ForegroundColor $Green
            
            # Test installer if requested
            if ($Test) {
                Write-Host "[METIS] Running installer validation..." -ForegroundColor $Yellow
                # You could add installer validation logic here
                Write-Host "[METIS] Manual testing recommended on a clean Windows system." -ForegroundColor $Yellow
            }
            
            Write-Host ""
            Write-Host "[METIS] Next steps for distribution:" -ForegroundColor $Green
            Write-Host "  1. Test the installer on a clean Windows system" -ForegroundColor $Yellow
            Write-Host "  2. Consider code signing for production deployment" -ForegroundColor $Yellow
            Write-Host "  3. Upload to your distribution server or repository" -ForegroundColor $Yellow
            Write-Host ""
        }
        else {
            Write-Host "[WARNING] Installer file not found at expected location: $InstallerPath" -ForegroundColor $Yellow
        }
    }
    else {
        Write-Host "[ERROR] Failed to build installer. Exit code: $($Process.ExitCode)" -ForegroundColor $Red
        Write-Host "Check the Inno Setup output for detailed error information." -ForegroundColor $Yellow
        exit 1
    }
}
catch {
    Write-Host "[ERROR] Failed to run Inno Setup: $($_.Exception.Message)" -ForegroundColor $Red
    exit 1
}

Write-Host "[METIS] Build process completed." -ForegroundColor $Green