unit S2400MonitorLink;

// =============================================================================
// S2400MonitorLink.pas - Absprache zwischen dem Hilfsprogramm "S2400 Monitor"
// und den Treibern (05.11.2026)
//
// S2400 Monitor haelt den Verbund offen, damit das Isla-Monitoring auch ohne
// Live laeuft. Will ein anderes Programm (Live, Matrix) den Verbund oder den
// Isla-Treiber oeffnen, muss der Monitor vorher UAD und Isla freigeben - beide
// Geraete kann immer nur ein Programm gleichzeitig benutzen.
//
// Ablauf (nur benannte Windows-Ereignisse, Sitzung des Nutzers):
//   - Der Monitor legt "Release" und "Released" an.
//   - Ein Treiber in einem FREMDEN Programm legt beim Oeffnen der Geraete die
//     Markierung "ForeignHost" an (bleibt bestehen, solange der Treiber
//     geladen ist - auch ein Absturz des Programms gibt sie frei), setzt
//     "Release" und wartet bis zu 5 s auf "Released".
//   - Der Monitor gibt frei, setzt "Released" und uebernimmt erst wieder,
//     wenn "ForeignHost" verschwunden ist.
// Im Prozess des Monitors selbst setzt dieser die Umgebungsvariable
// S2400_MONITOR_HOST=1 - dort fragt der Treiber nicht nach (er wuerde sonst
// auf sich selbst warten).
// =============================================================================

interface

uses
  Winapi.Windows;

const
  C_MON_ENV_NAME      = 'S2400_MONITOR_HOST';
  C_MON_EVT_RELEASE   = 'Local\S2400Monitor.Release';
  C_MON_EVT_RELEASED  = 'Local\S2400Monitor.Released';
  C_MON_EVT_FOREIGN   = 'Local\S2400Aggregate.ForeignHost';
  C_MON_RELEASE_WAIT  = 5000; // ms

  // eigener ASIO-future()-Wahlschalter des Verbunds: Isla-Mixer oeffnen
  // ('S2MX'; liegt ausserhalb der Steinberg-Werte)
  C_S2400_FUTURE_OPEN_MIXER = LongInt($53324D58);

type
  TS2400ClaimResult = (crNoMonitor, crReleased, crTimeout, crInMonitor);

// True im Prozess von S2400 Monitor
function S2400InMonitorHost: Boolean;

// Vor dem Oeffnen von UAD/Isla in einem fremden Programm: Markierung anlegen
// (AMarker, einmal pro Treiber-Objekt) und den Monitor um Freigabe bitten.
function S2400ClaimFromMonitor(var AMarker: THandle): TS2400ClaimResult;

// Beim Freigeben des Treiber-Objekts: Markierung schliessen
procedure S2400ReleaseClaim(var AMarker: THandle);

// fuer den Monitor: haelt gerade ein fremdes Programm einen der Treiber?
function S2400ForeignHostPresent: Boolean;

implementation

function S2400InMonitorHost: Boolean;
var
  Buf: array[0..7] of WideChar;
begin
  Result := (GetEnvironmentVariableW(C_MON_ENV_NAME, @Buf[0], Length(Buf)) > 0) and (Buf[0] = '1');
end;

function S2400ClaimFromMonitor(var AMarker: THandle): TS2400ClaimResult;
var
  HRelease, HReleased: THandle;
begin
  if S2400InMonitorHost then
    Exit(crInMonitor);

  // Markierung zuerst - so greift der Monitor nach dem Freigeben nicht
  // sofort wieder zu
  if AMarker = 0 then
    AMarker := CreateEventW(nil, True, False, C_MON_EVT_FOREIGN);

  HRelease := OpenEventW(EVENT_MODIFY_STATE, False, C_MON_EVT_RELEASE);
  if HRelease = 0 then
    Exit(crNoMonitor);
  HReleased := OpenEventW(SYNCHRONIZE or EVENT_MODIFY_STATE, False, C_MON_EVT_RELEASED);
  try
    if HReleased = 0 then
      Exit(crNoMonitor);
    // eine liegengebliebene Freigabe (frueherer Aufrufer schon weg) zaehlt nicht
    ResetEvent(HReleased);
    SetEvent(HRelease);
    if WaitForSingleObject(HReleased, C_MON_RELEASE_WAIT) = WAIT_OBJECT_0 then
      Result := crReleased
    else
      Result := crTimeout;
  finally
    CloseHandle(HRelease);
    if HReleased <> 0 then
      CloseHandle(HReleased);
  end;
end;

procedure S2400ReleaseClaim(var AMarker: THandle);
begin
  if AMarker <> 0 then
  begin
    CloseHandle(AMarker);
    AMarker := 0;
  end;
end;

function S2400ForeignHostPresent: Boolean;
var
  H: THandle;
begin
  H := OpenEventW(SYNCHRONIZE, False, C_MON_EVT_FOREIGN);
  Result := H <> 0;
  if H <> 0 then
    CloseHandle(H);
end;

end.
