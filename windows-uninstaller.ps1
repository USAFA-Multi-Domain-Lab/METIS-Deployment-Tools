# METIS Uninstall Script for Windows
# This script removes METIS and its associated components.

# Requires Administrator privileges
#Requires -RunAsAdministrator

$ErrorActionPreference = "Continue"

# Colors for output
function Write-Success      { Write-Host "[METIS] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Green }
function Write-MetisError   { Write-Host "[METIS][ERROR] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Red }
function Write-MetisWarning { Write-Host "[METIS][WARN] $($args -replace '^\[METIS\](\[WARN\]|\[ERROR\])?\s*','')" -ForegroundColor Yellow }

# Paths
$METIS_INSTALL_DIR = "C:\Program Files\METIS"
$CREDENTIALS_FILE  = "$env:PROGRAMDATA\.metis-credentials.txt"
$SERVICE_DATA_DIR  = "$env:PROGRAMDATA\METIS"
$CLI_WRAPPER       = "C:\Windows\System32\metis.bat"

# Global credential variables
$script:ADMIN_USER        = ""
$script:ADMIN_PASS        = ""
$script:METIS_USER        = ""
$script:METIS_PASS        = ""
$script:CREDENTIALS_PARSED    = $false
$script:MONGO_DROP_SUCCEEDED  = $false
$script:FAILED_STEPS          = [System.Collections.ArrayList]@()

# Reads MongoDB credentials from the credentials file before it is deleted.
# Sets $script:CREDENTIALS_PARSED to $true only if all four values are found.
function Read-METISCredentials {
    if (-not (Test-Path $CREDENTIALS_FILE)) {
        Write-MetisWarning "Credentials file not found at $CREDENTIALS_FILE. MongoDB user removal will be skipped."
        return
    }

    Write-Success "Reading credentials from $CREDENTIALS_FILE..."
    $credentials = Get-Content $CREDENTIALS_FILE

    $script:ADMIN_USER = ($credentials | Select-String "MongoDB Admin Username:" | ForEach-Object { $_ -replace "MongoDB Admin Username: ", "" }).Trim()
    $script:ADMIN_PASS = ($credentials | Select-String "MongoDB Admin Password:" | ForEach-Object { $_ -replace "MongoDB Admin Password: ", "" }).Trim()
    $script:METIS_USER = ($credentials | Select-String "MongoDB Web Username:"   | ForEach-Object { $_ -replace "MongoDB Web Username: ",   "" }).Trim()
    $script:METIS_PASS = ($credentials | Select-String "MongoDB Web Password:"   | ForEach-Object { $_ -replace "MongoDB Web Password: ",   "" }).Trim()

    if (-not $script:ADMIN_USER -or -not $script:ADMIN_PASS -or -not $script:METIS_USER -or -not $script:METIS_PASS) {
        Write-MetisWarning "Credentials file exists but could not be fully parsed. Expected format:"
        Write-Host "   MongoDB Admin Username: <value>" -ForegroundColor Yellow
        Write-Host "   MongoDB Admin Password: <value>" -ForegroundColor Yellow
        Write-Host "   MongoDB Web Username: <value>"   -ForegroundColor Yellow
        Write-Host "   MongoDB Web Password: <value>"   -ForegroundColor Yellow
        Write-Host ""
        Write-MetisWarning "The MongoDB user and database will not be removed automatically."
        Write-Host "To remove them manually, connect to mongosh and run:" -ForegroundColor White
        Write-Host "   use metis"                    -ForegroundColor Cyan
        Write-Host "   db.dropUser(`"<metis_user>`")" -ForegroundColor Cyan
        Write-Host "   db.dropDatabase()"            -ForegroundColor Cyan
        return
    }

    $script:CREDENTIALS_PARSED = $true
    Write-Success "Credentials loaded."
}

# Stops and removes the NSSM METIS Windows service.
function Remove-METISService {
    Write-Success "Removing METIS service..."

    $service = Get-Service -Name "METIS" -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-MetisWarning "METIS service not found. Skipping..."
        return
    }

    if ($service.Status -eq 'Running') {
        try {
            Stop-Service -Name "METIS" -Force -ErrorAction Stop
            Write-Success "METIS service stopped."
        } catch {
            Write-MetisWarning "Could not stop METIS service: $_"
        }
    }

    try {
        if (Get-Command nssm -ErrorAction SilentlyContinue) {
            & nssm remove METIS confirm
            Write-Success "METIS service removed."
        } else {
            # Fallback if NSSM is no longer on PATH
            & sc.exe delete METIS | Out-Null
            Write-Success "METIS service removed via sc.exe."
        }
    } catch {
        Write-MetisError "Service removal failed: $_"
        $null = $script:FAILED_STEPS.Add(@{
            Step      = "METIS service removal"
            NextSteps = "Kill any running METIS processes, then run: sc.exe delete METIS"
        })
    }
}

# Drops the METIS MongoDB user and database using saved admin credentials.
function Remove-METISMongoUser {
    if (-not $script:CREDENTIALS_PARSED) {
        Write-MetisWarning "Skipping MongoDB user removal (credentials unavailable or unparseable)."
        return
    }

    if (-not (Get-Command mongosh -ErrorAction SilentlyContinue)) {
        Write-MetisWarning "mongosh not found. Skipping MongoDB user removal."
        return
    }

    Write-Success "Removing METIS MongoDB user and database..."

    $dropScript = @"
use metis
try { db.dropUser("$($script:METIS_USER)") } catch(e) {}
db.getCollectionNames().forEach(function(c) { db.getCollection(c).drop() })
use admin
try { db.dropUser("$($script:ADMIN_USER)") } catch(e) {}
"@

    try {
        $output = $dropScript | & mongosh -u "$($script:ADMIN_USER)" -p "$($script:ADMIN_PASS)" --authenticationDatabase admin 2>&1
        if ($output -match "MongoServerError") {
            Write-MetisWarning "MongoDB reported an error during removal. The user or database may have already been removed."
            Write-Host "       MongoDB output:" -ForegroundColor Yellow
            $output | Where-Object { $_ -match "MongoServerError" } | ForEach-Object { Write-Host "       $_" -ForegroundColor Yellow }
        } else {
            Write-Success "METIS MongoDB user and database removed."
            $script:MONGO_DROP_SUCCEEDED = $true
        }
    } catch {
        Write-MetisWarning "Failed to remove MongoDB user/database: $_"
        $null = $script:FAILED_STEPS.Add(@{
            Step      = "MongoDB user/database removal"
            NextSteps = "Connect to mongosh and run: use metis / db.dropUser(`"`$(`$script:METIS_USER)`") / db.dropDatabase()"
        })
    }
}

# Deletes the METIS service data directory (logs, startup batch).
function Remove-METISFiles {
    Write-Success "Removing METIS service data directory..."
    if (Test-Path $SERVICE_DATA_DIR) {
        try {
            Remove-Item -Path $SERVICE_DATA_DIR -Recurse -Force
            Write-Success "Removed $SERVICE_DATA_DIR."
        } catch {
            Write-MetisWarning "Failed to remove ${SERVICE_DATA_DIR}: $_"
            $null = $script:FAILED_STEPS.Add(@{
                Step      = "METIS service data directory"
                NextSteps = "Manually delete: $SERVICE_DATA_DIR"
            })
        }
    } else {
        Write-MetisWarning "$SERVICE_DATA_DIR not found. Skipping..."
    }
}

# Deletes the saved MongoDB credentials file.
# Skipped if the MongoDB drop failed so credentials remain available for a retry.
function Remove-METISCredentials {
    if ($script:CREDENTIALS_PARSED -and -not $script:MONGO_DROP_SUCCEEDED) {
        Write-MetisWarning "Keeping credentials file at $CREDENTIALS_FILE because MongoDB user removal failed."
        Write-MetisWarning "Re-run this script to retry, or remove the user manually and then delete the file."
        $null = $script:FAILED_STEPS.Add(@{
            Step      = "METIS credentials file (retained)"
            NextSteps = "MongoDB user removal failed -- credentials kept for retry. Once resolved, manually delete: $CREDENTIALS_FILE"
        })
        return
    }
    Write-Success "Removing METIS credentials file..."
    if (Test-Path $CREDENTIALS_FILE) {
        try {
            Remove-Item -Path $CREDENTIALS_FILE -Force
            Write-Success "Removed $CREDENTIALS_FILE."
        } catch {
            Write-MetisError "Failed to remove ${CREDENTIALS_FILE}: $_"
            Write-MetisError "This file contains sensitive credentials and must be deleted manually."
            $null = $script:FAILED_STEPS.Add(@{
                Step      = "METIS credentials file"
                NextSteps = "This file contains sensitive credentials. Manually delete: $CREDENTIALS_FILE"
            })
        }
    } else {
        Write-MetisWarning "$CREDENTIALS_FILE not found. Skipping..."
    }
}

# Deletes the metis.bat CLI wrapper from System32.
function Remove-METISCLIWrapper {
    Write-Success "Removing METIS CLI wrapper..."
    if (Test-Path $CLI_WRAPPER) {
        try {
            Remove-Item -Path $CLI_WRAPPER -Force
            Write-Success "Removed $CLI_WRAPPER."
        } catch {
            Write-MetisWarning "Failed to remove ${CLI_WRAPPER}: $_"
            $null = $script:FAILED_STEPS.Add(@{
                Step      = "METIS CLI wrapper"
                NextSteps = "Manually delete: $CLI_WRAPPER"
            })
        }
    } else {
        Write-MetisWarning "$CLI_WRAPPER not found. Skipping..."
    }
}

# Deletes the METIS installation directory (last -- CLI lives here).
function Remove-METISInstallDir {
    Write-Success "Removing METIS installation directory..."
    if (Test-Path $METIS_INSTALL_DIR) {
        try {
            Remove-Item -Path $METIS_INSTALL_DIR -Recurse -Force
            Write-Success "Removed $METIS_INSTALL_DIR."
        } catch {
            Write-MetisError "Failed to remove ${METIS_INSTALL_DIR}: $_"
            $null = $script:FAILED_STEPS.Add(@{
                Step      = "METIS installation directory"
                NextSteps = "Manually delete: $METIS_INSTALL_DIR"
            })
        }
    } else {
        Write-MetisWarning "$METIS_INSTALL_DIR not found. Skipping..."
    }
}

# Uninstalls MongoDB via Chocolatey (optional).
function Invoke-MongoDBUninstall {
    Write-Success "Uninstalling MongoDB..."
    try {
        choco uninstall mongodb mongodb-shell mongodb-database-tools -y
        Write-Success "MongoDB uninstalled."
    } catch {
        Write-MetisWarning "MongoDB uninstall encountered an error: $_"
        $null = $script:FAILED_STEPS.Add(@{
            Step      = "MongoDB uninstall"
            NextSteps = "Run: choco uninstall mongodb mongodb-shell mongodb-database-tools -y"
        })
    }

    # Remove MongoDB data directory so a future reinstall starts clean.
    # Chocolatey only removes binaries; user/auth data in ProgramData persists otherwise.
    $mongoDataDir = "$env:PROGRAMDATA\MongoDB"
    if (Test-Path $mongoDataDir) {
        Write-Success "Removing MongoDB data directory ($mongoDataDir)..."
        try {
            Remove-Item -Path $mongoDataDir -Recurse -Force
            Write-Success "Removed $mongoDataDir."
        } catch {
            Write-MetisWarning "Failed to remove MongoDB data directory: $_"
            $null = $script:FAILED_STEPS.Add(@{
                Step      = "MongoDB data directory"
                NextSteps = "Manually delete: $mongoDataDir (contains auth data that will block a fresh reinstall)"
            })
        }
    }
}

# Uninstalls Node.js via Chocolatey (optional).
function Invoke-NodeJSUninstall {
    Write-Success "Uninstalling Node.js..."
    try {
        choco uninstall nodejs nodejs.install nodejs-lts -y --all-versions 2>&1 | Where-Object { $_ -notmatch "is not installed" } | Out-Null
        Write-Success "Node.js uninstalled."
    } catch {
        Write-MetisWarning "Node.js uninstall encountered an error: $_"
        $null = $script:FAILED_STEPS.Add(@{
            Step      = "Node.js uninstall"
            NextSteps = "Run: choco uninstall nodejs nodejs.install nodejs-lts -y --all-versions"
        })
    }
}

# Main execution
# ===============
Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "METIS Uninstaller"                               -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This will permanently remove:" -ForegroundColor White
Write-Host "   METIS Windows service"                -ForegroundColor Yellow
Write-Host "   METIS MongoDB user and database"      -ForegroundColor Yellow
Write-Host "   $SERVICE_DATA_DIR"                    -ForegroundColor Yellow
Write-Host "   $CREDENTIALS_FILE"                    -ForegroundColor Yellow
Write-Host "   $CLI_WRAPPER"                         -ForegroundColor Yellow
Write-Host "   $METIS_INSTALL_DIR"                   -ForegroundColor Yellow
Write-Host ""
Write-Host "MongoDB and Node.js will only be removed if you choose to below." -ForegroundColor White
Write-Host ""
Write-Host "This action is irreversible." -ForegroundColor Red
Write-Host ""

$confirm = Read-Host "Are you sure you want to uninstall METIS? (y/N)"
if ($confirm -ne 'y' -and $confirm -ne 'Y') {
    Write-MetisWarning "Uninstall cancelled."
    exit 0
}

Write-Host ""
Read-METISCredentials
Remove-METISService
Remove-METISMongoUser
Remove-METISFiles
Remove-METISCredentials
Remove-METISCLIWrapper
Remove-METISInstallDir

Write-Host ""

$removeMongo = Read-Host "Remove MongoDB (choco uninstall mongodb, mongodb-shell, mongodb-database-tools)? (y/N)"
if ($removeMongo -eq 'y' -or $removeMongo -eq 'Y') {
    Invoke-MongoDBUninstall
    Write-Host ""
}

$removeNode = Read-Host "Remove Node.js (choco uninstall nodejs)? (y/N)"
if ($removeNode -eq 'y' -or $removeNode -eq 'Y') {
    Invoke-NodeJSUninstall
    Write-Host ""
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

if ($script:FAILED_STEPS.Count -gt 0) {
    Write-MetisError "Uninstall completed with errors."
    Write-Host "The following steps failed and require manual action:" -ForegroundColor White
    Write-Host ""
    foreach ($failure in $script:FAILED_STEPS) {
        Write-Host "  [!] $($failure.Step)" -ForegroundColor Red
        Write-Host "      $($failure.NextSteps)" -ForegroundColor Yellow
        Write-Host ""
    }
} else {
    Write-Success "METIS has been successfully removed."
    Write-Host ""
}

Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

# NOTES
# - This script requires Administrator privileges to run
# - MongoDB and Node.js are left in place by default (may be used by other software)
# - If MongoDB credentials were manually changed after install, the DB user drop step will fail gracefully
