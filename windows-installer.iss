; METIS Windows Installer Script for Inno Setup
; This creates a GUI installer for METIS on Windows systems

#define MyAppName "METIS"
#define MyAppVersion "1.0"
#define MyAppPublisher "USAFA Multi-Domain Lab"
#define MyAppURL "https://github.com/USAFA-Multi-Domain-Lab"
#define MyAppExeName "node.exe"
#define MetisInstallDir "C:\Program Files\METIS"
#define NodeVersion "20.17.0"
#define MongoVersion "8.0.4"

[Setup]
; NOTE: The value of AppId uniquely identifies this application.
AppId={{12345678-1234-1234-1234-123456789ABC}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={#MetisInstallDir}
DisableProgramGroupPage=yes
LicenseFile=
OutputDir=output
OutputBaseFilename=METIS-Installer
SetupIconFile=
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "quicklaunchicon"; Description: "{cm:CreateQuickLaunchIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked; OnlyBelowVersion: 6.1

[Files]
; PowerShell setup scripts
Source: "scripts\setup-mongodb.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "scripts\setup-metis.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "scripts\create-service.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "scripts\install-prerequisites.ps1"; DestDir: "{tmp}"; Flags: deleteafterinstall

; NSSM for service creation
; NOTE: We no longer bundle NSSM to avoid compile-time dependency on a local file.
;       The create-service.ps1 script will download NSSM at install time if not present.

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Parameters: """{app}\server.js"""; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Parameters: """{app}\server.js"""; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Install prerequisites first
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{tmp}\install-prerequisites.ps1"""; StatusMsg: "Installing Node.js and MongoDB..."; Flags: runhidden waituntilterminated
; Setup MongoDB
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{tmp}\setup-mongodb.ps1"""; StatusMsg: "Configuring MongoDB..."; Flags: runhidden waituntilterminated
; Setup METIS application
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{tmp}\setup-metis.ps1"" -InstallPath ""{app}"""; StatusMsg: "Installing METIS application..."; Flags: runhidden waituntilterminated
; Create Windows service
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -File ""{tmp}\create-service.ps1"" -InstallPath ""{app}"""; StatusMsg: "Creating METIS service..."; Flags: runhidden waituntilterminated

[UninstallRun]
; Stop and remove the service
Filename: "sc.exe"; Parameters: "stop METIS"; RunOnceId: "StopService"; Flags: runhidden
Filename: "sc.exe"; Parameters: "delete METIS"; RunOnceId: "DeleteService"; Flags: runhidden

[Code]
var
  PrereqPage: TInputOptionWizardPage;
  MongoUserPage: TInputQueryWizardPage;
  
// Helper: convert common truthy strings to boolean
function StrToBoolEx(S: String): Boolean;
begin
  S := LowerCase(Trim(S));
  Result := (S = '1') or (S = 'true') or (S = 'yes') or (S = 'y');
end;

// Helper: boolean to '1' or '0'
function BoolTo01(B: Boolean): String;
begin
  if B then
    Result := '1'
  else
    Result := '0';
end;
  
function IsNodeJSInstalled(): Boolean;
var
  ResultCode: Integer;
begin
  Result := (Exec('cmd.exe', '/c node --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0));
end;

function IsMongoDBInstalled(): Boolean;
var
  ResultCode: Integer;
begin
  Result := (Exec('cmd.exe', '/c mongod --version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) and (ResultCode = 0));
end;

procedure InitializeWizard;
begin
  // Create a page for prerequisite options as checkboxes
  PrereqPage := CreateInputOptionPage(wpWelcome,
    'Prerequisites', 'Select required software',
    'METIS requires Node.js and MongoDB. The installer can download and install these for you.',
    False, False);

  PrereqPage.Add('Install Node.js (if not present)');
  PrereqPage.Add('Install MongoDB (if not present)');

  // Set default selections based on what's already installed
  PrereqPage.Values[0] := not IsNodeJSInstalled();
  PrereqPage.Values[1] := not IsMongoDBInstalled();

  // Create MongoDB user configuration page
  MongoUserPage := CreateInputQueryPage(PrereqPage.ID,
    'MongoDB Configuration', 'Database User Setup',
    'Configure MongoDB authentication. Leave fields empty to generate random credentials.');
    
  MongoUserPage.Add('MongoDB Admin Username (leave empty for random):', False);
  MongoUserPage.Add('MongoDB Admin Password (leave empty for random):', True);
  MongoUserPage.Add('METIS Database Username (leave empty for random):', False);
  MongoUserPage.Add('METIS Database Password (leave empty for random):', True);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  // Skip prerequisite page if both Node.js and MongoDB are already installed
  if (PageID = PrereqPage.ID) and IsNodeJSInstalled() and IsMongoDBInstalled() then
    Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigFile: String;
  AdminUser, AdminPass, MetisUser, MetisPass: String;
begin
  // Write configuration before [Run] executes
  if CurStep = ssInstall then
  begin
    // Save user preferences for PowerShell scripts
    ConfigFile := ExpandConstant('{tmp}\installer-config.txt');
    
    // Get MongoDB credentials (use random if empty)
    AdminUser := MongoUserPage.Values[0];
    AdminPass := MongoUserPage.Values[1];
    MetisUser := MongoUserPage.Values[2];
    MetisPass := MongoUserPage.Values[3];
    
    // Save configuration
    SaveStringToFile(ConfigFile, 'INSTALL_NODEJS=' + BoolTo01(PrereqPage.Values[0]) + #13#10, False);
    SaveStringToFile(ConfigFile, 'INSTALL_MONGODB=' + BoolTo01(PrereqPage.Values[1]) + #13#10, True);
    SaveStringToFile(ConfigFile, 'MONGO_ADMIN_USER=' + AdminUser + #13#10, True);
    SaveStringToFile(ConfigFile, 'MONGO_ADMIN_PASS=' + AdminPass + #13#10, True);
    SaveStringToFile(ConfigFile, 'METIS_DB_USER=' + MetisUser + #13#10, True);
    SaveStringToFile(ConfigFile, 'METIS_DB_PASS=' + MetisPass + #13#10, True);
    SaveStringToFile(ConfigFile, 'INSTALL_PATH=' + ExpandConstant('{app}') + #13#10, True);
  end;
end;