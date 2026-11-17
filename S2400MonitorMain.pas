unit S2400MonitorMain;

// =============================================================================
// S2400MonitorMain.pas - Hilfsprogramm "S2400 Monitor" (05.11.2026)
//
// Haelt den Verbund "S2400 Aggregate" offen, damit das Isla-Monitoring (Isla
// direkt auf die Monitore an der UAD) auch ohne Live laeuft. Kein eigenes
// Fenster - nur ein Symbol im Infobereich der Taskleiste:
//   Doppelklick / "Mixer & Matrix" oeffnet den Isla-Mixer (auch waehrend Live laeuft)
//   "Zuspieler"                     Samples ueber die Realtek in die Isla spielen (08.11.2026)
//   "Einstellungen"                 oeffnet das Fenster des Verbunds
//   "Neu verbinden"                 Verbund neu starten (z.B. Isla eingeschaltet)
//   "Pausieren"                     UAD und Isla freigeben, nicht wieder zugreifen
//   "Mit Windows starten"           Eintrag unter HKCU\...\Run
//
// Uebergabe an Live/Matrix (S2400MonitorLink): oeffnet ein anderes Programm
// den Verbund oder den Isla-Treiber, bittet der Treiber dort ueber das
// Ereignis "Release" um Freigabe. Der Monitor gibt UAD und Isla frei und
// uebernimmt erst wieder, wenn das andere Programm den Treiber geschlossen hat.
//
// Als ASIO-Host belegt der Monitor alle Kanaele des Verbunds und schreibt in
// jedem Rueckruf Stille in alle Ausgaenge - der Verbund mischt das
// Monitoring danach dazu.
// =============================================================================

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Win.Registry,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Menus,
  Vcl.ExtCtrls,
  Winapi.ShellAPI,
  AsioInterface,
  S2400AsioHost,
  S2400MonitorLink,
  S2400AggMixer,
  S2400Zuspieler,
  S2400Lang;

type
  TS2400MonState = (msStopped, msRunning, msYielded, msPaused);

  TS2400MonitorForm = class(TForm)
  private
    FTray: TTrayIcon;
    FMenu: TPopupMenu;
    FItemZuspieler: TMenuItem;
    FItemMixer, FItemSettings, FItemReconnect, FItemPause, FItemAutostart: TMenuItem;
    FTimer: TTimer;
    FHost: TS2400AsioHost;
    FOutBytes: TArray<Integer>;   // Bytes je Ausgangspuffer (fuer die Stille)
    FState: TS2400MonState;
    FInPanel: Boolean;
    FNextTry: UInt64;
    FFailedTries: Integer;
    FLastError: string;
    FEvtRelease, FEvtReleased: THandle;
    function StartAggregate: Boolean;
    procedure StopAggregate;
    procedure HostBufferSwitch(AIndex: Integer; ATimeInfo: PASIOTime);
    procedure TimerTick(Sender: TObject);
    procedure UpdateTray;
    function AddItem(const ACaption: string; AHandler: TNotifyEvent): TMenuItem;
    function DriverWindowReady: Boolean;
    procedure MixerClick(Sender: TObject);
    procedure ZuspielerClick(Sender: TObject);
    procedure SettingsClick(Sender: TObject);
    procedure ReconnectClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure AutostartClick(Sender: TObject);
    procedure QuitClick(Sender: TObject);
    function AutostartEnabled: Boolean;
    procedure SetAutostart(AEnabled: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  S2400MonitorForm: TS2400MonitorForm;

implementation

const
  C_RUN_KEY = 'Software\Microsoft\Windows\CurrentVersion\Run';
  C_RUN_VALUE = 'S2400 Monitor';
  C_AGG_NAME = 'S2400 Aggregate';
  C_RETRY_MS = 5000;     // naechster Versuch nach einem Fehlschlag
  C_RESUME_MS = 1500;    // Pause nach dem Freiwerden (andere Programme lassen UAD los)
  C_MAX_TRIES = 3;       // danach nur noch auf Wunsch ("Neu verbinden")

// ---------------------------------------------------------------------------
// Aufbau
// ---------------------------------------------------------------------------

constructor TS2400MonitorForm.Create(AOwner: TComponent);
begin
  // kein .dfm - das Fenster bleibt unsichtbar, es traegt nur Symbol und Timer
  inherited CreateNew(AOwner);
  Caption := 'S2400 Monitor';

  FEvtRelease := CreateEventW(nil, False, False, C_MON_EVT_RELEASE);
  FEvtReleased := CreateEventW(nil, False, False, C_MON_EVT_RELEASED);

  FMenu := TPopupMenu.Create(Self);
  FItemMixer := AddItem(Tr('Mixer && Matrix '#$2026, 'Mixer && matrix '#$2026), MixerClick);
  FItemMixer.Default := True;
  FItemZuspieler := AddItem(Tr('Zuspieler (Samples in die Isla) '#$2026, 'Feeder (samples into the Isla) '#$2026), ZuspielerClick);
  FItemSettings := AddItem(Tr('Einstellungen '#$2026, 'Settings '#$2026), SettingsClick);
  FItemReconnect := AddItem(Tr('Neu verbinden', 'Reconnect'), ReconnectClick);
  FItemPause := AddItem(Tr('Pausieren (Master und Isla freigeben)', 'Pause (release master and Isla)'), PauseClick);
  AddItem('-', nil);
  FItemAutostart := AddItem(Tr('Mit Windows starten', 'Start with Windows'), AutostartClick);
  FItemAutostart.Checked := AutostartEnabled;
  AddItem('-', nil);
  AddItem(Tr('Beenden', 'Exit'), QuitClick);

  FTray := TTrayIcon.Create(Self);
  FTray.Icon := Application.Icon;
  FTray.PopupMenu := FMenu;
  FTray.OnDblClick := MixerClick;
  FTray.Visible := True;

  FState := msStopped;
  FNextTry := 0;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := True;
  UpdateTray;
end;

destructor TS2400MonitorForm.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  CloseS2400Zuspieler; // eigenes Fenster mit Wiedergabe-Thread
  CloseS2400AggMixerModeless;
  StopAggregate;
  if FTray <> nil then
    FTray.Visible := False;
  if FEvtRelease <> 0 then
    CloseHandle(FEvtRelease);
  if FEvtReleased <> 0 then
    CloseHandle(FEvtReleased);
  inherited Destroy;
end;

function TS2400MonitorForm.AddItem(const ACaption: string; AHandler: TNotifyEvent): TMenuItem;
begin
  Result := TMenuItem.Create(FMenu);
  Result.Caption := ACaption;
  Result.OnClick := AHandler;
  FMenu.Items.Add(Result);
end;

// ---------------------------------------------------------------------------
// Verbund betreiben
// ---------------------------------------------------------------------------

function TS2400MonitorForm.StartAggregate: Boolean;
var
  Info: TS2400AsioDriverInfo;
  Ch: Integer;
begin
  Result := False;
  StopAggregate;
  if not TS2400AsioHost.FindDriver(C_AGG_NAME, Info) then
  begin
    FLastError := Tr('Der Verbund "S2400 Aggregate" ist nicht installiert.',
      'The "S2400 Aggregate" driver is not installed.');
    Exit;
  end;

  FHost := TS2400AsioHost.Create;
  FHost.OnBufferSwitch := HostBufferSwitch;
  // Besitzer fuer die Fenster des Treibers ist das unsichtbare Anwendungsfenster,
  // nicht dieses Formular: sonst tauchte es beim Einstellungsfenster als leeres
  // weisses Fenster "S2400 Monitor" auf (Z8, 12.11.2026)
  if not FHost.Load(Info, Pointer(Application.Handle)) or not FHost.CreateBuffers(0) then
  begin
    FLastError := FHost.LastError;
    StopAggregate;
    Exit;
  end;
  SetLength(FOutBytes, FHost.Outputs);
  for Ch := 0 to FHost.Outputs - 1 do
    FOutBytes[Ch] := FHost.BufferSize * AsioSampleBytes(FHost.OutputInfo(Ch).sampleType);
  if not FHost.Start then
  begin
    FLastError := FHost.LastError;
    StopAggregate;
    Exit;
  end;
  FHost.ResetRequested := False;
  FLastError := '';
  Result := True;
end;

procedure TS2400MonitorForm.StopAggregate;
begin
  if FHost <> nil then
  begin
    FHost.Unload; // stop, disposeBuffers, Treiber freigeben -> UAD und Isla frei
    FreeAndNil(FHost);
  end;
  FOutBytes := nil;
end;

// im Rueckruf-Thread: alle Ausgaenge still - das Monitoring mischt der
// Verbund NACH diesem Rueckruf dazu
procedure TS2400MonitorForm.HostBufferSwitch(AIndex: Integer; ATimeInfo: PASIOTime);
var
  Ch: Integer;
  P: Pointer;
begin
  for Ch := 0 to High(FOutBytes) do
  begin
    P := FHost.OutputBuffer(Ch, AIndex);
    if P <> nil then
      FillChar(P^, FOutBytes[Ch], 0);
  end;
end;

procedure TS2400MonitorForm.TimerTick(Sender: TObject);
var
  NowTick: UInt64;
begin
  // waehrend das Einstellungsfenster offen ist, nichts umbauen
  if FInPanel then
    Exit;
  NowTick := GetTickCount64;

  // ein anderes Programm will den Verbund oder die Isla
  if WaitForSingleObject(FEvtRelease, 0) = WAIT_OBJECT_0 then
  begin
    StopAggregate;
    if FState <> msPaused then
      FState := msYielded;
    SetEvent(FEvtReleased);
    FNextTry := NowTick + C_RESUME_MS;
    FFailedTries := 0;
  end;

  case FState of
    msRunning:
      // Einstellungen geaendert oder Samplerate gewechselt: neu anlegen
      if (FHost <> nil) and FHost.ResetRequested then
        if not StartAggregate then
        begin
          FState := msStopped;
          FNextTry := NowTick + C_RETRY_MS;
        end;
    msStopped, msYielded:
      if (NowTick >= FNextTry) and (FFailedTries < C_MAX_TRIES) and not S2400ForeignHostPresent then
      begin
        if StartAggregate then
        begin
          FState := msRunning;
          FFailedTries := 0;
        end
        else
        begin
          FState := msStopped;
          Inc(FFailedTries);
          FNextTry := NowTick + C_RETRY_MS;
        end;
      end;
  end;
  UpdateTray;
end;

procedure TS2400MonitorForm.UpdateTray;
var
  S: string;
begin
  case FState of
    msRunning:
      S := Tr('Isla-Monitoring aktiv', 'Isla monitoring active');
    msYielded:
      if S2400ForeignHostPresent then
        S := Tr('An Audio-Software '#$00FC'bergeben', 'Handed over to audio software')
      else
        S := Tr('Wird wieder verbunden '#$2026, 'Reconnecting '#$2026);
    msPaused:
      S := Tr('Pausiert', 'Paused');
  else
    if FLastError <> '' then
      S := Tr('Nicht verbunden: ', 'Not connected: ') + FLastError
    else
      S := Tr('Nicht verbunden', 'Not connected');
  end;
  // der Hinweistext des Symbols ist auf 127 Zeichen begrenzt
  FTray.Hint := Copy('S2400 Monitor - ' + S, 1, 127);
  FItemPause.Checked := FState = msPaused;
end;

// ---------------------------------------------------------------------------
// Menue
// ---------------------------------------------------------------------------

// True, wenn der Verbund hier laeuft; sonst Hinweis am Symbol
function TS2400MonitorForm.DriverWindowReady: Boolean;
var
  W: HWND;
begin
  Result := (FState = msRunning) and (FHost <> nil) and not FInPanel;
  if Result then
    Exit;
  if FInPanel then
  begin
    // Einstellungsfenster ist schon offen (evtl. verdeckt): nach vorn holen
    W := FindWindow('TS2400AggPanelForm', nil);
    if W <> 0 then
    begin
      if IsIconic(W) then
        ShowWindow(W, SW_RESTORE);
      SetForegroundWindow(W);
    end;
    Exit;
  end;
  FTray.BalloonTitle := 'S2400 Monitor';
  if FState = msYielded then
    FTray.BalloonHint := Tr('Der Verbund ist gerade an eine Audio-Software '#$00FC'bergeben. ' +
      'Mixer und Einstellungen dort '#$00FC'ber das Control Panel des Treibers '#$00F6'ffnen.',
      'The driver is currently handed over to audio software. Open mixer and settings there ' +
      'via the driver''s control panel.')
  else
    FTray.BalloonHint := Tr('Der Verbund ist nicht verbunden. "Neu verbinden" versuchen.',
      'The driver is not connected. Try "Reconnect".');
  FTray.ShowBalloonHint;
end;

// Isla-Mixer direkt hier im Monitor: er spricht ueber den gemeinsamen
// Speicher mit dem Treiber - egal ob der gerade hier oder in Live laeuft.
// Waehrend er offen ist, darf der Monitor weiter an Live abgeben (kein FInPanel).
// Seit 08.11.2026 nicht modal: Mixer und Zuspieler sind gleichzeitig bedienbar.
// eigene Programme (10.11.2026): "S2400 Isla-Mixer.exe" / "S2400 Zuspieler.exe"
// neben dem Monitor starten (installiert) bzw. die Delphi-Ausgabe
// "...App.exe" (Entwicklung). Laeuft es schon, holt es sich selbst nach
// vorn. False = nicht gefunden.
function StartOwnApp(const AInstalled, ADev: string): Boolean;
const
  C_ASFW_ANY = DWORD(-1);
var
  Dir, Exe: string;
begin
  Dir := ExtractFilePath(ParamStr(0));
  Exe := Dir + AInstalled;
  if not FileExists(Exe) then
    Exe := Dir + ADev;
  Result := FileExists(Exe);
  if not Result then
    Exit;
  AllowSetForegroundWindow(C_ASFW_ANY); // das gestartete Programm darf nach vorn
  Result := ShellExecute(0, 'open', PChar(Exe), nil, PChar(Dir), SW_SHOWNORMAL) > 32;
end;

procedure TS2400MonitorForm.MixerClick(Sender: TObject);
begin
  if FInPanel then
    Exit;
  // eigenes Programm; nur wenn es fehlt, im Monitor selbst
  if not StartOwnApp('S2400 Isla-Mixer.exe', 'S2400MixerApp.exe') then
    ShowS2400AggMixerModeless;
end;

// Isla-Zuspieler (08.11.2026): eigenes, nicht modales Fenster; spielt ueber
// die Realtek (WASAPI geteilt) und ist vom Verbund unabhaengig
procedure TS2400MonitorForm.ZuspielerClick(Sender: TObject);
begin
  if FInPanel then
    Exit; // das Einstellungsfenster des Verbunds (modal) ist offen
  if not StartOwnApp('S2400 Zuspieler.exe', 'S2400ZuspielerApp.exe') then
    ShowS2400Zuspieler;
end;

procedure TS2400MonitorForm.SettingsClick(Sender: TObject);
begin
  if not DriverWindowReady then
    Exit;
  FInPanel := True;
  try
    FHost.ShowControlPanel; // das Fenster des Verbunds (modal)
  finally
    FInPanel := False;
  end;
  // hat das Fenster einen Neustart verlangt, erledigt das der naechste Timer-Tick
end;

procedure TS2400MonitorForm.ReconnectClick(Sender: TObject);
begin
  if FState = msYielded then
    Exit; // gehoert gerade Live/Matrix
  FFailedTries := 0;
  if StartAggregate then
    FState := msRunning
  else
  begin
    FState := msStopped;
    FFailedTries := C_MAX_TRIES; // kein automatisches Wiederholen nach Klick
  end;
  UpdateTray;
end;

procedure TS2400MonitorForm.PauseClick(Sender: TObject);
begin
  if FState = msPaused then
  begin
    FState := msStopped;
    FFailedTries := 0;
    FNextTry := 0;
  end
  else
  begin
    StopAggregate;
    FState := msPaused;
  end;
  UpdateTray;
end;

procedure TS2400MonitorForm.AutostartClick(Sender: TObject);
begin
  SetAutostart(not AutostartEnabled);
  FItemAutostart.Checked := AutostartEnabled;
end;

procedure TS2400MonitorForm.QuitClick(Sender: TObject);
begin
  Close; // Hauptfenster -> Programmende, Destroy gibt den Verbund frei
end;

function TS2400MonitorForm.AutostartEnabled: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(C_RUN_KEY) then
      Result := Reg.ValueExists(C_RUN_VALUE);
  finally
    Reg.Free;
  end;
end;

procedure TS2400MonitorForm.SetAutostart(AEnabled: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(C_RUN_KEY, True) then
    begin
      if AEnabled then
        Reg.WriteString(C_RUN_VALUE, '"' + ParamStr(0) + '"')
      else if Reg.ValueExists(C_RUN_VALUE) then
        Reg.DeleteValue(C_RUN_VALUE);
    end;
  finally
    Reg.Free;
  end;
end;

end.
