#define AppName "Genreport"
#define AppVersion "1.0.0"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\Genreport
DefaultGroupName={#AppName}
OutputDir=dist
OutputBaseFilename=GenreportSetup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin

[Files]
Source: "publish\dotnet\*";         DestDir: "{app}\dotnet";         Flags: recursesubdirs
Source: "publish\goservice.exe";    DestDir: "{app}\go"
Source: "publish\web\*";            DestDir: "{app}\web";            Flags: recursesubdirs
Source: "publish\ollama\*";         DestDir: "{app}\ollama";         Flags: recursesubdirs
Source: "publish\rabbitmq\*";       DestDir: "{app}\rabbitmq";       Flags: recursesubdirs
Source: "publish\models\*";         DestDir: "{app}\ollama\models";  Flags: recursesubdirs
Source: "publish\launcher.exe";     DestDir: "{app}"
Source: "publish\configwriter.exe"; DestDir: "{app}"

[Icons]
Name: "{group}\{#AppName}";           Filename: "{app}\launcher.exe"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"

[Code]

// ── Page handles ──────────────────────────────────────────────────────────────
var
  PageDB:    TInputQueryWizardPage;
  PagePorts: TInputQueryWizardPage;
  PageSMTP:  TInputQueryWizardPage;
  PageR2:    TInputQueryWizardPage;

procedure InitializeWizard;
begin
  // Page 1 — Database
  PageDB := CreateInputQueryPage(wpSelectDir,
    'Database configuration',
    'Enter your PostgreSQL connection details.',
    'These will be written to appsettings.json and the Go .env file.');
  PageDB.Add('Host:',          False); PageDB.Values[0] := 'localhost';
  PageDB.Add('Port:',          False); PageDB.Values[1] := '5432';
  PageDB.Add('Database name:', False); PageDB.Values[2] := 'genreport';
  PageDB.Add('Username:',      False); PageDB.Values[3] := 'postgres';
  PageDB.Add('Password:',      True);  // masked field

  // Page 2 — Ports (shown with auto-detected defaults)
  PagePorts := CreateInputQueryPage(PageDB.ID,
    'Ports & dependencies',
    'Default ports shown. Change only if there are conflicts.',
    'The installer has checked for existing RabbitMQ and Ollama installations.');
  PagePorts.Add('.NET API port:',   False); PagePorts.Values[0] := '5000';
  PagePorts.Add('Go service port:', False); PagePorts.Values[1] := '12334';
  PagePorts.Add('RabbitMQ port:',   False); PagePorts.Values[2] := '5672';
  PagePorts.Add('Ollama port:',     False); PagePorts.Values[3] := '11434';

  // Page 3 — SMTP
  PageSMTP := CreateInputQueryPage(PagePorts.ID,
    'Email (SMTP)',
    'Outbound email settings. Leave blank to configure later.',
    'Used for notifications and password resets.');
  PageSMTP.Add('SMTP host:',    False); PageSMTP.Values[0] := '';
  PageSMTP.Add('Port:',         False); PageSMTP.Values[1] := '587';
  PageSMTP.Add('Username:',     False); PageSMTP.Values[2] := '';
  PageSMTP.Add('Password:',     True);
  PageSMTP.Add('From address:', False); PageSMTP.Values[4] := 'noreply@genreport.app';

  // Page 4 — Cloudflare R2
  PageR2 := CreateInputQueryPage(PageSMTP.ID,
    'R2 storage',
    'Cloudflare R2 for file storage. Leave blank to configure later.',
    '');
  PageR2.Add('Account ID:',    False);
  PageR2.Add('Bucket:',        False);
  PageR2.Add('Access Key ID:', False);
  PageR2.Add('Secret Key:',    True);
  PageR2.Add('Public URL:',    False);
end;

// ── Validation ────────────────────────────────────────────────────────────────
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;

  if CurPageID = PageDB.ID then begin
    if PageDB.Values[0] = '' then begin
      MsgBox('Host is required.', mbError, MB_OK);
      Result := False; Exit;
    end;
    if PageDB.Values[2] = '' then begin
      MsgBox('Database name is required.', mbError, MB_OK);
      Result := False; Exit;
    end;
    if PageDB.Values[3] = '' then begin
      MsgBox('Username is required.', mbError, MB_OK);
      Result := False; Exit;
    end;
  end;

  if CurPageID = PagePorts.ID then begin
    if PagePorts.Values[0] = '' then begin
      MsgBox('All port fields are required.', mbError, MB_OK);
      Result := False; Exit;
    end;
  end;
end;

// ── Post-install: invoke config writer + register Windows Service ─────────────
procedure CurStepChanged(CurStep: TSetupStep);
var
  ConfigWriter, Params: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then begin
    ConfigWriter := ExpandConstant('{app}\configwriter.exe');

    Params :=
      ' --installdir "'   + ExpandConstant('{app}') + '"' +
      ' --dbhost "'       + PageDB.Values[0] + '"' +
      ' --dbport "'       + PageDB.Values[1] + '"' +
      ' --dbname "'       + PageDB.Values[2] + '"' +
      ' --dbuser "'       + PageDB.Values[3] + '"' +
      ' --dbpassword "'   + PageDB.Values[4] + '"' +
      ' --dotnetport "'   + PagePorts.Values[0] + '"' +
      ' --goport "'       + PagePorts.Values[1] + '"' +
      ' --rabbitmqport "' + PagePorts.Values[2] + '"' +
      ' --ollamaport "'   + PagePorts.Values[3] + '"' +
      ' --smtphost "'     + PageSMTP.Values[0] + '"' +
      ' --smtpport "'     + PageSMTP.Values[1] + '"' +
      ' --smtpuser "'     + PageSMTP.Values[2] + '"' +
      ' --smtppass "'     + PageSMTP.Values[3] + '"' +
      ' --smtpfrom "'     + PageSMTP.Values[4] + '"' +
      ' --r2accountid "'  + PageR2.Values[0] + '"' +
      ' --r2bucket "'     + PageR2.Values[1] + '"' +
      ' --r2accesskey "'  + PageR2.Values[2] + '"' +
      ' --r2secretkey "'  + PageR2.Values[3] + '"' +
      ' --r2publicurl "'  + PageR2.Values[4] + '"';

    if not Exec(ConfigWriter, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
      MsgBox('Config writer failed (code ' + IntToStr(ResultCode) + '). Installation may be incomplete.',
        mbError, MB_OK);
      Exit;
    end;

    // Register launcher as a Windows Service
    Exec('sc.exe',
      'create Genreport binPath= "' + ExpandConstant('{app}') + '\launcher.exe" ' +
      'start= auto DisplayName= "Genreport"',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);

    Exec('sc.exe', 'start Genreport',
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    Exec('sc.exe', 'stop Genreport',   '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('sc.exe', 'delete Genreport', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
