# METIS-Deployment-Tools

This repository contains tools for deploying METIS on various platforms. It includes scripts for setting up the necessary infrastructure, configuring the environment, and installing the METIS web server. The official repository for METIS can be found [here](https://github.com/USAFA-Multi-Domain-Lab/METIS).

# Running Installer Scripts

Instructions for running the installer scripts can be found [here](https://github.com/USAFA-Multi-Domain-Lab/METIS/blob/master/docs/setup/index.md).

# Running Windows Tests

Tests for the Windows Installer and Uninstaller are written using [Pester](https://pester.dev/) and require PowerShell 7+ with the Pester module (v5.0+) installed.

Install Pester if needed:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Force
```

Run all tests from the repository root:

```powershell
pwsh ./tests/Run-Tests.ps1
```
