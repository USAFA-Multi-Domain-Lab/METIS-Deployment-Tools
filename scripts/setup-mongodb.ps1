# METIS MongoDB Setup Script
# Configures MongoDB with authentication and creates users

param(
    [string]$ConfigFile = "$env:TEMP\installer-config.txt"
)

# Colors for output
$Green = "Green"
$Red = "Red"
$Yellow = "Yellow"

Write-Host "[METIS] Starting MongoDB configuration..." -ForegroundColor $Green

# Read configuration
$Config = @{}
if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match "^(.+)=(.+)$") {
            $Config[$matches[1]] = $matches[2]
        }
    }
}

# Generate random credentials if not provided
function New-RandomString {
    param([int]$Length = 12)
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    $random = 1..$Length | ForEach-Object { Get-Random -Maximum $chars.Length }
    return -join ($random | ForEach-Object { $chars[$_] })
}

function New-RandomPassword {
    return [System.Web.Security.Membership]::GeneratePassword(16, 4)
}

# Load or generate credentials
$AdminUser = $Config["MONGO_ADMIN_USER"]
$AdminPass = $Config["MONGO_ADMIN_PASS"]
$MetisUser = $Config["METIS_DB_USER"]
$MetisPass = $Config["METIS_DB_PASS"]

if ([string]::IsNullOrEmpty($AdminUser)) {
    $AdminUser = "admin_" + (New-RandomString -Length 8)
}
if ([string]::IsNullOrEmpty($AdminPass)) {
    $AdminPass = New-RandomPassword
}
if ([string]::IsNullOrEmpty($MetisUser)) {
    $MetisUser = "metis_" + (New-RandomString -Length 8)
}
if ([string]::IsNullOrEmpty($MetisPass)) {
    $MetisPass = New-RandomPassword
}

Write-Host "[METIS] Using admin user: $AdminUser" -ForegroundColor $Yellow

# Find MongoDB installation
$MongoPath = Get-ChildItem "C:\Program Files\MongoDB\Server\*\bin\mongod.exe" | Select-Object -First 1
if (-not $MongoPath) {
    Write-Host "[METIS] MongoDB installation not found." -ForegroundColor $Red
    exit 1
}

$MongoBinPath = Split-Path $MongoPath.FullName -Parent
$MongoDataPath = "C:\Program Files\MongoDB\Server\data"
$MongoLogPath = "C:\Program Files\MongoDB\Server\logs"
$MongoConfigPath = "C:\Program Files\MongoDB\Server\mongod.cfg"

# Create data and log directories
if (-not (Test-Path $MongoDataPath)) {
    New-Item -ItemType Directory -Path $MongoDataPath -Force | Out-Null
}
if (-not (Test-Path $MongoLogPath)) {
    New-Item -ItemType Directory -Path $MongoLogPath -Force | Out-Null
}

# Create MongoDB configuration file
$MongoConfig = @"
systemLog:
  destination: file
  path: $MongoLogPath\mongod.log
  logAppend: true
storage:
  dbPath: $MongoDataPath
net:
  bindIp: 0.0.0.0
  port: 27017
security:
  authorization: enabled
"@

Set-Content -Path $MongoConfigPath -Value $MongoConfig -Encoding UTF8

Write-Host "[METIS] MongoDB configuration file created." -ForegroundColor $Green

# Stop MongoDB service if running
try {
    Stop-Service -Name "MongoDB" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}
catch {
    Write-Host "[METIS] MongoDB service was not running." -ForegroundColor $Yellow
}

# Start MongoDB without authentication to create initial users
Write-Host "[METIS] Starting MongoDB without authentication..." -ForegroundColor $Green

$MongoProcess = Start-Process -FilePath "$MongoBinPath\mongod.exe" -ArgumentList "--config", $MongoConfigPath, "--noauth" -PassThru
Start-Sleep -Seconds 5

try {
    # Wait for MongoDB to be ready
    $retries = 0
    do {
        Start-Sleep -Seconds 2
        $retries++
        try {
            & "$MongoBinPath\mongosh.exe" --eval "db.runCommand({connectionStatus: 1})" --quiet | Out-Null
            $connected = $true
            break
        }
        catch {
            $connected = $false
        }
    } while ($retries -lt 10 -and -not $connected)

    if (-not $connected) {
        Write-Host "[METIS] Failed to connect to MongoDB after 20 seconds." -ForegroundColor $Red
        exit 1
    }

    Write-Host "[METIS] Creating MongoDB admin user..." -ForegroundColor $Green

    # Create admin user
    $CreateAdminScript = @"
use admin
db.createUser({
  user: "$AdminUser",
  pwd: "$AdminPass",
  roles: [
    { role: "userAdminAnyDatabase", db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" }
  ]
})
"@

    $CreateAdminScript | & "$MongoBinPath\mongosh.exe" --quiet

    Write-Host "[METIS] Admin user created successfully." -ForegroundColor $Green
}
finally {
    # Stop the temporary MongoDB process
    if ($MongoProcess -and -not $MongoProcess.HasExited) {
        $MongoProcess.Kill()
        $MongoProcess.WaitForExit(5000)
    }
}

# Start MongoDB with authentication
Write-Host "[METIS] Starting MongoDB with authentication..." -ForegroundColor $Green
$MongoProcess = Start-Process -FilePath "$MongoBinPath\mongod.exe" -ArgumentList "--config", $MongoConfigPath -PassThru
Start-Sleep -Seconds 5

try {
    # Wait for MongoDB to be ready
    $retries = 0
    do {
        Start-Sleep -Seconds 2
        $retries++
        try {
            & "$MongoBinPath\mongosh.exe" -u $AdminUser -p $AdminPass --authenticationDatabase admin --eval "db.runCommand({connectionStatus: 1})" --quiet | Out-Null
            $connected = $true
            break
        }
        catch {
            $connected = $false
        }
    } while ($retries -lt 10 -and -not $connected)

    if (-not $connected) {
        Write-Host "[METIS] Failed to connect to MongoDB with authentication after 20 seconds." -ForegroundColor $Red
        exit 1
    }

    Write-Host "[METIS] Creating METIS database user..." -ForegroundColor $Green

    # Create METIS database user
    $CreateMetisScript = @"
use metis
db.createUser({
  user: "$MetisUser",
  pwd: "$MetisPass",
  roles: [ { role: "readWrite", db: "metis" } ]
})
"@

    $CreateMetisScript | & "$MongoBinPath\mongosh.exe" -u $AdminUser -p $AdminPass --authenticationDatabase admin --quiet

    Write-Host "[METIS] METIS database user created successfully." -ForegroundColor $Green
}
finally {
    # Stop the temporary MongoDB process
    if ($MongoProcess -and -not $MongoProcess.HasExited) {
        $MongoProcess.Kill()
        $MongoProcess.WaitForExit(5000)
    }
}

# Install MongoDB as Windows service
Write-Host "[METIS] Installing MongoDB as Windows service..." -ForegroundColor $Green

& "$MongoBinPath\mongod.exe" --config $MongoConfigPath --install --serviceName "MongoDB"

# Start MongoDB service
Start-Service -Name "MongoDB"
Set-Service -Name "MongoDB" -StartupType Automatic

Write-Host "[METIS] MongoDB service installed and started." -ForegroundColor $Green

# Save credentials
$CredentialsFile = "C:\ProgramData\METIS\credentials.txt"
$CredentialsDir = Split-Path $CredentialsFile -Parent

if (-not (Test-Path $CredentialsDir)) {
    New-Item -ItemType Directory -Path $CredentialsDir -Force | Out-Null
}

$CredentialsContent = @"
MongoDB Admin Username: $AdminUser
MongoDB Admin Password: $AdminPass
MongoDB Web Username: $MetisUser
MongoDB Web Password: $MetisPass
"@

Set-Content -Path $CredentialsFile -Value $CredentialsContent -Encoding UTF8

# Set restrictive permissions on credentials file
$Acl = Get-Acl $CredentialsFile
$Acl.SetAccessRuleProtection($true, $false)  # Remove inherited permissions
$AdminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
$Acl.SetAccessRule($AdminRule)
Set-Acl -Path $CredentialsFile -AclObject $Acl

Write-Host "[METIS] Credentials saved to $CredentialsFile" -ForegroundColor $Green
Write-Host "[METIS] MongoDB setup completed." -ForegroundColor $Green