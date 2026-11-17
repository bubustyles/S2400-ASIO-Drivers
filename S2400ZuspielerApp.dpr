program S2400ZuspielerApp;

// =============================================================================
// S2400ZuspielerApp.dpr - eigenes Programm "S2400 Zuspieler" (10.11.2026)
//
// Der Isla-Zuspieler (S2400Zuspieler.pas) als eigenstaendiges Programm mit
// eigenem Symbol, damit er sich an die Taskleiste heften laesst. Installiert
// als "S2400 Zuspieler.exe"; der S2400 Monitor startet ihn ueber sein Menue.
// Laeuft nur einmal: ein zweiter Start holt das offene Fenster nach vorn.
// =============================================================================

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Vcl.Forms,
  S2400Lang in 'S2400Lang.pas',
  S2400UiKit in 'S2400UiKit.pas',
  S2400Resampler in 'S2400Resampler.pas',
  S2400WasapiOut in 'S2400WasapiOut.pas',
  S2400AudioFile in 'S2400AudioFile.pas',
  S2400ZsDsp in 'S2400ZsDsp.pas',
  S2400Zuspieler in 'S2400Zuspieler.pas';

{$R *.res}

var
  InstanceMutex: THandle;
  Wnd: HWND;

begin
  InstanceMutex := CreateMutexW(nil, False, 'Local\S2400Zuspieler.Instance');
  if (InstanceMutex = 0) or (GetLastError = ERROR_ALREADY_EXISTS) then
  begin
    // laeuft schon: Fenster nach vorn holen
    Wnd := FindWindowW('TZsForm', nil);
    if Wnd <> 0 then
    begin
      if IsIconic(Wnd) then
        ShowWindow(Wnd, SW_RESTORE);
      SetForegroundWindow(Wnd);
    end;
    Exit;
  end;

  // Dateidialoge und WASAPI brauchen COM (STA wie im Monitor)
  CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    Application.Initialize;
    Application.MainFormOnTaskbar := True;
    Application.Title := 'S2400 Zuspieler';
    RunS2400ZuspielerApp;
  finally
    CoUninitialize;
    CloseHandle(InstanceMutex);
  end;
end.