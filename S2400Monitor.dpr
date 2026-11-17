program S2400Monitor;

// =============================================================================
// S2400Monitor.dpr - Hilfsprogramm "S2400 Monitor" (05.11.2026)
//
// Haelt den Verbund "S2400 Aggregate" offen, damit die Isla auch ohne Live
// digital ueber die UAD auf den Monitoren zu hoeren ist (Isla-Monitoring,
// siehe S2400AggCore.pas). Laeuft unsichtbar mit einem Symbol im
// Infobereich der Taskleiste (S2400MonitorMain.pas) und gibt UAD und Isla
// automatisch frei, sobald Live oder Matrix einen der Treiber oeffnet
// (S2400MonitorLink.pas).
// =============================================================================

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Vcl.Forms,
  AsioInterface in 'AsioInterface.pas',
  S2400AsioHost in 'S2400AsioHost.pas',
  S2400Lang in 'S2400Lang.pas',
  S2400MonitorLink in 'S2400MonitorLink.pas',
  S2400UiKit in 'S2400UiKit.pas',
  S2400AggMixer in 'S2400AggMixer.pas',
  S2400Resampler in 'S2400Resampler.pas',
  S2400WasapiOut in 'S2400WasapiOut.pas',
  S2400AudioFile in 'S2400AudioFile.pas',
  S2400ZsDsp in 'S2400ZsDsp.pas',
  S2400Zuspieler in 'S2400Zuspieler.pas',
  S2400MonitorMain in 'S2400MonitorMain.pas';

{$R *.res}

var
  InstanceMutex: THandle;

begin
  // nur einmal pro Anmeldung
  InstanceMutex := CreateMutexW(nil, False, 'Local\S2400Monitor.Instance');
  if (InstanceMutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
    Exit;

  // fuer den Treiber in diesem Prozess: hier nicht um Freigabe bitten
  SetEnvironmentVariableW(C_MON_ENV_NAME, '1');

  // ASIO-Treiber erwarten ein STA wie in Live
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    Application.Initialize;
    Application.MainFormOnTaskbar := False;
    Application.ShowMainForm := False;
    Application.Title := 'S2400 Monitor';
    Application.CreateForm(TS2400MonitorForm, S2400MonitorForm);
    Application.Run;
  finally
    CoUninitialize;
    CloseHandle(InstanceMutex);
  end;
end.
