; =============================================================================
; S2400Setup.iss - gemeinsames Setup fuer beide Treiber (30.10.2026)
;
; Inno Setup 7. Ersetzt S2400AsioDriverSetup.iss (nur Isla-Treiber, aus dem
; Debug-Ordner). Gleiche AppId -> Windows erkennt es als Update derselben
; Software, ein vorhandener Installationsordner wird weiterverwendet.
;
; Komponenten (waehlbar):
;   isla       S2400AsioDriver.dll  - Isla direkt per Kernel Streaming
;   aggregate  S2400Aggregate.dll   - Verbund (ASIO-Master + Isla + Windows-Ausgang)
;              S2400Monitor.exe     - Hilfsprogramm fuer das Isla-Monitoring ohne Live
;              (05.11.2026, Symbol im Infobereich, Autostart als Aufgabe waehlbar)
;              S2400 Zuspieler.exe / S2400 Isla-Mixer.exe - eigene Programme mit
;              eigenem Symbol (10.11.2026, aus S2400ZuspielerApp/S2400MixerApp)
;
; Beide DLLs registrieren sich selbst ("regserver" ruft DllRegisterServer
; bzw. beim Deinstallieren DllUnregisterServer auf) - dabei entstehen bzw.
; verschwinden HKCR\CLSID\{...} und HKLM\SOFTWARE\ASIO\<Name>.
;
; Sprache: Deutsch/Englisch (Auswahl beim Start, Vorschlag nach Windows-
; Sprache). Die Treiber selbst zeigen ihre Fenster ebenfalls je nach
; Windows-Sprache deutsch oder englisch (S2400Lang.pas).
;
; Quelle sind die RELEASE-Builds (Win64\Release) beider Projekte.
; =============================================================================

#define MyAppName "S2400 ASIO Drivers"
#define MyAppVersion "1.5.9"
#define MyAppPublisher "David Ritter"

[Setup]
; AppId des bisherigen Isla-Setups - NICHT aendern (Update-Erkennung)
AppId={{5F7B564D-967C-4146-BAC9-D8888F40957E}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppCopyright=Copyright (C) 2026 David Ritter
AppPublisherURL=https://github.com/bubustyles/S2400-ASIO-Drivers
AppSupportURL=https://github.com/bubustyles/S2400-ASIO-Drivers
VersionInfoVersion={#MyAppVersion}.0
VersionInfoDescription={#MyAppName} Setup

DefaultDirName={autopf}\S2400 ASIO Drivers
DisableProgramGroupPage=yes

OutputDir=.\Output
OutputBaseFilename=S2400_ASIO_Drivers_Setup_{#MyAppVersion}

; reine 64-Bit-Treiber
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os

Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; DllRegisterServer schreibt nach HKLM/HKCR
PrivilegesRequired=admin

; Programme, die eine der DLLs geladen haben (Live, Matrix, SoundID ...),
; ueber den Windows-Neustart-Manager schliessen lassen statt einen
; Neustart zu verlangen
CloseApplications=yes
RestartApplications=no

ShowLanguageDialog=yes
LanguageDetectionMethod=uilanguage

UninstallDisplayIcon={uninstallexe}
UninstallDisplayName={#MyAppName}

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"; LicenseFile: "Setup\License_de.txt"; InfoAfterFile: "Setup\Info_de.txt"
Name: "english"; MessagesFile: "compiler:Default.isl"; LicenseFile: "Setup\License_en.txt"; InfoAfterFile: "Setup\Info_en.txt"

[CustomMessages]
german.TypeFull=Beide Treiber
german.TypeCustom=Benutzerdefinierte Auswahl
german.CompIsla=ISLA S2400 ASIO Driver (die Isla allein als ASIO-Gerät)
german.CompAgg=S2400 Aggregate (Isla zusammen mit einem anderen ASIO-Gerät, z.B. einem Audio-Interface)
english.TypeFull=Both drivers
english.TypeCustom=Custom selection
english.CompIsla=ISLA S2400 ASIO Driver (the Isla on its own as an ASIO device)
english.CompAgg=S2400 Aggregate (the Isla together with another ASIO device, e.g. an audio interface)
german.TaskAutostart=S2400 Monitor mit Windows starten (Isla-Monitoring ohne Audio-Software)
english.TaskAutostart=Start S2400 Monitor with Windows (Isla monitoring without audio software)
german.RunMonitor=S2400 Monitor jetzt starten
english.RunMonitor=Start S2400 Monitor now
german.TaskDesktop=Symbole für Zuspieler und Isla-Mixer auf dem Desktop
english.TaskDesktop=Desktop icons for feeder and Isla mixer

[Types]
Name: "full"; Description: "{cm:TypeFull}"
Name: "custom"; Description: "{cm:TypeCustom}"; Flags: iscustom

[Components]
Name: "isla"; Description: "{cm:CompIsla}"; Types: full custom
Name: "aggregate"; Description: "{cm:CompAgg}"; Types: full

[Tasks]
Name: "autostart"; Description: "{cm:TaskAutostart}"; Components: aggregate
Name: "desktopicons"; Description: "{cm:TaskDesktop}"; Components: aggregate; Flags: unchecked

[Files]
Source: "Win64\Release\S2400AsioDriver.dll"; DestDir: "{app}"; Components: isla; Flags: regserver 64bit restartreplace ignoreversion
Source: "Win64\Release\S2400Aggregate.dll"; DestDir: "{app}"; Components: aggregate; Flags: regserver 64bit restartreplace ignoreversion
Source: "Win64\Release\S2400Monitor.exe"; DestDir: "{app}"; Components: aggregate; Flags: 64bit ignoreversion
Source: "Win64\Release\S2400ZuspielerApp.exe"; DestDir: "{app}"; DestName: "S2400 Zuspieler.exe"; Components: aggregate; Flags: 64bit ignoreversion
Source: "Win64\Release\S2400MixerApp.exe"; DestDir: "{app}"; DestName: "S2400 Isla-Mixer.exe"; Components: aggregate; Flags: 64bit ignoreversion
Source: "Setup\Info_de.txt"; DestDir: "{app}"; DestName: "Hinweise.txt"; Languages: german
Source: "Setup\Info_en.txt"; DestDir: "{app}"; DestName: "Readme.txt"; Languages: english
Source: "Setup\License_de.txt"; DestDir: "{app}"; DestName: "Nutzungsbedingungen.txt"; Languages: german
Source: "Setup\License_en.txt"; DestDir: "{app}"; DestName: "Terms of use.txt"; Languages: english
Source: "Setup\LICENSE.txt"; DestDir: "{app}"; DestName: "LICENSE.txt"
; Software-Handbuch (aus Handbuch\build_handbuch.py, gleiche Versionsnummer wie das Setup)
Source: "Handbuch\S2400_ASIO_Drivers_Software-Handbuch_DE_{#MyAppVersion}.pdf"; DestDir: "{app}"; DestName: "S2400 Software-Handbuch.pdf"; Languages: german; Flags: ignoreversion
Source: "Handbuch\S2400_ASIO_Drivers_Software-Manual_EN_{#MyAppVersion}.pdf"; DestDir: "{app}"; DestName: "S2400 Software Manual.pdf"; Languages: english; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\S2400 Monitor"; Filename: "{app}\S2400Monitor.exe"; Components: aggregate
Name: "{autoprograms}\S2400 Zuspieler"; Filename: "{app}\S2400 Zuspieler.exe"; Components: aggregate
Name: "{autoprograms}\S2400 Isla-Mixer"; Filename: "{app}\S2400 Isla-Mixer.exe"; Components: aggregate
Name: "{autoprograms}\S2400 Software-Handbuch"; Filename: "{app}\S2400 Software-Handbuch.pdf"; Languages: german
Name: "{autoprograms}\S2400 Software Manual"; Filename: "{app}\S2400 Software Manual.pdf"; Languages: english
Name: "{autodesktop}\S2400 Zuspieler"; Filename: "{app}\S2400 Zuspieler.exe"; Components: aggregate; Tasks: desktopicons
Name: "{autodesktop}\S2400 Isla-Mixer"; Filename: "{app}\S2400 Isla-Mixer.exe"; Components: aggregate; Tasks: desktopicons

[Registry]
; Autostart fuer den angemeldeten Nutzer (das Programm kann ihn selbst wieder abschalten)
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "S2400 Monitor"; ValueData: """{app}\S2400Monitor.exe"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\S2400Monitor.exe"; Description: "{cm:RunMonitor}"; Components: aggregate; Flags: postinstall nowait skipifsilent runasoriginaluser

[UninstallRun]
; S2400 Monitor haelt den Verbund geladen - vor dem Entfernen beenden
Filename: "{sys}\taskkill.exe"; Parameters: "/im S2400Monitor.exe /f"; Flags: runhidden; RunOnceId: "StopS2400Monitor"
Filename: "{sys}\taskkill.exe"; Parameters: "/im ""S2400 Zuspieler.exe"" /f"; Flags: runhidden; RunOnceId: "StopS2400Zuspieler"
Filename: "{sys}\taskkill.exe"; Parameters: "/im ""S2400 Isla-Mixer.exe"" /f"; Flags: runhidden; RunOnceId: "StopS2400Mixer"

[InstallDelete]
; Testinstallation des Verbunds aus der Entwicklung (von Hand kopiert und
; registriert) aufraeumen - die Registrierung zeigt nach diesem Setup auf
; die neue DLL im Installationsordner
Type: files; Name: "{autopf}\S2400 Aggregate\S2400Aggregate*.dll"; Components: aggregate
Type: dirifempty; Name: "{autopf}\S2400 Aggregate"; Components: aggregate

[UninstallDelete]
Type: dirifempty; Name: "{app}"
