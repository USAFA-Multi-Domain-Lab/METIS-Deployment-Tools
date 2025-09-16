@echo off
REM METIS Windows Installer Build Script
REM This script builds the METIS Windows installer using Inno Setup

setlocal enabledelayedexpansion

echo [METIS] Building Windows Installer...

REM Check for Inno Setup installation
set "INNO_PATH=%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe"
if not exist "%INNO_PATH%" (
    set "INNO_PATH=%ProgramFiles%\Inno Setup 6\ISCC.exe"
)

if not exist "%INNO_PATH%" (
    echo [ERROR] Inno Setup 6 not found. Please install from: https://jrsoftware.org/isdl.php
    echo Expected location: %ProgramFiles(x86)%\Inno Setup 6\ISCC.exe
    pause
    exit /b 1
)

echo [METIS] Found Inno Setup at: %INNO_PATH%

REM Create output directory if it doesn't exist
if not exist "output" mkdir output

REM Check if the main installer script exists
if not exist "windows-installer.iss" (
    echo [ERROR] windows-installer.iss not found in current directory
    pause
    exit /b 1
)

REM Build the installer
echo [METIS] Compiling installer...
"%INNO_PATH%" "windows-installer.iss"

if %errorlevel% equ 0 (
    echo [METIS] Installer built successfully!
    echo [METIS] Output location: output\METIS-Installer.exe
    
    REM Show file size and creation time
    for %%A in ("output\METIS-Installer.exe") do (
        echo [METIS] File size: %%~zA bytes
        echo [METIS] Created: %%~tA
    )
    
    echo.
    echo [METIS] To distribute the installer:
    echo   1. Test the installer on a clean Windows system
    echo   2. Consider code signing for production deployment
    echo   3. Upload to your distribution server or repository
    echo.
) else (
    echo [ERROR] Failed to build installer. Check the Inno Setup output for errors.
    pause
    exit /b 1
)

echo [METIS] Build process completed.
pause