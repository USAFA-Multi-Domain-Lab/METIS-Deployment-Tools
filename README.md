# METIS-Deployment-Tools

ALL RIGHTS RESERVED

## Installation Options

METIS can be installed on both Ubuntu and Windows systems with automated installers.

### Ubuntu 24 Installation

Run this command on a fresh Ubuntu 24 install to set up METIS:

```bash
curl -o /tmp/ubuntu-24-installer.sh https://raw.githubusercontent.com/USAFA-Multi-Domain-Lab/METIS-Deployment-Tools/master/ubuntu-24-installer.sh && chmod +x /tmp/ubuntu-24-installer.sh && sudo /tmp/ubuntu-24-installer.sh && rm /tmp/ubuntu-24-installer.sh
```

Once complete, METIS will be set up as a service and will start automatically on boot. You can control the METIS server using the following commands:

```bash
sudo systemctl start metis.service
sudo systemctl stop metis.service
sudo systemctl restart metis.service
sudo systemctl status metis.service
```

### Windows Installation

For Windows systems, we provide a GUI installer built with Inno Setup that mirrors the Ubuntu installation functionality.

#### Quick Install

1. Download the `METIS-Installer.exe` from the releases
2. Run as Administrator
3. Follow the GUI prompts
4. METIS will be installed and configured as a Windows service

#### Building the Windows Installer

If you need to build the installer yourself:

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php)
2. Run the build script:
   ```cmd
   build-installer.bat
   ```
   Or use PowerShell:
   ```powershell
   .\Build-Installer.ps1
   ```

#### Windows Service Management

After installation, control METIS using:

```cmd
# Start service
net start METIS

# Stop service
net stop METIS

# Check status
sc query METIS
```

Or use the provided batch scripts in `C:\Program Files\METIS\scripts\`:

- `start-metis.bat`
- `stop-metis.bat`
- `status-metis.bat`

For detailed Windows installation information, see [README-Windows.md](README-Windows.md).
