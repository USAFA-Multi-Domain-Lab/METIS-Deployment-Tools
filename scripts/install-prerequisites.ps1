# METIS Prerequisites Installer Script
# Downloads and installs Node.js and MongoDB if needed

param(
    [string]$ConfigFile = "$env:TEMP\installer-config.txt"
)

# Colors for output
$Green = "Green"
$Red = "Red"
$Yellow = "Yellow"

# Default versions
$NodeVersion = "20.17.0"
$MongoVersion = "8.0.4"

Write-Host "[METIS] Starting prerequisites installation..." -ForegroundColor $Green

# Read configuration
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match "^(.+)=(.+)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

$InstallNodeJS = $Config["INSTALL_NODEJS"] -eq "1"
$InstallMongoDB = $Config["INSTALL_MONGODB"] -eq "1"

# Function to check if a program is installed
function Test-ProgramInstalled {
    param([string]$ProgramName)
    
    try {
        $null = Get-Command $ProgramName -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Function to download file
function Download-File {
    param(
        [string]$Url,
        [string]$OutputPath
    )
    
    Write-Host "Downloading from: $Url" -ForegroundColor $Yellow
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutputPath -UseBasicParsing
        return $true
    }
    catch {
        Write-Host "Failed to download: $($_.Exception.Message)" -ForegroundColor $Red
        return $false
    }
}

# Install Node.js
if ($InstallNodeJS) {
    Write-Host "[METIS] Installing Node.js..." -ForegroundColor $Green
    
    if (Test-ProgramInstalled "node") {
        Write-Host "[METIS] Node.js is already installed. Skipping..." -ForegroundColor $Yellow
    }
    else {
        $NodeUrl = "https://nodejs.org/dist/v$NodeVersion/node-v$NodeVersion-x64.msi"
        $NodeMsi = "$env:TEMP\nodejs.msi"
        
        if (Download-File $NodeUrl $NodeMsi) {
            Write-Host "[METIS] Installing Node.js..." -ForegroundColor $Green
            
            # Install Node.js silently
            $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i", $NodeMsi, "/quiet", "/norestart" -Wait -PassThru
            
            if ($Process.ExitCode -eq 0) {
                Write-Host "[METIS] Node.js installed successfully." -ForegroundColor $Green
                
                # Refresh environment variables
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
            }
            else {
                Write-Host "[METIS] Node.js installation failed with exit code: $($Process.ExitCode)" -ForegroundColor $Red
                exit 1
            }
            
            # Clean up
            Remove-Item $NodeMsi -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "[METIS] Failed to download Node.js installer." -ForegroundColor $Red
            exit 1
        }
    }
}

# Install MongoDB
if ($InstallMongoDB) {
    Write-Host "[METIS] Installing MongoDB..." -ForegroundColor $Green
    
    if (Test-Path "C:\Program Files\MongoDB\Server\*\bin\mongod.exe") {
        Write-Host "[METIS] MongoDB is already installed. Skipping..." -ForegroundColor $Yellow
    }
    else {
        $MongoUrl = "https://fastdl.mongodb.org/windows/mongodb-windows-x86_64-$MongoVersion-signed.msi"
        $MongoMsi = "$env:TEMP\mongodb.msi"
        
        if (Download-File $MongoUrl $MongoMsi) {
            Write-Host "[METIS] Installing MongoDB..." -ForegroundColor $Green
            
            # Install MongoDB with specific options
            $MongoArgs = @(
                "/i", $MongoMsi
                "/quiet"
                "/norestart"
                "INSTALLLOCATION=`"C:\Program Files\MongoDB\Server\$MongoVersion\`""
                "ADDLOCAL=ServerService,Client,MongoDBCompass"
            )
            
            $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $MongoArgs -Wait -PassThru
            
            if ($Process.ExitCode -eq 0) {
                Write-Host "[METIS] MongoDB installed successfully." -ForegroundColor $Green
            }
            else {
                Write-Host "[METIS] MongoDB installation failed with exit code: $($Process.ExitCode)" -ForegroundColor $Red
                exit 1
            }
            
            # Clean up
            Remove-Item $MongoMsi -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "[METIS] Failed to download MongoDB installer." -ForegroundColor $Red
            exit 1
        }
    }
}

Write-Host "[METIS] Prerequisites installation completed." -ForegroundColor $Green