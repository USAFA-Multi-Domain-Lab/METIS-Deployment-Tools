# METIS Windows Service Creation Script
# Creates and configures METIS as a Windows service using NSSM

param(
    [string]$InstallPath = "C:\Program Files\METIS",
    [string]$ConfigFile = "$env:TEMP\installer-config.txt"
)

# Colors for output
$Green = "Green"
$Red = "Red"
$Yellow = "Yellow"

Write-Host "[METIS] Creating Windows service..." -ForegroundColor $Green

# Paths
$MetisPath = Join-Path $InstallPath "metis"
$NssmPath = Join-Path $InstallPath "bin\nssm.exe"
$ServiceName = "METIS"

# Check if NSSM exists
if (-not (Test-Path $NssmPath)) {
    Write-Host "[METIS] NSSM not found at $NssmPath" -ForegroundColor $Red
    
    # Try to download NSSM as fallback
    Write-Host "[METIS] Downloading NSSM..." -ForegroundColor $Yellow
    try {
        $NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
        $NssmZip = "$env:TEMP\nssm.zip"
        
        Invoke-WebRequest -Uri $NssmUrl -OutFile $NssmZip -UseBasicParsing
        
        # Extract NSSM
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($NssmZip, "$env:TEMP\nssm")
        
        # Copy NSSM executable
        $NssmBinDir = Join-Path $InstallPath "bin"
        if (-not (Test-Path $NssmBinDir)) {
            New-Item -ItemType Directory -Path $NssmBinDir -Force | Out-Null
        }
        
        $NssmExe = Get-ChildItem "$env:TEMP\nssm\nssm-*\win64\nssm.exe" | Select-Object -First 1
        if ($NssmExe) {
            Copy-Item $NssmExe.FullName $NssmPath -Force
            Write-Host "[METIS] NSSM downloaded and installed." -ForegroundColor $Green
        }
        else {
            throw "NSSM executable not found in downloaded package"
        }
        
        # Clean up
        Remove-Item $NssmZip -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\nssm" -Recurse -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "[METIS] Failed to download NSSM: $($_.Exception.Message)" -ForegroundColor $Red
        Write-Host "[METIS] Falling back to built-in service creation..." -ForegroundColor $Yellow
    }
}

# Find Node.js executable
$NodeExe = ""
try {
    $NodeExe = (Get-Command node).Source
    Write-Host "[METIS] Found Node.js at: $NodeExe" -ForegroundColor $Green
}
catch {
    # Try common installation paths
    $CommonPaths = @(
        "${env:ProgramFiles}\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "$env:APPDATA\npm\node.exe"
    )
    
    foreach ($Path in $CommonPaths) {
        if (Test-Path $Path) {
            $NodeExe = $Path
            Write-Host "[METIS] Found Node.js at: $NodeExe" -ForegroundColor $Green
            break
        }
    }
    
    if (-not $NodeExe) {
        Write-Host "[METIS] Node.js executable not found." -ForegroundColor $Red
        exit 1
    }
}

# Main server script path
$ServerScript = Join-Path $MetisPath "server.js"
if (-not (Test-Path $ServerScript)) {
    # Try alternative names
    $AlternativeScripts = @("app.js", "index.js", "main.js")
    foreach ($Script in $AlternativeScripts) {
        $TestPath = Join-Path $MetisPath $Script
        if (Test-Path $TestPath) {
            $ServerScript = $TestPath
            break
        }
    }
    
    if (-not (Test-Path $ServerScript)) {
        Write-Host "[METIS] Server script not found. Checked: server.js, app.js, index.js, main.js" -ForegroundColor $Red
        exit 1
    }
}

Write-Host "[METIS] Using server script: $ServerScript" -ForegroundColor $Green

# Remove existing service if it exists
$ExistingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($ExistingService) {
    Write-Host "[METIS] Stopping and removing existing service..." -ForegroundColor $Yellow
    
    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        
        if (Test-Path $NssmPath) {
            & $NssmPath remove $ServiceName confirm
        }
        else {
            # Use SC command
            & sc.exe delete $ServiceName | Out-Null
        }
        
        Start-Sleep -Seconds 2
        Write-Host "[METIS] Existing service removed." -ForegroundColor $Green
    }
    catch {
        Write-Host "[METIS] Warning: Could not remove existing service: $($_.Exception.Message)" -ForegroundColor $Yellow
    }
}

# Create the service
if (Test-Path $NssmPath) {
    Write-Host "[METIS] Creating service with NSSM..." -ForegroundColor $Green
    
    # Install service
    & $NssmPath install $ServiceName $NodeExe $ServerScript
    
    # Configure service
    & $NssmPath set $ServiceName AppDirectory $MetisPath
    & $NssmPath set $ServiceName DisplayName "METIS Web Service"
    & $NssmPath set $ServiceName Description "METIS Multi-Domain Cyber Range Management System"
    & $NssmPath set $ServiceName Start SERVICE_AUTO_START
    
    # Set environment variables
    & $NssmPath set $ServiceName AppEnvironmentExtra "NODE_ENV=production"
    
    # Configure logging
    $LogDir = Join-Path $MetisPath "logs"
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    
    & $NssmPath set $ServiceName AppStdout (Join-Path $LogDir "metis-service.log")
    & $NssmPath set $ServiceName AppStderr (Join-Path $LogDir "metis-error.log")
    & $NssmPath set $ServiceName AppRotateFiles 1
    & $NssmPath set $ServiceName AppRotateOnline 1
    & $NssmPath set $ServiceName AppRotateSeconds 86400  # Daily rotation
    & $NssmPath set $ServiceName AppRotateBytes 10485760  # 10MB max size
    
    Write-Host "[METIS] Service created with NSSM." -ForegroundColor $Green
}
else {
    # Fallback: Create service without NSSM (limited functionality)
    Write-Host "[METIS] Creating service with SC command..." -ForegroundColor $Yellow
    
    $ServiceCommand = "`"$NodeExe`" `"$ServerScript`""
    
    & sc.exe create $ServiceName binPath= $ServiceCommand start= auto DisplayName= "METIS Web Service"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[METIS] Service created with SC command." -ForegroundColor $Green
    }
    else {
        Write-Host "[METIS] Failed to create service with SC command." -ForegroundColor $Red
        exit 1
    }
}

# Set service recovery options
Write-Host "[METIS] Configuring service recovery options..." -ForegroundColor $Green

& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000

# Start the service
Write-Host "[METIS] Starting METIS service..." -ForegroundColor $Green

try {
    Start-Service -Name $ServiceName
    Start-Sleep -Seconds 5
    
    $Service = Get-Service -Name $ServiceName
    if ($Service.Status -eq "Running") {
        Write-Host "[METIS] Service started successfully!" -ForegroundColor $Green
        Write-Host "[METIS] Service Status: $($Service.Status)" -ForegroundColor $Green
    }
    else {
        Write-Host "[METIS] Service Status: $($Service.Status)" -ForegroundColor $Yellow
        Write-Host "[METIS] Service may take a moment to fully start." -ForegroundColor $Yellow
    }
}
catch {
    Write-Host "[METIS] Warning: Could not start service immediately: $($_.Exception.Message)" -ForegroundColor $Yellow
    Write-Host "[METIS] Service can be started manually using: Start-Service -Name $ServiceName" -ForegroundColor $Yellow
}

# Create service management scripts
$ScriptsDir = Join-Path $InstallPath "scripts"
if (-not (Test-Path $ScriptsDir)) {
    New-Item -ItemType Directory -Path $ScriptsDir -Force | Out-Null
}

# Start service script
$StartScript = @"
@echo off
echo Starting METIS service...
net start $ServiceName
if %errorlevel% == 0 (
    echo METIS service started successfully.
) else (
    echo Failed to start METIS service.
)
pause
"@
Set-Content -Path (Join-Path $ScriptsDir "start-metis.bat") -Value $StartScript -Encoding ASCII

# Stop service script
$StopScript = @"
@echo off
echo Stopping METIS service...
net stop $ServiceName
if %errorlevel% == 0 (
    echo METIS service stopped successfully.
) else (
    echo Failed to stop METIS service.
)
pause
"@
Set-Content -Path (Join-Path $ScriptsDir "stop-metis.bat") -Value $StopScript -Encoding ASCII

# Status service script
$StatusScript = @"
@echo off
echo METIS service status:
sc query $ServiceName
pause
"@
Set-Content -Path (Join-Path $ScriptsDir "status-metis.bat") -Value $StatusScript -Encoding ASCII

Write-Host "[METIS] Service management scripts created in $ScriptsDir" -ForegroundColor $Green
Write-Host "[METIS] Windows service creation completed!" -ForegroundColor $Green

# Display final information
Write-Host "" -ForegroundColor $Green
Write-Host "=== METIS Service Information ===" -ForegroundColor $Green
Write-Host "Service Name: $ServiceName" -ForegroundColor $Yellow
Write-Host "Installation Path: $MetisPath" -ForegroundColor $Yellow
Write-Host "Service Management Scripts: $ScriptsDir" -ForegroundColor $Yellow
Write-Host "" -ForegroundColor $Green
Write-Host "To manage the service:" -ForegroundColor $Green
Write-Host "  Start:   net start $ServiceName" -ForegroundColor $Yellow
Write-Host "  Stop:    net stop $ServiceName" -ForegroundColor $Yellow
Write-Host "  Status:  sc query $ServiceName" -ForegroundColor $Yellow