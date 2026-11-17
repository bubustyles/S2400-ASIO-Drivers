program S2400MixerApp;

// =============================================================================
// S2400MixerApp.dpr - eigenes Programm "S2400 Isla-Mixer" (10.11.2026)
//
// Der Isla-Mixer (S2400AggMixer.pas, nicht modal) als eigenstaendiges
// Programm mit eigenem Symbol, damit er sich an die Taskleiste heften laesst.
// Spricht ueber den gemeinsamen Speicher mit dem Treiber (Live oder Monitor);
// laeuft auch ohne beide. Installiert als "S2400 Isla-Mixer.exe"; der
// S2400 Monitor startet ihn ueber sein Menue. Laeuft nur einmal (zwei Mixer
// wuerden sich die Einstellungen ueberschreiben).
// =============================================================================

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Vcl.Forms,
  S2400Lang in 'S2400Lang.pas',
  S2400UiKit in 'S2400UiKit.pas',
  S2400AggMixer in 'S2400AggMixer.pas';

{$R *.res}

var
  InstanceMutex: THandle;
  Wnd: HWND;

begin
  InstanceMutex := CreateMutexW(nil, False, 'Local\S2400Mixer.Instance');
  if (InstanceMutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    Wnd := FindWindowW('TS2400MixerForm', nil);
    if Wnd <> 0 then
    begin
      if IsIconic(Wnd) then
        ShowWindow(Wnd, SW_RESTORE);
      SetForegroundWindow(Wnd);
    end;
    Exit;
  end;

  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.Title := 'S2400 Isla-Mixer';
    RunS2400AggMixerApp;
  finally
    CoUninitialize;
    CloseHandle(InstanceMutex);
  end;
end.