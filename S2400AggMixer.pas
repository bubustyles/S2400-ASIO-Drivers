unit S2400AggMixer;

// =============================================================================
// S2400AggMixer.pas - Isla-Mixer mit Matrix (06.11.2026)
//
// Fenster des Isla-Monitorings im Verbund "S2400 Aggregate". Gestaltung nach
// Art einer Hardware-Konsole in den Farben von S2400UiKit (Anthrazit,
// Bernstein, Tuerkis), mit GDI+ und feinen Farbverlaeufen gezeichnet:
//   links    Isla-Feld: Hauptschalter Monitoring, Zustand, Bedienhinweis
//   Mitte    je Isla-Kanal (Mix L/R, Out 1-8) ein Kanalzug: Kopfleiste,
//            Panorama-Drehknopf, Stummtaste, Metall-Fader mit Skala,
//            vertiefte LED-Pegelanzeige mit Skala, Spitzenwert
//   unten    Routing: Zeilen = Ausgangspaare des Masters (UAD) mit deren
//            Ausgangspegel, Spalten = die Kanalzuege; LED-Taste = Kanal auf
//            das Paar. Mehrere Ziele je Kanal moeglich.
//
// Gemeinsamer Speicher (06.11.2026): Mixer und Treiber tauschen sich ueber
// den benannten Speicherbereich "Local\S2400Aggregate.Mixer" aus - der Mixer
// funktioniert damit in JEDEM Programm (S2400 Monitor, Live), egal welches
// Programm den Verbund gerade betreibt:
//   Mixer   -> Treiber  Einstellungen + Zaehler Seq (Treiber uebernimmt im
//                       naechsten Master-Rueckruf, ohne Neustart)
//   Treiber -> Mixer    Zustand, Latenz, Namen der Ausgangspaare, Spitzen-
//                       werte (der Mixer liest sie alle 50 ms und setzt sie
//                       zurueck)
// Gespeichert (Registry) wird beim Schliessen des Mixers.
// =============================================================================

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.DwmApi,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  System.Math,
  System.Win.Registry,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Winapi.GDIPAPI,
  Winapi.GDIPOBJ,
  S2400UiKit,
  S2400Lang;

const
  C_MIX_CHANNELS = 10;   // Isla-USB-Kanaele: 1/2 Mix, 3..10 = Out 1..8
  C_MIX_MAX_PAIRS = 16;  // Ausgangspaare des Masters (UAD: 12)
  C_MIX_DB_MIN = -60;
  C_MIX_DB_MAX = 6;
  C_MIX_PAN_MAX = 100;   // -100 = ganz links, +100 = ganz rechts
  C_MIX_NAME_LEN = 64;

type
  TS2400MixSettings = record
    Enabled: Boolean;                                   // Isla-Monitoring an
    ChOn: array[0..C_MIX_CHANNELS - 1] of Boolean;      // False = stumm (Taste M)
    ChDb: array[0..C_MIX_CHANNELS - 1] of Integer;
    ChPan: array[0..C_MIX_CHANNELS - 1] of Integer;
    ChRoute: array[0..C_MIX_CHANNELS - 1] of Cardinal;  // Bit p = Ausgangspaar p
  end;

  // gemeinsamer Speicher zwischen Mixer und Treiber (siehe Unit-Kopf)
  TS2400MixShared = record
    Magic: Cardinal;
    Seq: Integer;                    // +1 bei jeder Aenderung von Settings
    Settings: TS2400MixSettings;
    OwnerPid: Cardinal;              // Prozess, der den Verbund gerade betreibt (0 = keiner)
    OwnerName: array[0..C_MIX_NAME_LEN - 1] of WideChar;
    Running: LongBool;               // Audio-Engine laeuft
    IslaActive: LongBool;            // Isla streamt
    LatencyMs: Double;
    PairCount: Integer;
    PairNames: array[0..C_MIX_MAX_PAIRS - 1, 0..C_MIX_NAME_LEN - 1] of WideChar;
    InPeak: array[0..C_MIX_CHANNELS - 1] of Single;       // linear, seit dem letzten Abruf
    OutPeak: array[0..2 * C_MIX_MAX_PAIRS - 1] of Single; // [Paar * 2 + Seite]
  end;
  PS2400MixShared = ^TS2400MixShared;

// Vorgabe: Mix L/R auf Paar 1 (ganz links/rechts), Einzelausgaenge nirgends
function S2400MixDefaults: TS2400MixSettings;
// Panorama mit gleicher Leistung: ganz aussen 1/0, Mitte je 0,707
procedure S2400MixPanGains(APan: Integer; out AL, AR: Single);

// Einstellungen in HKCU\Software\S2400 Aggregate (mit Uebernahme des Stands
// vom 05.11.2026: MonPair/MonOn/MonDb)
function S2400MixLoad: TS2400MixSettings;
procedure S2400MixSave(const ASettings: TS2400MixSettings);

// gemeinsamen Speicher oeffnen (beim ersten Oeffnen aus der Registry
// vorbelegt); nil, wenn Windows ihn nicht anlegen kann
function S2400MixSharedOpen(out AMapping: THandle): PS2400MixShared;
procedure S2400MixSharedClose(var AMapping: THandle; var AView: PS2400MixShared);
// vom Treiber: Namen der Ausgangspaare (auch in die Registry, fuer den
// Mixer ohne laufenden Treiber) und Zustand
procedure S2400MixSetPairNames(AView: PS2400MixShared; const ANames: TArray<string>);
procedure S2400MixSetOwner(AView: PS2400MixShared; ARunning, AIslaActive: Boolean; ALatencyMs: Double);
procedure S2400MixClearOwner(AView: PS2400MixShared);

// zeigt den Mixer modal (AOwnerWnd 0 = ohne Besitzerfenster)
procedure ShowS2400AggMixer(AOwnerWnd: HWND);
// nicht modal, eigenes Fenster in der Taskleiste (S2400 Monitor, 08.11.2026)
procedure ShowS2400AggMixerModeless;
procedure CloseS2400AggMixerModeless;
// eigenes Programm "S2400 Isla-Mixer" (10.11.2026): nicht modal zeigen und
// laufen, bis das Fenster geschlossen wird
procedure RunS2400AggMixerApp;

implementation

type
  // Momentaufnahme fuer die Anzeige (aus dem gemeinsamen Speicher)
  TS2400MixStatus = record
    Running: Boolean;
    MonActive: Boolean;
    LatencyMs: Double;
    OwnerName: string;
    InPeak: array[0..C_MIX_CHANNELS - 1] of Single;
    OutPeak: array[0..2 * C_MIX_MAX_PAIRS - 1] of Single;
  end;
  TS2400MixStatusFunc = reference to function: TS2400MixStatus;
  TS2400MixChangeProc = reference to procedure(const ASettings: TS2400MixSettings);


const
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  DWMWA_CAPTION_COLOR = 35;
  DWMWA_TEXT_COLOR = 36;

  // Farben der Konsole (TColor = $00BBGGRR)
  C_MX_BG          = TColor($001B1817); // #17181B Fenster
  C_MX_PANEL_TOP   = TColor($00312D2B); // #2B2D31 Kanalzug oben
  C_MX_PANEL_BOT   = TColor($00282523); // #232528 Kanalzug unten
  C_MX_PANEL       = TColor($002D2927); // #27292D Flaeche der Kanalzuege (Elemente darauf)
  C_MX_HEAD_TOP    = TColor($00282523); // Kopfleiste
  C_MX_HEAD_BOT    = TColor($00221F1D); // #1D1F22
  C_MX_EDGE        = TColor($00141211); // #111214 dunkle Kante
  C_MX_HILITE      = TColor($00443F3C); // #3C3F44 Lichtkante oben
  C_MX_WELL        = TColor($000F0D0C); // #0C0D0F vertieftes Feld
  C_MX_WELL_EDGE   = TColor($00070606); // #060607
  C_MX_LED_OFF     = TColor($001E1C1A); // #1A1C1E unbeleuchtete LED
  C_MX_SCALE       = TColor($006F7476); // #76746F Skalenziffern
  C_MX_GROOVE      = TColor($000D0C0B); // #0B0C0D Fader-Schlitz
  C_MX_CAP_TOP     = TColor($00DCE2E4); // #E4E2DC Fader-Kappe hell
  C_MX_CAP_MID     = TColor($009BA1A3); // #A3A19B
  C_MX_CAP_BOT     = TColor($00797D80); // #807D79
  C_MX_KNOB_RING   = TColor($00171514); // #141517 Bahn des Drehknopfs
  C_MX_KNOB_TOP    = TColor($005E5855); // #55585E Knopfkappe
  C_MX_KNOB_BOT    = TColor($00302C2A); // #2A2C30
  C_MX_BTN_TOP     = TColor($0046413E); // #3E4146 Taste
  C_MX_BTN_BOT     = TColor($00302C2A); // #2A2C30
  C_MX_BTN_ON_TOP  = TColor($0014456A); // #6A4514 Taste gedrueckt (Bernstein)
  C_MX_BTN_ON_BOT  = TColor($0008283E); // #3E2808
  C_MX_ROW_ALT     = TColor($001F1D1C); // #1C1D1F jede zweite Routing-Zeile
  C_MX_LED_AMBER_H = TColor($0040B0F5); // #F5B040

  C_METER_MIN_DB = -60.0;
  C_METER_SEGMENTS = 30;
  C_METER_SEGMENTS_H = 24;
  C_METER_FALL_DB = 1.5;    // pro Timer-Takt (50 ms) = 30 dB/s
  C_METER_HOLD_MS = 1500;

  C_CHANNEL_NAMES: array[0..C_MIX_CHANNELS - 1] of string =
    ('Mix L', 'Mix R', 'Out 1', 'Out 2', 'Out 3', 'Out 4', 'Out 5', 'Out 6', 'Out 7', 'Out 8');

  // Fader-Kennlinie wie an einer Konsole: oben fein, unten grob
  C_FADER_DB: array[0..8] of Integer = (6, 0, -6, -12, -20, -32, -45, -54, -60);
  C_FADER_POS: array[0..8] of Single = (0, 0.18, 0.33, 0.47, 0.60, 0.74, 0.86, 0.94, 1);
  C_FADER_TICKS: array[0..7] of Integer = (6, 0, -6, -12, -20, -32, -45, -60);
  C_METER_TICKS: array[0..9] of Integer = (0, -3, -6, -9, -12, -18, -24, -36, -48, -60);

function S2400MixDefaults: TS2400MixSettings;
var
  Ch: Integer;
begin
  Result := Default(TS2400MixSettings);
  for Ch := 0 to C_MIX_CHANNELS - 1 do
  begin
    Result.ChOn[Ch] := True;
    if Odd(Ch) then
      Result.ChPan[Ch] := C_MIX_PAN_MAX
    else
      Result.ChPan[Ch] := -C_MIX_PAN_MAX;
  end;
  Result.ChRoute[0] := 1;
  Result.ChRoute[1] := 1;
end;

procedure S2400MixPanGains(APan: Integer; out AL, AR: Single);
var
  T: Double;
begin
  T := (EnsureRange(APan, -C_MIX_PAN_MAX, C_MIX_PAN_MAX) + C_MIX_PAN_MAX) / (2 * C_MIX_PAN_MAX) * (Pi / 2);
  AL := Cos(T);
  AR := Sin(T);
  // ganz aussen exakt 0 statt Rundungsrest
  if APan <= -C_MIX_PAN_MAX then AR := 0;
  if APan >= C_MIX_PAN_MAX then AL := 0;
end;

// ---------------------------------------------------------------------------
// Einstellungen (Registry) und gemeinsamer Speicher
// ---------------------------------------------------------------------------

const
  C_MIX_SETTINGS_KEY = 'Software\S2400 Aggregate';
  C_MIX_SHARED_NAME = 'Local\S2400Aggregate.Mixer';
  C_MIX_MAGIC = $53324D31; // 'S2M1' - Aufbau von TS2400MixShared

function S2400MixLoad: TS2400MixSettings;
var
  Reg: TRegistry;
  K, Ch, Side, OldPair, OldDb: Integer;
  OldOn: Boolean;
begin
  Result := S2400MixDefaults;
  Reg := TRegistry.Create(KEY_READ);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if not Reg.OpenKeyReadOnly(C_MIX_SETTINGS_KEY) then
        Exit;
      if Reg.ValueExists('MonEnabled') then
        Result.Enabled := Reg.ReadInteger('MonEnabled') <> 0;
      if Reg.ValueExists('MixRoute0') then
      begin
        for Ch := 0 to C_MIX_CHANNELS - 1 do
        begin
          if Reg.ValueExists(Format('MixOn%d', [Ch])) then
            Result.ChOn[Ch] := Reg.ReadInteger(Format('MixOn%d', [Ch])) <> 0;
          if Reg.ValueExists(Format('MixDb%d', [Ch])) then
            Result.ChDb[Ch] := EnsureRange(Reg.ReadInteger(Format('MixDb%d', [Ch])), C_MIX_DB_MIN, C_MIX_DB_MAX);
          if Reg.ValueExists(Format('MixPan%d', [Ch])) then
            Result.ChPan[Ch] := EnsureRange(Reg.ReadInteger(Format('MixPan%d', [Ch])), -C_MIX_PAN_MAX, C_MIX_PAN_MAX);
          if Reg.ValueExists(Format('MixRoute%d', [Ch])) then
            Result.ChRoute[Ch] := Cardinal(Reg.ReadInteger(Format('MixRoute%d', [Ch])));
        end;
      end
      else if Reg.ValueExists('MonPair') then
      begin
        // Stand 05.11.2026: Kanalpaare mit Ein/Pegel auf EIN Ausgangspaar
        OldPair := EnsureRange(Reg.ReadInteger('MonPair'), 0, C_MIX_MAX_PAIRS - 1);
        for K := 0 to C_MIX_CHANNELS div 2 - 1 do
        begin
          OldOn := K = 0;
          if Reg.ValueExists(Format('MonOn%d', [K])) then
            OldOn := Reg.ReadInteger(Format('MonOn%d', [K])) <> 0;
          OldDb := 0;
          if Reg.ValueExists(Format('MonDb%d', [K])) then
            OldDb := EnsureRange(Reg.ReadInteger(Format('MonDb%d', [K])), C_MIX_DB_MIN, C_MIX_DB_MAX);
          for Side := 0 to 1 do
          begin
            Ch := K * 2 + Side;
            Result.ChDb[Ch] := OldDb;
            if OldOn then
              Result.ChRoute[Ch] := Cardinal(1) shl OldPair
            else
              Result.ChRoute[Ch] := 0;
          end;
        end;
      end;
    except
      // unlesbare Werte: Vorgabe behalten
    end;
  finally
    Reg.Free;
  end;
end;

procedure S2400MixSave(const ASettings: TS2400MixSettings);
var
  Reg: TRegistry;
  Ch: Integer;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKey(C_MIX_SETTINGS_KEY, True) then
      begin
        Reg.WriteInteger('MonEnabled', Ord(ASettings.Enabled));
        for Ch := 0 to C_MIX_CHANNELS - 1 do
        begin
          Reg.WriteInteger(Format('MixOn%d', [Ch]), Ord(ASettings.ChOn[Ch]));
          Reg.WriteInteger(Format('MixDb%d', [Ch]), ASettings.ChDb[Ch]);
          Reg.WriteInteger(Format('MixPan%d', [Ch]), ASettings.ChPan[Ch]);
          Reg.WriteInteger(Format('MixRoute%d', [Ch]), Integer(ASettings.ChRoute[Ch]));
        end;
      end;
    except
      // nicht speicherbar: der Stand gilt trotzdem bis zum Beenden
    end;
  finally
    Reg.Free;
  end;
end;

procedure CopyName(const S: string; ADst: PWideChar);
var
  N: Integer;
begin
  N := Min(Length(S), C_MIX_NAME_LEN - 1);
  if N > 0 then
    Move(PChar(S)^, ADst^, N * SizeOf(WideChar));
  ADst[N] := #0;
end;

// Namen der Ausgangspaare aus der Registry (zuletzt vom Treiber gemeldet)
procedure LoadPairNames(AView: PS2400MixShared);
var
  Reg: TRegistry;
  L: TStringList;
  P: Integer;
begin
  Reg := TRegistry.Create(KEY_READ);
  L := TStringList.Create;
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKeyReadOnly(C_MIX_SETTINGS_KEY) and Reg.ValueExists('MixPairNames') then
      begin
        L.Delimiter := '|';
        L.StrictDelimiter := True;
        L.DelimitedText := Reg.ReadString('MixPairNames');
        AView^.PairCount := Min(L.Count, C_MIX_MAX_PAIRS);
        for P := 0 to AView^.PairCount - 1 do
          CopyName(L[P], @AView^.PairNames[P, 0]);
      end;
    except
      AView^.PairCount := 0;
    end;
  finally
    L.Free;
    Reg.Free;
  end;
end;

function S2400MixSharedOpen(out AMapping: THandle): PS2400MixShared;
var
  IsNew: Boolean;
begin
  Result := nil;
  AMapping := CreateFileMappingW(INVALID_HANDLE_VALUE, nil, PAGE_READWRITE, 0,
    SizeOf(TS2400MixShared), C_MIX_SHARED_NAME);
  if AMapping = 0 then
    Exit;
  IsNew := GetLastError <> ERROR_ALREADY_EXISTS;
  Result := MapViewOfFile(AMapping, FILE_MAP_ALL_ACCESS, 0, 0, SizeOf(TS2400MixShared));
  if Result = nil then
  begin
    CloseHandle(AMapping);
    AMapping := 0;
    Exit;
  end;
  if IsNew or (Result^.Magic <> C_MIX_MAGIC) then
  begin
    FillChar(Result^, SizeOf(TS2400MixShared), 0);
    Result^.Settings := S2400MixLoad;
    LoadPairNames(Result);
    Result^.Seq := 1;
    Result^.Magic := C_MIX_MAGIC;
  end;
end;

procedure S2400MixSharedClose(var AMapping: THandle; var AView: PS2400MixShared);
begin
  if AView <> nil then
    UnmapViewOfFile(AView);
  AView := nil;
  if AMapping <> 0 then
    CloseHandle(AMapping);
  AMapping := 0;
end;

procedure S2400MixSetPairNames(AView: PS2400MixShared; const ANames: TArray<string>);
var
  P: Integer;
  S: string;
  Reg: TRegistry;
begin
  if AView = nil then
    Exit;
  AView^.PairCount := Min(Length(ANames), C_MIX_MAX_PAIRS);
  S := '';
  for P := 0 to AView^.PairCount - 1 do
  begin
    CopyName(ANames[P], @AView^.PairNames[P, 0]);
    if P > 0 then
      S := S + '|';
    S := S + ANames[P];
  end;
  Reg := TRegistry.Create(KEY_WRITE);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKey(C_MIX_SETTINGS_KEY, True) then
        Reg.WriteString('MixPairNames', S);
    except
      // nur fuer die Anzeige ohne laufenden Treiber
    end;
  finally
    Reg.Free;
  end;
end;

procedure S2400MixSetOwner(AView: PS2400MixShared; ARunning, AIslaActive: Boolean; ALatencyMs: Double);
var
  Buf: array[0..MAX_PATH] of WideChar;
begin
  if AView = nil then
    Exit;
  if GetModuleFileNameW(0, Buf, MAX_PATH) = 0 then
    Buf[0] := #0;
  CopyName(ExtractFileName(string(PWideChar(@Buf[0]))), @AView^.OwnerName[0]);
  AView^.LatencyMs := ALatencyMs;
  AView^.IslaActive := AIslaActive;
  AView^.OwnerPid := GetCurrentProcessId;
  AView^.Running := ARunning;
end;

procedure S2400MixClearOwner(AView: PS2400MixShared);
begin
  if (AView = nil) or (AView^.OwnerPid <> GetCurrentProcessId) then
    Exit;
  AView^.Running := False;
  AView^.IslaActive := False;
  AView^.OwnerPid := 0;
end;

function LinToDb(AValue: Single): Single;
begin
  if AValue < 1E-6 then
    Result := -120
  else
    Result := 20 * Log10(AValue);
end;

// ---------------------------------------------------------------------------
// Zeichenhelfer (GDI+)
// ---------------------------------------------------------------------------

function ColA(AColor: TColor; AAlpha: Byte): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(AColor);
  Result := MakeColor(AAlpha, GetRValue(C), GetGValue(C), GetBValue(C));
end;

// abgerundetes Rechteck in einer Farbe mit Deckkraft (Schatten, Schein)
procedure FillRoundA(G: TGPGraphics; X, Y, W, H, R: Single; AColor: ARGB);
var
  P: TGPGraphicsPath;
  B: TGPSolidBrush;
begin
  if (W <= 0) or (H <= 0) then
    Exit;
  P := RoundPath(X, Y, W, H, R);
  B := TGPSolidBrush.Create(AColor);
  try
    G.FillPath(B, P);
  finally
    B.Free;
    P.Free;
  end;
end;

// abgerundetes Rechteck mit senkrechtem Farbverlauf
procedure FillGrad(G: TGPGraphics; X, Y, W, H, R: Single; ATop, ABottom: TColor);
var
  P: TGPGraphicsPath;
  B: TGPLinearGradientBrush;
begin
  if (W <= 0) or (H <= 0) then
    Exit;
  P := RoundPath(X, Y, W, H, R);
  B := TGPLinearGradientBrush.Create(MakeRect(X, Y - 0.5, W, H + 1), GpColor(ATop), GpColor(ABottom),
    LinearGradientModeVertical);
  try
    G.FillPath(B, P);
  finally
    B.Free;
    P.Free;
  end;
end;

procedure StrokeRound(G: TGPGraphics; X, Y, W, H, R: Single; AColor: ARGB; AWidth: Single);
var
  P: TGPGraphicsPath;
  Pen: TGPPen;
begin
  if (W <= AWidth) or (H <= AWidth) then
    Exit;
  P := RoundPath(X + AWidth / 2, Y + AWidth / 2, W - AWidth, H - AWidth, R);
  Pen := TGPPen.Create(AColor, AWidth);
  try
    G.DrawPath(Pen, P);
  finally
    Pen.Free;
    P.Free;
  end;
end;

procedure DrawLineA(G: TGPGraphics; X1, Y1, X2, Y2: Single; AColor: ARGB; AWidth: Single);
var
  Pen: TGPPen;
begin
  Pen := TGPPen.Create(AColor, AWidth);
  try
    G.DrawLine(Pen, X1, Y1, X2, Y2);
  finally
    Pen.Free;
  end;
end;

// vertieftes schwarzes Feld (Pegel, Anzeigen)
procedure DrawWell(G: TGPGraphics; X, Y, W, H: Single);
begin
  GpFillRound(G, X, Y, W, H, Sc(2), C_MX_WELL);
  StrokeRound(G, X, Y, W, H, Sc(2), GpColor(C_MX_WELL_EDGE), 1);
  // Lichtkante unten: das Feld wirkt eingelassen
  DrawLineA(G, X + Sc(2), Y + H + 0.5, X + W - Sc(2), Y + H + 0.5, ColA(C_MX_HILITE, 160), 1);
end;

// Farbe einer LED je nach Pegelbereich (Anteil von unten/links)
function LedColor(AFrac: Single): TColor;
begin
  if AFrac >= 0.95 then        // ab -3 dB
    Result := C_UI_ERR
  else if AFrac >= 0.8 then    // ab -12 dB
    Result := C_UI_ACCENT
  else
    Result := C_UI_LEVEL;
end;

function MeterFrac(ADb: Single): Single;
begin
  Result := (ADb - C_METER_MIN_DB) / -C_METER_MIN_DB;
  if Result < 0 then
    Result := 0
  else if Result > 1 then
    Result := 1;
end;

function FaderDbToPos(ADb: Single): Single;
var
  I: Integer;
  T: Single;
begin
  if ADb >= C_FADER_DB[0] then
    Exit(0);
  for I := 1 to High(C_FADER_DB) do
    if ADb >= C_FADER_DB[I] then
    begin
      T := (C_FADER_DB[I - 1] - ADb) / (C_FADER_DB[I - 1] - C_FADER_DB[I]);
      Exit(C_FADER_POS[I - 1] + T * (C_FADER_POS[I] - C_FADER_POS[I - 1]));
    end;
  Result := 1;
end;

function FaderPosToDb(APos: Single): Integer;
var
  I: Integer;
  T: Single;
begin
  if APos <= 0 then
    Exit(C_MIX_DB_MAX);
  for I := 1 to High(C_FADER_POS) do
    if APos <= C_FADER_POS[I] then
    begin
      T := (APos - C_FADER_POS[I - 1]) / (C_FADER_POS[I] - C_FADER_POS[I - 1]);
      Exit(Round(C_FADER_DB[I - 1] + T * (C_FADER_DB[I] - C_FADER_DB[I - 1])));
    end;
  Result := C_MIX_DB_MIN;
end;

procedure SmallFont(ACanvas: TCanvas; AColor: TColor; APx: Integer);
begin
  ACanvas.Font.Name := C_UI_FONT;
  ACanvas.Font.Style := [];
  ACanvas.Font.Height := -Sc(APx);
  ACanvas.Font.Color := AColor;
  ACanvas.Font.Quality := fqClearType;
end;

type
  // ---------------------------------------------------------------------------
  // LED-Pegelanzeige im vertieften Feld; senkrecht mit Skala rechts oder
  // waagerecht ohne Skala
  // ---------------------------------------------------------------------------
  TS2400Meter = class(TS2400UiControl)
  private
    FLevel, FPeak: Single;
    FVertical: Boolean;
    FShowScale: Boolean;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLevel(ALevelDb, APeakDb: Single);
    property Vertical: Boolean read FVertical write FVertical;
    property ShowScale: Boolean read FShowScale write FShowScale;
  end;

  // ---------------------------------------------------------------------------
  // Metall-Fader mit Skala links (Doppelklick = 0 dB, Mausrad 1 dB,
  // Umschalt 6 dB; der Griff laesst sich ohne Sprung ziehen)
  // ---------------------------------------------------------------------------
  TS2400Fader = class(TS2400UiControl)
  private
    FValue: Integer;
    FDragging: Boolean;
    FDragOffset: Integer;
    FOnChange: TNotifyEvent;
    procedure SetValue(AValue: Integer);
    function ScaleW: Integer;
    function CapH: Integer;
    function TrackTop: Integer;
    function TrackLen: Integer;
    function ValueToY(AValue: Single): Integer;
    procedure SetFromY(Y: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Value: Integer read FValue write SetValue;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // ---------------------------------------------------------------------------
  // Panorama-Drehknopf -100..+100 mit Wertebogen (ziehen auf/ab, Mausrad,
  // Doppelklick = Mitte)
  // ---------------------------------------------------------------------------
  TS2400Knob = class(TS2400UiControl)
  private
    FValue: Integer;
    FDragging: Boolean;
    FDragY, FDragValue: Integer;
    FOnChange: TNotifyEvent;
    procedure SetValue(AValue: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Value: Integer read FValue write SetValue;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // ---------------------------------------------------------------------------
  // Hardware-Taste mit Aufschrift (z.B. "M"); gedrueckt = bernstein
  // ---------------------------------------------------------------------------
  TS2400HwButton = class(TS2400UiControl)
  private
    FChecked: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Checked: Boolean read FChecked write SetChecked;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // ---------------------------------------------------------------------------
  // Routing-Taste mit LED-Streifen
  // ---------------------------------------------------------------------------
  TS2400CrossCell = class(TS2400UiControl)
  private
    FChecked: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Checked: Boolean read FChecked write SetChecked;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // ---------------------------------------------------------------------------
  // Zahlenanzeige im vertieften Feld (Spitzenwert)
  // ---------------------------------------------------------------------------
  TS2400Readout = class(TS2400UiControl)
  private
    FText: string;
    FAlarm: Boolean;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetValue(const AText: string; AAlarm: Boolean);
  end;

  TS2400MixPanel = record
    R: TRect;
    HeadH: Integer;   // Hoehe der Kopfleiste (0 = keine)
  end;

  TS2400MixerForm = class(TForm)
  private
    FStatus: TS2400MixStatusFunc;
    FOnChange: TS2400MixChangeProc;
    FPairCount: Integer;
    FPanels: TArray<TS2400MixPanel>;
    FRowRects: TArray<TRect>;      // jede zweite Routing-Zeile leicht abgesetzt
    FTimer: TTimer;
    FTick: Integer;
    FLoading: Boolean;
    FInDisp, FInHold, FInPeakHold: array[0..C_MIX_CHANNELS - 1] of Single;
    FInHoldUntil, FInPeakUntil: array[0..C_MIX_CHANNELS - 1] of UInt64;
    FOutDisp, FOutHold: array[0..2 * C_MIX_MAX_PAIRS - 1] of Single;
    FOutHoldUntil: array[0..2 * C_MIX_MAX_PAIRS - 1] of UInt64;
    // nicht modal (S2400 Monitor, 08.11.2026): das Fenster haelt den
    // gemeinsamen Speicher selbst und gibt ihn beim Schliessen frei
    FModeless: Boolean;
    FMapping: THandle;
    FView: PS2400MixShared;
    procedure AddPanel(const AR: TRect; AHeadH: Integer);
    function AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
      AColor: TColor; AAlign: TAlignment = taLeftJustify; ASemibold: Boolean = False): TLabel;
    procedure FormPaint(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TimerTick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure MasterChange(Sender: TObject);
    procedure MuteChange(Sender: TObject);
    procedure FaderChange(Sender: TObject);
    procedure PanChange(Sender: TObject);
    procedure CellChange(Sender: TObject);
    procedure MixChanged;
    procedure UpdateSub(const S: TS2400MixStatus);
  protected
    procedure CreateWnd; override;
    procedure CreateParams(var Params: TCreateParams); override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    Settings: TS2400MixSettings;
    LabelSub: TLabel;
    ToggleMaster: TS2400Toggle;
    MeterIn: array[0..C_MIX_CHANNELS - 1] of TS2400Meter;
    Fader: array[0..C_MIX_CHANNELS - 1] of TS2400Fader;
    Readout: array[0..C_MIX_CHANNELS - 1] of TS2400Readout;
    Knob: array[0..C_MIX_CHANNELS - 1] of TS2400Knob;
    ButtonMute: array[0..C_MIX_CHANNELS - 1] of TS2400HwButton;
    Cell: array[0..C_MIX_CHANNELS - 1, 0..C_MIX_MAX_PAIRS - 1] of TS2400CrossCell;
    MeterOutL, MeterOutR: array[0..C_MIX_MAX_PAIRS - 1] of TS2400Meter;
    ButtonClose: TS2400Button;
    constructor CreateMixer(AOwner: TComponent; const AStatus: TS2400MixStatusFunc;
      const APairNames: TArray<string>; const ASettings: TS2400MixSettings;
      const AOnChange: TS2400MixChangeProc);
    destructor Destroy; override;
  end;

// ---------------------------------------------------------------------------
// TS2400Meter
// ---------------------------------------------------------------------------

constructor TS2400Meter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  FLevel := -120;
  FPeak := -120;
  FVertical := True;
end;

procedure TS2400Meter.SetLevel(ALevelDb, APeakDb: Single);
begin
  if (Abs(ALevelDb - FLevel) < 0.05) and (Abs(APeakDb - FPeak) < 0.05) then
    Exit;
  FLevel := ALevelDb;
  FPeak := APeakDb;
  Invalidate;
end;

procedure TS2400Meter.Paint;
var
  G: TGPGraphics;
  WellW, WellH, Pad, Gap, SegL, Pos, FLvl, FPk: Single;
  N, I, PeakSeg, Tick: Integer;
  SegFrac: Single;
  Col: TColor;
  R: TRect;
  Y: Integer;
begin
  PaintBackground;
  if FVertical then
  begin
    N := C_METER_SEGMENTS;
    if FShowScale then WellW := Sc(10) else WellW := Width;
    WellH := Height;
  end
  else
  begin
    N := C_METER_SEGMENTS_H;
    WellW := Width;
    WellH := Height;
  end;
  if FVertical then Pad := 2 else Pad := 1; // die waagerechten Anzeigen sind nur 5 px hoch
  Gap := 1;
  FLvl := MeterFrac(FLevel);
  FPk := MeterFrac(FPeak);
  PeakSeg := -1;
  if FPeak > C_METER_MIN_DB then
  begin
    PeakSeg := Integer(Trunc(FPk * N - 0.0001));
    if PeakSeg > N - 1 then
      PeakSeg := N - 1;
  end;

  G := GpBegin(Canvas.Handle);
  try
    DrawWell(G, 0, 0, WellW, WellH - 1);
    if FVertical then
      SegL := (WellH - 1 - 2 * Pad - (N - 1) * Gap) / N
    else
      SegL := (WellW - 2 * Pad - (N - 1) * Gap) / N;
    for I := 0 to N - 1 do
    begin
      SegFrac := (I + 1) / N;
      if (SegFrac <= FLvl + 0.0001) or (I = PeakSeg) then
        Col := LedColor((I + 0.5) / N)
      else
        Col := C_MX_LED_OFF;
      Pos := Pad + I * (SegL + Gap);
      if FVertical then
        GpFillRound(G, Pad, WellH - 1 - Pos - SegL, WellW - 2 * Pad, SegL, 0.5, Col)
      else
        GpFillRound(G, Pos, Pad, SegL, WellH - 1 - 2 * Pad, 0.5, Col);
    end;
  finally
    G.Free;
  end;

  // Skala rechts neben dem Feld
  if FVertical and FShowScale then
  begin
    SmallFont(Canvas, C_MX_SCALE, 9);
    for Tick in C_METER_TICKS do
    begin
      Y := Round(WellH - 1 - Pad - MeterFrac(Tick) * (WellH - 1 - 2 * Pad));
      R := Rect(Round(WellW) + Sc(2), Y - Sc(6), Width, Y + Sc(6));
      UiText(Canvas, IntToStr(Abs(Tick)), R, DT_LEFT);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Fader
// ---------------------------------------------------------------------------

constructor TS2400Fader.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crHandPoint;
  TabStop := True;
  Width := Sc(36);
  Height := Sc(220);
end;

function TS2400Fader.ScaleW: Integer;
begin
  Result := Sc(14);
end;

function TS2400Fader.CapH: Integer;
begin
  Result := Sc(30);
end;

function TS2400Fader.TrackTop: Integer;
begin
  Result := CapH div 2;
end;

function TS2400Fader.TrackLen: Integer;
begin
  Result := Height - CapH;
end;

function TS2400Fader.ValueToY(AValue: Single): Integer;
begin
  Result := TrackTop + Round(FaderDbToPos(AValue) * TrackLen);
end;

procedure TS2400Fader.SetFromY(Y: Integer);
begin
  if TrackLen <= 0 then
    Exit;
  Value := FaderPosToDb((Y - TrackTop) / TrackLen);
end;

procedure TS2400Fader.SetValue(AValue: Integer);
begin
  AValue := EnsureRange(AValue, C_MIX_DB_MIN, C_MIX_DB_MAX);
  if AValue = FValue then
    Exit;
  FValue := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400Fader.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  CapY: Integer;
begin
  inherited;
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  if ssDouble in Shift then
  begin
    Value := 0;
    Exit;
  end;
  FDragging := True;
  CapY := ValueToY(FValue);
  if Abs(Y - CapY) <= CapH div 2 then
    FDragOffset := Y - CapY // am Griff gefasst: ohne Sprung ziehen
  else
  begin
    FDragOffset := 0;
    SetFromY(Y);
  end;
end;

procedure TS2400Fader.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDragging then
    SetFromY(Y - FDragOffset);
end;

procedure TS2400Fader.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDragging := False;
  Invalidate;
end;

function TS2400Fader.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  Step: Integer;
begin
  Result := True;
  if not Enabled then
    Exit;
  if ssShift in Shift then Step := 6 else Step := 1;
  if WheelDelta > 0 then
    Value := FValue + Step
  else if WheelDelta < 0 then
    Value := FValue - Step;
end;

procedure TS2400Fader.Paint;
var
  G: TGPGraphics;
  CX, SlotW, CapW, YT, Y, Tick: Integer;
  X0, Y0: Single;
  R: TRect;
  S: string;
begin
  PaintBackground;
  CX := ScaleW + (Width - ScaleW) div 2;
  SlotW := Sc(5);
  CapW := Width - ScaleW - Sc(2);
  YT := ValueToY(FValue);

  // Skala links
  SmallFont(Canvas, C_MX_SCALE, 9);
  for Tick in C_FADER_TICKS do
  begin
    Y := ValueToY(Tick);
    if Tick <= C_MIX_DB_MIN then
      S := #$221E
    else
      S := IntToStr(Abs(Tick));
    R := Rect(0, Y - Sc(6), ScaleW - Sc(3), Y + Sc(6));
    UiText(Canvas, S, R, DT_RIGHT);
  end;

  G := GpBegin(Canvas.Handle);
  try
    // Teilstriche zwischen Skala und Schlitz
    for Tick in C_FADER_TICKS do
    begin
      Y := ValueToY(Tick);
      DrawLineA(G, ScaleW - Sc(1), Y + 0.5, CX - SlotW, Y + 0.5, GpColor(C_MX_SCALE), 1);
    end;

    // Schlitz
    GpFillRound(G, CX - SlotW / 2, TrackTop - Sc(2), SlotW, TrackLen + Sc(4), SlotW / 2, C_MX_GROOVE);
    StrokeRound(G, CX - SlotW / 2 - 1, TrackTop - Sc(2) - 1, SlotW + 2, TrackLen + Sc(4) + 2,
      SlotW / 2 + 1, ColA(C_MX_HILITE, 140), 1);

    // Griff: Schatten, gebuerstetes Metall, Rillen, Bernstein-Mittellinie
    X0 := CX - CapW / 2;
    Y0 := YT - CapH / 2;
    FillRoundA(G, X0 + 1, Y0 + 2, CapW, CapH, Sc(3), ColA(clBlack, 110));
    FillGrad(G, X0, Y0, CapW, CapH / 2, Sc(3), C_MX_CAP_TOP, C_MX_CAP_MID);
    FillGrad(G, X0, Y0 + CapH / 2 - 1, CapW, CapH / 2 + 1, Sc(3), C_MX_CAP_MID, C_MX_CAP_BOT);
    StrokeRound(G, X0, Y0, CapW, CapH, Sc(3), ColA(clBlack, 200), 1);
    DrawLineA(G, X0 + Sc(2), Y0 + 1.5, X0 + CapW - Sc(2), Y0 + 1.5, ColA(clWhite, 150), 1);
    DrawLineA(G, X0 + Sc(3), Y0 + CapH * 0.25, X0 + CapW - Sc(3), Y0 + CapH * 0.25, ColA(clBlack, 70), 1);
    DrawLineA(G, X0 + Sc(3), Y0 + CapH * 0.75, X0 + CapW - Sc(3), Y0 + CapH * 0.75, ColA(clBlack, 70), 1);
    if FHot or FDragging then
      DrawLineA(G, X0 + 1, YT, X0 + CapW - 1, YT, GpColor(C_MX_LED_AMBER_H), Sc(2))
    else
      DrawLineA(G, X0 + 1, YT, X0 + CapW - 1, YT, GpColor(C_UI_ACCENT), Sc(2));
  finally
    G.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Knob
// ---------------------------------------------------------------------------

constructor TS2400Knob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crSizeNS;
  TabStop := True;
  Width := Sc(34);
  Height := Sc(34);
end;

procedure TS2400Knob.SetValue(AValue: Integer);
begin
  AValue := EnsureRange(AValue, -C_MIX_PAN_MAX, C_MIX_PAN_MAX);
  if AValue = FValue then
    Exit;
  FValue := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400Knob.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  if ssDouble in Shift then
  begin
    Value := 0;
    Exit;
  end;
  FDragging := True;
  FDragY := Y;
  FDragValue := FValue;
end;

procedure TS2400Knob.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  // 150 Pixel Weg = ganzer Bereich; mit Umschalt feiner
  if FDragging then
    if ssShift in Shift then
      Value := FDragValue + Round((FDragY - Y) * 0.4)
    else
      Value := FDragValue + Round((FDragY - Y) * 200 / Sc(150));
end;

procedure TS2400Knob.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDragging := False;
  Invalidate;
end;

function TS2400Knob.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  Step: Integer;
begin
  Result := True;
  if not Enabled then
    Exit;
  if ssShift in Shift then Step := 25 else Step := 5;
  if WheelDelta > 0 then
    Value := FValue + Step
  else if WheelDelta < 0 then
    Value := FValue - Step;
end;

procedure TS2400Knob.Paint;
var
  G: TGPGraphics;
  Pen: TGPPen;
  CX, CY, RA, RC, A, Rad: Single;
  ArcCol: ARGB;
begin
  PaintBackground;
  CX := Width / 2;
  CY := Height / 2;
  RA := Min(Width, Height) / 2 - Sc(3);   // Wertebogen
  RC := RA - Sc(4);                        // Knopfkappe
  A := FValue * 1.35;                      // -135..+135 Grad, 0 = oben
  G := GpBegin(Canvas.Handle);
  try
    // Bahn und Wertebogen (GDI+: 0 Grad = rechts, im Uhrzeigersinn)
    Pen := TGPPen.Create(GpColor(C_MX_KNOB_RING), Sc(3));
    try
      Pen.SetStartCap(LineCapRound);
      Pen.SetEndCap(LineCapRound);
      G.DrawArc(Pen, CX - RA, CY - RA, 2 * RA, 2 * RA, 135, 270);
    finally
      Pen.Free;
    end;
    if FHot or FDragging then ArcCol := GpColor(C_MX_LED_AMBER_H) else ArcCol := GpColor(C_UI_ACCENT);
    if Abs(A) > 0.5 then
    begin
      Pen := TGPPen.Create(ArcCol, Sc(3));
      try
        Pen.SetStartCap(LineCapRound);
        Pen.SetEndCap(LineCapRound);
        if A < 0 then
          G.DrawArc(Pen, CX - RA, CY - RA, 2 * RA, 2 * RA, -90 + A, -A)
        else
          G.DrawArc(Pen, CX - RA, CY - RA, 2 * RA, 2 * RA, -90, A);
      finally
        Pen.Free;
      end;
    end
    else
      GpFillCircle(G, CX, CY - RA, 1.5 * GUiScale, C_UI_ACCENT); // Mittelstellung: Punkt oben

    // Kappe: Schatten, Metallverlauf, Lichtkante
    GpFillCircle(G, CX + 0.5, CY + 1.5, RC, C_MX_EDGE);
    FillGrad(G, CX - RC, CY - RC, 2 * RC, 2 * RC, RC, C_MX_KNOB_TOP, C_MX_KNOB_BOT);
    StrokeRound(G, CX - RC, CY - RC, 2 * RC, 2 * RC, RC, ColA(clBlack, 200), 1);
    StrokeRound(G, CX - RC + 1, CY - RC + 1, 2 * RC - 2, 2 * RC - 2, RC - 1, ColA(clWhite, 40), 1);

    // Zeiger
    Rad := (A - 90) * Pi / 180;
    Pen := TGPPen.Create(GpColor(C_UI_TEXT), Sc(2));
    try
      Pen.SetStartCap(LineCapRound);
      Pen.SetEndCap(LineCapRound);
      G.DrawLine(Pen, CX + RC * 0.25 * Cos(Rad), CY + RC * 0.25 * Sin(Rad),
        CX + (RC - Sc(2)) * Cos(Rad), CY + (RC - Sc(2)) * Sin(Rad));
    finally
      Pen.Free;
    end;
  finally
    G.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TS2400HwButton
// ---------------------------------------------------------------------------

constructor TS2400HwButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crHandPoint;
  Width := Sc(26);
  Height := Sc(18);
end;

procedure TS2400HwButton.SetChecked(AValue: Boolean);
begin
  if AValue = FChecked then
    Exit;
  FChecked := AValue;
  Invalidate;
end;

procedure TS2400HwButton.Click;
begin
  inherited;
  if not Enabled then
    Exit;
  Checked := not FChecked;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400HwButton.Paint;
var
  G: TGPGraphics;
  W, H: Single;
  R: TRect;
begin
  PaintBackground;
  W := Width;
  H := Height - 1;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 1, W, H, Sc(3), C_MX_EDGE); // Schatten
    if FChecked then
      FillGrad(G, 0, 0, W, H, Sc(3), C_MX_BTN_ON_TOP, C_MX_BTN_ON_BOT)
    else if FHot then
      FillGrad(G, 0, 0, W, H, Sc(3), C_MX_HILITE, C_MX_BTN_BOT)
    else
      FillGrad(G, 0, 0, W, H, Sc(3), C_MX_BTN_TOP, C_MX_BTN_BOT);
    if FChecked then
      StrokeRound(G, 0, 0, W, H, Sc(3), GpColor(C_UI_SEL_BORDER), 1)
    else
      StrokeRound(G, 0, 0, W, H, Sc(3), GpColor(C_MX_EDGE), 1);
    DrawLineA(G, Sc(3), 1.5, W - Sc(3), 1.5, ColA(clWhite, 45), 1);
  finally
    G.Free;
  end;
  Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Sc(11);
  Canvas.Font.Quality := fqClearType;
  if FChecked then
    Canvas.Font.Color := C_UI_SEL_TEXT
  else
    Canvas.Font.Color := C_UI_TEXT2;
  R := Rect(0, 0, Width, Height - 1);
  UiText(Canvas, Caption, R, DT_CENTER);
end;

// ---------------------------------------------------------------------------
// TS2400CrossCell
// ---------------------------------------------------------------------------

constructor TS2400CrossCell.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_BG;
  Cursor := crHandPoint;
  Width := Sc(40);
  Height := Sc(20);
end;

procedure TS2400CrossCell.SetChecked(AValue: Boolean);
begin
  if AValue = FChecked then
    Exit;
  FChecked := AValue;
  Invalidate;
end;

procedure TS2400CrossCell.Click;
begin
  inherited;
  if not Enabled then
    Exit;
  Checked := not FChecked;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400CrossCell.Paint;
var
  G: TGPGraphics;
  W, H, LW, LH, LX, LY: Single;
begin
  PaintBackground;
  W := Width;
  H := Height - 1;
  LW := W - Sc(10);
  if LW > Sc(16) then
    LW := Sc(16);
  LH := Sc(5);
  LX := (W - LW) / 2;
  LY := (H - LH) / 2;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 1, W, H, Sc(3), C_MX_EDGE);
    if FHot then
      FillGrad(G, 0, 0, W, H, Sc(3), C_MX_HILITE, C_MX_PANEL_BOT)
    else
      FillGrad(G, 0, 0, W, H, Sc(3), C_MX_PANEL_TOP, C_MX_PANEL_BOT);
    StrokeRound(G, 0, 0, W, H, Sc(3), GpColor(C_MX_EDGE), 1);
    DrawLineA(G, Sc(3), 1.5, W - Sc(3), 1.5, ColA(clWhite, 30), 1);
    if FChecked then
    begin
      // leuchtende LED mit leichtem Schein
      FillRoundA(G, LX - Sc(3), LY - Sc(3), LW + Sc(6), LH + Sc(6), Sc(4), ColA(C_UI_ACCENT, 45));
      FillGrad(G, LX, LY, LW, LH, 1.5, C_MX_LED_AMBER_H, C_UI_SEL_DETAIL);
    end
    else
    begin
      GpFillRound(G, LX, LY, LW, LH, 1.5, C_MX_KNOB_RING);
      StrokeRound(G, LX, LY, LW, LH, 1.5, GpColor(C_MX_WELL_EDGE), 1);
    end;
  finally
    G.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Readout
// ---------------------------------------------------------------------------

constructor TS2400Readout.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Width := Sc(44);
  Height := Sc(18);
  FText := #$2212#$221E;
end;

procedure TS2400Readout.SetValue(const AText: string; AAlarm: Boolean);
begin
  if (AText = FText) and (AAlarm = FAlarm) then
    Exit;
  FText := AText;
  FAlarm := AAlarm;
  Invalidate;
end;

procedure TS2400Readout.Paint;
var
  G: TGPGraphics;
  R: TRect;
begin
  PaintBackground;
  G := GpBegin(Canvas.Handle);
  try
    DrawWell(G, 0, 0, Width, Height - 1);
  finally
    G.Free;
  end;
  Canvas.Font.Name := 'Consolas';
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Sc(11);
  Canvas.Font.Quality := fqClearType;
  if FAlarm then
    Canvas.Font.Color := C_UI_ERR
  else
    Canvas.Font.Color := C_UI_TEXT;
  R := Rect(0, 0, Width, Height - 1);
  UiText(Canvas, FText, R, DT_CENTER);
end;

// ---------------------------------------------------------------------------
// TS2400MixerForm - Aufbau
// ---------------------------------------------------------------------------

var
  GMixCreatingModeless: Boolean = False; // gesetzt waehrend CreateMixer fuer das nicht modale Fenster
  GMixModeless: TS2400MixerForm = nil;

constructor TS2400MixerForm.CreateMixer(AOwner: TComponent; const AStatus: TS2400MixStatusFunc;
  const APairNames: TArray<string>; const ASettings: TS2400MixSettings;
  const AOnChange: TS2400MixChangeProc);
var
  M, G, LabelW, SW, X, Y, Y0, StripH, RowH, Ch, P, CellW: Integer;
  L: TLabel;
begin
  FModeless := GMixCreatingModeless; // vor dem Anlegen des Fensters (CreateParams)
  inherited CreateNew(AOwner);
  FStatus := AStatus;
  FOnChange := AOnChange;
  Settings := ASettings;
  FPairCount := Min(Length(APairNames), C_MIX_MAX_PAIRS);
  FLoading := True;

  Scaled := False;
  BorderStyle := bsDialog;
  BorderIcons := [biSystemMenu];
  Position := poScreenCenter;
  Caption := Tr('Isla-Mixer', 'Isla mixer');
  Color := C_MX_BG;
  DoubleBuffered := True;
  KeyPreview := True;
  UiSetFont(Font, 9, C_UI_TEXT);
  OnPaint := FormPaint;
  OnKeyDown := FormKeyDown;

  M := Sc(14);       // Rand
  G := Sc(4);        // Abstand der Kanalzuege
  LabelW := Sc(150); // linke Spalte: Isla-Feld oben, Namen der Ausgangspaare unten
  SW := Sc(62);      // Breite eines Kanalzugs
  StripH := Sc(372);
  RowH := Sc(28);
  ClientWidth := M + LabelW + G + C_MIX_CHANNELS * SW + (C_MIX_CHANNELS - 1) * G + M;
  Y0 := M;

  // --- Isla-Feld links ---
  AddPanel(Rect(M, Y0, M + LabelW, Y0 + StripH), Sc(22));
  AddLabel(M, Y0 + Sc(2), LabelW, Sc(18), 'ISLA S2400', 9, C_UI_TEXT, taCenter, True);
  AddLabel(M + Sc(12), Y0 + Sc(34), LabelW - Sc(24), Sc(20), Tr('Isla-Mixer', 'Isla mixer'), 13, C_UI_TEXT, taLeftJustify, True);
  ToggleMaster := TS2400Toggle.Create(Self);
  ToggleMaster.Parent := Self;
  ToggleMaster.Color := C_MX_PANEL;
  ToggleMaster.Caption := 'Monitoring';
  ToggleMaster.SetBounds(M + Sc(10), Y0 + Sc(64), LabelW - Sc(20), Sc(24));
  ToggleMaster.Checked := Settings.Enabled;
  ToggleMaster.OnChange := MasterChange;
  LabelSub := AddLabel(M + Sc(12), Y0 + Sc(98), LabelW - Sc(24), Sc(110), '', 8, C_UI_TEXT2);
  LabelSub.WordWrap := True;
  L := AddLabel(M + Sc(12), Y0 + StripH - Sc(118), LabelW - Sc(24), Sc(108),
    Tr('Fader und Knopf: Doppelklick = 0 dB bzw. Mitte. Mausrad = 1 dB bzw. 5 %, Umschalt = gr'#$00F6#$00DF'er. ' +
    #$00C4'nderungen gelten sofort.',
    'Fader and knob: double-click = 0 dB or centre. Mouse wheel = 1 dB or 5 %, Shift = larger. ' +
    'Changes apply immediately.'), 8, C_UI_MUTED);
  L.WordWrap := True;

  // --- Kanalzuege ---
  for Ch := 0 to C_MIX_CHANNELS - 1 do
  begin
    X := M + LabelW + G + Ch * (SW + G);
    AddPanel(Rect(X, Y0, X + SW, Y0 + StripH), Sc(22));
    AddLabel(X, Y0 + Sc(2), SW, Sc(18), UpperCase(C_CHANNEL_NAMES[Ch]), 9, C_UI_TEXT, taCenter, True);

    Knob[Ch] := TS2400Knob.Create(Self);
    Knob[Ch].Parent := Self;
    Knob[Ch].SetBounds(X + (SW - Sc(36)) div 2, Y0 + Sc(30), Sc(36), Sc(36));
    Knob[Ch].Tag := Ch;
    Knob[Ch].Value := Settings.ChPan[Ch];
    Knob[Ch].OnChange := PanChange;
    with AddLabel(X + Sc(8), Y0 + Sc(62), Sc(12), Sc(12), 'L', 7, C_MX_SCALE) do Font.Height := -Sc(9);
    with AddLabel(X + SW - Sc(20), Y0 + Sc(62), Sc(12), Sc(12), 'R', 7, C_MX_SCALE, taRightJustify) do Font.Height := -Sc(9);

    ButtonMute[Ch] := TS2400HwButton.Create(Self);
    ButtonMute[Ch].Parent := Self;
    ButtonMute[Ch].Caption := 'M';
    ButtonMute[Ch].SetBounds(X + (SW - Sc(28)) div 2, Y0 + Sc(80), Sc(28), Sc(19));
    ButtonMute[Ch].Tag := Ch;
    ButtonMute[Ch].Checked := not Settings.ChOn[Ch];
    ButtonMute[Ch].OnChange := MuteChange;

    Fader[Ch] := TS2400Fader.Create(Self);
    Fader[Ch].Parent := Self;
    Fader[Ch].SetBounds(X + Sc(2), Y0 + Sc(110), Sc(34), Sc(220));
    Fader[Ch].Tag := Ch;
    Fader[Ch].Value := Settings.ChDb[Ch];
    Fader[Ch].OnChange := FaderChange;

    MeterIn[Ch] := TS2400Meter.Create(Self);
    MeterIn[Ch].Parent := Self;
    MeterIn[Ch].ShowScale := True;
    MeterIn[Ch].SetBounds(X + Sc(38), Y0 + Sc(110) + Sc(13), Sc(23), Sc(220) - Sc(26));

    Readout[Ch] := TS2400Readout.Create(Self);
    Readout[Ch].Parent := Self;
    Readout[Ch].SetBounds(X + (SW - Sc(46)) div 2, Y0 + Sc(342), Sc(46), Sc(19));
  end;

  // --- Routing ---
  Y := Y0 + StripH + Sc(10);
  AddPanel(Rect(M, Y, ClientWidth - M, Y + Sc(22)), Sc(22));
  AddLabel(M + Sc(10), Y + Sc(2), Sc(400), Sc(18),
    AnsiUpperCase(Tr('Routing zu den Ausg'#$00E4'ngen des Masters', 'Routing to the master outputs')), 8, C_UI_TEXT2, taLeftJustify, True);
  Inc(Y, Sc(22) + Sc(6));
  CellW := SW - Sc(14);
  SetLength(FRowRects, 0);
  for P := 0 to FPairCount - 1 do
  begin
    if not Odd(P) then
      FRowRects := FRowRects + [Rect(M, Y - Sc(2), ClientWidth - M, Y + RowH - Sc(2))];
    L := AddLabel(M + Sc(8), Y, LabelW - Sc(14), Sc(15), APairNames[P], 8, C_UI_TEXT2);
    L.EllipsisPosition := epEndEllipsis;
    MeterOutL[P] := TS2400Meter.Create(Self);
    MeterOutL[P].Parent := Self;
    MeterOutL[P].Vertical := False;
    MeterOutL[P].Color := C_MX_BG;
    MeterOutL[P].SetBounds(M + Sc(8), Y + Sc(16), LabelW - Sc(16), Sc(5));
    MeterOutR[P] := TS2400Meter.Create(Self);
    MeterOutR[P].Parent := Self;
    MeterOutR[P].Vertical := False;
    MeterOutR[P].Color := C_MX_BG;
    MeterOutR[P].SetBounds(M + Sc(8), Y + Sc(21), LabelW - Sc(16), Sc(5));
    for Ch := 0 to C_MIX_CHANNELS - 1 do
    begin
      X := M + LabelW + G + Ch * (SW + G);
      Cell[Ch, P] := TS2400CrossCell.Create(Self);
      Cell[Ch, P].Parent := Self;
      Cell[Ch, P].SetBounds(X + (SW - CellW) div 2, Y + Sc(2), CellW, Sc(20));
      Cell[Ch, P].Tag := Ch * C_MIX_MAX_PAIRS + P;
      Cell[Ch, P].Checked := (Settings.ChRoute[Ch] and (Cardinal(1) shl P)) <> 0;
      Cell[Ch, P].OnChange := CellChange;
    end;
    Inc(Y, RowH);
  end;
  if FPairCount = 0 then
  begin
    AddLabel(M + Sc(8), Y, ClientWidth - 2 * M, Sc(22), Tr('Kein Master-Ger'#$00E4't geladen.', 'No master device loaded.'), 9, C_UI_TEXT2);
    Inc(Y, Sc(24));
  end;
  // abwechselnd abgesetzte Zeilen: Farbe auch hinter den Elementen
  for P := 0 to FPairCount - 1 do
  begin
    if Odd(P) then
      Continue;
    MeterOutL[P].Color := C_MX_ROW_ALT;
    MeterOutR[P].Color := C_MX_ROW_ALT;
    for Ch := 0 to C_MIX_CHANNELS - 1 do
      Cell[Ch, P].Color := C_MX_ROW_ALT;
  end;
  Inc(Y, Sc(8));

  // --- Fuss ---
  ButtonClose := TS2400Button.Create(Self);
  ButtonClose.Parent := Self;
  ButtonClose.Color := C_MX_BG;
  ButtonClose.Caption := Tr('Schlie'#$00DF'en', 'Close');
  ButtonClose.Primary := True;
  ButtonClose.Width := Max(Sc(110), ButtonClose.PreferredWidth);
  ButtonClose.SetBounds(ClientWidth - M - ButtonClose.Width, Y, ButtonClose.Width, Sc(30));
  ButtonClose.OnClick := CloseClick;
  Inc(Y, Sc(30) + M);
  ClientHeight := Y;

  for Ch := 0 to C_MIX_CHANNELS - 1 do
  begin
    FInDisp[Ch] := -120;
    FInHold[Ch] := -120;
    FInPeakHold[Ch] := -120;
  end;
  for P := 0 to 2 * C_MIX_MAX_PAIRS - 1 do
  begin
    FOutDisp[P] := -120;
    FOutHold[P] := -120;
  end;
  FLoading := False;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := Assigned(FStatus);
end;

destructor TS2400MixerForm.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  if FModeless then
  begin
    // Einstellungen sichern, gemeinsamen Speicher freigeben
    S2400MixSave(Settings);
    S2400MixSharedClose(FMapping, FView);
  end;
  inherited Destroy;
  if FModeless then
  begin
    UiGdiplusStop;
    if GMixModeless = Self then
      GMixModeless := nil;
  end;
end;

procedure TS2400MixerForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  if FModeless then
  begin
    // eigene Schaltflaeche in der Taskleiste, unabhaengig vom Monitor
    Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
    Params.WndParent := 0;
  end;
end;

procedure TS2400MixerForm.DoClose(var Action: TCloseAction);
begin
  inherited DoClose(Action);
  if FModeless then
    Action := caFree;
end;

procedure TS2400MixerForm.CreateWnd;
var
  Dark: BOOL;
  Col: COLORREF;
begin
  inherited CreateWnd;
  Dark := True;
  if DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @Dark, SizeOf(Dark)) <> S_OK then
    DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, @Dark, SizeOf(Dark));
  Col := ColorToRGB(C_MX_BG);
  DwmSetWindowAttribute(Handle, DWMWA_CAPTION_COLOR, @Col, SizeOf(Col));
  Col := ColorToRGB(C_UI_TEXT);
  DwmSetWindowAttribute(Handle, DWMWA_TEXT_COLOR, @Col, SizeOf(Col));
end;

procedure TS2400MixerForm.AddPanel(const AR: TRect; AHeadH: Integer);
var
  P: TS2400MixPanel;
begin
  P.R := AR;
  P.HeadH := AHeadH;
  FPanels := FPanels + [P];
end;

function TS2400MixerForm.AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
  AColor: TColor; AAlign: TAlignment; ASemibold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.AutoSize := False;
  Result.Transparent := True;
  Result.ShowAccelChar := False;
  Result.Alignment := AAlign;
  Result.Layout := tlCenter;
  Result.SetBounds(AX, AY, AW, AH);
  UiSetFont(Result.Font, ASize, AColor, ASemibold);
  Result.Caption := AText;
end;

// Flaechen der Konsole: Kanalzuege mit Metallverlauf, Lichtkante oben,
// dunkler Kante, Kopfleiste; Routing-Zeilen abwechselnd abgesetzt
procedure TS2400MixerForm.FormPaint(Sender: TObject);
var
  G: TGPGraphics;
  P: TS2400MixPanel;
  RR: TRect;
  X, Y, W, H, HH: Single;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_MX_BG;
  Canvas.FillRect(ClientRect);
  G := GpBegin(Canvas.Handle);
  try
    for RR in FRowRects do
      GpFillRound(G, RR.Left, RR.Top, RR.Width, RR.Height, Sc(3), C_MX_ROW_ALT);
    for P in FPanels do
    begin
      X := P.R.Left;
      Y := P.R.Top;
      W := P.R.Width;
      H := P.R.Height;
      FillRoundA(G, X + 1, Y + 2, W, H, Sc(4), ColA(clBlack, 120)); // Schatten
      GpFillRound(G, X, Y, W, H, Sc(4), C_MX_PANEL);
      if P.HeadH > 0 then
      begin
        HH := P.HeadH;
        if HH > H then
          HH := H;
        FillGrad(G, X, Y, W, HH, Sc(4), C_MX_HEAD_TOP, C_MX_HEAD_BOT);
        if P.HeadH < H then
          DrawLineA(G, X + 1, Y + P.HeadH + 0.5, X + W - 1, Y + P.HeadH + 0.5, GpColor(C_MX_EDGE), 1);
      end;
      StrokeRound(G, X, Y, W, H, Sc(4), GpColor(C_MX_EDGE), 1);
      DrawLineA(G, X + Sc(4), Y + 1.5, X + W - Sc(4), Y + 1.5, ColA(clWhite, 28), 1);
    end;
  finally
    G.Free;
  end;
end;

procedure TS2400MixerForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_ESCAPE) or (Key = VK_RETURN) then
  begin
    if FModeless then
      Close
    else
      ModalResult := mrOk;
    Key := 0;
  end;
end;

// ---------------------------------------------------------------------------
// Aenderungen
// ---------------------------------------------------------------------------

procedure TS2400MixerForm.MixChanged;
begin
  if not FLoading and Assigned(FOnChange) then
    FOnChange(Settings);
end;

procedure TS2400MixerForm.MasterChange(Sender: TObject);
begin
  Settings.Enabled := ToggleMaster.Checked;
  MixChanged;
end;

procedure TS2400MixerForm.MuteChange(Sender: TObject);
var
  Ch: Integer;
begin
  Ch := TComponent(Sender).Tag;
  Settings.ChOn[Ch] := not ButtonMute[Ch].Checked;
  MixChanged;
end;

procedure TS2400MixerForm.FaderChange(Sender: TObject);
var
  Ch: Integer;
begin
  Ch := TComponent(Sender).Tag;
  Settings.ChDb[Ch] := Fader[Ch].Value;
  MixChanged;
end;

procedure TS2400MixerForm.PanChange(Sender: TObject);
var
  Ch: Integer;
begin
  Ch := TComponent(Sender).Tag;
  Settings.ChPan[Ch] := Knob[Ch].Value;
  MixChanged;
end;

procedure TS2400MixerForm.CellChange(Sender: TObject);
var
  Ch, P: Integer;
  Bit: Cardinal;
begin
  Ch := TComponent(Sender).Tag div C_MIX_MAX_PAIRS;
  P := TComponent(Sender).Tag mod C_MIX_MAX_PAIRS;
  Bit := Cardinal(1) shl P;
  if Cell[Ch, P].Checked then
    Settings.ChRoute[Ch] := Settings.ChRoute[Ch] or Bit
  else
    Settings.ChRoute[Ch] := Settings.ChRoute[Ch] and not Bit;
  MixChanged;
end;

procedure TS2400MixerForm.CloseClick(Sender: TObject);
begin
  if FModeless then
    Close
  else
    ModalResult := mrOk;
end;

// ---------------------------------------------------------------------------
// Live-Anzeige
// ---------------------------------------------------------------------------

procedure TS2400MixerForm.UpdateSub(const S: TS2400MixStatus);
var
  Host: string;
begin
  Host := ChangeFileExt(ExtractFileName(S.OwnerName), '');
  if not S.Running then
    LabelSub.Caption := Tr('Der Verbund l'#$00E4'uft gerade in keinem Programm. Einstellungen gelten beim n'#$00E4'chsten Start.',
      'The aggregate is not running in any program. Settings apply at the next start.')
  else if not Settings.Enabled then
    LabelSub.Caption := Format(Tr('L'#$00E4'uft in: %s'#13#10#13#10'Monitoring aus. Die Pegel zeigen trotzdem, ' +
      'was von der Isla kommt.', 'Running in: %s'#13#10#13#10'Monitoring off. The meters still show what ' +
      'comes from the Isla.'), [Host])
  else if S.MonActive and (S.LatencyMs > 0) then
    LabelSub.Caption := Format(Tr('L'#$00E4'uft in: %s'#13#10'Latenz ca. %.1f ms'#13#10#13#10'In der Audio-' +
      'Software das Monitoring der Isla-Spuren auf "Aus" stellen.', 'Running in: %s'#13#10'Latency approx. %.1f ms' +
      #13#10#13#10'In your audio software set monitoring of the Isla tracks to "Off".'), [Host, S.LatencyMs])
  else
    LabelSub.Caption := Format(Tr('L'#$00E4'uft in: %s'#13#10#13#10'Wartet auf die Isla.',
      'Running in: %s'#13#10#13#10'Waiting for the Isla.'), [Host]);
end;

procedure TS2400MixerForm.TimerTick(Sender: TObject);
var
  S: TS2400MixStatus;
  NowT: UInt64;
  Ch, P: Integer;
  Db: Single;

  procedure Upd(AMeter: TS2400Meter; APeak: Single; var ADisp, AHold: Single; var AHoldUntil: UInt64);
  var
    D: Single;
  begin
    D := LinToDb(APeak);
    // Anzeige faellt langsam, steigt sofort
    ADisp := ADisp - C_METER_FALL_DB;
    if D > ADisp then
      ADisp := D;
    if D >= AHold then
    begin
      AHold := D;
      AHoldUntil := NowT + C_METER_HOLD_MS;
    end
    else if NowT > AHoldUntil then
    begin
      AHold := AHold - C_METER_FALL_DB;
      if D > AHold then
        AHold := D;
    end;
    if ADisp < -120 then ADisp := -120;
    if AHold < -120 then AHold := -120;
    AMeter.SetLevel(ADisp, AHold);
  end;

begin
  try
    S := FStatus();
    NowT := GetTickCount64;
    for Ch := 0 to C_MIX_CHANNELS - 1 do
    begin
      Upd(MeterIn[Ch], S.InPeak[Ch], FInDisp[Ch], FInHold[Ch], FInHoldUntil[Ch]);
      // Spitzenwert in Zahlen: 3 s halten
      Db := LinToDb(S.InPeak[Ch]);
      if (Db >= FInPeakHold[Ch]) or (NowT > FInPeakUntil[Ch]) then
      begin
        FInPeakHold[Ch] := Db;
        FInPeakUntil[Ch] := NowT + 3000;
      end;
      if FInPeakHold[Ch] <= C_METER_MIN_DB then
        Readout[Ch].SetValue(#$2212#$221E, False)
      else
        Readout[Ch].SetValue(FormatFloat('0.0', FInPeakHold[Ch]), FInPeakHold[Ch] >= -0.1);
    end;
    for P := 0 to FPairCount - 1 do
    begin
      Upd(MeterOutL[P], S.OutPeak[P * 2], FOutDisp[P * 2], FOutHold[P * 2], FOutHoldUntil[P * 2]);
      Upd(MeterOutR[P], S.OutPeak[P * 2 + 1], FOutDisp[P * 2 + 1], FOutHold[P * 2 + 1], FOutHoldUntil[P * 2 + 1]);
    end;
    if FTick mod 5 = 0 then
      UpdateSub(S);
    Inc(FTick);
  except
    FTimer.Enabled := False; // Anzeige ist nie wichtiger als der Host
  end;
end;

// ---------------------------------------------------------------------------
// Aufruf
// ---------------------------------------------------------------------------

// lebt der Prozess noch, der den Verbund betreibt? (Absturz von Live o.ae.)
function ProcessAlive(APid: Cardinal): Boolean;
var
  H: THandle;
begin
  Result := False;
  if APid = 0 then
    Exit;
  if APid = GetCurrentProcessId then
    Exit(True);
  H := OpenProcess(SYNCHRONIZE, False, APid);
  if H = 0 then
    Exit;
  try
    Result := WaitForSingleObject(H, 0) = WAIT_TIMEOUT;
  finally
    CloseHandle(H);
  end;
end;

// Mixer-Fenster fuer einen geoeffneten gemeinsamen Speicher anlegen
function NewMixerForm(AView: PS2400MixShared): TS2400MixerForm;
var
  Names: TArray<string>;
  P: Integer;
begin
  Names := nil;
  for P := 0 to Min(AView^.PairCount, C_MIX_MAX_PAIRS) - 1 do
    Names := Names + [string(PWideChar(@AView^.PairNames[P, 0]))];
  Result := TS2400MixerForm.CreateMixer(nil,
    function: TS2400MixStatus
    var
      I: Integer;
    begin
      Result := Default(TS2400MixStatus);
      Result.Running := AView^.Running and ProcessAlive(AView^.OwnerPid);
      Result.MonActive := Result.Running and AView^.IslaActive and AView^.Settings.Enabled;
      Result.LatencyMs := AView^.LatencyMs;
      if Result.Running then
        Result.OwnerName := string(PWideChar(@AView^.OwnerName[0]));
      // Spitzen seit dem letzten Abruf abholen und zuruecksetzen
      for I := 0 to C_MIX_CHANNELS - 1 do
      begin
        Result.InPeak[I] := AView^.InPeak[I];
        AView^.InPeak[I] := 0;
      end;
      for I := 0 to 2 * C_MIX_MAX_PAIRS - 1 do
      begin
        Result.OutPeak[I] := AView^.OutPeak[I];
        AView^.OutPeak[I] := 0;
      end;
    end,
    Names, AView^.Settings,
    procedure(const AMix: TS2400MixSettings)
    begin
      // erst die Werte, dann den Zaehler - der Treiber uebernimmt beim naechsten Rueckruf
      AView^.Settings := AMix;
      InterlockedIncrement(AView^.Seq);
    end);
end;

// nicht modal (S2400 Monitor): Mixer und andere Fenster, z.B. der
// Isla-Zuspieler, bleiben gleichzeitig bedienbar
procedure ShowS2400AggMixerModeless;
var
  Mapping: THandle;
  View: PS2400MixShared;
begin
  if GMixModeless <> nil then
  begin
    if IsIconic(GMixModeless.Handle) then
      ShowWindow(GMixModeless.Handle, SW_RESTORE);
    GMixModeless.Show;
    SetForegroundWindow(GMixModeless.Handle);
    Exit;
  end;
  View := S2400MixSharedOpen(Mapping);
  if View = nil then
  begin
    MessageBox(0, PChar(Tr('Der Isla-Mixer kann nicht ge'#$00F6'ffnet werden (gemeinsamer Speicher fehlt).',
      'The Isla mixer cannot be opened (shared memory missing).')), 'S2400', MB_ICONWARNING);
    Exit;
  end;
  GUiScale := Screen.PixelsPerInch / 96;
  UiGdiplusStart;
  try
    GMixCreatingModeless := True;
    try
      GMixModeless := NewMixerForm(View);
    finally
      GMixCreatingModeless := False;
    end;
  except
    // Destroy (automatisch nach dem Fehler) hat UiGdiplusStop schon gerufen
    GMixModeless := nil;
    S2400MixSharedClose(Mapping, View);
    raise;
  end;
  GMixModeless.FMapping := Mapping; // gibt das Fenster beim Schliessen frei
  GMixModeless.FView := View;
  GMixModeless.Show;
  SetForegroundWindow(GMixModeless.Handle);
end;

procedure CloseS2400AggMixerModeless;
begin
  if GMixModeless <> nil then
    GMixModeless.Free; // Destroy speichert und setzt GMixModeless zurueck
end;

procedure RunS2400AggMixerApp;
begin
  ShowS2400AggMixerModeless;
  // eigene Nachrichtenschleife: das Fenster ist kein Application.MainForm
  while (GMixModeless <> nil) and not Application.Terminated do
    Application.HandleMessage;
end;

procedure ShowS2400AggMixer(AOwnerWnd: HWND);
var
  Form: TS2400MixerForm;
  PrevAppHandle: HWND;
  Mapping: THandle;
  View: PS2400MixShared;
  S: TS2400MixSettings;
begin
  View := S2400MixSharedOpen(Mapping);
  if View = nil then
  begin
    MessageBox(AOwnerWnd, PChar(Tr('Der Isla-Mixer kann nicht ge'#$00F6'ffnet werden (gemeinsamer Speicher fehlt).',
      'The Isla mixer cannot be opened (shared memory missing).')), 'S2400', MB_ICONWARNING);
    Exit;
  end;
  try
    S := View^.Settings;
    GUiScale := Screen.PixelsPerInch / 96;
    UiGdiplusStart;
    try
      Form := NewMixerForm(View);
      try
        PrevAppHandle := Application.Handle;
        if AOwnerWnd <> 0 then
          Application.Handle := AOwnerWnd;
        try
          Form.ShowModal;
        finally
          Application.Handle := PrevAppHandle;
        end;
        S := Form.Settings;
      finally
        Form.Free;
      end;
    finally
      UiGdiplusStop;
    end;
    S2400MixSave(S);
  finally
    S2400MixSharedClose(Mapping, View);
  end;
end;

end.
