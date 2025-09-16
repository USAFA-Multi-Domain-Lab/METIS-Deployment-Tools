# METIS Windows Installer

This directory contains the Windows installer for METIS using Inno Setup, which provides a professional GUI installation experience equivalent to the Ubuntu installer script.

## Prerequisites

1. **Inno Setup 6.0 or later** - Download from [https://jrsoftware.org/isdl.php](https://jrsoftware.org/isdl.php)
2. **Windows 10/11** (64-bit recommended)
3. **Administrator privileges** for installation
4. **Internet connection** for downloading Node.js and MongoDB during installation

## What Gets Installed

The Windows installer automatically handles:

- **Node.js 20.17.0** (if not already installed)
- **MongoDB Community Server 8.0.4** (if not already installed)
- **METIS Application** (cloned from Git repository)
- **Windows Service** configuration for automatic startup
- **Database users** with secure random credentials
- **Configuration files** for production environment

## Building the Installer

### Method 1: Using Inno Setup IDE (Recommended)

1. Install Inno Setup from the official website
2. Open `windows-installer.iss` in the Inno Setup IDE
3. Click **Build** > **Compile** or press **F9**
4. The installer will be created in the `output/` directory

### Method 2: Command Line Build

```cmd
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows-installer.iss
```

### Method 3: PowerShell Build Script

```powershell
# Build the installer
$InnoSetupPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (Test-Path $InnoSetupPath) {
    & $InnoSetupPath "windows-installer.iss"
} else {
    Write-Host "Inno Setup not found. Please install Inno Setup 6." -ForegroundColor Red
}
```

## Directory Structure

```
METIS-Deployment-Tools/
├── ubuntu-24-installer.sh          # Original Ubuntu installer
├── windows-installer.iss           # Main Inno Setup script
├── scripts/                        # PowerShell installation scripts
│   ├── install-prerequisites.ps1   # Downloads Node.js and MongoDB
│   ├── setup-mongodb.ps1          # Configures MongoDB with auth
│   ├── setup-metis.ps1            # Installs METIS application
│   └── create-service.ps1          # Creates Windows service
├── bin/                            # Utilities (NSSM will be downloaded)
├── output/                         # Generated installer (created after build)
└── README-Windows.md               # This file
```

## Installation Process

1. **Run the installer** as Administrator (`METIS-Installer.exe`)
2. **Prerequisites Check** - Choose which components to install
3. **MongoDB Configuration** - Enter custom credentials or use auto-generated ones
4. **Installation** - Automatic download and setup of all components
5. **Service Creation** - METIS is configured as a Windows service
6. **Completion** - Service starts automatically

## Post-Installation

### Service Management

The installer creates batch scripts for easy service management:

```cmd
# Navigate to installation directory
cd "C:\Program Files\METIS\scripts"

# Start METIS service
start-metis.bat

# Stop METIS service
stop-metis.bat

# Check service status
status-metis.bat
```

### Using Windows Services Manager

1. Press **Win+R**, type `services.msc`, press Enter
2. Find **METIS** service
3. Right-click to Start/Stop/Restart

### Command Line Service Control

```cmd
# Start service
net start METIS

# Stop service
net stop METIS

# Check status
sc query METIS
```

### Credentials Location

Database credentials are securely stored at:

```
C:\ProgramData\METIS\credentials.txt
```

This file is only accessible by Administrators.

## Configuration Files

### MongoDB Configuration

```
C:\Program Files\MongoDB\Server\mongod.cfg
```

### METIS Environment Configuration

```
C:\Program Files\METIS\metis\config\prod.env
```

## Accessing METIS

After installation, METIS will be available at:

- **Web Interface**: `http://localhost:3000` (or configured port)
- **Service runs automatically** on system startup

## Troubleshooting

### Installation Issues

1. **Run as Administrator** - The installer requires admin privileges
2. **Check Windows Defender** - May need to allow the installer
3. **Firewall Settings** - Ensure ports are open for MongoDB (27017) and METIS web server
4. **Antivirus Software** - May interfere with downloads or service creation

### Service Issues

1. **Check Service Status**:

   ```cmd
   sc query METIS
   ```

2. **View Service Logs**:

   ```
   C:\Program Files\METIS\metis\logs\metis-service.log
   C:\Program Files\METIS\metis\logs\metis-error.log
   ```

3. **Restart Service**:
   ```cmd
   net stop METIS
   net start METIS
   ```

### MongoDB Issues

1. **Check MongoDB Service**:

   ```cmd
   sc query MongoDB
   ```

2. **Test Connection**:

   ```cmd
   "C:\Program Files\MongoDB\Server\8.0\bin\mongosh.exe" --eval "db.runCommand({connectionStatus: 1})"
   ```

3. **View MongoDB Logs**:
   ```
   C:\Program Files\MongoDB\Server\logs\mongod.log
   ```

## Uninstallation

1. Use **Windows Settings** > **Apps** > Find "METIS" > **Uninstall**
2. Or use the uninstaller in the Start Menu
3. The uninstaller will:
   - Stop the METIS service
   - Remove the Windows service
   - Remove application files
   - **Note**: MongoDB and Node.js are left installed for system stability

## Manual Cleanup (if needed)

If complete removal is desired:

```cmd
# Stop and remove METIS service
net stop METIS
sc delete METIS

# Remove application directory
rmdir /s "C:\Program Files\METIS"

# Remove configuration data
rmdir /s "C:\ProgramData\METIS"
```

## Security Considerations

- MongoDB is configured with authentication enabled
- Random passwords are generated for database users
- Credentials file has restricted permissions
- Service runs with appropriate Windows service account permissions
- Network binding allows external connections (modify `mongod.cfg` if needed)

## Customization

To modify the installer:

1. Edit `windows-installer.iss` for installer behavior
2. Modify PowerShell scripts in `scripts/` directory
3. Rebuild with Inno Setup

## Support

For issues specific to the Windows installer, check:

1. Windows Event Viewer for service errors
2. Log files in installation directory
3. MongoDB log files
4. Ensure all prerequisites are properly installed

---

**Note**: This installer is designed to mirror the functionality of the Ubuntu installer script while providing a native Windows installation experience with a GUI.
