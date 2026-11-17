unit S2400Zuspieler;

// =============================================================================
// S2400Zuspieler.pas - Isla-Zuspieler (08.11.2026)
//
// Spielt Samples (z.B. von Splice) analog in die Isla S2400: Ausgabe ueber
// die Realtek-Karte (WASAPI, geteilter Modus - laeuft also auch neben dem
// Verbund und Live), Kabel auf Line 1&2 der Isla, dort mit 26 kHz/12 Bit
// sampeln (Shift+Sample).
//
//   Plattenspieler  Original, 33->45, 45->78, +1 Oktave (Tempo und Tonhoehe
//                   gemeinsam) - gilt fuer alle Spuren. STACK-TEMPO frei
//                   (-/+ 0,1 bzw. 1 BPM, eintippen), Schlag-LEDs, TONHOEHE
//                   HALTEN (Tempo ohne Tonhoehe, per Zeitdehnung)
//   Spuren 1..8     Spur 1 fuehrt, alle weiteren folgen ihrem Tempo wie von
//                   Platte (Tempo und Tonhoehe gemeinsam, SP-1200-Art).
//                   Je Spur: Wellenform, BPM, Faktor, Tonart Original ->
//                   Ergebnis, Pitch (Halbtoene; Tempo bleibt), Pegel, M
//                   (stumm - laeuft weiter, bleibt synchron), S (solo),
//                   entfernen. "+ Spur hinzufuegen" bzw. Datei ablegen.
//   Editor          die ausgewaehlte Spur gross: Start-/Endmarke ziehen,
//                   Zoom (Mausrad), schieben (Umschalt+Rad), Feinverstellung
//                   1/10 ms, Nulldurchgangs-Fang, Laenge in Schlaegen,
//                   Bereich hoeren (nur diese Spur in Schleife), BPM
//                   korrigieren, Pitch fein (Cent).
//                   EINZELSOUNDS: Drumloop an den Anschlaegen zerlegen
//                   (Empfindlichkeit), Marken ziehen/setzen/loeschen, Pads
//                   (Klick = hoeren, Strg+Klick = waehlen), Auswahl als WAV
//                   24 Bit speichern - wie gehoert (Plattenspieler + Pitch)
//   Transport       Abspielen/Stopp (Leertaste), Schleife, Vorlauf 1 s
//                   (Zeit, um die Isla scharf zu schalten), Ausgangspegel.
//                   Schleife = gemeinsame Stack-Schleife: Spur 1 gibt die
//                   Laenge vor, kuerzere Spuren wiederholen sich darin auf
//                   festem Raster, alle starten gemeinsam neu (kein Wandern)
//   Stack           STACK SPEICHERN/LADEN: alle Spuren mit Einstellungen als
//                   .s2400stack (INI-Text, nur Pfade der Samples).
//                   STACK LADEN nimmt auch einen Splice-Stack (Export
//                   "Stems" als ZIP oder ein Stem daraus): je Stem eine Spur
//   Browser links   Splice-Ordner, neueste zuerst, Suche; Klick = vorhoeren
//                   (wahlweise im Tempo von Spur 1 und synchron zur
//                   laufenden Wiedergabe), Doppelklick/Enter = neue Spur.
//                   Dateien lassen sich auch aus Explorer/Splice ablegen.
//
// Rechenteil in S2400ZsDsp.pas, Dateien in S2400AudioFile.pas. Gestaltung
// wie der Isla-Mixer (S2400AggMixer.pas): Hardware-Konsole in den Farben von
// S2400UiKit.
// Einstellungen: HKCU\Software\S2400 Aggregate\Zuspieler
// =============================================================================

interface

uses
  Winapi.Windows;

// oeffnet das Fenster (nicht modal) oder holt es nach vorn
procedure ShowS2400Zuspieler;
// schliesst es (beim Beenden des Monitors)
procedure CloseS2400Zuspieler;
// eigenes Programm "S2400 Zuspieler" (10.11.2026): Fenster zeigen und
// laufen, bis es geschlossen wird
procedure RunS2400ZuspielerApp;

implementation

uses
  Winapi.Messages,
  Winapi.ShellAPI,
  Winapi.ShlObj,
  Winapi.DwmApi,
  Winapi.UxTheme,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.UITypes,
  System.Math,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Win.Registry,
  System.IniFiles,
  System.IOUtils,
  System.Zip,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Menus,
  Vcl.Dialogs,
  Winapi.GDIPAPI,
  Winapi.GDIPOBJ,
  S2400UiKit,
  S2400Lang,
  S2400WasapiOut,
  S2400AudioFile,
  S2400ZsDsp;

const
  C_REG_KEY = 'Software\S2400 Aggregate\Zuspieler';
  C_REG_AGG = 'Software\S2400 Aggregate';

  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  DWMWA_CAPTION_COLOR = 35;
  DWMWA_TEXT_COLOR = 36;

  // Farben wie im Isla-Mixer (TColor = $00BBGGRR)
  C_MX_BG          = TColor($001B1817); // #17181B Fenster
  C_MX_PANEL_TOP   = TColor($00312D2B); // #2B2D31
  C_MX_PANEL_BOT   = TColor($00282523); // #232528
  C_MX_PANEL       = TColor($002D2927); // #27292D Flaeche der Felder
  C_MX_HEAD_TOP    = TColor($00282523); // Kopfleiste
  C_MX_HEAD_BOT    = TColor($00221F1D); // #1D1F22
  C_MX_EDGE        = TColor($00141211); // #111214 dunkle Kante
  C_MX_HILITE      = TColor($00443F3C); // #3C3F44 Lichtkante
  C_MX_WELL        = TColor($000F0D0C); // #0C0D0F vertieftes Feld
  C_MX_WELL_EDGE   = TColor($00070606); // #060607
  C_MX_LED_OFF     = TColor($001E1C1A); // #1A1C1E
  C_MX_SCALE       = TColor($006F7476); // #76746F Skala, Beschriftung
  C_MX_KNOB_RING   = TColor($00171514); // #141517
  C_MX_KNOB_TOP    = TColor($005E5855); // #55585E
  C_MX_KNOB_BOT    = TColor($00302C2A); // #2A2C30
  C_MX_BTN_TOP     = TColor($0046413E); // #3E4146
  C_MX_BTN_BOT     = TColor($00302C2A); // #2A2C30
  C_MX_BTN_ON_TOP  = TColor($0014456A); // #6A4514 gedrueckt (Bernstein)
  C_MX_BTN_ON_BOT  = TColor($0008283E); // #3E2808
  C_MX_LED_AMBER_H = TColor($0040B0F5); // #F5B040
  C_MX_WAVE_DIM    = TColor($00403B38); // #383B40 Wellenform ausserhalb der Marken

  C_METER_MIN_DB = -60.0;
  C_METER_SEGMENTS = 32;
  C_METER_FALL_DB = 1.5;    // pro Timer-Takt (50 ms)
  C_METER_HOLD_MS = 1500;

  C_RPM_COUNT = 4;
  C_RPM_FACTOR: array[0..C_RPM_COUNT - 1] of Double = (1.0, 1.35, 78 / 45, 2.0); // 33 1/3 -> 45 = 1,35
  C_RENDER_DELAY_MS = 120;  // Neuberechnung erst, wenn der Regler kurz ruht
  C_ENV_COLUMNS = 2048;

// ---------------------------------------------------------------------------
// Hilfen
// ---------------------------------------------------------------------------

function NumFmt: TFormatSettings;
begin
  Result := TFormatSettings.Create;
  if S2400IsGerman then
    Result.DecimalSeparator := ','
  else
    Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function FmtNum(AValue: Double; ADecimals: Integer): string;
begin
  if ADecimals <= 0 then
    Result := FormatFloat('0', AValue, NumFmt)
  else
    Result := FormatFloat('0.' + StringOfChar('0', ADecimals), AValue, NumFmt);
end;

// mit Vorzeichen: "+5,20", "-3,00" (Minus als echtes Minuszeichen), "0,00"
function FmtSigned(AValue: Double; ADecimals: Integer): string;
var
  Lim: Double;
begin
  Lim := 0.5 * Power(10, -ADecimals * 1.0);
  if AValue >= Lim then
    Result := '+' + FmtNum(AValue, ADecimals)
  else if AValue <= -Lim then
    Result := #$2212 + FmtNum(-AValue, ADecimals)
  else
    Result := FmtNum(0, ADecimals);
end;

function DbToLin(ADb: Integer): Single;
begin
  if ADb <= -60 then
    Result := 0
  else
    Result := Power(10, ADb / 20);
end;

function LinToDb(AValue: Single): Single;
begin
  if AValue < 1E-6 then
    Result := -120
  else
    Result := 20 * Log10(AValue);
end;

function ShiftDown: Boolean;
begin
  Result := GetKeyState(VK_SHIFT) < 0;
end;

// ---------------------------------------------------------------------------
// Zeichenhelfer (GDI+), wie im Isla-Mixer
// ---------------------------------------------------------------------------

function ColA(AColor: TColor; AAlpha: Byte): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(AColor);
  Result := MakeColor(AAlpha, GetRValue(C), GetGValue(C), GetBValue(C));
end;

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

procedure DrawWell(G: TGPGraphics; X, Y, W, H: Single);
begin
  GpFillRound(G, X, Y, W, H, Sc(2), C_MX_WELL);
  StrokeRound(G, X, Y, W, H, Sc(2), GpColor(C_MX_WELL_EDGE), 1);
  DrawLineA(G, X + Sc(2), Y + H + 0.5, X + W - Sc(2), Y + H + 0.5, ColA(C_MX_HILITE, 160), 1);
end;

function LedColor(AFrac: Single): TColor;
begin
  if AFrac >= 0.95 then
    Result := C_UI_ERR
  else if AFrac >= 0.8 then
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

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Wiedergabe: eigener Thread, schreibt in das WASAPI-Geraet
// ---------------------------------------------------------------------------

const
  C_MAX_TRACKS = 8;
  C_PREVIEW = C_MAX_TRACKS;   // Stimme fuer das Vorhoeren

type
  TZsVoice = record
    Buf: TArray<Single>;   // Stereo interleaved, Rate des Geraets
    Len: Integer;          // Frames
    Pos: Integer;
    Gain: Single;
    Mute: Boolean;
    Solo: Boolean;
    Done: Boolean;
  end;

  TZsEngine = class(TThread)
  private
    FOut: TS2400WasapiOut;
    FLock: TCriticalSection;
    FVoice: array[0..C_MAX_TRACKS] of TZsVoice;
    FPlaying: Boolean;
    FLoop: Boolean;
    FPreroll: Integer;
    FOnly: Integer;          // >= 0: nur diese Spur ("Bereich hoeren")
    FPrevActive: Boolean;
    FPrevOnce: Boolean;      // Vorhoeren einmal von vorn (Einzelsound), nie in Schleife
    FOnceGain: Single;       // Pegel dafuer (= Pegel der Spur, nicht der Vorhoer-Knopf)
    FMix: TArray<Single>;
    FPeakL, FPeakR: Single;
    // gemeinsame Stack-Schleife: alle Spuren auf einem Raster
    FStackPos: Integer;      // Frame im Stack
    FStackLen: Integer;      // Laenge des Stacks (Vielfaches von Spur 1)
    FLeadLen: Integer;       // Laenge der fuehrenden Spur bei der letzten Rechnung
    FReps: array[0..C_MAX_TRACKS - 1] of Integer; // Wiederholungen je Spur im Stack
    procedure Render(AFrames: Integer);
    function SyncPos(ALen: Integer): Integer;
    function StackMode: Boolean;
    procedure UpdateStack;
  protected
    procedure Execute; override;
  public
    constructor Create(AOut: TS2400WasapiOut);
    destructor Destroy; override;
    procedure SetVoice(AIdx: Integer; const ABuf: TArray<Single>; AKeepPhase: Boolean);
    procedure SetMix(AIdx: Integer; AGain: Single; AMute, ASolo: Boolean);
    procedure RemoveVoice(AIdx: Integer);
    procedure SetLoop(AValue: Boolean);
    procedure Play(APrerollFrames, AOnly: Integer);
    procedure StopPlay;
    procedure StartPreview(const ABuf: TArray<Single>; AOnce: Boolean = False; AOnceGain: Single = 1);
    procedure SetOnceGain(AGain: Single);
    procedure StopPreview;
    procedure SetPreviewGain(AGain: Single);
    function IsPlaying: Boolean;
    function InPreroll: Boolean;
    function OnlyTrack: Integer;
    function PreviewActive: Boolean;
    // Position in der Spur 0..1, -1 = steht
    function VoiceFrac(AIdx: Integer): Double;
    // Frames seit Beginn von Spur 1 bzw. der Stack-Schleife (-1 = steht)
    function PlayFrames: Integer;
    procedure TakePeaks(out AL, AR: Single);
  end;

procedure ClearVoice(var V: TZsVoice);
begin
  V.Buf := nil;
  V.Len := 0;
  V.Pos := 0;
  V.Gain := 1;
  V.Mute := False;
  V.Solo := False;
  V.Done := True;
end;

constructor TZsEngine.Create(AOut: TS2400WasapiOut);
var
  I: Integer;
begin
  FOut := AOut;
  FLock := TCriticalSection.Create;
  for I := 0 to C_MAX_TRACKS do
    ClearVoice(FVoice[I]);
  FOnly := -1;
  inherited Create(False);
  Priority := tpHigher;
end;

destructor TZsEngine.Destroy;
begin
  Terminate;
  if FOut <> nil then
    FOut.Abort; // weckt WaitReady
  inherited Destroy; // wartet auf das Ende von Execute
  FLock.Free;
end;

procedure TZsEngine.Execute;
var
  N: Integer;
begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    while not Terminated do
    begin
      if not FOut.WaitReady(100) then
        Continue;
      if Terminated then
        Break;
      N := FOut.WritableFrames;
      if N <= 0 then
        Continue;
      if Length(FMix) < 2 * N then
        SetLength(FMix, 2 * N);
      Render(N);
      FOut.WriteFrames(System.PSingle(Pointer(FMix)), N, 2);
    end;
  finally
    CoUninitialize;
  end;
end;

procedure TZsEngine.Render(AFrames: Integer);
var
  F, T, P: Integer;
  Slot: Int64;
  L, R, PL, PR, G: Single;
  AnySolo, Audible, AllDone: Boolean;
begin
  PL := 0;
  PR := 0;
  FLock.Enter;
  try
    AnySolo := False;
    for T := 0 to C_MAX_TRACKS - 1 do
      if FVoice[T].Solo and (FVoice[T].Len > 0) then
        AnySolo := True;
    for F := 0 to AFrames - 1 do
    begin
      L := 0;
      R := 0;
      if FPlaying then
      begin
        if FPreroll > 0 then
          Dec(FPreroll)
        else if StackMode and (FStackLen > 0) then
        begin
          // Stack-Schleife: jede Spur beginnt ihre Wiederholung genau auf dem
          // Raster des Stacks, am Ende starten alle gemeinsam neu - so laeuft
          // nichts auseinander (Rest einer kuerzeren Spur = Stille, Ueberhang
          // einer laengeren wird abgeschnitten)
          for T := 0 to C_MAX_TRACKS - 1 do
            if FVoice[T].Len > 0 then
            begin
              Slot := (Int64(FStackPos) * FReps[T]) div FStackLen;
              P := FStackPos - Integer((Slot * FStackLen + FReps[T] - 1) div FReps[T]);
              FVoice[T].Done := False;
              if P < FVoice[T].Len then
              begin
                Audible := not FVoice[T].Mute and (not AnySolo or FVoice[T].Solo);
                if Audible then
                begin
                  L := L + FVoice[T].Buf[2 * P] * FVoice[T].Gain;
                  R := R + FVoice[T].Buf[2 * P + 1] * FVoice[T].Gain;
                end;
                FVoice[T].Pos := P;
              end
              else
                FVoice[T].Pos := FVoice[T].Len - 1;
            end;
          Inc(FStackPos);
          if FStackPos >= FStackLen then
            FStackPos := 0;
        end
        else
          for T := 0 to C_MAX_TRACKS - 1 do
            if not FVoice[T].Done and (FVoice[T].Len > 0) then
            begin
              P := FVoice[T].Pos;
              // stumme Spuren laufen weiter, damit alle synchron bleiben
              if FOnly >= 0 then
                Audible := FOnly = T
              else
                Audible := not FVoice[T].Mute and (not AnySolo or FVoice[T].Solo);
              if Audible then
              begin
                L := L + FVoice[T].Buf[2 * P] * FVoice[T].Gain;
                R := R + FVoice[T].Buf[2 * P + 1] * FVoice[T].Gain;
              end;
              Inc(P);
              if P >= FVoice[T].Len then
              begin
                if FLoop or (FOnly >= 0) then
                  P := 0
                else
                  FVoice[T].Done := True;
              end;
              FVoice[T].Pos := P;
            end;
      end;
      // Vorhoeren: laeuft auch ohne die Spuren; mit laufender Schleife in
      // Schleife, sonst einmal
      if FPrevActive and (FVoice[C_PREVIEW].Len > 0) and not (FPlaying and (FPreroll > 0)) then
      begin
        P := FVoice[C_PREVIEW].Pos;
        // Einzelsound: Pegel der Spur (geht so in die Isla), sonst Vorhoer-Pegel
        if FPrevOnce then
          G := FOnceGain
        else
          G := FVoice[C_PREVIEW].Gain;
        L := L + FVoice[C_PREVIEW].Buf[2 * P] * G;
        R := R + FVoice[C_PREVIEW].Buf[2 * P + 1] * G;
        Inc(P);
        if P >= FVoice[C_PREVIEW].Len then
        begin
          if FPlaying and (FLoop or (FOnly >= 0)) and not FPrevOnce then
            P := 0
          else
            FPrevActive := False;
        end;
        FVoice[C_PREVIEW].Pos := P;
      end;
      FMix[2 * F] := L;
      FMix[2 * F + 1] := R;
      if Abs(L) > PL then PL := Abs(L);
      if Abs(R) > PR then PR := Abs(R);
    end;
    if FPlaying and (FPreroll = 0) then
    begin
      AllDone := True;
      for T := 0 to C_MAX_TRACKS - 1 do
        if not FVoice[T].Done and (FVoice[T].Len > 0) then
          AllDone := False;
      if AllDone then
      begin
        FPlaying := False;
        FOnly := -1;
      end;
    end;
    if PL > FPeakL then FPeakL := PL;
    if PR > FPeakR then FPeakR := PR;
  finally
    FLock.Leave;
  end;
end;

// Einstiegsstelle fuer eine neue Stimme waehrend der Wiedergabe: gleiche
// Stelle im Takt wie die fuehrende Spur (alle laufen im selben Tempo)
function TZsEngine.SyncPos(ALen: Integer): Integer;
var
  T: Integer;
begin
  Result := 0;
  if (ALen <= 0) or not FPlaying or (FPreroll > 0) then
    Exit;
  if StackMode and (FStackLen > 0) then
    Exit(FStackPos mod ALen);
  for T := 0 to C_MAX_TRACKS - 1 do
    if not FVoice[T].Done and (FVoice[T].Len > 0) then
      Exit(FVoice[T].Pos mod ALen);
end;

function TZsEngine.StackMode: Boolean;
begin
  Result := FLoop and (FOnly < 0);
end;

// Stack-Raster neu bestimmen (unter FLock): Spur 1 gibt die Laenge vor,
// laengere Spuren verlaengern den Stack auf ein ganzes Vielfaches davon,
// kuerzere wiederholen sich darin (auf ganze Wiederholungen gerundet)
procedure TZsEngine.UpdateStack;
var
  T, Lead, MaxLen, N, OldLen: Integer;
begin
  Lead := -1;
  MaxLen := 0;
  for T := 0 to C_MAX_TRACKS - 1 do
    if FVoice[T].Len > 0 then
    begin
      if Lead < 0 then
        Lead := T;
      if FVoice[T].Len > MaxLen then
        MaxLen := FVoice[T].Len;
    end;
  OldLen := FStackLen;
  if Lead < 0 then
  begin
    FStackLen := 0;
    FLeadLen := 0;
    FStackPos := 0;
    Exit;
  end;
  N := Round(MaxLen / FVoice[Lead].Len);
  if N < 1 then
    N := 1;
  FStackLen := FVoice[Lead].Len * N;
  for T := 0 to C_MAX_TRACKS - 1 do
    if FVoice[T].Len > 0 then
    begin
      FReps[T] := Round(FStackLen / FVoice[T].Len);
      if FReps[T] < 1 then
        FReps[T] := 1;
    end
    else
      FReps[T] := 1;
  // Tempo/Ausschnitt von Spur 1 geaendert: an derselben Stelle im Takt
  // bleiben; sonst (Spur dazu/weg) Position behalten
  if (FLeadLen > 0) and (FLeadLen <> FVoice[Lead].Len) and (OldLen > 0) then
    FStackPos := Integer(Int64(FStackPos) * FStackLen div OldLen);
  FLeadLen := FVoice[Lead].Len;
  if FStackPos >= FStackLen then
    FStackPos := FStackPos mod FStackLen;
  if FStackPos < 0 then
    FStackPos := 0;
end;

procedure TZsEngine.SetVoice(AIdx: Integer; const ABuf: TArray<Single>; AKeepPhase: Boolean);
var
  NewLen, OldLen, OldPos: Integer;
begin
  if (AIdx < 0) or (AIdx >= C_MAX_TRACKS) then
    Exit;
  NewLen := Length(ABuf) div 2;
  FLock.Enter;
  try
    OldLen := FVoice[AIdx].Len;
    OldPos := FVoice[AIdx].Pos;
    FVoice[AIdx].Buf := ABuf;
    FVoice[AIdx].Len := NewLen;
    if NewLen = 0 then
    begin
      FVoice[AIdx].Pos := 0;
      FVoice[AIdx].Done := True;
    end
    else if AKeepPhase and (OldLen > 0) and not FVoice[AIdx].Done then
    begin
      // gleiche relative Stelle (Tempo/Pitch geaendert, waehrend es laeuft)
      FVoice[AIdx].Pos := Integer(Int64(OldPos) * NewLen div OldLen);
      if FVoice[AIdx].Pos >= NewLen then
        FVoice[AIdx].Pos := NewLen - 1;
    end
    else
    begin
      // neue Datei: steigt waehrend der Wiedergabe im Takt ein
      FVoice[AIdx].Pos := SyncPos(NewLen);
      FVoice[AIdx].Done := not FPlaying;
    end;
    UpdateStack;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.SetMix(AIdx: Integer; AGain: Single; AMute, ASolo: Boolean);
begin
  if (AIdx < 0) or (AIdx >= C_MAX_TRACKS) then
    Exit;
  FLock.Enter;
  try
    FVoice[AIdx].Gain := AGain;
    FVoice[AIdx].Mute := AMute;
    FVoice[AIdx].Solo := ASolo;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.RemoveVoice(AIdx: Integer);
var
  J: Integer;
begin
  if (AIdx < 0) or (AIdx >= C_MAX_TRACKS) then
    Exit;
  FLock.Enter;
  try
    for J := AIdx to C_MAX_TRACKS - 2 do
      FVoice[J] := FVoice[J + 1];
    ClearVoice(FVoice[C_MAX_TRACKS - 1]);
    if FOnly = AIdx then
      FOnly := -1
    else if FOnly > AIdx then
      Dec(FOnly);
    UpdateStack;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.SetLoop(AValue: Boolean);
var
  T: Integer;
begin
  FLock.Enter;
  try
    if AValue and not FLoop then
    begin
      // Schleife waehrend der Wiedergabe eingeschaltet: Stack-Position von
      // der fuehrenden Spur uebernehmen, beendete Spuren laufen wieder mit
      UpdateStack;
      FStackPos := 0;
      for T := 0 to C_MAX_TRACKS - 1 do
        if FVoice[T].Len > 0 then
        begin
          if not FVoice[T].Done then
            FStackPos := FVoice[T].Pos;
          Break;
        end;
      if FStackLen > 0 then
        FStackPos := FStackPos mod FStackLen;
    end;
    FLoop := AValue;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.Play(APrerollFrames, AOnly: Integer);
var
  T: Integer;
begin
  FLock.Enter;
  try
    for T := 0 to C_MAX_TRACKS - 1 do
    begin
      FVoice[T].Pos := 0;
      FVoice[T].Done := FVoice[T].Len = 0;
    end;
    FPreroll := APrerollFrames;
    FOnly := AOnly;
    UpdateStack;
    FStackPos := 0;
    FPlaying := True;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.StopPlay;
begin
  FLock.Enter;
  try
    FPlaying := False;
    FPreroll := 0;
    FOnly := -1;
    FPrevActive := False;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.StartPreview(const ABuf: TArray<Single>; AOnce: Boolean; AOnceGain: Single);
begin
  FLock.Enter;
  try
    FVoice[C_PREVIEW].Buf := ABuf;
    FVoice[C_PREVIEW].Len := Length(ABuf) div 2;
    FPrevOnce := AOnce;
    FOnceGain := AOnceGain;
    if AOnce then
      FVoice[C_PREVIEW].Pos := 0
    else
      FVoice[C_PREVIEW].Pos := SyncPos(FVoice[C_PREVIEW].Len);
    FPrevActive := FVoice[C_PREVIEW].Len > 0;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.SetPreviewGain(AGain: Single);
begin
  FLock.Enter;
  try
    FVoice[C_PREVIEW].Gain := AGain;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.SetOnceGain(AGain: Single);
begin
  FLock.Enter;
  try
    FOnceGain := AGain;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.StopPreview;
begin
  FLock.Enter;
  try
    FPrevActive := False;
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.IsPlaying: Boolean;
begin
  FLock.Enter;
  try
    Result := FPlaying;
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.InPreroll: Boolean;
begin
  FLock.Enter;
  try
    Result := FPlaying and (FPreroll > 0);
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.OnlyTrack: Integer;
begin
  FLock.Enter;
  try
    if FPlaying then
      Result := FOnly
    else
      Result := -1;
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.PreviewActive: Boolean;
begin
  FLock.Enter;
  try
    Result := FPrevActive;
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.VoiceFrac(AIdx: Integer): Double;
begin
  Result := -1;
  if (AIdx < 0) or (AIdx >= C_MAX_TRACKS) then
    Exit;
  FLock.Enter;
  try
    if FPlaying and (FPreroll = 0) and not FVoice[AIdx].Done and (FVoice[AIdx].Len > 0) then
      Result := FVoice[AIdx].Pos / FVoice[AIdx].Len;
  finally
    FLock.Leave;
  end;
end;

function TZsEngine.PlayFrames: Integer;
var
  T: Integer;
begin
  Result := -1;
  FLock.Enter;
  try
    if not FPlaying or (FPreroll > 0) then
      Exit;
    if StackMode and (FStackLen > 0) then
      Exit(FStackPos);
    for T := 0 to C_MAX_TRACKS - 1 do
      if FVoice[T].Len > 0 then
      begin
        if not FVoice[T].Done then
          Result := FVoice[T].Pos;
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TZsEngine.TakePeaks(out AL, AR: Single);
begin
  FLock.Enter;
  try
    AL := FPeakL;
    AR := FPeakR;
    FPeakL := 0;
    FPeakR := 0;
  finally
    FLock.Leave;
  end;
end;

// Bedienelemente
// ---------------------------------------------------------------------------

type
  // Drehknopf mit Wertebogen (ziehen auf/ab, Mausrad, Doppelklick = Vorgabe)
  TZsKnob = class(TS2400UiControl)
  private
    FValue, FMin, FMax, FDefault, FWheelStep: Integer;
    FBipolar: Boolean;
    FDragging: Boolean;
    FDragY, FDragValue: Integer;
    FOnChange: TNotifyEvent;
    procedure SetValue(AValue: Integer);
    function AngleOf(AValue: Integer): Single;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetRange(AMin, AMax, ADefault, AWheelStep: Integer);
    property Value: Integer read FValue write SetValue;
    // True: Bogen ab der Nullstellung (Pitch), False: ab dem Anschlag (Pegel)
    property Bipolar: Boolean read FBipolar write FBipolar;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // Liste mit dunklen Bildlaufleisten
  TZsList = class(TListBox)
  protected
    procedure CreateWnd; override;
  end;

  // Hardware-Taste; Toggle = rastet ein (bernstein), sonst Tastendruck
  TZsKey = class(TS2400UiControl)
  private
    FChecked: Boolean;
    FToggle: Boolean;
    FPressed: Boolean;
    FFontPx: Integer;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Click; override;
    property Checked: Boolean read FChecked write SetChecked;
    property Toggle: Boolean read FToggle write FToggle;
    property FontPx: Integer read FFontPx write FFontPx;
  end;

  // Anzeige im vertieften Feld
  TZsReadout = class(TS2400UiControl)
  private
    FText: string;
    FTextColor: TColor;
    FFontPx: Integer;
    FMono: Boolean;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetText(const AText: string; AColor: TColor);
    property FontPx: Integer read FFontPx write FFontPx;
    property Mono: Boolean read FMono write FMono;
  end;

  // waagerechte Stereo-LED-Anzeige
  TZsMeter = class(TS2400UiControl)
  private
    FLevel, FPeak: array[0..1] of Single;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetLevels(ALevelL, APeakL, ALevelR, APeakR: Single);
  end;

  // Wellenform mit Start-/Endmarke und Abspielposition
  TZsWave = class(TS2400UiControl)
  private
    FEnv: TArray<Single>;
    FMarkS, FMarkE: Double;
    FPlay: Double;
    FDrag: Integer;          // 0 = nichts, 1 = Startmarke, 2 = Endmarke
    FWaveColor: TColor;
    FEmptyText: string;
    FEditable: Boolean;
    FOnMarks: TNotifyEvent;
    FOnMarksMoving: TNotifyEvent;
    function InnerRect: TRect;
    function FracToX(AFrac: Double): Single;
    function XToFrac(X: Integer): Double;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetEnvelope(const AEnv: TArray<Single>);
    procedure SetMarks(AStart, AEnd: Double);
    procedure SetPlay(AFrac: Double);
    property MarkStart: Double read FMarkS;
    property MarkEnd: Double read FMarkE;
    property WaveColor: TColor read FWaveColor write FWaveColor;
    property EmptyText: string read FEmptyText write FEmptyText;
    // False: nur Anzeige (Klick waehlt die Spur, OnClick)
    property Editable: Boolean read FEditable write FEditable;
    property OnMarks: TNotifyEvent read FOnMarks write FOnMarks;
    property OnMarksMoving: TNotifyEvent read FOnMarksMoving write FOnMarksMoving;
  end;

{ TZsKnob }

constructor TZsKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crSizeNS;
  TabStop := True;
  Width := Sc(50);
  Height := Sc(50);
  FMin := -100;
  FMax := 100;
  FWheelStep := 1;
  FBipolar := True;
end;

{ TZsList }

procedure TZsList.CreateWnd;
begin
  inherited CreateWnd;
  SetWindowTheme(Handle, 'DarkMode_Explorer', nil);
end;

procedure TZsKnob.SetRange(AMin, AMax, ADefault, AWheelStep: Integer);
begin
  FMin := AMin;
  FMax := AMax;
  FDefault := ADefault;
  FWheelStep := AWheelStep;
  FValue := EnsureRange(FValue, FMin, FMax);
  Invalidate;
end;

procedure TZsKnob.SetValue(AValue: Integer);
begin
  AValue := EnsureRange(AValue, FMin, FMax);
  if AValue = FValue then
    Exit;
  FValue := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TZsKnob.AngleOf(AValue: Integer): Single;
begin
  if FMax <= FMin then
    Exit(0);
  Result := -135 + 270 * (AValue - FMin) / (FMax - FMin);
end;

procedure TZsKnob.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  if ssDouble in Shift then
  begin
    Value := FDefault;
    Exit;
  end;
  FDragging := True;
  FDragY := Y;
  FDragValue := FValue;
end;

procedure TZsKnob.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Span: Double;
begin
  inherited;
  if not FDragging then
    Exit;
  // 150 Pixel = ganzer Bereich, mit Umschalt viermal feiner
  Span := (FMax - FMin) / Sc(150);
  if ssShift in Shift then
    Span := Span / 4;
  Value := FDragValue + Round((FDragY - Y) * Span);
end;

procedure TZsKnob.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  FDragging := False;
  Invalidate;
end;

function TZsKnob.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  Step: Integer;
begin
  Result := True;
  if not Enabled then
    Exit;
  Step := FWheelStep;
  if ssShift in Shift then
    Step := Step * 5;
  if WheelDelta > 0 then
    Value := FValue + Step
  else if WheelDelta < 0 then
    Value := FValue - Step;
end;

procedure TZsKnob.Paint;
var
  G: TGPGraphics;
  Pen: TGPPen;
  CX, CY, RA, RC, A, Z, Rad, A0, Sweep: Single;
  ArcCol: ARGB;
begin
  PaintBackground;
  CX := Width / 2;
  CY := Height / 2;
  RA := Min(Width, Height) / 2 - Sc(3);
  RC := RA - Sc(5);
  A := AngleOf(FValue);
  if FBipolar and (FMin < 0) and (FMax > 0) then
    Z := AngleOf(0)      // zweiseitig: Bogen ab der Nullstellung
  else
    Z := -135;           // einseitig: Bogen ab dem Anschlag
  G := GpBegin(Canvas.Handle);
  try
    Pen := TGPPen.Create(GpColor(C_MX_KNOB_RING), Sc(3));
    try
      Pen.SetStartCap(LineCapRound);
      Pen.SetEndCap(LineCapRound);
      G.DrawArc(Pen, CX - RA, CY - RA, 2 * RA, 2 * RA, 135, 270);
    finally
      Pen.Free;
    end;
    if FHot or FDragging then ArcCol := GpColor(C_MX_LED_AMBER_H) else ArcCol := GpColor(C_UI_ACCENT);
    Sweep := Abs(A - Z);
    if Sweep > 0.5 then
    begin
      A0 := Min(A, Z);
      Pen := TGPPen.Create(ArcCol, Sc(3));
      try
        Pen.SetStartCap(LineCapRound);
        Pen.SetEndCap(LineCapRound);
        G.DrawArc(Pen, CX - RA, CY - RA, 2 * RA, 2 * RA, A0 - 90, Sweep);
      finally
        Pen.Free;
      end;
    end
    else
    begin
      Rad := (Z - 90) * Pi / 180;
      GpFillCircle(G, CX + RA * Cos(Rad), CY + RA * Sin(Rad), 1.5 * GUiScale, C_UI_ACCENT);
    end;

    GpFillCircle(G, CX + 0.5, CY + 1.5, RC, C_MX_EDGE);
    FillGrad(G, CX - RC, CY - RC, 2 * RC, 2 * RC, RC, C_MX_KNOB_TOP, C_MX_KNOB_BOT);
    StrokeRound(G, CX - RC, CY - RC, 2 * RC, 2 * RC, RC, ColA(clBlack, 200), 1);
    StrokeRound(G, CX - RC + 1, CY - RC + 1, 2 * RC - 2, 2 * RC - 2, RC - 1, ColA(clWhite, 40), 1);

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

{ TZsKey }

constructor TZsKey.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crHandPoint;
  Width := Sc(64);
  Height := Sc(26);
  FFontPx := 11;
end;

procedure TZsKey.SetChecked(AValue: Boolean);
begin
  if AValue = FChecked then
    Exit;
  FChecked := AValue;
  Invalidate;
end;

procedure TZsKey.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
  inherited;
end;

procedure TZsKey.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FPressed := False;
  Invalidate;
  inherited;
end;

procedure TZsKey.Click;
begin
  if not Enabled then
    Exit;
  if FToggle then
    Checked := not FChecked;
  inherited Click;
end;

procedure TZsKey.Paint;
var
  G: TGPGraphics;
  W, H, Y0: Single;
  R: TRect;
begin
  PaintBackground;
  W := Width;
  H := Height - 1;
  if FPressed then Y0 := 1 else Y0 := 0;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 1, W, H, Sc(3), C_MX_EDGE);
    if FChecked then
      FillGrad(G, 0, Y0, W, H - Y0, Sc(3), C_MX_BTN_ON_TOP, C_MX_BTN_ON_BOT)
    else if FHot then
      FillGrad(G, 0, Y0, W, H - Y0, Sc(3), C_MX_HILITE, C_MX_BTN_BOT)
    else
      FillGrad(G, 0, Y0, W, H - Y0, Sc(3), C_MX_BTN_TOP, C_MX_BTN_BOT);
    if FChecked then
      StrokeRound(G, 0, Y0, W, H - Y0, Sc(3), GpColor(C_UI_SEL_BORDER), 1)
    else
      StrokeRound(G, 0, Y0, W, H - Y0, Sc(3), GpColor(C_MX_EDGE), 1);
    if not FPressed then
      DrawLineA(G, Sc(3), 1.5, W - Sc(3), 1.5, ColA(clWhite, 45), 1);
  finally
    G.Free;
  end;
  Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Sc(FFontPx);
  Canvas.Font.Quality := fqClearType;
  if not Enabled then
    Canvas.Font.Color := C_UI_DISABLED
  else if FChecked then
    Canvas.Font.Color := C_UI_SEL_TEXT
  else
    Canvas.Font.Color := C_UI_TEXT2;
  R := Rect(0, Round(Y0), Width, Height - 1 + Round(Y0));
  UiText(Canvas, Caption, R, DT_CENTER);
end;

{ TZsReadout }

constructor TZsReadout.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Width := Sc(90);
  Height := Sc(24);
  FFontPx := 12;
  FMono := True;
  FTextColor := C_UI_TEXT;
  FText := #$2014;
end;

procedure TZsReadout.SetText(const AText: string; AColor: TColor);
begin
  if (AText = FText) and (AColor = FTextColor) then
    Exit;
  FText := AText;
  FTextColor := AColor;
  Invalidate;
end;

procedure TZsReadout.Paint;
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
  if FMono then
    Canvas.Font.Name := 'Consolas'
  else
    Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Sc(FFontPx);
  Canvas.Font.Quality := fqClearType;
  Canvas.Font.Color := FTextColor;
  R := Rect(Sc(4), 0, Width - Sc(4), Height - 1);
  UiText(Canvas, FText, R, DT_CENTER);
end;

{ TZsMeter }

constructor TZsMeter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Width := Sc(220);
  Height := Sc(22);
  FLevel[0] := -120;
  FLevel[1] := -120;
  FPeak[0] := -120;
  FPeak[1] := -120;
end;

procedure TZsMeter.SetLevels(ALevelL, APeakL, ALevelR, APeakR: Single);
begin
  if (Abs(ALevelL - FLevel[0]) < 0.05) and (Abs(ALevelR - FLevel[1]) < 0.05) and
    (Abs(APeakL - FPeak[0]) < 0.05) and (Abs(APeakR - FPeak[1]) < 0.05) then
    Exit;
  FLevel[0] := ALevelL;
  FLevel[1] := ALevelR;
  FPeak[0] := APeakL;
  FPeak[1] := APeakR;
  Invalidate;
end;

procedure TZsMeter.Paint;
var
  G: TGPGraphics;
  Ch, I, PeakSeg: Integer;
  RowH, Pad, Gap, SegL, X, Y, Lvl: Single;
  Col: TColor;
begin
  PaintBackground;
  Pad := 2;
  Gap := 1;
  RowH := (Height - 1 - 2 * Pad - Gap) / 2;
  SegL := (Width - 2 * Pad - (C_METER_SEGMENTS - 1) * Gap) / C_METER_SEGMENTS;
  G := GpBegin(Canvas.Handle);
  try
    DrawWell(G, 0, 0, Width, Height - 1);
    for Ch := 0 to 1 do
    begin
      Lvl := MeterFrac(FLevel[Ch]);
      PeakSeg := -1;
      if FPeak[Ch] > C_METER_MIN_DB then
        PeakSeg := Min(C_METER_SEGMENTS - 1, Integer(Trunc(MeterFrac(FPeak[Ch]) * C_METER_SEGMENTS - 0.0001)));
      Y := Pad + Ch * (RowH + Gap);
      for I := 0 to C_METER_SEGMENTS - 1 do
      begin
        if ((I + 1) / C_METER_SEGMENTS <= Lvl + 0.0001) or (I = PeakSeg) then
          Col := LedColor((I + 0.5) / C_METER_SEGMENTS)
        else
          Col := C_MX_LED_OFF;
        X := Pad + I * (SegL + Gap);
        GpFillRound(G, X, Y, SegL, RowH, 0.5, Col);
      end;
    end;
  finally
    G.Free;
  end;
end;

{ TZsWave }

constructor TZsWave.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crSizeWE;
  FMarkS := 0;
  FMarkE := 1;
  FPlay := -1;
  FWaveColor := C_UI_TEXT2;
end;

function TZsWave.InnerRect: TRect;
begin
  Result := Rect(Sc(4), Sc(3), Width - Sc(4), Height - Sc(4));
end;

function TZsWave.FracToX(AFrac: Double): Single;
var
  R: TRect;
begin
  R := InnerRect;
  Result := R.Left + AFrac * R.Width;
end;

function TZsWave.XToFrac(X: Integer): Double;
var
  R: TRect;
begin
  R := InnerRect;
  if R.Width <= 0 then
    Exit(0);
  Result := (X - R.Left) / R.Width;
  if Result < 0 then Result := 0;
  if Result > 1 then Result := 1;
end;

procedure TZsWave.SetEnvelope(const AEnv: TArray<Single>);
begin
  FEnv := AEnv;
  FPlay := -1;
  Invalidate;
end;

procedure TZsWave.SetMarks(AStart, AEnd: Double);
begin
  FMarkS := AStart;
  FMarkE := AEnd;
  Invalidate;
end;

procedure TZsWave.SetPlay(AFrac: Double);
var
  OldX, NewX: Single;
begin
  if AFrac < 0 then
    NewX := -1
  else
    NewX := FracToX(FMarkS + AFrac * (FMarkE - FMarkS));
  if FPlay < 0 then
    OldX := -1
  else
    OldX := FracToX(FMarkS + FPlay * (FMarkE - FMarkS));
  FPlay := AFrac;
  if Abs(NewX - OldX) >= 1 then
    Invalidate;
end;

procedure TZsWave.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  F: Double;
begin
  inherited;
  if not FEditable or (Button <> mbLeft) or (Length(FEnv) = 0) then
    Exit;
  if ssDouble in Shift then
  begin
    FDrag := 0;
    SetMarks(0, 1);
    if Assigned(FOnMarks) then
      FOnMarks(Self);
    Exit;
  end;
  F := XToFrac(X);
  // naechstgelegene Marke fassen und gleich dorthin setzen
  if Abs(F - FMarkS) <= Abs(F - FMarkE) then
    FDrag := 1
  else
    FDrag := 2;
  MouseMove(Shift, X, Y);
end;

procedure TZsWave.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  F, MinGap: Double;
begin
  inherited;
  if FDrag = 0 then
    Exit;
  F := XToFrac(X);
  MinGap := 0.002;
  if FDrag = 1 then
  begin
    if F > FMarkE - MinGap then F := FMarkE - MinGap;
    if F < 0 then F := 0;
    FMarkS := F;
  end
  else
  begin
    if F < FMarkS + MinGap then F := FMarkS + MinGap;
    if F > 1 then F := 1;
    FMarkE := F;
  end;
  Invalidate;
  if Assigned(FOnMarksMoving) then
    FOnMarksMoving(Self);
end;

procedure TZsWave.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if FDrag <> 0 then
  begin
    FDrag := 0;
    if Assigned(FOnMarks) then
      FOnMarks(Self);
  end;
end;

procedure TZsWave.Paint;
var
  G: TGPGraphics;
  R: TRect;
  X, I0, I1, I, N, MidY, HalfH: Integer;
  M, XS, XE, XP: Single;
  Col: TColor;
  TR: TRect;
begin
  PaintBackground;
  R := InnerRect;
  G := GpBegin(Canvas.Handle);
  try
    DrawWell(G, 0, 0, Width, Height - 1);
    N := Length(FEnv);
    if N > 0 then
    begin
      MidY := R.Top + R.Height div 2;
      HalfH := R.Height div 2 - 1;
      XS := FracToX(FMarkS);
      XE := FracToX(FMarkE);
      // Mittellinie
      DrawLineA(G, R.Left, MidY + 0.5, R.Right, MidY + 0.5, ColA(C_MX_HILITE, 120), 1);
      for X := R.Left to R.Right - 1 do
      begin
        I0 := Int64(X - R.Left) * N div R.Width;
        I1 := Int64(X - R.Left + 1) * N div R.Width;
        if I1 <= I0 then
          I1 := I0 + 1;
        M := 0;
        for I := I0 to Min(I1, N) - 1 do
          if FEnv[I] > M then
            M := FEnv[I];
        if (X + 0.5 >= XS) and (X + 0.5 <= XE) then
          Col := FWaveColor
        else
          Col := C_MX_WAVE_DIM;
        if M * HalfH >= 0.5 then
          DrawLineA(G, X + 0.5, MidY - M * HalfH, X + 0.5, MidY + M * HalfH + 1, GpColor(Col), 1);
      end;
      // Marken (tuerkis) mit Faehnchen
      DrawLineA(G, XS, R.Top, XS, R.Bottom, GpColor(C_UI_LEVEL), 1.5 * GUiScale);
      GpFillRound(G, XS, R.Top, Sc(7), Sc(8), 1, C_UI_LEVEL);
      DrawLineA(G, XE, R.Top, XE, R.Bottom, GpColor(C_UI_LEVEL), 1.5 * GUiScale);
      GpFillRound(G, XE - Sc(7), R.Top, Sc(7), Sc(8), 1, C_UI_LEVEL);
      // Abspielposition (bernstein)
      if FPlay >= 0 then
      begin
        XP := FracToX(FMarkS + FPlay * (FMarkE - FMarkS));
        DrawLineA(G, XP, R.Top, XP, R.Bottom, GpColor(C_UI_ACCENT), 1.5 * GUiScale);
      end;
    end;
  finally
    G.Free;
  end;
  if Length(FEnv) = 0 then
  begin
    Canvas.Font.Name := C_UI_FONT;
    Canvas.Font.Style := [];
    Canvas.Font.Height := -Sc(12);
    Canvas.Font.Quality := fqClearType;
    Canvas.Font.Color := C_MX_SCALE;
    TR := R;
    UiText(Canvas, FEmptyText, TR, DT_CENTER);
  end;
end;

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Editor-Wellenform: Zoom, Marken, Nulldurchgangs-Fang
// ---------------------------------------------------------------------------

type
  TZsEditWave = class(TS2400UiControl)
  private
    FData: TArray<Single>;
    FFrames, FRate: Integer;
    FMarkS, FMarkE, FViewS, FViewE, FPlay: Double;
    FDrag: Integer;          // 0 nichts, 1 Start, 2 Ende, 3 Bildlaufleiste, 4 Schnittmarke
    FSnap: Boolean;
    FEmptyText: string;
    FOnMarks, FOnMarksMoving: TNotifyEvent;
    // Einzelsound-Modus: Schnittmarken statt Start/Ende
    FSliceMode: Boolean;
    FSlices: TArray<Double>;     // Anfaenge der Sounds (Anteile der Datei), [0] = Bereichsanfang
    FSliceSel: TArray<Boolean>;
    FSliceActive: Integer;
    FDragIdx: Integer;
    FClickedSlice: Integer;
    FClickCtrl: Boolean;
    FOnSlices, FOnSliceClick: TNotifyEvent;
    function SliceAt(AFrac: Double): Integer;
    function SliceMarkNear(X, ARadius: Integer): Integer;
    procedure SetSliceMode(AValue: Boolean);
    function WaveRect: TRect;
    function BarRect: TRect;
    function FracToX(F: Double): Single;
    function XToFrac(X: Integer): Double;
    function Mono(I: Integer): Single;
    procedure ClampView;
    procedure CenterViewAt(X: Integer);
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetSource(const AData: TArray<Single>; AFrames, ARate: Integer);
    procedure SetMarks(AStart, AEnd: Double);
    procedure SetPlay(AFrac: Double);
    procedure ResetView;
    // naechster Nulldurchgang (ADir 0 = beide Richtungen, +1 vorwaerts, -1 rueckwaerts)
    function SnapFrac(AFrac: Double; ADir: Integer): Double;
    property MarkStart: Double read FMarkS;
    property MarkEnd: Double read FMarkE;
    property Snap: Boolean read FSnap write FSnap;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnMarks: TNotifyEvent read FOnMarks write FOnMarks;
    property OnMarksMoving: TNotifyEvent read FOnMarksMoving write FOnMarksMoving;
    // Einzelsounds
    procedure SetSlices(const ASlices: TArray<Double>; const ASel: TArray<Boolean>; AActive: Integer);
    property SliceMode: Boolean read FSliceMode write SetSliceMode;
    property Slices: TArray<Double> read FSlices;
    property SliceSelection: TArray<Boolean> read FSliceSel;
    property ClickedSlice: Integer read FClickedSlice;
    property ClickCtrl: Boolean read FClickCtrl;
    // Marke gesetzt/geloescht/verschoben
    property OnSlices: TNotifyEvent read FOnSlices write FOnSlices;
    // Klick in einen Sound (ClickedSlice, ClickCtrl)
    property OnSliceClick: TNotifyEvent read FOnSliceClick write FOnSliceClick;
  end;

constructor TZsEditWave.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crSizeWE;
  FMarkE := 1;
  FViewE := 1;
  FPlay := -1;
  FSnap := True;
  FSliceActive := -1;
  FDragIdx := -1;
  FClickedSlice := -1;
end;

procedure TZsEditWave.SetSliceMode(AValue: Boolean);
begin
  if AValue = FSliceMode then
    Exit;
  FSliceMode := AValue;
  FDrag := 0;
  if FSliceMode then
    Cursor := crHandPoint
  else
    Cursor := crSizeWE;
  Invalidate;
end;

procedure TZsEditWave.SetSlices(const ASlices: TArray<Double>; const ASel: TArray<Boolean>; AActive: Integer);
begin
  FSlices := Copy(ASlices);
  FSliceSel := Copy(ASel);
  SetLength(FSliceSel, Length(FSlices));
  FSliceActive := AActive;
  Invalidate;
end;

// Sound, in dem AFrac liegt (-1 = ausserhalb des Bereichs)
function TZsEditWave.SliceAt(AFrac: Double): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (Length(FSlices) = 0) or (AFrac < FSlices[0]) or (AFrac > FMarkE) then
    Exit;
  for I := High(FSlices) downto 0 do
    if AFrac >= FSlices[I] then
      Exit(I);
end;

// Schnittmarke nahe X (die erste = Bereichsanfang ist fest)
function TZsEditWave.SliceMarkNear(X, ARadius: Integer): Integer;
var
  I: Integer;
  D, BestD: Single;
begin
  Result := -1;
  BestD := ARadius;
  for I := 1 to High(FSlices) do
  begin
    D := Abs(X - FracToX(FSlices[I]));
    if D <= BestD then
    begin
      BestD := D;
      Result := I;
    end;
  end;
end;

function TZsEditWave.WaveRect: TRect;
begin
  Result := Rect(Sc(4), Sc(3), Width - Sc(4), Height - Sc(16));
end;

function TZsEditWave.BarRect: TRect;
begin
  Result := Rect(Sc(4), Height - Sc(12), Width - Sc(4), Height - Sc(4));
end;

function TZsEditWave.FracToX(F: Double): Single;
var
  R: TRect;
begin
  R := WaveRect;
  if FViewE <= FViewS then
    Exit(R.Left);
  Result := R.Left + (F - FViewS) / (FViewE - FViewS) * R.Width;
end;

function TZsEditWave.XToFrac(X: Integer): Double;
var
  R: TRect;
begin
  R := WaveRect;
  if R.Width <= 0 then
    Exit(0);
  Result := FViewS + (X - R.Left) / R.Width * (FViewE - FViewS);
  if Result < 0 then Result := 0;
  if Result > 1 then Result := 1;
end;

function TZsEditWave.Mono(I: Integer): Single;
begin
  Result := 0.5 * (FData[2 * I] + FData[2 * I + 1]);
end;

procedure TZsEditWave.ClampView;
var
  Span, MinSpan: Double;
begin
  Span := FViewE - FViewS;
  if FFrames > 0 then
    MinSpan := 200 / FFrames
  else
    MinSpan := 0.001;
  if MinSpan > 1 then
    MinSpan := 1;
  if Span < MinSpan then
    Span := MinSpan;
  if Span >= 1 then
  begin
    FViewS := 0;
    FViewE := 1;
    Exit;
  end;
  if FViewS < 0 then
    FViewS := 0;
  if FViewS + Span > 1 then
    FViewS := 1 - Span;
  FViewE := FViewS + Span;
end;

procedure TZsEditWave.CenterViewAt(X: Integer);
var
  R: TRect;
  C, Span: Double;
begin
  R := BarRect;
  if R.Width <= 0 then
    Exit;
  C := (X - R.Left) / R.Width;
  Span := FViewE - FViewS;
  FViewS := C - Span / 2;
  FViewE := FViewS + Span;
  ClampView;
  Invalidate;
end;

procedure TZsEditWave.SetSource(const AData: TArray<Single>; AFrames, ARate: Integer);
begin
  FData := AData;
  FFrames := AFrames;
  FRate := ARate;
  FPlay := -1;
  ResetView;
end;

procedure TZsEditWave.SetMarks(AStart, AEnd: Double);
begin
  FMarkS := AStart;
  FMarkE := AEnd;
  Invalidate;
end;

procedure TZsEditWave.SetPlay(AFrac: Double);
var
  OldX, NewX: Single;
begin
  if AFrac < 0 then
    NewX := -1
  else
    NewX := FracToX(FMarkS + AFrac * (FMarkE - FMarkS));
  if FPlay < 0 then
    OldX := -1
  else
    OldX := FracToX(FMarkS + FPlay * (FMarkE - FMarkS));
  FPlay := AFrac;
  if Abs(NewX - OldX) >= 1 then
    Invalidate;
end;

procedure TZsEditWave.ResetView;
begin
  FViewS := 0;
  FViewE := 1;
  Invalidate;
end;

function TZsEditWave.SnapFrac(AFrac: Double; ADir: Integer): Double;
var
  C, MaxK, K, I: Integer;

  function Crossing(AI: Integer): Boolean;
  var
    A, B: Single;
  begin
    Result := False;
    if (AI < 1) or (AI >= FFrames) then
      Exit;
    A := Mono(AI - 1);
    B := Mono(AI);
    Result := ((A <= 0) and (B > 0)) or ((A >= 0) and (B < 0));
  end;

begin
  Result := AFrac;
  if (FFrames <= 1) or (FRate <= 0) then
    Exit;
  C := Round(AFrac * FFrames);
  if (C <= 0) or (C >= FFrames) then
    Exit; // Dateianfang/-ende bleiben
  MaxK := FRate div 100; // bis 10 ms weit suchen
  for K := 0 to MaxK do
  begin
    if ADir >= 0 then
    begin
      I := C + K;
      if Crossing(I) then
        Exit(I / FFrames);
    end;
    if ADir <= 0 then
    begin
      I := C - K;
      if Crossing(I) then
        Exit(I / FFrames);
    end;
  end;
end;

procedure TZsEditWave.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  F: Double;
  I: Integer;
begin
  inherited;
  // Einzelsounds: Rechtsklick auf/nahe einer Marke loescht sie
  if FSliceMode and (Button = mbRight) and (FFrames > 0) then
  begin
    I := SliceMarkNear(X, Sc(10));
    if I > 0 then
    begin
      Delete(FSlices, I, 1);
      Delete(FSliceSel, I, 1);
      FSliceActive := -1;
      Invalidate;
      if Assigned(FOnSlices) then
        FOnSlices(Self);
    end;
    Exit;
  end;
  if (Button <> mbLeft) or (FFrames = 0) then
    Exit;
  if CanFocus then
    SetFocus;
  if Y >= BarRect.Top - Sc(2) then
  begin
    FDrag := 3;
    CenterViewAt(X);
    Exit;
  end;
  if FSliceMode then
  begin
    FDrag := 0;
    if Length(FSlices) = 0 then
      Exit;
    I := SliceMarkNear(X, Sc(5));
    if ssDouble in Shift then
    begin
      // Doppelklick: Marke loeschen bzw. neue Marke setzen
      if I > 0 then
      begin
        Delete(FSlices, I, 1);
        Delete(FSliceSel, I, 1);
      end
      else
      begin
        F := XToFrac(X);
        if FSnap then
          F := SnapFrac(F, -1);
        if (F > FSlices[0] + 32 / Max(FFrames, 1)) and (F < FMarkE - 32 / Max(FFrames, 1)) then
        begin
          I := SliceAt(F) + 1;
          Insert(F, FSlices, I);
          Insert(False, FSliceSel, I);
        end;
      end;
      FSliceActive := -1;
      Invalidate;
      if Assigned(FOnSlices) then
        FOnSlices(Self);
      Exit;
    end;
    if I > 0 then
    begin
      FDrag := 4;
      FDragIdx := I;
      Exit;
    end;
    FClickedSlice := SliceAt(XToFrac(X));
    FClickCtrl := ssCtrl in Shift;
    if (FClickedSlice >= 0) and Assigned(FOnSliceClick) then
      FOnSliceClick(Self);
    Exit;
  end;
  if ssDouble in Shift then
  begin
    FDrag := 0;
    SetMarks(0, 1);
    ResetView;
    if Assigned(FOnMarks) then
      FOnMarks(Self);
    Exit;
  end;
  F := XToFrac(X);
  if Abs(X - FracToX(FMarkS)) <= Abs(X - FracToX(FMarkE)) then
    FDrag := 1
  else
    FDrag := 2;
  if F < 0 then F := 0;
  MouseMove(Shift, X, Y);
end;

procedure TZsEditWave.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  F, MinGap: Double;
begin
  inherited;
  case FDrag of
    3: CenterViewAt(X);
    4:
      if (FDragIdx > 0) and (FDragIdx <= High(FSlices)) then
      begin
        F := XToFrac(X);
        if FFrames > 0 then
          MinGap := 32 / FFrames
        else
          MinGap := 0.001;
        if F < FSlices[FDragIdx - 1] + MinGap then
          F := FSlices[FDragIdx - 1] + MinGap;
        if FDragIdx < High(FSlices) then
        begin
          if F > FSlices[FDragIdx + 1] - MinGap then
            F := FSlices[FDragIdx + 1] - MinGap;
        end
        else if F > FMarkE - MinGap then
          F := FMarkE - MinGap;
        FSlices[FDragIdx] := F;
        Invalidate;
      end;
    1, 2:
      begin
        F := XToFrac(X);
        if FFrames > 0 then
          MinGap := 32 / FFrames
        else
          MinGap := 0.001;
        if FDrag = 1 then
        begin
          if F > FMarkE - MinGap then F := FMarkE - MinGap;
          if F < 0 then F := 0;
          FMarkS := F;
        end
        else
        begin
          if F < FMarkS + MinGap then F := FMarkS + MinGap;
          if F > 1 then F := 1;
          FMarkE := F;
        end;
        Invalidate;
        if Assigned(FOnMarksMoving) then
          FOnMarksMoving(Self);
      end;
  end;
end;

procedure TZsEditWave.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  D: Integer;
begin
  inherited;
  D := FDrag;
  FDrag := 0;
  if D = 4 then
  begin
    if FSnap and (FDragIdx > 0) and (FDragIdx <= High(FSlices)) then
    begin
      FSlices[FDragIdx] := SnapFrac(FSlices[FDragIdx], -1);
      if FSlices[FDragIdx] <= FSlices[FDragIdx - 1] then
        FSlices[FDragIdx] := FSlices[FDragIdx - 1] + 32 / Max(FFrames, 1);
    end;
    FDragIdx := -1;
    Invalidate;
    if Assigned(FOnSlices) then
      FOnSlices(Self);
    Exit;
  end;
  if (D = 1) or (D = 2) then
  begin
    if FSnap then
    begin
      if D = 1 then
        FMarkS := SnapFrac(FMarkS, 0)
      else
        FMarkE := SnapFrac(FMarkE, 0);
      if FMarkE <= FMarkS then
        FMarkE := FMarkS + 32 / Max(FFrames, 1);
      if FMarkE > 1 then
        FMarkE := 1;
      Invalidate;
    end;
    if Assigned(FOnMarks) then
      FOnMarks(Self);
  end;
end;

function TZsEditWave.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
var
  P: TPoint;
  A, Span, NewSpan: Double;
begin
  Result := True;
  if FFrames = 0 then
    Exit;
  Span := FViewE - FViewS;
  if ssShift in Shift then
  begin
    // schieben: 10 % des Ausschnitts je Raste
    if WheelDelta > 0 then
      FViewS := FViewS - Span * 0.1
    else
      FViewS := FViewS + Span * 0.1;
    FViewE := FViewS + Span;
  end
  else
  begin
    // zoomen um die Mausposition
    P := ScreenToClient(MousePos);
    A := XToFrac(P.X);
    if WheelDelta > 0 then
      NewSpan := Span * 0.8
    else
      NewSpan := Span * 1.25;
    FViewS := A - (A - FViewS) * NewSpan / Span;
    FViewE := FViewS + NewSpan;
  end;
  ClampView;
  Invalidate;
end;

procedure TZsEditWave.Paint;
var
  G: TGPGraphics;
  R, B, TR: TRect;
  X, I, I0, I1, MidY, HalfH, Last: Integer;
  A0, A1, Lo, Hi, V, XS, XE, XP, T0, T1: Single;
  Col: TColor;
  FrameA, FrameB, Per: Double;
begin
  PaintBackground;
  R := WaveRect;
  B := BarRect;
  G := GpBegin(Canvas.Handle);
  try
    DrawWell(G, 0, 0, Width, Height - 1);
    if FFrames > 0 then
    begin
      MidY := R.Top + R.Height div 2;
      HalfH := R.Height div 2 - 2;
      XS := FracToX(FMarkS);
      XE := FracToX(FMarkE);
      // Einzelsounds: gewaehlte Sounds hinterlegt, der gerade gespielte heller
      if FSliceMode then
        for I := 0 to High(FSlices) do
          if FSliceSel[I] or (I = FSliceActive) then
          begin
            T0 := FracToX(FSlices[I]);
            if I < High(FSlices) then
              T1 := FracToX(FSlices[I + 1])
            else
              T1 := XE;
            if T0 < R.Left then T0 := R.Left;
            if T1 > R.Right then T1 := R.Right;
            if T1 > T0 then
            begin
              if I = FSliceActive then
                FillRoundA(G, T0, R.Top, T1 - T0, R.Height, 0, ColA(C_UI_ACCENT, 70))
              else
                FillRoundA(G, T0, R.Top, T1 - T0, R.Height, 0, ColA(C_UI_ACCENT, 32));
            end;
          end;
      DrawLineA(G, R.Left, MidY + 0.5, R.Right, MidY + 0.5, ColA(C_MX_HILITE, 120), 1);
      Per := (FViewE - FViewS) * FFrames / R.Width;  // Frames je Pixel
      Last := FFrames - 1;
      for X := R.Left to R.Right - 1 do
      begin
        FrameA := FViewS * FFrames + (X - R.Left) * Per;
        FrameB := FrameA + Per;
        I0 := Trunc(FrameA);
        I1 := Trunc(FrameB);
        if I1 < I0 + 1 then
          I1 := I0 + 1;    // Nachbarsample dazu: durchgehende Linie beim Zoomen
        if I0 > Last then Break;
        if I1 > Last then I1 := Last;
        Lo := 2;
        Hi := -2;
        for I := I0 to I1 do
        begin
          V := Mono(I);
          if V < Lo then Lo := V;
          if V > Hi then Hi := V;
        end;
        if Lo < -1 then Lo := -1;
        if Hi > 1 then Hi := 1;
        if (X + 0.5 >= XS) and (X + 0.5 <= XE) then
          Col := C_UI_LEVEL
        else
          Col := C_MX_WAVE_DIM;
        A0 := MidY - Hi * HalfH;
        A1 := MidY - Lo * HalfH;
        if A1 - A0 < 1 then
          A1 := A0 + 1;
        DrawLineA(G, X + 0.5, A0, X + 0.5, A1, GpColor(Col), 1);
      end;
      // Marken
      if FSliceMode then
      begin
        for I := 0 to High(FSlices) do
        begin
          T0 := FracToX(FSlices[I]);
          if (T0 >= R.Left - 1) and (T0 <= R.Right + 1) then
          begin
            DrawLineA(G, T0, R.Top, T0, R.Bottom, GpColor(C_UI_ACCENT), 1.2 * GUiScale);
            GpFillRound(G, T0, R.Top, Sc(16), Sc(13), 1, C_UI_ACCENT);
          end;
        end;
        if (XE >= R.Left - 1) and (XE <= R.Right + 1) then
          DrawLineA(G, XE, R.Top, XE, R.Bottom, ColA(C_UI_ACCENT, 120), 1);
      end
      else if (XS >= R.Left - 1) and (XS <= R.Right + 1) then
      begin
        DrawLineA(G, XS, R.Top, XS, R.Bottom, GpColor(C_UI_LEVEL), 2 * GUiScale);
        GpFillRound(G, XS, R.Top, Sc(9), Sc(11), 1, C_UI_LEVEL);
      end;
      if not FSliceMode and (XE >= R.Left - 1) and (XE <= R.Right + 1) then
      begin
        DrawLineA(G, XE, R.Top, XE, R.Bottom, GpColor(C_UI_LEVEL), 2 * GUiScale);
        GpFillRound(G, XE - Sc(9), R.Top, Sc(9), Sc(11), 1, C_UI_LEVEL);
      end;
      if FPlay >= 0 then
      begin
        XP := FracToX(FMarkS + FPlay * (FMarkE - FMarkS));
        if (XP >= R.Left) and (XP <= R.Right) then
          DrawLineA(G, XP, R.Top, XP, R.Bottom, GpColor(C_UI_ACCENT), 1.5 * GUiScale);
      end;
      // Bildlaufleiste: sichtbarer Ausschnitt
      GpFillRound(G, B.Left, B.Top, B.Width, B.Height, Sc(2), C_MX_LED_OFF);
      T0 := B.Left + FViewS * B.Width;
      T1 := B.Left + FViewE * B.Width;
      if T1 - T0 < Sc(6) then
        T1 := T0 + Sc(6);
      GpFillRound(G, T0, B.Top + 1, T1 - T0, B.Height - 2, Sc(2), C_MX_BTN_TOP);
    end;
  finally
    G.Free;
  end;
  // Nummern der Einzelsounds auf den Faehnchen
  if FSliceMode and (FFrames > 0) then
  begin
    Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
    Canvas.Font.Style := [];
    Canvas.Font.Height := -Sc(10);
    Canvas.Font.Quality := fqClearType;
    Canvas.Font.Color := C_MX_BG;
    Canvas.Brush.Style := bsClear;
    for I := 0 to High(FSlices) do
    begin
      T0 := FracToX(FSlices[I]);
      if (T0 >= R.Left - 1) and (T0 <= R.Right + 1) then
      begin
        TR := Rect(Round(T0), R.Top, Round(T0) + Sc(16), R.Top + Sc(13));
        UiText(Canvas, IntToStr(I + 1), TR, DT_CENTER);
      end;
    end;
  end;
  if FFrames = 0 then
  begin
    Canvas.Font.Name := C_UI_FONT;
    Canvas.Font.Style := [];
    Canvas.Font.Height := -Sc(12);
    Canvas.Font.Quality := fqClearType;
    Canvas.Font.Color := C_MX_SCALE;
    TR := R;
    UiText(Canvas, FEmptyText, TR, DT_CENTER);
  end;
end;

// ---------------------------------------------------------------------------
// Pads der Einzelsounds: Klick = anhoeren, Strg+Klick = auswaehlen
// ---------------------------------------------------------------------------

type
  TZsPads = class(TS2400UiControl)
  private
    FCount, FActive, FClicked: Integer;
    FSel: TArray<Boolean>;
    FClickCtrl: Boolean;
    FEmptyText: string;
    FOnPadClick: TNotifyEvent;
    function PadAt(X: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetPads(ACount: Integer; const ASel: TArray<Boolean>; AActive: Integer);
    property Clicked: Integer read FClicked;
    property ClickCtrl: Boolean read FClickCtrl;
    property EmptyText: string read FEmptyText write FEmptyText;
    property OnPadClick: TNotifyEvent read FOnPadClick write FOnPadClick;
  end;

constructor TZsPads.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  Cursor := crHandPoint;
  FActive := -1;
  FClicked := -1;
end;

procedure TZsPads.SetPads(ACount: Integer; const ASel: TArray<Boolean>; AActive: Integer);
begin
  FCount := ACount;
  FSel := Copy(ASel);
  SetLength(FSel, FCount);
  FActive := AActive;
  Invalidate;
end;

function TZsPads.PadAt(X: Integer): Integer;
begin
  Result := -1;
  if (FCount <= 0) or (Width <= 0) then
    Exit;
  Result := X * FCount div Width;
  if Result < 0 then Result := 0;
  if Result >= FCount then Result := FCount - 1;
end;

procedure TZsPads.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button <> mbLeft then
    Exit;
  FClicked := PadAt(X);
  FClickCtrl := ssCtrl in Shift;
  if (FClicked >= 0) and Assigned(FOnPadClick) then
    FOnPadClick(Self);
end;

procedure TZsPads.Paint;
var
  G: TGPGraphics;
  I: Integer;
  X0, X1, Gap, H: Single;
  TR: TRect;
begin
  PaintBackground;
  H := Height - 1;
  Gap := Sc(4);
  if FCount > 24 then
    Gap := Sc(2);
  G := GpBegin(Canvas.Handle);
  try
    if FCount = 0 then
      DrawWell(G, 0, 0, Width, H)
    else
      for I := 0 to FCount - 1 do
      begin
        X0 := I * Width / FCount;
        X1 := (I + 1) * Width / FCount - Gap;
        FillRoundA(G, X0, 1, X1 - X0, H, Sc(3), ColA(clBlack, 110));
        if FSel[I] then
          FillGrad(G, X0, 0, X1 - X0, H - 1, Sc(3), C_MX_BTN_ON_TOP, C_MX_BTN_ON_BOT)
        else
          FillGrad(G, X0, 0, X1 - X0, H - 1, Sc(3), C_MX_BTN_TOP, C_MX_BTN_BOT);
        if I = FActive then
          StrokeRound(G, X0, 0, X1 - X0, H - 1, Sc(3), GpColor(C_UI_LEVEL), 2 * GUiScale)
        else
          StrokeRound(G, X0, 0, X1 - X0, H - 1, Sc(3), GpColor(C_MX_EDGE), 1);
      end;
  finally
    G.Free;
  end;
  Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
  Canvas.Font.Style := [];
  Canvas.Font.Quality := fqClearType;
  if FCount = 0 then
  begin
    Canvas.Font.Height := -Sc(11);
    Canvas.Font.Color := C_MX_SCALE;
    TR := ClientRect;
    UiText(Canvas, FEmptyText, TR, DT_CENTER);
    Exit;
  end;
  if FCount > 24 then
    Canvas.Font.Height := -Sc(9)
  else
    Canvas.Font.Height := -Sc(11);
  for I := 0 to FCount - 1 do
  begin
    if FSel[I] then
      Canvas.Font.Color := C_MX_LED_AMBER_H
    else
      Canvas.Font.Color := C_UI_TEXT2;
    TR := Rect(Round(I * Width / FCount), 0, Round((I + 1) * Width / FCount - Gap), Height - 1);
    UiText(Canvas, IntToStr(I + 1), TR, DT_CENTER);
  end;
end;

// ---------------------------------------------------------------------------
// Schlag-LEDs: vier Lampen, die beim Abspielen im Takt mitlaufen
// ---------------------------------------------------------------------------

type
  TZsBeatLeds = class(TS2400UiControl)
  private
    FBeat: Integer;          // 0..3, -1 = aus
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetBeat(ABeat: Integer);
  end;

constructor TZsBeatLeds.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_PANEL;
  FBeat := -1;
end;

procedure TZsBeatLeds.SetBeat(ABeat: Integer);
begin
  if ABeat = FBeat then
    Exit;
  FBeat := ABeat;
  Invalidate;
end;

procedure TZsBeatLeds.Paint;
var
  G: TGPGraphics;
  I: Integer;
  D, Gap, X, Y: Single;
  C: TColor;
begin
  PaintBackground;
  D := Sc(14);
  Gap := (Width - 4 * D) / 3;
  Y := (Height - D) / 2;
  G := GpBegin(Canvas.Handle);
  try
    for I := 0 to 3 do
    begin
      X := I * (D + Gap);
      GpFillCircle(G, X + D / 2, Y + D / 2, D / 2 + 1, C_MX_EDGE);
      if I = FBeat then
      begin
        // erster Schlag des Takts hell, die anderen gedaempft
        if I = 0 then
          C := C_MX_LED_AMBER_H
        else
          C := C_UI_ACCENT;
        GpFillCircle(G, X + D / 2, Y + D / 2, D / 2, C);
      end
      else
        GpFillCircle(G, X + D / 2, Y + D / 2, D / 2, C_MX_LED_OFF);
    end;
  finally
    G.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Spurzeile, Feld "+ Spur hinzufuegen", Rollbereich
// ---------------------------------------------------------------------------

type
  TZsBpmSource = (zbNone, zbName, zbLength, zbManual);
  TZsKeySource = (zkNone, zkName, zkMeasured);

  TZsScroll = class(TScrollBox)
  protected
    procedure CreateWnd; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  end;

  TZsRow = class(TS2400UiControl)
  private
    FSelected: Boolean;
    procedure SetSelected(AValue: Boolean);
  protected
    procedure Paint; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    // Daten
    Index: Integer;
    Audio: TS2400Audio;
    FileName: string;
    Env: TArray<Single>;
    MarkS, MarkE: Double;
    Bpm: Double;
    BpmSource: TZsBpmSource;
    KeyPc: Integer;
    KeyMinor: Boolean;
    KeySource: TZsKeySource;
    Cents: Integer;
    RenderedLen: Integer;
    Dirty: Boolean;
    // Einzelsounds (Anfaenge als Anteile der Datei, [0] = Bereichsanfang)
    Slices: TArray<Double>;
    SliceSel: TArray<Boolean>;
    SliceSens: Integer;
    SliceThr: Integer;          // Schwelle in dB unter dem lautesten (-60..0)
    SliceManual: Boolean;       // keine Erkennung, Marken nur von Hand
    SlicesValid: Boolean;
    // Bedienelemente
    LabelName, LabelSub, LabelFile: TLabel;
    Wave: TZsWave;
    ReadBpm, ReadFactor, ReadKey: TZsReadout;
    KnobPitch, KnobGain: TZsKnob;
    KeyMute, KeySolo, KeyRemove: TZsKey;
    constructor Create(AOwner: TComponent); override;
    function HasAudio: Boolean;
    property Selected: Boolean read FSelected write SetSelected;
  end;

  TZsAddRow = class(TS2400UiControl)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

procedure TZsScroll.CreateWnd;
begin
  inherited CreateWnd;
  SetWindowTheme(Handle, 'DarkMode_Explorer', nil);
end;

function TZsScroll.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  VertScrollBar.Position := VertScrollBar.Position - WheelDelta div 3;
end;

constructor TZsRow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_BG;
  Cursor := crHandPoint;
  MarkE := 1;
  KeyPc := -1;
  SliceSens := 50;
  SliceThr := -45;
end;

function TZsRow.HasAudio: Boolean;
begin
  Result := Audio.Frames > 0;
end;

procedure TZsRow.SetSelected(AValue: Boolean);
begin
  if AValue = FSelected then
    Exit;
  FSelected := AValue;
  Invalidate;
end;

function TZsRow.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  // Mausrad ueber der Zeile rollt die Spurliste
  Result := True;
  if Parent is TZsScroll then
    TZsScroll(Parent).VertScrollBar.Position := TZsScroll(Parent).VertScrollBar.Position - WheelDelta div 3;
end;

procedure TZsRow.Paint;
var
  G: TGPGraphics;
  W, H: Single;
begin
  PaintBackground;
  W := Width;
  H := Height - 2;
  G := GpBegin(Canvas.Handle);
  try
    FillRoundA(G, 1, 2, W - 1, H, Sc(4), ColA(clBlack, 120));
    GpFillRound(G, 0, 0, W - 1, H, Sc(4), C_MX_PANEL);
    if FSelected then
    begin
      StrokeRound(G, 0, 0, W - 1, H, Sc(4), GpColor(C_UI_ACCENT), 1.5 * GUiScale);
      GpFillRound(G, 0, Sc(6), Sc(3), H - Sc(12), 1, C_UI_ACCENT);
    end
    else
      StrokeRound(G, 0, 0, W - 1, H, Sc(4), GpColor(C_MX_EDGE), 1);
    DrawLineA(G, Sc(4), 1.5, W - Sc(5), 1.5, ColA(clWhite, 28), 1);
  finally
    G.Free;
  end;
end;

constructor TZsAddRow.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := C_MX_BG;
  Cursor := crHandPoint;
end;

procedure TZsAddRow.Paint;
var
  G: TGPGraphics;
  Pen: TGPPen;
  P: TGPGraphicsPath;
  R: TRect;
begin
  PaintBackground;
  G := GpBegin(Canvas.Handle);
  try
    if FHot then
      GpFillRound(G, 0, 0, Width - 1, Height - 1, Sc(4), C_MX_PANEL);
    P := RoundPath(0.5, 0.5, Width - 2, Height - 2, Sc(4));
    Pen := TGPPen.Create(GpColor(C_MX_SCALE), 1);
    try
      Pen.SetDashStyle(DashStyleDash);
      G.DrawPath(Pen, P);
    finally
      Pen.Free;
      P.Free;
    end;
  finally
    G.Free;
  end;
  Canvas.Font.Name := C_UI_FONT_SEMIBOLD;
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Sc(12);
  Canvas.Font.Quality := fqClearType;
  if FHot then
    Canvas.Font.Color := C_UI_TEXT
  else
    Canvas.Font.Color := C_UI_TEXT2;
  R := ClientRect;
  UiText(Canvas, Caption, R, DT_CENTER);
end;

// ---------------------------------------------------------------------------
// Fenster
// ---------------------------------------------------------------------------

type
  TZsPanel = record
    R: TRect;
    HeadH: Integer;
  end;

  TZsFileEntry = record
    Path: string;
    Time: TDateTime;
    Search: string;   // Kleinbuchstaben: relativer Pfad
  end;

  TZsForm = class(TForm)
  private
    FPanels: TArray<TZsPanel>;
    FWells: TArray<TRect>;
    FRows: TList<TZsRow>;
    FSel: TZsRow;
    FSpeed: Double;             // Wiedergabe gesamt = FTempo x Plattenspieler-Stufe
    FTempo: Double;             // Stack-Tempo / Original-Tempo von Spur 1 (vor dem Plattenspieler)
    FRpm: Integer;              // Plattenspieler-Stufe (C_RPM_FACTOR)
    FKeepPitch: Boolean;        // Tonhoehe beim Tempo halten (Zeitdehnung)
    FLoading: Boolean;
    // Geraet
    FOut: TS2400WasapiOut;
    FEngine: TZsEngine;
    FDevId, FDevName, FDevError: string;
    FDevRate: Integer;
    FDevMenu: TPopupMenu;
    FStatusMsg: string;
    FStatusUntil: UInt64;
    FStatusOk: Boolean;         // Meldung ist eine Bestaetigung, kein Fehler
    // Stack speichern/laden
    FStackDir: string;
    FImportDir: string;         // zuletzt gewaehlter Ordner fuer Splice-Stems
    FStackName: string;
    FBulk: Boolean;             // beim Laden: noch nicht rechnen
    // Browser / Vorhoeren
    FFolder: string;
    FFiles: TList<TZsFileEntry>;
    FShown: TArray<Integer>;
    FPrevFile: string;
    FPrevAudio: TS2400Audio;
    FPrevBpm: Double;
    FPrevIdx: Integer;          // Index in FFiles des vorgehoerten Samples
    FPrevWasActive: Boolean;
    // Anzeige
    FTimer, FRenderTimer, FPrevTimer: TTimer;
    FMeterDisp, FMeterHold: array[0..1] of Single;
    FMeterHoldUntil: array[0..1] of UInt64;
    // Steuerelemente
    KeyRpm: array[0..C_RPM_COUNT - 1] of TZsKey;
    ReadTempo: TZsReadout;
    KeyTempoDown, KeyTempoUp, KeyKeepPitch: TZsKey;
    EditTempo: TEdit;
    BeatLeds: TZsBeatLeds;
    LabelTempoInfo: TLabel;
    RowsBox: TZsScroll;
    AddRow: TZsAddRow;
    LabelEdit: TLabel;
    EditWave: TZsEditWave;
    KeyNudge: array[0..7] of TZsKey;
    ReadStart, ReadEnd, ReadLen: TZsReadout;
    KeySnap, KeyAudition, KeyReset: TZsKey;
    ReadBpm: TZsReadout;
    KeyBpm: array[0..3] of TZsKey;
    LabelBpmSrc: TLabel;
    KnobCent: TZsKnob;
    ReadCent: TZsReadout;
    ButtonPlay: TS2400Button;
    KeyLoop, KeyPreroll: TZsKey;
    Meter: TZsMeter;
    LabelDevice, LabelStatus: TLabel;
    LabelFolder: TLabel;
    ButtonFolder, ButtonNew, ButtonReplace: TS2400Button;
    EditSearch: TEdit;
    ListFiles: TListBox;
    KeyPrevOn, KeyPrevTempo: TZsKey;
    KnobPrev: TZsKnob;
    ReadPrev: TZsReadout;
    KeyStackLoad, KeyStackSave: TZsKey;
    // Einzelsounds
    LabelEditHint: TLabel;
    KeySliceMode, KeySliceAll, KeySliceNone, KeySliceSave, KeySliceManual, KeySliceClear: TZsKey;
    Pads: TZsPads;
    KnobSens, KnobThr: TZsKnob;
    LabelSens, LabelThr: TLabel;
    ReadSlices, ReadThr: TZsReadout;
    FEdNormal, FEdSlice: TArray<TControl>;
    FSliceActive: Integer;      // gerade gespielter Einzelsound (-1 = keiner)
    FSliceLast: Integer;        // zuletzt angeklickter Einzelsound (fuer Entf)
    FSliceDir: string;
    procedure AddPanel(const AR: TRect; AHeadH: Integer);
    function AddLabel(AParent: TWinControl; AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
      AColor: TColor; AAlign: TAlignment = taLeftJustify; ASemibold: Boolean = False): TLabel;
    function AddReadout(AParent: TWinControl; AX, AY, AW, AH, AFontPx: Integer): TZsReadout;
    function AddKey(AParent: TWinControl; AX, AY, AW, AH: Integer; const ACaption: string; AToggle: Boolean;
      AOnClick: TNotifyEvent): TZsKey;
    function AddKnob(AParent: TWinControl; AX, AY, ASize: Integer; AMin, AMax, ADefault, AStep: Integer;
      AOnChange: TNotifyEvent): TZsKnob;
    function AddButton(AX, AY, AW, AH: Integer; const ACaption, AGlyph: string; AOnClick: TNotifyEvent): TS2400Button;
    procedure FormPaint(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure WMDropFiles(var Msg: TWMDropFiles); message WM_DROPFILES;
    // Geraet
    procedure ResolveDevice;
    procedure OpenDevice;
    procedure CloseDevice;
    procedure DeviceClick(Sender: TObject);
    procedure DeviceItemClick(Sender: TObject);
    // Spuren
    function RowOf(Sender: TObject): TZsRow;
    function NewRow: TZsRow;
    function AddTrack(const AFileName: string): TZsRow;
    function LoadInto(ARow: TZsRow; const AFileName: string): Boolean;
    procedure RemoveRow(ARow: TZsRow);
    procedure LayoutRows;
    procedure SelectRow(ARow: TZsRow);
    function RowSpeed(ARow: TZsRow): Double;
    procedure MarkDirty(ARow: TZsRow);
    procedure MarkAllDirty;
    procedure RenderTimerTick(Sender: TObject);
    procedure RenderRow(ARow: TZsRow);
    procedure ApplyMix;
    procedure UpdateDisplay;
    procedure UpdateEditor(AResetView: Boolean);
    procedure ApplyEditMarks(AFinal: Boolean);
    // Ereignisse
    procedure RpmClick(Sender: TObject);
    procedure TempoKeyClick(Sender: TObject);
    procedure TempoReadClick(Sender: TObject);
    procedure TempoEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TempoEditExit(Sender: TObject);
    procedure TempoEditKeyPress(Sender: TObject; var Key: Char);
    procedure KeepPitchClick(Sender: TObject);
    procedure SetTempo(ATempo: Double);
    procedure ApplySpeed;
    function StackBpm: Double;
    function PlayBpm: Double;
    function PitchComp: Double;
    procedure RowClick(Sender: TObject);
    procedure RowPitchChange(Sender: TObject);
    procedure RowGainChange(Sender: TObject);
    procedure RowMixClick(Sender: TObject);
    procedure RowRemoveClick(Sender: TObject);
    procedure AddRowClick(Sender: TObject);
    procedure EditMarksMoving(Sender: TObject);
    procedure EditMarks(Sender: TObject);
    procedure NudgeClick(Sender: TObject);
    procedure SnapClick(Sender: TObject);
    procedure AuditionClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure BpmKeyClick(Sender: TObject);
    procedure CentChange(Sender: TObject);
    procedure PlayClick(Sender: TObject);
    procedure LoopClick(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    // Browser
    procedure FolderClick(Sender: TObject);
    procedure ScanFolder;
    procedure ApplyFilter;
    procedure SearchChange(Sender: TObject);
    procedure ListData(Control: TWinControl; Index: Integer; var Data: string);
    procedure ListDraw(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
    procedure ListClick(Sender: TObject);
    procedure ListDblClick(Sender: TObject);
    procedure ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure NewTrackClick(Sender: TObject);
    procedure ReplaceTrackClick(Sender: TObject);
    procedure PrevTimerTick(Sender: TObject);
    procedure PrevGainChange(Sender: TObject);
    procedure StartPreviewFile(const AFileName: string);
    function SelectedFile: string;
    function SelectedFileIdx: Integer;
    // Stack
    procedure StackLoadClick(Sender: TObject);
    procedure StackSaveClick(Sender: TObject);
    function StackFolder: string;
    function FindStackFile(const AFileName, AStackDir: string): string;
    procedure ClearRows;
    procedure SaveStack(const AFileName: string);
    function SaveStackSlices(const AStackFile: string; out AError: string): Integer;
    procedure LoadStack(const AFileName: string);
    procedure ImportSplice(const AFileName: string);
    // Einzelsounds
    procedure SliceModeClick(Sender: TObject);
    procedure SliceSensChange(Sender: TObject);
    procedure SliceSelClick(Sender: TObject);
    procedure SliceManualClick(Sender: TObject);
    procedure SliceClearClick(Sender: TObject);
    procedure SliceSaveClick(Sender: TObject);
    procedure PadClick(Sender: TObject);
    procedure EditSliceClick(Sender: TObject);
    procedure EditSlicesChanged(Sender: TObject);
    procedure SliceHit(AIdx: Integer; AToggle: Boolean);
    procedure DeleteSliceMark(AIdx: Integer);
    procedure DetectSlices(ARow: TZsRow);
    procedure UpdateSliceUi;
    function RenderSlice(ARow: TZsRow; AIdx, ARate: Integer): TArray<Single>;
    procedure ShowStatus(const AMsg: string; AOk: Boolean);
    // Einstellungen
    procedure LoadSettings;
    procedure SaveSettings;
  protected
    procedure CreateParams(var Params: TCreateParams); override;
    procedure CreateWnd; override;
    procedure DoClose(var Action: TCloseAction); override;
  public
    constructor CreateZs(AOwner: TComponent);
    destructor Destroy; override;
  end;

var
  GZsForm: TZsForm = nil;

const
  C_ROW_H = 60;
  C_ROW_GAP = 6;

// ---------------------------------------------------------------------------
// Aufbau
// ---------------------------------------------------------------------------

constructor TZsForm.CreateZs(AOwner: TComponent);
const
  M = 14;
var
  BW, X0, RW, Y, I, PY, EY, TY, BH: Integer;
  Before: TArray<TControl>;

  // Controls[] ist nicht in Erstellungsreihenfolge (erst grafische, dann
  // Fenster-Steuerelemente) - daher Vorher/Nachher vergleichen
  function AllControls: TArray<TControl>;
  var
    J: Integer;
  begin
    SetLength(Result, ControlCount);
    for J := 0 to ControlCount - 1 do
      Result[J] := Controls[J];
  end;

  function NewSince(const AOld: TArray<TControl>): TArray<TControl>;
  var
    J, K: Integer;
    Found: Boolean;
  begin
    Result := nil;
    for J := 0 to ControlCount - 1 do
    begin
      Found := False;
      for K := 0 to High(AOld) do
        if AOld[K] = Controls[J] then
        begin
          Found := True;
          Break;
        end;
      if not Found then
        Result := Result + [Controls[J]];
    end;
  end;

begin
  inherited CreateNew(AOwner);
  FLoading := True;
  FFiles := TList<TZsFileEntry>.Create;
  FRows := TList<TZsRow>.Create;
  FSpeed := 1;
  FTempo := 1;
  FRpm := 0;
  FPrevIdx := -1;

  Scaled := False;
  BorderStyle := bsSingle;
  BorderIcons := [biSystemMenu, biMinimize];
  Position := poScreenCenter;
  Caption := Tr('Isla-Zuspieler', 'Isla feeder');
  Color := C_MX_BG;
  DoubleBuffered := True;
  KeyPreview := True;
  UiSetFont(Font, 9, C_UI_TEXT);
  OnPaint := FormPaint;
  OnKeyDown := FormKeyDown;

  BW := Sc(300);
  X0 := Sc(M) + BW + Sc(10);
  RW := Sc(842);
  BH := Sc(716);                  // Unterkante der Felder
  ClientWidth := X0 + RW + Sc(M);
  ClientHeight := BH + Sc(M);

  // ===== Browser links =====
  AddPanel(Rect(Sc(M), Sc(M), Sc(M) + BW, BH), Sc(22));
  AddLabel(Self, Sc(M), Sc(M) + Sc(2), BW, Sc(18), 'SAMPLES', 9, C_UI_TEXT, taCenter, True);
  LabelFolder := AddLabel(Self, Sc(M) + Sc(12), Sc(M) + Sc(32), BW - Sc(24), Sc(30), '', 8, C_UI_TEXT2);
  LabelFolder.WordWrap := True;
  LabelFolder.Layout := tlTop;
  ButtonFolder := AddButton(Sc(M) + Sc(12), Sc(M) + Sc(66), Sc(120), Sc(26), Tr('Ordner '#$2026, 'Folder '#$2026), #$E8B7, FolderClick);
  AddLabel(Self, Sc(M) + Sc(140), Sc(M) + Sc(66), BW - Sc(152), Sc(26), Tr('neueste zuerst', 'newest first'), 8, C_UI_MUTED, taRightJustify);

  FWells := FWells + [Rect(Sc(M) + Sc(12), Sc(M) + Sc(100), Sc(M) + BW - Sc(12), Sc(M) + Sc(126))];
  EditSearch := TEdit.Create(Self);
  EditSearch.Parent := Self;
  EditSearch.BorderStyle := bsNone;
  EditSearch.Color := C_MX_WELL;
  UiSetFont(EditSearch.Font, 9, C_UI_TEXT);
  EditSearch.TextHint := Tr('Suchen (z.B. bass 92 Dm)', 'Search (e.g. bass 92 Dm)');
  EditSearch.SetBounds(Sc(M) + Sc(20), Sc(M) + Sc(105), BW - Sc(40), Sc(18));
  EditSearch.OnChange := SearchChange;

  FWells := FWells + [Rect(Sc(M) + Sc(12), Sc(M) + Sc(134), Sc(M) + BW - Sc(12), BH - Sc(126))];
  ListFiles := TZsList.Create(Self);
  ListFiles.Parent := Self;
  ListFiles.Style := lbVirtualOwnerDraw;
  ListFiles.BorderStyle := bsNone;
  ListFiles.Color := C_MX_WELL;
  ListFiles.ItemHeight := Sc(36);
  UiSetFont(ListFiles.Font, 9, C_UI_TEXT);
  ListFiles.SetBounds(Sc(M) + Sc(14), Sc(M) + Sc(136), BW - Sc(28), BH - Sc(128) - Sc(M) - Sc(136));
  ListFiles.OnData := ListData;
  ListFiles.OnDrawItem := ListDraw;
  ListFiles.OnClick := ListClick;
  ListFiles.OnDblClick := ListDblClick;
  ListFiles.OnKeyDown := ListKeyDown;

  // Stack: alle Spuren mit Einstellungen in eine Datei / aus einer Datei
  KeyStackLoad := AddKey(Self, Sc(M) + Sc(12), BH - Sc(118), (BW - Sc(32)) div 2, Sc(28), Tr('STACK LADEN', 'LOAD STACK'), False, StackLoadClick);
  KeyStackLoad.FontPx := 10;
  KeyStackLoad.Hint := Tr('Gespeicherten Stack '#$00F6'ffnen (ersetzt die Spuren)', 'Open a saved stack (replaces the tracks)');
  KeyStackLoad.ShowHint := True;
  KeyStackSave := AddKey(Self, Sc(M) + Sc(20) + (BW - Sc(32)) div 2, BH - Sc(118), (BW - Sc(32)) div 2, Sc(28), Tr('STACK SPEICHERN', 'SAVE STACK'), False, StackSaveClick);
  KeyStackSave.FontPx := 10;
  KeyStackSave.Hint := Tr('Alle Spuren mit Start/Ende, Pitch, Pegel, M/S und Plattenspieler speichern',
    'Save all tracks with start/end, pitch, level, M/S and turntable');
  KeyStackSave.ShowHint := True;

  // Vorhoeren: zwei Tasten, Pegel-Knopf mit Anzeige
  KeyPrevOn := AddKey(Self, Sc(M) + Sc(12), BH - Sc(80), Sc(88), Sc(28), Tr('VORH'#$00D6'REN', 'PREVIEW'), True, nil);
  KeyPrevOn.FontPx := 10;
  KeyPrevOn.Hint := Tr('Klick in der Liste spielt das Sample an (Esc = aus)', 'Click in the list plays the sample (Esc = off)');
  KeyPrevOn.ShowHint := True;
  KnobPrev := AddKnob(Self, Sc(M) + Sc(196), BH - Sc(81), Sc(30), -60, 6, -12, 1, PrevGainChange);
  KnobPrev.Bipolar := False;
  KnobPrev.Hint := Tr('Pegel beim Vorh'#$00F6'ren (Doppelklick = -12 dB)', 'Preview level (double-click = -12 dB)');
  KnobPrev.ShowHint := True;
  ReadPrev := AddReadout(Self, Sc(M) + Sc(230), BH - Sc(78), BW - Sc(242), Sc(24), 10);
  KeyPrevTempo := AddKey(Self, Sc(M) + Sc(104), BH - Sc(80), Sc(88), Sc(28), Tr('IM TEMPO', 'IN TEMPO'), True, nil);
  KeyPrevTempo.FontPx := 10;
  KeyPrevTempo.Hint := Tr('Vorh'#$00F6'ren im Tempo von Spur 1, synchron zur Wiedergabe', 'Preview in the tempo of track 1, in sync with playback');
  KeyPrevTempo.ShowHint := True;
  ButtonNew := AddButton(Sc(M) + Sc(12), BH - Sc(42), (BW - Sc(32)) div 2, Sc(30), Tr('Neue Spur', 'New track'), #$E710, NewTrackClick);
  ButtonReplace := AddButton(Sc(M) + Sc(20) + (BW - Sc(32)) div 2, BH - Sc(42), (BW - Sc(32)) div 2, Sc(30), Tr('In Spur 1', 'To track 1'), #$E72A, ReplaceTrackClick);

  // ===== Plattenspieler =====
  PY := Sc(M);
  AddPanel(Rect(X0, PY, X0 + RW, PY + Sc(52)), 0);
  AddLabel(Self, X0 + Sc(12), PY + Sc(4), Sc(310), Sc(14), Tr('PLATTENSPIELER '#$00B7' GILT F'#$00DC'R ALLE SPUREN', 'TURNTABLE '#$00B7' APPLIES TO ALL TRACKS'), 7, C_UI_ACCENT, taLeftJustify, True);
  for I := 0 to C_RPM_COUNT - 1 do
  begin
    case I of
      0: KeyRpm[I] := AddKey(Self, X0 + Sc(12) + I * Sc(74), PY + Sc(20), Sc(68), Sc(26), 'Original', False, RpmClick);
      1: KeyRpm[I] := AddKey(Self, X0 + Sc(12) + I * Sc(74), PY + Sc(20), Sc(68), Sc(26), '33 '#$2192' 45', False, RpmClick);
      2: KeyRpm[I] := AddKey(Self, X0 + Sc(12) + I * Sc(74), PY + Sc(20), Sc(68), Sc(26), '45 '#$2192' 78', False, RpmClick);
      3: KeyRpm[I] := AddKey(Self, X0 + Sc(12) + I * Sc(74), PY + Sc(20), Sc(68), Sc(26), Tr('+1 Okt.', '+1 oct.'), False, RpmClick);
    end;
    KeyRpm[I].Tag := I;
  end;
  KeyRpm[0].Checked := True;
  // Stack-Tempo: frei einstellbar (- / + / eintippen), alle Spuren folgen
  AddLabel(Self, X0 + Sc(316), PY + Sc(4), Sc(210), Sc(14), Tr('STACK-TEMPO', 'STACK TEMPO'), 7, C_MX_SCALE);
  KeyTempoDown := AddKey(Self, X0 + Sc(316), PY + Sc(20), Sc(26), Sc(26), #$2212, False, TempoKeyClick);
  KeyTempoDown.Tag := -1;
  KeyTempoDown.Hint := Tr('0,1 BPM langsamer (Umschalt: 1 BPM)', '0.1 BPM slower (Shift: 1 BPM)');
  KeyTempoDown.ShowHint := True;
  ReadTempo := AddReadout(Self, X0 + Sc(346), PY + Sc(20), Sc(150), Sc(26), 16);
  ReadTempo.Cursor := crIBeam;
  ReadTempo.Hint := Tr('Klicken: Tempo eintippen (Enter '#$00FC'bernimmt, Esc bricht ab)', 'Click: type the tempo (Enter applies, Esc cancels)');
  ReadTempo.ShowHint := True;
  ReadTempo.OnClick := TempoReadClick;
  EditTempo := TEdit.Create(Self);
  EditTempo.Parent := Self;
  EditTempo.Visible := False;
  EditTempo.BorderStyle := bsNone;
  EditTempo.Color := C_MX_WELL;
  EditTempo.Alignment := taRightJustify;
  UiSetFont(EditTempo.Font, 12, C_UI_ACCENT);
  EditTempo.SetBounds(X0 + Sc(352), PY + Sc(23), Sc(138), Sc(20));
  EditTempo.OnKeyDown := TempoEditKeyDown;
  EditTempo.OnExit := TempoEditExit;
  EditTempo.OnKeyPress := TempoEditKeyPress;
  KeyTempoUp := AddKey(Self, X0 + Sc(500), PY + Sc(20), Sc(26), Sc(26), '+', False, TempoKeyClick);
  KeyTempoUp.Tag := 1;
  KeyTempoUp.Hint := Tr('0,1 BPM schneller (Umschalt: 1 BPM)', '0.1 BPM faster (Shift: 1 BPM)');
  KeyTempoUp.ShowHint := True;
  AddLabel(Self, X0 + Sc(540), PY + Sc(4), Sc(80), Sc(14), Tr('SCHLAG', 'BEAT'), 7, C_MX_SCALE);
  BeatLeds := TZsBeatLeds.Create(Self);
  BeatLeds.Parent := Self;
  BeatLeds.SetBounds(X0 + Sc(540), PY + Sc(20), Sc(80), Sc(26));
  LabelTempoInfo := AddLabel(Self, X0 + Sc(632), PY + Sc(4), RW - Sc(644), Sc(14), '', 7, C_MX_SCALE);
  KeyKeepPitch := AddKey(Self, X0 + Sc(632), PY + Sc(20), RW - Sc(644), Sc(26), Tr('TONH'#$00D6'HE HALTEN', 'KEEP PITCH'), True, KeepPitchClick);
  KeyKeepPitch.FontPx := 10;
  KeyKeepPitch.Hint := Tr('Aus: wie Platte (Tonh'#$00F6'he geht mit dem Tempo). An: Tonh'#$00F6'he bleibt, nur das Tempo '#$00E4'ndert sich',
    'Off: like a record (pitch follows the tempo). On: pitch stays, only the tempo changes');
  KeyKeepPitch.ShowHint := True;

  // ===== Spuren =====
  RowsBox := TZsScroll.Create(Self);
  RowsBox.Parent := Self;
  RowsBox.BorderStyle := bsNone;
  RowsBox.Color := C_MX_BG;
  RowsBox.ParentBackground := False;
  RowsBox.HorzScrollBar.Visible := False;
  RowsBox.VertScrollBar.Tracking := True;
  RowsBox.SetBounds(X0, Sc(74), RW, Sc(5 * (C_ROW_H + C_ROW_GAP)));
  AddRow := TZsAddRow.Create(Self);
  AddRow.Parent := RowsBox;
  AddRow.Caption := Tr('+ Spur hinzuf'#$00FC'gen (oder Datei hierher ziehen)', '+ Add track (or drop a file here)');
  AddRow.OnClick := AddRowClick;

  // ===== Editor =====
  EY := Sc(412);
  AddPanel(Rect(X0, EY, X0 + RW, EY + Sc(236)), Sc(22));
  LabelEdit := AddLabel(Self, X0 + Sc(12), EY + Sc(2), Sc(340), Sc(18), '', 9, C_UI_ACCENT, taLeftJustify, True);
  LabelEditHint := AddLabel(Self, X0 + Sc(360), EY + Sc(3), RW - Sc(490), Sc(18), '', 7, C_UI_MUTED, taRightJustify);
  // Umschalter Start/Ende <-> Einzelsounds
  KeySliceMode := AddKey(Self, X0 + RW - Sc(122), EY + Sc(2), Sc(110), Sc(19), Tr('EINZELSOUNDS', 'SINGLE HITS'), True, SliceModeClick);
  KeySliceMode.FontPx := 9;
  KeySliceMode.Hint := Tr('Drumloop in Einzelsounds zerlegen, anh'#$00F6'ren und speichern',
    'Split a drum loop into single hits, audition and save them');
  KeySliceMode.ShowHint := True;
  EditWave := TZsEditWave.Create(Self);
  EditWave.Parent := Self;
  EditWave.SetBounds(X0 + Sc(12), EY + Sc(30), RW - Sc(24), Sc(118));
  EditWave.EmptyText := Tr('Keine Spur ausgew'#$00E4'hlt', 'No track selected');
  EditWave.OnMarks := EditMarks;
  EditWave.OnMarksMoving := EditMarksMoving;
  EditWave.OnSlices := EditSlicesChanged;
  EditWave.OnSliceClick := EditSliceClick;
  // alles bis PITCH FEIN gehoert zum Start/Ende-Modus
  Before := AllControls;

  Y := EY + Sc(154);
  AddLabel(Self, X0 + Sc(12), Y, Sc(200), Sc(14), 'START', 7, C_MX_SCALE);
  AddLabel(Self, X0 + Sc(240), Y, Sc(200), Sc(14), Tr('ENDE', 'END'), 7, C_MX_SCALE);
  AddLabel(Self, X0 + Sc(468), Y, Sc(250), Sc(14), Tr('L'#$00C4'NGE (ORIGINAL '#$2192' IN DER ISLA)', 'LENGTH (ORIGINAL '#$2192' IN THE ISLA)'), 7, C_MX_SCALE);
  for I := 0 to 1 do
  begin
    KeyNudge[I * 4 + 0] := AddKey(Self, X0 + Sc(12) + I * Sc(228), Y + Sc(16), Sc(30), Sc(24), #$25C0#$25C0, False, NudgeClick);
    KeyNudge[I * 4 + 1] := AddKey(Self, X0 + Sc(46) + I * Sc(228), Y + Sc(16), Sc(30), Sc(24), #$25C0, False, NudgeClick);
    KeyNudge[I * 4 + 2] := AddKey(Self, X0 + Sc(166) + I * Sc(228), Y + Sc(16), Sc(30), Sc(24), #$25B6, False, NudgeClick);
    KeyNudge[I * 4 + 3] := AddKey(Self, X0 + Sc(200) + I * Sc(228), Y + Sc(16), Sc(30), Sc(24), #$25B6#$25B6, False, NudgeClick);
  end;
  for I := 0 to 7 do
  begin
    KeyNudge[I].Tag := I;
    KeyNudge[I].FontPx := 9;
    if I mod 4 in [0, 3] then
      KeyNudge[I].Hint := '10 ms'
    else
      KeyNudge[I].Hint := '1 ms';
    KeyNudge[I].ShowHint := True;
  end;
  ReadStart := AddReadout(Self, X0 + Sc(80), Y + Sc(16), Sc(82), Sc(24), 11);
  ReadEnd := AddReadout(Self, X0 + Sc(308), Y + Sc(16), Sc(82), Sc(24), 11);
  ReadLen := AddReadout(Self, X0 + Sc(468), Y + Sc(16), Sc(250), Sc(24), 11);

  Y := EY + Sc(202);
  KeySnap := AddKey(Self, X0 + Sc(12), Y, Sc(130), Sc(26), Tr('NULLDURCHGANG', 'ZERO CROSSING'), True, SnapClick);
  KeySnap.FontPx := 10;
  KeySnap.Checked := True;
  KeyAudition := AddKey(Self, X0 + Sc(148), Y, Sc(130), Sc(26), Tr('BEREICH H'#$00D6'REN', 'PLAY REGION'), True, AuditionClick);
  KeyAudition.FontPx := 10;
  KeyReset := AddKey(Self, X0 + Sc(284), Y, Sc(110), Sc(26), Tr('ZUR'#$00DC'CKSETZEN', 'RESET'), False, ResetClick);
  KeyReset.FontPx := 10;
  ReadBpm := AddReadout(Self, X0 + Sc(410), Y + Sc(1), Sc(76), Sc(24), 11);
  KeyBpm[0] := AddKey(Self, X0 + Sc(490), Y + Sc(1), Sc(26), Sc(24), #$2212, False, BpmKeyClick);
  KeyBpm[1] := AddKey(Self, X0 + Sc(518), Y + Sc(1), Sc(26), Sc(24), '+', False, BpmKeyClick);
  KeyBpm[2] := AddKey(Self, X0 + Sc(546), Y + Sc(1), Sc(26), Sc(24), #$00BD, False, BpmKeyClick);
  KeyBpm[3] := AddKey(Self, X0 + Sc(574), Y + Sc(1), Sc(32), Sc(24), #$00D7'2', False, BpmKeyClick);
  for I := 0 to 3 do
    KeyBpm[I].Tag := I;
  KeyBpm[0].Hint := Tr('0,1 BPM (Umschalt: 1 BPM)', '0.1 BPM (Shift: 1 BPM)');
  KeyBpm[1].Hint := KeyBpm[0].Hint;
  KeyBpm[0].ShowHint := True;
  KeyBpm[1].ShowHint := True;
  LabelBpmSrc := AddLabel(Self, X0 + Sc(612), Y, Sc(120), Sc(26), '', 7, C_UI_MUTED);
  LabelBpmSrc.WordWrap := True;
  AddLabel(Self, X0 + RW - Sc(102), EY + Sc(152), Sc(90), Sc(14), Tr('PITCH FEIN', 'FINE PITCH'), 7, C_MX_SCALE, taCenter);
  KnobCent := AddKnob(Self, X0 + RW - Sc(79), EY + Sc(166), Sc(44), -50, 50, 0, 1, CentChange);
  ReadCent := AddReadout(Self, X0 + RW - Sc(92), EY + Sc(212), Sc(70), Sc(20), 10);
  FEdNormal := NewSince(Before);

  // Einzelsound-Modus (gleiche Flaeche, anfangs verborgen)
  Before := AllControls;
  Pads := TZsPads.Create(Self);
  Pads.Parent := Self;
  Pads.SetBounds(X0 + Sc(12), EY + Sc(156), RW - Sc(24) - Sc(148), Sc(32));
  Pads.EmptyText := Tr('Keine Einzelsounds '#$2013' Empfindlichkeit/Schwelle '#$00E4'ndern oder MANUELL',
    'No single hits '#$2013' change sensitivity/threshold or MANUAL');
  Pads.OnPadClick := PadClick;
  // manuell: keine Erkennung, Marken nur von Hand (z.B. Klavier)
  KeySliceManual := AddKey(Self, X0 + RW - Sc(12) - Sc(140), EY + Sc(156), Sc(70), Sc(32), Tr('MANUELL', 'MANUAL'), True, SliceManualClick);
  KeySliceManual.FontPx := 10;
  KeySliceManual.Hint := Tr('Keine automatische Erkennung: Marken per Doppelklick setzen (z.B. Klavier)',
    'No automatic detection: set markers by double-click (e.g. piano)');
  KeySliceManual.ShowHint := True;
  KeySliceClear := AddKey(Self, X0 + RW - Sc(12) - Sc(66), EY + Sc(156), Sc(66), Sc(32), Tr('LEEREN', 'CLEAR'), False, SliceClearClick);
  KeySliceClear.FontPx := 10;
  KeySliceClear.Hint := Tr('Alle Marken entfernen (schaltet auf MANUELL)', 'Remove all markers (switches to MANUAL)');
  KeySliceClear.ShowHint := True;
  Y := EY + Sc(198);
  LabelSens := AddLabel(Self, X0 + Sc(12), Y + Sc(9), Sc(74), Sc(16), Tr('EMPFINDLICH', 'SENSITIVITY'), 7, C_MX_SCALE);
  KnobSens := AddKnob(Self, X0 + Sc(86), Y, Sc(32), 0, 100, 50, 5, SliceSensChange);
  KnobSens.Bipolar := False;
  KnobSens.Hint := Tr('Wie deutlich ein Schlag einsetzen muss: h'#$00F6'her = auch Ghost Notes und weiche T'#$00F6'ne (Doppelklick = Mitte)',
    'How sharp a hit must start: higher = ghost notes and soft notes too (double-click = middle)');
  KnobSens.ShowHint := True;
  LabelThr := AddLabel(Self, X0 + Sc(128), Y + Sc(9), Sc(60), Sc(16), Tr('SCHWELLE', 'THRESHOLD'), 7, C_MX_SCALE);
  KnobThr := AddKnob(Self, X0 + Sc(188), Y, Sc(32), -60, 0, -45, 1, SliceSensChange);
  KnobThr.Bipolar := False;
  KnobThr.Hint := Tr('Leisere Schl'#$00E4'ge als die Schwelle (unter dem lautesten) z'#$00E4'hlen nicht (Doppelklick = '#$2212'45 dB)',
    'Hits quieter than the threshold (below the loudest) are ignored (double-click = -45 dB)');
  KnobThr.ShowHint := True;
  ReadThr := AddReadout(Self, X0 + Sc(224), Y + Sc(4), Sc(66), Sc(24), 11);
  ReadSlices := AddReadout(Self, X0 + Sc(300), Y + Sc(4), Sc(164), Sc(24), 11);
  KeySliceAll := AddKey(Self, X0 + Sc(472), Y + Sc(4), Sc(56), Sc(24), Tr('ALLE', 'ALL'), False, SliceSelClick);
  KeySliceAll.Tag := 1;
  KeySliceAll.FontPx := 10;
  KeySliceNone := AddKey(Self, X0 + Sc(532), Y + Sc(4), Sc(56), Sc(24), Tr('KEINE', 'NONE'), False, SliceSelClick);
  KeySliceNone.Tag := 0;
  KeySliceNone.FontPx := 10;
  KeySliceSave := AddKey(Self, X0 + RW - Sc(12) - Sc(190), Y + Sc(4), Sc(190), Sc(24),
    Tr('AUSWAHL SPEICHERN '#$2026, 'SAVE SELECTION '#$2026), False, SliceSaveClick);
  KeySliceSave.FontPx := 10;
  KeySliceSave.Hint := Tr('Gew'#$00E4'hlte Sounds als WAV (24 Bit) speichern, mit Plattenspieler und Pitch',
    'Save the selected hits as WAV (24 bit), with turntable and pitch');
  KeySliceSave.ShowHint := True;
  FEdSlice := NewSince(Before);
  FSliceLast := -1;
  for I := 0 to High(FEdSlice) do
    FEdSlice[I].Visible := False;
  FSliceActive := -1;
  UpdateSliceUi;

  // ===== Transport =====
  TY := Sc(656);
  AddPanel(Rect(X0, TY, X0 + RW, BH), 0);
  ButtonPlay := AddButton(X0 + Sc(12), TY + Sc(14), Sc(140), Sc(32), Tr('Abspielen', 'Play'), #$E768, PlayClick);
  ButtonPlay.Primary := True;
  KeyLoop := AddKey(Self, X0 + Sc(164), TY + Sc(14), Sc(92), Sc(32), Tr('SCHLEIFE', 'LOOP'), True, LoopClick);
  KeyPreroll := AddKey(Self, X0 + Sc(264), TY + Sc(14), Sc(104), Sc(32), Tr('VORLAUF 1 s', 'PRE-ROLL 1 s'), True, nil);
  AddLabel(Self, X0 + Sc(384), TY + Sc(6), Sc(220), Sc(14), Tr('AUSGANG L / R', 'OUTPUT L / R'), 7, C_MX_SCALE);
  Meter := TZsMeter.Create(Self);
  Meter.Parent := Self;
  Meter.SetBounds(X0 + Sc(384), TY + Sc(24), Sc(220), Sc(20));
  LabelDevice := AddLabel(Self, X0 + Sc(620), TY + Sc(8), RW - Sc(632), Sc(20), '', 9, C_UI_TEXT, taLeftJustify, True);
  LabelDevice.Cursor := crHandPoint;
  LabelDevice.OnClick := DeviceClick;
  LabelDevice.Hint := Tr('Klicken: Ausgabeger'#$00E4't w'#$00E4'hlen', 'Click: choose output device');
  LabelDevice.ShowHint := True;
  LabelStatus := AddLabel(Self, X0 + Sc(620), TY + Sc(30), RW - Sc(632), Sc(20), '', 8, C_UI_TEXT2);
  LabelStatus.Cursor := crHandPoint;
  LabelStatus.OnClick := DeviceClick;

  FDevMenu := TPopupMenu.Create(Self);

  FRenderTimer := TTimer.Create(Self);
  FRenderTimer.Enabled := False;
  FRenderTimer.Interval := C_RENDER_DELAY_MS;
  FRenderTimer.OnTimer := RenderTimerTick;

  FPrevTimer := TTimer.Create(Self);
  FPrevTimer.Enabled := False;
  FPrevTimer.Interval := 150;
  FPrevTimer.OnTimer := PrevTimerTick;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 50;
  FTimer.OnTimer := TimerTick;

  for I := 0 to 1 do
  begin
    FMeterDisp[I] := -120;
    FMeterHold[I] := -120;
  end;

  LoadSettings;
  EditWave.Snap := KeySnap.Checked;
  PrevGainChange(nil);
  ResolveDevice;
  OpenDevice;
  ScanFolder;
  AddTrack(''); // leere Spur 1 als Ziel zum Ablegen
  FLoading := False;
  UpdateEditor(True);
  UpdateDisplay;
end;

destructor TZsForm.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  if FRenderTimer <> nil then
    FRenderTimer.Enabled := False;
  if FPrevTimer <> nil then
    FPrevTimer.Enabled := False;
  if (KeyLoop <> nil) and (KeyPrevTempo <> nil) and (KeySnap <> nil) then
    SaveSettings; // nicht nach einem Fehler im Aufbau
  CloseDevice;
  FFiles.Free;
  FRows.Free;    // die Zeilen selbst gehoeren dem Fenster (Owner)
  inherited Destroy;
  UiGdiplusStop;
  if GZsForm = Self then
    GZsForm := nil;
end;

procedure TZsForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  // eigene Schaltflaeche in der Taskleiste (der Monitor selbst hat keine)
  Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
  Params.WndParent := 0;
end;

procedure TZsForm.CreateWnd;
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
  DragAcceptFiles(Handle, True);
end;

procedure TZsForm.DoClose(var Action: TCloseAction);
begin
  inherited DoClose(Action);
  Action := caFree;
end;

procedure TZsForm.AddPanel(const AR: TRect; AHeadH: Integer);
var
  P: TZsPanel;
begin
  P.R := AR;
  P.HeadH := AHeadH;
  FPanels := FPanels + [P];
end;

function TZsForm.AddLabel(AParent: TWinControl; AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
  AColor: TColor; AAlign: TAlignment; ASemibold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := AParent;
  Result.AutoSize := False;
  Result.Transparent := True;
  Result.ShowAccelChar := False;
  Result.Alignment := AAlign;
  Result.Layout := tlCenter;
  Result.EllipsisPosition := epEndEllipsis;
  Result.SetBounds(AX, AY, AW, AH);
  UiSetFont(Result.Font, ASize, AColor, ASemibold);
  Result.Caption := AText;
end;

function TZsForm.AddReadout(AParent: TWinControl; AX, AY, AW, AH, AFontPx: Integer): TZsReadout;
begin
  Result := TZsReadout.Create(Self);
  Result.Parent := AParent;
  Result.FontPx := AFontPx;
  Result.SetBounds(AX, AY, AW, AH);
end;

function TZsForm.AddKey(AParent: TWinControl; AX, AY, AW, AH: Integer; const ACaption: string; AToggle: Boolean;
  AOnClick: TNotifyEvent): TZsKey;
begin
  Result := TZsKey.Create(Self);
  Result.Parent := AParent;
  Result.Caption := ACaption;
  Result.Toggle := AToggle;
  Result.SetBounds(AX, AY, AW, AH);
  Result.OnClick := AOnClick;
end;

function TZsForm.AddKnob(AParent: TWinControl; AX, AY, ASize: Integer; AMin, AMax, ADefault, AStep: Integer;
  AOnChange: TNotifyEvent): TZsKnob;
begin
  Result := TZsKnob.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(AX, AY, ASize, ASize);
  Result.SetRange(AMin, AMax, ADefault, AStep);
  Result.Value := ADefault;
  Result.OnChange := AOnChange;
end;

function TZsForm.AddButton(AX, AY, AW, AH: Integer; const ACaption, AGlyph: string; AOnClick: TNotifyEvent): TS2400Button;
begin
  Result := TS2400Button.Create(Self);
  Result.Parent := Self;
  Result.Color := C_MX_PANEL;
  Result.Caption := ACaption;
  Result.Glyph := AGlyph;
  Result.SetBounds(AX, AY, AW, AH);
  Result.OnClick := AOnClick;
end;

procedure TZsForm.FormPaint(Sender: TObject);
var
  G: TGPGraphics;
  P: TZsPanel;
  W: TRect;
  X, Y, Wd, H: Single;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_MX_BG;
  Canvas.FillRect(ClientRect);
  G := GpBegin(Canvas.Handle);
  try
    for P in FPanels do
    begin
      X := P.R.Left;
      Y := P.R.Top;
      Wd := P.R.Width;
      H := P.R.Height;
      FillRoundA(G, X + 1, Y + 2, Wd, H, Sc(4), ColA(clBlack, 120));
      GpFillRound(G, X, Y, Wd, H, Sc(4), C_MX_PANEL);
      if P.HeadH > 0 then
      begin
        FillGrad(G, X, Y, Wd, P.HeadH, Sc(4), C_MX_HEAD_TOP, C_MX_HEAD_BOT);
        DrawLineA(G, X + 1, Y + P.HeadH + 0.5, X + Wd - 1, Y + P.HeadH + 0.5, GpColor(C_MX_EDGE), 1);
      end;
      StrokeRound(G, X, Y, Wd, H, Sc(4), GpColor(C_MX_EDGE), 1);
      DrawLineA(G, X + Sc(4), Y + 1.5, X + Wd - Sc(4), Y + 1.5, ColA(clWhite, 28), 1);
    end;
    for W in FWells do
      DrawWell(G, W.Left, W.Top, W.Width, W.Height);
  finally
    G.Free;
  end;
end;

procedure TZsForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ActiveControl = EditSearch) or (ActiveControl = EditTempo) then
    Exit;
  // Leertaste = Abspielen/Stopp, Esc = Vorhoeren aus
  if Key = VK_SPACE then
  begin
    PlayClick(nil);
    Key := 0;
  end
  else if (Key = VK_ESCAPE) and (FEngine <> nil) then
  begin
    FEngine.StopPreview;
    Key := 0;
  end
  else if (Key = VK_DELETE) and KeySliceMode.Checked then
  begin
    // Einzelsounds: Marke vor dem zuletzt angeklickten Sound loeschen
    DeleteSliceMark(FSliceLast);
    Key := 0;
  end;
end;

procedure TZsForm.WMDropFiles(var Msg: TWMDropFiles);
var
  Count, I: Integer;
  Buf: array[0..MAX_PATH * 2] of Char;
  Pt, P: TPoint;
  Names: TArray<string>;
  Target, R: TZsRow;
begin
  try
    Count := DragQueryFile(Msg.Drop, $FFFFFFFF, nil, 0);
    Names := nil;
    for I := 0 to Count - 1 do
      if DragQueryFile(Msg.Drop, I, Buf, Length(Buf)) > 0 then
        if S2400IsAudioFile(Buf) then
          Names := Names + [string(Buf)];
    DragQueryPoint(Msg.Drop, Pt);
  finally
    DragFinish(Msg.Drop);
  end;
  Msg.Result := 0;
  if Length(Names) = 0 then
    Exit;
  // auf eine Spur: diese ersetzen (weitere Dateien als neue Spuren)
  Target := nil;
  for R in FRows do
  begin
    P := R.ScreenToClient(ClientToScreen(Pt));
    if PtInRect(R.ClientRect, P) then
    begin
      Target := R;
      Break;
    end;
  end;
  I := 0;
  if Target <> nil then
  begin
    LoadInto(Target, Names[0]);
    SelectRow(Target);
    I := 1;
  end
  else if (FRows.Count > 0) and not FRows[FRows.Count - 1].HasAudio then
  begin
    // leere letzte Spur zuerst fuellen
    Target := FRows[FRows.Count - 1];
    LoadInto(Target, Names[0]);
    SelectRow(Target);
    I := 1;
  end;
  while I < Length(Names) do
  begin
    if AddTrack(Names[I]) = nil then
      Break;
    Inc(I);
  end;
end;

// ---------------------------------------------------------------------------
// Ausgabegeraet
// ---------------------------------------------------------------------------

// Reihenfolge: eigene Wahl, dann der Windows-Ausgang des Verbunds, dann ein
// Geraet mit "Realtek" im Namen, sonst das erste
procedure TZsForm.ResolveDevice;
var
  Devs: TArray<TS2400WinDevice>;
  D: TS2400WinDevice;
  Reg: TRegistry;
  AggId: string;
begin
  Devs := TS2400WasapiOut.ListDevices;
  if FDevId <> '' then
    for D in Devs do
      if D.Id = FDevId then
      begin
        FDevName := D.Name;
        Exit;
      end;
  AggId := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(C_REG_AGG) and Reg.ValueExists('WinDeviceId') then
      AggId := Reg.ReadString('WinDeviceId');
  finally
    Reg.Free;
  end;
  if AggId <> '' then
    for D in Devs do
      if D.Id = AggId then
      begin
        FDevId := D.Id;
        FDevName := D.Name;
        Exit;
      end;
  for D in Devs do
    if Pos('REALTEK', UpperCase(D.Name)) > 0 then
    begin
      FDevId := D.Id;
      FDevName := D.Name;
      Exit;
    end;
  if Length(Devs) > 0 then
  begin
    FDevId := Devs[0].Id;
    FDevName := Devs[0].Name;
  end
  else
  begin
    FDevId := '';
    FDevName := '';
  end;
end;

procedure TZsForm.OpenDevice;
var
  R: TZsRow;
begin
  CloseDevice;
  FDevError := '';
  FDevRate := 0;
  if FDevId = '' then
  begin
    FDevError := Tr('Kein Ausgabeger'#$00E4't gefunden', 'No output device found');
    UpdateDisplay;
    Exit;
  end;
  FOut := TS2400WasapiOut.Create;
  // geteilter Modus: Windows mischt mit dem Verbund und anderen Programmen
  if not FOut.Open(FDevId, 48000, False) or not FOut.Start then
  begin
    FDevError := FOut.LastError;
    if FDevError = '' then
      FDevError := Tr('Ger'#$00E4't startet nicht', 'Device does not start');
    FreeAndNil(FOut);
    UpdateDisplay;
    Exit;
  end;
  FDevRate := FOut.SampleRate;
  FEngine := TZsEngine.Create(FOut);
  FEngine.SetLoop(KeyLoop.Checked);
  PrevGainChange(nil);
  // vorhandene Spuren fuer die Rate des Geraets neu rechnen
  for R in FRows do
    RenderRow(R);
  ApplyMix;
  UpdateDisplay;
end;

procedure TZsForm.CloseDevice;
begin
  FreeAndNil(FEngine); // beendet den Thread (vor dem Geraet)
  if FOut <> nil then
  begin
    FOut.Stop;
    FreeAndNil(FOut);
  end;
end;

procedure TZsForm.DeviceClick(Sender: TObject);
var
  Devs: TArray<TS2400WinDevice>;
  D: TS2400WinDevice;
  Item: TMenuItem;
  Pt: TPoint;
begin
  FDevMenu.Items.Clear;
  Devs := TS2400WasapiOut.ListDevices;
  for D in Devs do
  begin
    Item := TMenuItem.Create(FDevMenu);
    Item.Caption := StringReplace(D.Name, '&', '&&', [rfReplaceAll]);
    Item.Hint := D.Id;
    Item.RadioItem := True;
    Item.Checked := D.Id = FDevId;
    Item.OnClick := DeviceItemClick;
    FDevMenu.Items.Add(Item);
  end;
  if FDevMenu.Items.Count = 0 then
    Exit;
  Pt := LabelDevice.ClientToScreen(Point(0, LabelDevice.Height));
  FDevMenu.Popup(Pt.X, Pt.Y);
end;

procedure TZsForm.DeviceItemClick(Sender: TObject);
begin
  FDevId := TMenuItem(Sender).Hint;
  ResolveDevice;
  OpenDevice;
  SaveSettings;
end;

// ---------------------------------------------------------------------------
// Spuren
// ---------------------------------------------------------------------------

function TZsForm.RowOf(Sender: TObject): TZsRow;
begin
  Result := nil;
  if Sender is TZsRow then
    Result := TZsRow(Sender)
  else if (Sender is TControl) and (TControl(Sender).Parent is TZsRow) then
    Result := TZsRow(TControl(Sender).Parent);
end;

function TZsForm.NewRow: TZsRow;
var
  R: TZsRow;
  W: Integer;
begin
  R := TZsRow.Create(Self);
  R.Parent := RowsBox;
  W := RowsBox.Width - Sc(18);
  R.SetBounds(0, 0, W, Sc(C_ROW_H));
  R.OnClick := RowClick;
  R.LabelName := AddLabel(R, Sc(10), Sc(8), Sc(70), Sc(18), '', 9, C_UI_LEVEL, taLeftJustify, True);
  R.LabelName.OnClick := RowClick;
  R.LabelSub := AddLabel(R, Sc(10), Sc(28), Sc(72), Sc(16), '', 7, C_UI_MUTED);
  R.LabelSub.OnClick := RowClick;
  R.LabelFile := AddLabel(R, Sc(84), Sc(3), Sc(300), Sc(16), '', 8, C_UI_TEXT2);
  R.LabelFile.OnClick := RowClick;
  R.Wave := TZsWave.Create(Self);
  R.Wave.Parent := R;
  R.Wave.Editable := False;
  R.Wave.Cursor := crHandPoint;
  R.Wave.SetBounds(Sc(84), Sc(20), Sc(300), Sc(34));
  R.Wave.EmptyText := Tr('Datei hierher ziehen', 'Drop a file here');
  R.Wave.OnClick := RowClick;
  AddLabel(R, Sc(392), Sc(3), Sc(70), Sc(16), 'BPM', 7, C_MX_SCALE);
  R.ReadBpm := AddReadout(R, Sc(392), Sc(20), Sc(70), Sc(26), 11);
  AddLabel(R, Sc(468), Sc(3), Sc(70), Sc(16), Tr('FAKTOR', 'FACTOR'), 7, C_MX_SCALE);
  R.ReadFactor := AddReadout(R, Sc(468), Sc(20), Sc(70), Sc(26), 11);
  AddLabel(R, Sc(544), Sc(3), Sc(96), Sc(16), Tr('TONART', 'KEY'), 7, C_MX_SCALE);
  R.ReadKey := AddReadout(R, Sc(544), Sc(20), Sc(96), Sc(26), 11);
  R.ReadKey.Mono := False;
  R.KnobPitch := AddKnob(R, Sc(649), Sc(3), Sc(38), -12, 12, 0, 1, RowPitchChange);
  AddLabel(R, Sc(640), Sc(42), Sc(56), Sc(14), 'PITCH', 7, C_MX_SCALE, taCenter);
  R.KnobGain := AddKnob(R, Sc(699), Sc(3), Sc(38), -60, 6, 0, 1, RowGainChange);
  R.KnobGain.Bipolar := False;
  AddLabel(R, Sc(690), Sc(42), Sc(56), Sc(14), Tr('PEGEL', 'LEVEL'), 7, C_MX_SCALE, taCenter);
  R.KeyMute := AddKey(R, Sc(744), Sc(17), Sc(26), Sc(24), 'M', True, RowMixClick);
  R.KeyMute.Hint := Tr('Stumm (l'#$00E4'uft synchron weiter)', 'Mute (keeps running in sync)');
  R.KeyMute.ShowHint := True;
  R.KeySolo := AddKey(R, Sc(772), Sc(17), Sc(26), Sc(24), 'S', True, RowMixClick);
  R.KeySolo.Hint := Tr('Solo: nur diese Spur(en) h'#$00F6'ren', 'Solo: hear only this track (these tracks)');
  R.KeySolo.ShowHint := True;
  R.KeyRemove := AddKey(R, Sc(800), Sc(17), Sc(20), Sc(24), #$00D7, False, RowRemoveClick);
  R.KeyRemove.Hint := Tr('Spur entfernen', 'Remove track');
  R.KeyRemove.ShowHint := True;
  Result := R;
end;

function TZsForm.AddTrack(const AFileName: string): TZsRow;
begin
  Result := nil;
  if FRows.Count >= C_MAX_TRACKS then
  begin
    ShowStatus(Format(Tr('H'#$00F6'chstens %d Spuren', 'At most %d tracks'), [C_MAX_TRACKS]), False);
    Exit;
  end;
  Result := NewRow;
  Result.Index := FRows.Count;
  FRows.Add(Result);
  LayoutRows;
  if AFileName <> '' then
    LoadInto(Result, AFileName);
  SelectRow(Result);
  RowsBox.ScrollInView(Result);
  ApplyMix;
  UpdateDisplay;
end;

function TZsForm.LoadInto(ARow: TZsRow; const AFileName: string): Boolean;
var
  A: TS2400Audio;
  Err: string;
  Info: TS2400NameInfo;
  Pc: Integer;
  Minor: Boolean;
  R: TZsRow;
begin
  Result := False;
  Screen.Cursor := crHourGlass;
  try
    if not S2400LoadAudio(AFileName, A, Err) then
    begin
      FStatusOk := False;
      FStatusMsg := ExtractFileName(AFileName) + ': ' + Err;
      FStatusUntil := GetTickCount64 + 6000;
      UpdateDisplay;
      Exit;
    end;
    ARow.Audio := A;
    ARow.FileName := AFileName;
    ARow.Slices := nil;
    ARow.SliceSel := nil;
    ARow.SliceManual := False;
    ARow.SlicesValid := False;
    ARow.Env := S2400Envelope(A, C_ENV_COLUMNS);
    ARow.MarkS := 0;
    ARow.MarkE := 1;
    Info := S2400ParseSampleName(AFileName);
    if Info.Bpm > 0 then
    begin
      ARow.Bpm := Info.Bpm;
      ARow.BpmSource := zbName;
    end
    else
    begin
      ARow.Bpm := S2400BpmFromLength(A.Frames, A.Rate);
      if ARow.Bpm > 0 then
        ARow.BpmSource := zbLength
      else
        ARow.BpmSource := zbNone;
    end;
    if Info.KeyPc >= 0 then
    begin
      ARow.KeyPc := Info.KeyPc;
      ARow.KeyMinor := Info.Minor;
      ARow.KeySource := zkName;
    end
    else if S2400DetectKey(A, Pc, Minor) then
    begin
      ARow.KeyPc := Pc;
      ARow.KeyMinor := Minor;
      ARow.KeySource := zkMeasured;
    end
    else
    begin
      ARow.KeyPc := -1;
      ARow.KeySource := zkNone;
    end;
    ARow.Wave.SetEnvelope(ARow.Env);
    ARow.Wave.SetMarks(0, 1);
    RenderRow(ARow);
    // Spur 1 bestimmt das Tempo der anderen
    if ARow.Index = 0 then
      for R in FRows do
        if R <> ARow then
          RenderRow(R);
    Result := True;
  finally
    Screen.Cursor := crDefault;
  end;
  if ARow = FSel then
    UpdateEditor(True);
  UpdateDisplay;
end;

procedure TZsForm.RemoveRow(ARow: TZsRow);
var
  Idx, I: Integer;
begin
  Idx := FRows.IndexOf(ARow);
  if Idx < 0 then
    Exit;
  if FEngine <> nil then
    FEngine.RemoveVoice(Idx);
  FRows.Delete(Idx);
  if FSel = ARow then
    FSel := nil;
  ARow.Free;
  for I := 0 to FRows.Count - 1 do
    FRows[I].Index := I;
  LayoutRows;
  if FSel = nil then
  begin
    if FRows.Count > 0 then
      SelectRow(FRows[Min(Idx, FRows.Count - 1)])
    else
      SelectRow(nil);
  end;
  // neue Spur 1 -> anderes Leittempo
  if Idx = 0 then
    MarkAllDirty;
  ApplyMix;
  UpdateDisplay;
end;

procedure TZsForm.LayoutRows;
var
  Y, I, W: Integer;
begin
  W := RowsBox.Width - Sc(18);
  Y := -RowsBox.VertScrollBar.Position;
  for I := 0 to FRows.Count - 1 do
  begin
    FRows[I].SetBounds(0, Y, W, Sc(C_ROW_H));
    Inc(Y, Sc(C_ROW_H + C_ROW_GAP));
  end;
  AddRow.Visible := FRows.Count < C_MAX_TRACKS;
  AddRow.SetBounds(0, Y, W, Sc(40));
end;

procedure TZsForm.SelectRow(ARow: TZsRow);
var
  R: TZsRow;
begin
  FSel := ARow;
  for R in FRows do
    R.Selected := R = FSel;
  UpdateEditor(True);
  UpdateDisplay;
end;

function TZsForm.RowSpeed(ARow: TZsRow): Double;
var
  R0: TZsRow;
begin
  Result := FSpeed;
  if (ARow = nil) or (ARow.Index = 0) or (FRows.Count = 0) then
    Exit;
  R0 := FRows[0];
  // folgt dem neuen Tempo von Spur 1 (wie von Platte)
  if R0.HasAudio and (R0.Bpm > 0) and (ARow.Bpm > 0) then
    Result := R0.Bpm * FSpeed / ARow.Bpm;
  if Result < 0.25 then Result := 0.25;
  if Result > 4 then Result := 4;
end;

procedure TZsForm.MarkDirty(ARow: TZsRow);
begin
  if (ARow = nil) or not ARow.HasAudio then
    Exit;
  ARow.Dirty := True;
  FRenderTimer.Enabled := False;
  FRenderTimer.Enabled := True;
end;

procedure TZsForm.MarkAllDirty;
var
  R: TZsRow;
begin
  for R in FRows do
    MarkDirty(R);
end;

procedure TZsForm.RenderTimerTick(Sender: TObject);
var
  R: TZsRow;
begin
  FRenderTimer.Enabled := False;
  for R in FRows do
    if R.Dirty then
      RenderRow(R);
end;

procedure TZsForm.RenderRow(ARow: TZsRow);
var
  Buf: TArray<Single>;
begin
  if FBulk then
  begin
    // Stack wird geladen: erst rechnen, wenn alle Werte gesetzt sind
    ARow.Dirty := True;
    Exit;
  end;
  ARow.Dirty := False;
  if not ARow.HasAudio or (FDevRate <= 0) then
  begin
    ARow.RenderedLen := 0;
    if FEngine <> nil then
      FEngine.SetVoice(ARow.Index, nil, False);
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  try
    Buf := S2400RenderTrack(ARow.Audio, ARow.MarkS, ARow.MarkE, ARow.KnobPitch.Value + ARow.Cents / 100 + PitchComp,
      RowSpeed(ARow), FDevRate);
  finally
    Screen.Cursor := crDefault;
  end;
  ARow.RenderedLen := Length(Buf) div 2;
  if FEngine <> nil then
    FEngine.SetVoice(ARow.Index, Buf, True);
  UpdateDisplay;
end;

procedure TZsForm.ApplyMix;
var
  R: TZsRow;
begin
  if FEngine = nil then
    Exit;
  for R in FRows do
    FEngine.SetMix(R.Index, DbToLin(R.KnobGain.Value), R.KeyMute.Checked, R.KeySolo.Checked);
end;

function BeatsText(ABeats: Double): string;
begin
  if Abs(ABeats - Round(ABeats)) < 0.05 then
    Result := IntToStr(Round(ABeats))
  else
    Result := FmtNum(ABeats, 1);
end;

procedure TZsForm.UpdateDisplay;
var
  R, R0: TZsRow;
  Sp, Total, L0, L1: Double;
  N, C, Pc: Integer;
  S: string;
begin
  if FLoading then
    Exit;

  // Plattenspieler
  R0 := nil;
  if FRows.Count > 0 then
    R0 := FRows[0];
  // gross: das eingestellte Stack-Tempo; klein: Original bzw. mit
  // Plattenspieler das, was wirklich in die Isla geht
  if StackBpm > 0 then
  begin
    if Abs(FTempo - 1) < 1E-6 then
      ReadTempo.SetText(FmtNum(StackBpm, 1) + ' BPM', C_UI_TEXT)
    else
      ReadTempo.SetText(FmtNum(StackBpm, 1) + ' BPM', C_UI_ACCENT);
    if FRpm > 0 then
      S := Tr('PLATTE ', 'RECORD ') + #$00D7 + FmtNum(C_RPM_FACTOR[FRpm], 3) + ' '#$2192' ' + FmtNum(PlayBpm, 1) + ' BPM'
    else
      S := Tr('ORIGINAL ', 'ORIGINAL ') + FmtNum(R0.Bpm, 1);
  end
  else
  begin
    ReadTempo.SetText(#$00D7 + FmtNum(FTempo, 3), C_UI_TEXT);
    if FRpm > 0 then
      S := Tr('PLATTE ', 'RECORD ') + #$00D7 + FmtNum(C_RPM_FACTOR[FRpm], 3)
    else
      S := Tr('SPUR 1 OHNE TEMPO', 'TRACK 1 WITHOUT TEMPO');
  end;
  // gesamte Tonhoehenverschiebung (Tempo, falls nicht gehalten, + Platte)
  S := S + ' '#$00B7' ' + FmtSigned(12 * Log2(FSpeed) + PitchComp, 2) + Tr(' HT', ' ST');
  LabelTempoInfo.Caption := S;

  // Spurzeilen
  for R in FRows do
  begin
    R.LabelName.Caption := Tr('SPUR ', 'TRACK ') + IntToStr(R.Index + 1);
    if R.Index = 0 then
    begin
      R.LabelName.Font.Color := C_UI_ACCENT;
      R.LabelSub.Caption := Tr('f'#$00FC'hrt', 'leads');
    end
    else
    begin
      R.LabelName.Font.Color := C_UI_LEVEL;
      if (R0 <> nil) and R0.HasAudio and (R0.Bpm > 0) and (R.Bpm > 0) then
        R.LabelSub.Caption := Tr('folgt Spur 1', 'follows track 1')
      else
        R.LabelSub.Caption := Tr('Plattenspieler', 'turntable');
    end;
    if R.HasAudio then
    begin
      Sp := RowSpeed(R);
      R.LabelFile.Caption := ExtractFileName(R.FileName);
      R.LabelFile.Font.Color := C_UI_TEXT2;
      if R.Bpm > 0 then
        R.ReadBpm.SetText(FmtNum(R.Bpm, 1), C_UI_TEXT)
      else
        R.ReadBpm.SetText(#$2014, C_UI_MUTED);
      R.ReadFactor.SetText(FmtNum(Sp, 3) + #$00D7, C_UI_TEXT);
      Total := 12 * Log2(Sp) + PitchComp + R.KnobPitch.Value + R.Cents / 100;
      if R.KeyPc >= 0 then
      begin
        N := Round(Total);
        Pc := ((R.KeyPc + N) mod 12 + 12) mod 12;
        S := S2400KeyName(R.KeyPc, R.KeyMinor) + ' '#$2192' ' + S2400KeyName(Pc, R.KeyMinor);
        if Abs(Total) < 0.005 then
          R.ReadKey.SetText(S, C_UI_TEXT)
        else
          R.ReadKey.SetText(S, C_UI_ACCENT);
      end
      else if Abs(Total) < 0.005 then
        R.ReadKey.SetText(#$2014, C_UI_MUTED)
      else
        R.ReadKey.SetText(FmtSigned(Total, 1) + Tr(' HT', ' st'), C_UI_ACCENT);
    end
    else
    begin
      // aus einem Stack geladen, Datei aber nicht gefunden
      if R.FileName <> '' then
      begin
        R.LabelFile.Caption := Tr('FEHLT: ', 'MISSING: ') + ExtractFileName(R.FileName);
        R.LabelFile.Font.Color := C_UI_ERR;
      end
      else
        R.LabelFile.Caption := '';
      R.ReadBpm.SetText(#$2014, C_UI_MUTED);
      R.ReadFactor.SetText(#$2014, C_UI_MUTED);
      R.ReadKey.SetText(#$2014, C_UI_MUTED);
    end;
  end;

  // Editor
  if (FSel <> nil) and FSel.HasAudio then
  begin
    LabelEdit.Caption := Tr('EDITOR '#$00B7' SPUR ', 'EDITOR '#$00B7' TRACK ') + IntToStr(FSel.Index + 1) + ' '#$00B7' ' +
      ExtractFileName(FSel.FileName);
    ReadStart.SetText(FmtNum(FSel.MarkS * FSel.Audio.Frames / FSel.Audio.Rate, 3) + ' s', C_UI_TEXT);
    ReadEnd.SetText(FmtNum(FSel.MarkE * FSel.Audio.Frames / FSel.Audio.Rate, 3) + ' s', C_UI_TEXT);
    L0 := (FSel.MarkE - FSel.MarkS) * FSel.Audio.Frames / FSel.Audio.Rate;
    S := FmtNum(L0, 2) + ' s';
    if (FSel.RenderedLen > 0) and (FDevRate > 0) then
    begin
      L1 := FSel.RenderedLen / FDevRate;
      S := S + ' '#$2192' ' + FmtNum(L1, 2) + ' s';
    end;
    if FSel.Bpm > 0 then
      S := S + '  '#$00B7'  ' + BeatsText(L0 * FSel.Bpm / 60) + Tr(' Schl'#$00E4'ge', ' beats');
    ReadLen.SetText(S, C_UI_TEXT);
    if FSel.Bpm > 0 then
      ReadBpm.SetText(FmtNum(FSel.Bpm, 1) + ' BPM', C_UI_TEXT)
    else
      ReadBpm.SetText(#$2014, C_UI_MUTED);
    case FSel.BpmSource of
      zbName: LabelBpmSrc.Caption := Tr('Tempo aus dem Dateinamen', 'tempo from the file name');
      zbLength: LabelBpmSrc.Caption := Tr('Tempo aus der L'#$00E4'nge gesch'#$00E4'tzt', 'tempo estimated from the length');
      zbManual: LabelBpmSrc.Caption := Tr('Tempo von Hand', 'tempo set by hand');
    else
      LabelBpmSrc.Caption := Tr('Tempo unbekannt (One-Shot?)', 'tempo unknown (one-shot?)');
    end;
    C := FSel.Cents;
    if C <> 0 then
      ReadCent.SetText(FmtSigned(C, 0) + ' ct', C_UI_LEVEL)
    else
      ReadCent.SetText(FmtSigned(C, 0) + ' ct', C_UI_TEXT);
  end
  else
  begin
    if FSel <> nil then
      LabelEdit.Caption := Tr('EDITOR '#$00B7' SPUR ', 'EDITOR '#$00B7' TRACK ') + IntToStr(FSel.Index + 1) + Tr(' (leer)', ' (empty)')
    else
      LabelEdit.Caption := 'EDITOR';
    ReadStart.SetText(#$2014, C_UI_MUTED);
    ReadEnd.SetText(#$2014, C_UI_MUTED);
    ReadLen.SetText(#$2014, C_UI_MUTED);
    ReadBpm.SetText(#$2014, C_UI_MUTED);
    ReadCent.SetText(#$2014, C_UI_MUTED);
    LabelBpmSrc.Caption := '';
  end;

  // Browser-Knopf
  if FSel <> nil then
    ButtonReplace.Caption := Tr('In Spur ', 'To track ') + IntToStr(FSel.Index + 1)
  else
    ButtonReplace.Caption := Tr('In Spur', 'To track');
  ButtonReplace.Invalidate;

  // Geraet
  if FDevName <> '' then
    LabelDevice.Caption := FDevName
  else
    LabelDevice.Caption := Tr('Kein Ausgabeger'#$00E4't', 'No output device');
  if FDevError <> '' then
  begin
    LabelStatus.Caption := FDevError;
    LabelStatus.Font.Color := C_UI_ERR;
  end
  else if (FStatusMsg <> '') and (GetTickCount64 < FStatusUntil) then
  begin
    LabelStatus.Caption := FStatusMsg;
    if FStatusOk then
      LabelStatus.Font.Color := C_UI_LEVEL
    else
      LabelStatus.Font.Color := C_UI_ERR;
  end
  else if FOut <> nil then
  begin
    LabelStatus.Caption := FOut.FormatText + Tr('  '#$00B7'  Isla: Line 1&2', '  '#$00B7'  Isla: line 1&2');
    LabelStatus.Font.Color := C_UI_TEXT2;
  end;
end;

// Editor auf die ausgewaehlte Spur stellen
procedure TZsForm.UpdateEditor(AResetView: Boolean);
var
  Old: Boolean;
begin
  Old := FLoading;
  FLoading := True;   // Knopf setzen ohne Rueckmeldung
  try
    if (FSel <> nil) and FSel.HasAudio then
    begin
      if AResetView then
        EditWave.SetSource(FSel.Audio.Data, FSel.Audio.Frames, FSel.Audio.Rate);
      EditWave.SetMarks(FSel.MarkS, FSel.MarkE);
      KnobCent.Value := FSel.Cents;
    end
    else
    begin
      EditWave.SetSource(nil, 0, 0);
      KnobCent.Value := 0;
    end;
  finally
    FLoading := Old;
  end;
  // Einzelsound-Modus: Marken der ausgewaehlten Spur
  if KeySliceMode <> nil then
  begin
    if AResetView then
    begin
      FSliceActive := -1;
      FSliceLast := -1;
    end;
    if KeySliceMode.Checked and (FSel <> nil) and FSel.HasAudio and not FSel.SlicesValid then
      DetectSlices(FSel);
    UpdateSliceUi;
  end;
end;

procedure TZsForm.ApplyEditMarks(AFinal: Boolean);
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  FSel.MarkS := EditWave.MarkStart;
  FSel.MarkE := EditWave.MarkEnd;
  FSel.Wave.SetMarks(FSel.MarkS, FSel.MarkE);
  if AFinal then
  begin
    FSel.SlicesValid := False;   // Einzelsounds im neuen Bereich neu suchen
    // geschaetztes Tempo passt sich dem neuen Ausschnitt an
    if FSel.BpmSource = zbLength then
    begin
      FSel.Bpm := S2400BpmFromLength(Round((FSel.MarkE - FSel.MarkS) * FSel.Audio.Frames), FSel.Audio.Rate);
      if FSel.Bpm <= 0 then
        FSel.BpmSource := zbNone;
      if FSel.Index = 0 then
        MarkAllDirty;
    end;
    MarkDirty(FSel);
  end;
  UpdateDisplay;
end;

// ---------------------------------------------------------------------------
// Ereignisse
// ---------------------------------------------------------------------------

procedure TZsForm.RpmClick(Sender: TObject);
var
  I, Idx: Integer;
begin
  // Plattenspieler-Trick oben drauf: das eingestellte Stack-Tempo bleibt
  Idx := TZsKey(Sender).Tag;
  FRpm := Idx;
  for I := 0 to C_RPM_COUNT - 1 do
    KeyRpm[I].Checked := I = Idx;
  ApplySpeed;
end;

// Stack-Tempo (eingestellt, vor dem Plattenspieler); 0 = Spur 1 ohne Tempo
function TZsForm.StackBpm: Double;
begin
  Result := 0;
  if (FRows.Count > 0) and FRows[0].HasAudio and (FRows[0].Bpm > 0) then
    Result := FRows[0].Bpm * FTempo;
end;

// tatsaechlich gespieltes Tempo (mit Plattenspieler)
function TZsForm.PlayBpm: Double;
begin
  Result := 0;
  if (FRows.Count > 0) and FRows[0].HasAudio and (FRows[0].Bpm > 0) then
    Result := FRows[0].Bpm * FSpeed;
end;

// TONHOEHE HALTEN: nur die Tonhoehenaenderung durch das Stack-Tempo wieder
// abziehen - der Plattenspieler-Trick veraendert die Tonhoehe gewollt
function TZsForm.PitchComp: Double;
begin
  if FKeepPitch and (FTempo > 0) and (Abs(FTempo - 1) > 1E-6) then
    Result := -12 * Log2(FTempo)
  else
    Result := 0;
end;

procedure TZsForm.ApplySpeed;
begin
  if (FRpm < 0) or (FRpm >= C_RPM_COUNT) then
    FRpm := 0;
  FSpeed := FTempo * C_RPM_FACTOR[FRpm];
  MarkAllDirty;
  UpdateDisplay;
end;

procedure TZsForm.SetTempo(ATempo: Double);
begin
  if ATempo < 0.25 then ATempo := 0.25;
  if ATempo > 4 then ATempo := 4;
  FTempo := ATempo;
  ApplySpeed;
end;

procedure TZsForm.TempoKeyClick(Sender: TObject);
var
  B, Step: Double;
begin
  if ShiftDown then Step := 1 else Step := 0.1;
  B := StackBpm;
  if B > 0 then
  begin
    B := Round((B + TZsKey(Sender).Tag * Step) * 10) / 10;
    SetTempo(B / FRows[0].Bpm);
  end
  else
    // Spur 1 ohne Tempo: in Schritten von 0,1 % bzw. 1 %
    SetTempo(FTempo * (1 + TZsKey(Sender).Tag * Step / 100));
end;

procedure TZsForm.TempoReadClick(Sender: TObject);
begin
  if StackBpm <= 0 then
  begin
    ShowStatus(Tr('Spur 1 hat kein Tempo (BPM im Editor setzen)', 'Track 1 has no tempo (set BPM in the editor)'), False);
    Exit;
  end;
  EditTempo.Text := FmtNum(StackBpm, 1);
  EditTempo.Visible := True;
  EditTempo.BringToFront;
  EditTempo.SetFocus;
  EditTempo.SelectAll;
end;

procedure TZsForm.TempoEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  S: string;
  B: Double;
begin
  if Key = VK_RETURN then
  begin
    S := StringReplace(Trim(EditTempo.Text), ',', '.', [rfReplaceAll]);
    B := StrToFloatDef(S, 0, TFormatSettings.Invariant);
    Key := 0;
    EditTempo.Visible := False;
    if (B >= 20) and (B <= 400) and (StackBpm > 0) then
      SetTempo(B / FRows[0].Bpm)
    else
      ShowStatus(Tr('Tempo zwischen 20 und 400 BPM eingeben', 'Enter a tempo between 20 and 400 BPM'), False);
    if ListFiles.CanFocus then
      ListFiles.SetFocus;
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    EditTempo.Visible := False;
    if ListFiles.CanFocus then
      ListFiles.SetFocus;
  end;
end;

// kein Signalton bei Enter/Esc im Eingabefeld
procedure TZsForm.TempoEditKeyPress(Sender: TObject; var Key: Char);
begin
  if (Key = #13) or (Key = #27) then
    Key := #0;
end;

procedure TZsForm.TempoEditExit(Sender: TObject);
begin
  EditTempo.Visible := False;
end;

procedure TZsForm.KeepPitchClick(Sender: TObject);
begin
  FKeepPitch := KeyKeepPitch.Checked;
  MarkAllDirty;
  UpdateDisplay;
end;

procedure TZsForm.RowClick(Sender: TObject);
var
  R: TZsRow;
begin
  R := RowOf(Sender);
  if (R <> nil) and (R <> FSel) then
    SelectRow(R);
end;

procedure TZsForm.RowPitchChange(Sender: TObject);
var
  R: TZsRow;
begin
  R := RowOf(Sender);
  if R = nil then
    Exit;
  if R <> FSel then
    SelectRow(R);
  MarkDirty(R);
  UpdateDisplay;
end;

procedure TZsForm.RowGainChange(Sender: TObject);
begin
  ApplyMix;
  // klingt gerade ein Einzelsound dieser Spur: Pegel sofort mitnehmen
  if (FEngine <> nil) and (FSliceActive >= 0) and (FSel <> nil) and (RowOf(Sender) = FSel) then
    FEngine.SetOnceGain(DbToLin(FSel.KnobGain.Value));
end;

procedure TZsForm.RowMixClick(Sender: TObject);
begin
  ApplyMix;
end;

procedure TZsForm.RowRemoveClick(Sender: TObject);
var
  R: TZsRow;
begin
  R := RowOf(Sender);
  if R = nil then
    Exit;
  // erst nach dem Klick entfernen (die Taste gehoert zur Zeile)
  TThread.ForceQueue(nil,
    procedure
    begin
      RemoveRow(R);
    end);
end;

procedure TZsForm.AddRowClick(Sender: TObject);
begin
  AddTrack(SelectedFile);
end;

procedure TZsForm.EditMarksMoving(Sender: TObject);
begin
  ApplyEditMarks(False);
end;

procedure TZsForm.EditMarks(Sender: TObject);
begin
  ApplyEditMarks(True);
end;

procedure TZsForm.NudgeClick(Sender: TObject);
const
  C_MS: array[0..3] of Integer = (-10, -1, 1, 10);
var
  Code: Integer;
  S, E, D, MinGap: Double;
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  Code := TZsKey(Sender).Tag;
  D := C_MS[Code mod 4] / 1000 * FSel.Audio.Rate / FSel.Audio.Frames;
  MinGap := 32 / FSel.Audio.Frames;
  S := EditWave.MarkStart;
  E := EditWave.MarkEnd;
  if Code < 4 then
  begin
    S := S + D;
    if KeySnap.Checked then
      S := EditWave.SnapFrac(S, Sign(D));
    if S < 0 then S := 0;
    if S > E - MinGap then S := E - MinGap;
  end
  else
  begin
    E := E + D;
    if KeySnap.Checked then
      E := EditWave.SnapFrac(E, Sign(D));
    if E > 1 then E := 1;
    if E < S + MinGap then E := S + MinGap;
  end;
  EditWave.SetMarks(S, E);
  ApplyEditMarks(True);
end;

procedure TZsForm.SnapClick(Sender: TObject);
begin
  EditWave.Snap := KeySnap.Checked;
end;

procedure TZsForm.AuditionClick(Sender: TObject);
begin
  if FEngine = nil then
  begin
    KeyAudition.Checked := False;
    Exit;
  end;
  if KeyAudition.Checked and (FSel <> nil) and FSel.HasAudio then
  begin
    RenderTimerTick(nil);
    FEngine.Play(0, FSel.Index);
  end
  else
  begin
    KeyAudition.Checked := False;
    FEngine.StopPlay;
  end;
  TimerTick(nil);
end;

procedure TZsForm.ResetClick(Sender: TObject);
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  EditWave.SetMarks(0, 1);
  EditWave.ResetView;
  ApplyEditMarks(True);
end;

procedure TZsForm.BpmKeyClick(Sender: TObject);
var
  B, Step: Double;
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  B := FSel.Bpm;
  if B <= 0 then
    B := 90;
  if ShiftDown then Step := 1 else Step := 0.1;
  case TZsKey(Sender).Tag of
    0: B := B - Step;
    1: B := B + Step;
    2: B := B / 2;
    3: B := B * 2;
  end;
  if B < 20 then B := 20;
  if B > 400 then B := 400;
  FSel.Bpm := Round(B * 10) / 10;
  FSel.BpmSource := zbManual;
  // Spur 1 bestimmt das Tempo der anderen, die anderen nur sich selbst
  if FSel.Index = 0 then
    MarkAllDirty
  else
    MarkDirty(FSel);
  UpdateDisplay;
end;

procedure TZsForm.CentChange(Sender: TObject);
begin
  if FLoading or (FSel = nil) or not FSel.HasAudio then
    Exit;
  FSel.Cents := KnobCent.Value;
  MarkDirty(FSel);
  UpdateDisplay;
end;

procedure TZsForm.PlayClick(Sender: TObject);
begin
  if FEngine = nil then
  begin
    OpenDevice; // z.B. Geraet war belegt
    if FEngine = nil then
      Exit;
  end;
  if FEngine.IsPlaying then
    FEngine.StopPlay
  else
  begin
    // ausstehende Neuberechnung zuerst, damit genau das Eingestellte laeuft
    RenderTimerTick(nil);
    if KeyPreroll.Checked then
      FEngine.Play(FDevRate, -1)
    else
      FEngine.Play(0, -1);
  end;
  KeyAudition.Checked := False;
  TimerTick(nil);
end;

procedure TZsForm.LoopClick(Sender: TObject);
begin
  if FEngine <> nil then
    FEngine.SetLoop(KeyLoop.Checked);
end;

procedure TZsForm.TimerTick(Sender: TObject);
var
  PL, PR, Db: Single;
  Pk: array[0..1] of Single;
  I: Integer;
  NowTick: UInt64;
  R: TZsRow;
  PrevNow: Boolean;
  Fr: Integer;
begin
  if (FStatusMsg <> '') and (GetTickCount64 >= FStatusUntil) then
  begin
    FStatusMsg := '';
    UpdateDisplay;
  end;
  if FEngine = nil then
  begin
    Meter.SetLevels(-120, -120, -120, -120);
    for R in FRows do
      R.Wave.SetPlay(-1);
    EditWave.SetPlay(-1);
    Exit;
  end;
  FEngine.TakePeaks(PL, PR);
  Pk[0] := PL;
  Pk[1] := PR;
  NowTick := GetTickCount64;
  for I := 0 to 1 do
  begin
    Db := LinToDb(Pk[I]);
    if Db > FMeterDisp[I] then
      FMeterDisp[I] := Db
    else
    begin
      FMeterDisp[I] := FMeterDisp[I] - C_METER_FALL_DB;
      if FMeterDisp[I] < Db then
        FMeterDisp[I] := Db;
    end;
    if (Db >= FMeterHold[I]) or (NowTick >= FMeterHoldUntil[I]) then
    begin
      FMeterHold[I] := Db;
      FMeterHoldUntil[I] := NowTick + C_METER_HOLD_MS;
    end;
  end;
  Meter.SetLevels(FMeterDisp[0], FMeterHold[0], FMeterDisp[1], FMeterHold[1]);
  // Schlag-LEDs: Position seit Beginn von Spur 1 / Stack in Schlaegen
  Fr := FEngine.PlayFrames;
  if (Fr >= 0) and (PlayBpm > 0) and (FDevRate > 0) then
    BeatLeds.SetBeat(Trunc(Fr / (FDevRate * 60 / PlayBpm)) mod 4)
  else
    BeatLeds.SetBeat(-1);
  for R in FRows do
    R.Wave.SetPlay(FEngine.VoiceFrac(R.Index));
  if FSel <> nil then
    EditWave.SetPlay(FEngine.VoiceFrac(FSel.Index))
  else
    EditWave.SetPlay(-1);

  if FEngine.IsPlaying then
  begin
    if FEngine.InPreroll then
      ButtonPlay.Caption := Tr('Vorlauf '#$2026, 'Pre-roll '#$2026)
    else
      ButtonPlay.Caption := Tr('Stopp', 'Stop');
    ButtonPlay.Glyph := #$E71A;
  end
  else
  begin
    ButtonPlay.Caption := Tr('Abspielen', 'Play');
    ButtonPlay.Glyph := #$E768;
  end;
  ButtonPlay.Invalidate;
  if KeyAudition.Checked and (FEngine.OnlyTrack < 0) then
    KeyAudition.Checked := False;

  // Markierung des vorgehoerten Samples in der Liste
  PrevNow := FEngine.PreviewActive;
  if PrevNow <> FPrevWasActive then
  begin
    FPrevWasActive := PrevNow;
    ListFiles.Invalidate;
  end;
  // Einzelsound ausgeklungen: Pad nicht mehr hervorheben
  if (FSliceActive >= 0) and not PrevNow then
  begin
    FSliceActive := -1;
    UpdateSliceUi;
  end;
end;

// ---------------------------------------------------------------------------
// Browser und Vorhoeren
// ---------------------------------------------------------------------------

function DefaultSpliceFolder: string;
var
  Buf: array[0..MAX_PATH] of Char;
  Docs: string;
begin
  Docs := '';
  if SHGetFolderPath(0, CSIDL_PERSONAL, 0, 0, Buf) = S_OK then
    Docs := Buf;
  Result := IncludeTrailingPathDelimiter(Docs) + 'Splice\Samples';
  if DirectoryExists(Result) then
    Exit;
  Result := IncludeTrailingPathDelimiter(Docs) + 'Splice';
  if DirectoryExists(Result) then
    Exit;
  Result := Docs;
end;

procedure TZsForm.FolderClick(Sender: TObject);
var
  Dlg: TFileOpenDialog;
begin
  Dlg := TFileOpenDialog.Create(Self);
  try
    Dlg.Options := [fdoPickFolders, fdoPathMustExist, fdoForceFileSystem];
    Dlg.Title := Tr('Sample-Ordner w'#$00E4'hlen', 'Choose sample folder');
    if DirectoryExists(FFolder) then
      Dlg.DefaultFolder := FFolder;
    if Dlg.Execute then
    begin
      FFolder := Dlg.FileName;
      SaveSettings;
      ScanFolder;
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TZsForm.ScanFolder;
const
  C_MAX_FILES = 100000;
var
  Root: string;

  procedure Walk(const ADir: string; ADepth: Integer);
  var
    SR: TSearchRec;
    E: TZsFileEntry;
  begin
    if (ADepth > 12) or (FFiles.Count >= C_MAX_FILES) then
      Exit;
    if FindFirst(ADir + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;
        if (SR.Attr and faDirectory) <> 0 then
          Walk(ADir + SR.Name + '\', ADepth + 1)
        else if S2400IsAudioFile(SR.Name) then
        begin
          E.Path := ADir + SR.Name;
          E.Time := SR.TimeStamp;
          E.Search := LowerCase(Copy(E.Path, Length(Root) + 1, MaxInt));
          FFiles.Add(E);
          if FFiles.Count >= C_MAX_FILES then
            Exit;
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  FFiles.Clear;
  FPrevIdx := -1;
  LabelFolder.Caption := FFolder;
  if DirectoryExists(FFolder) then
  begin
    Screen.Cursor := crHourGlass;
    try
      Root := IncludeTrailingPathDelimiter(FFolder);
      Walk(Root, 0);
      // neueste zuerst (frisch geladene Splice-Samples oben)
      FFiles.Sort(TComparer<TZsFileEntry>.Construct(
        function(const A, B: TZsFileEntry): Integer
        begin
          Result := CompareValue(B.Time, A.Time);
        end));
    finally
      Screen.Cursor := crDefault;
    end;
  end
  else
    LabelFolder.Caption := Tr('Ordner nicht gefunden: ', 'Folder not found: ') + FFolder;
  ApplyFilter;
end;

procedure TZsForm.ApplyFilter;
var
  Words: TArray<string>;
  I, J, N: Integer;
  Ok: Boolean;
  Q: string;
begin
  Q := LowerCase(Trim(EditSearch.Text));
  Words := Q.Split([' '], TStringSplitOptions.ExcludeEmpty);
  SetLength(FShown, FFiles.Count);
  N := 0;
  for I := 0 to FFiles.Count - 1 do
  begin
    Ok := True;
    for J := 0 to High(Words) do
      if Pos(Words[J], FFiles[I].Search) = 0 then
      begin
        Ok := False;
        Break;
      end;
    if Ok then
    begin
      FShown[N] := I;
      Inc(N);
    end;
  end;
  SetLength(FShown, N);
  ListFiles.Count := N;
  ListFiles.ItemIndex := -1; // nichts vorhoeren, bevor geklickt wird
  ListFiles.Invalidate;
end;

procedure TZsForm.SearchChange(Sender: TObject);
begin
  ApplyFilter;
end;

procedure TZsForm.ListData(Control: TWinControl; Index: Integer; var Data: string);
begin
  if (Index >= 0) and (Index < Length(FShown)) then
    Data := ExtractFileName(FFiles[FShown[Index]].Path)
  else
    Data := '';
end;

procedure TZsForm.ListDraw(Control: TWinControl; Index: Integer; Rect: TRect; State: TOwnerDrawState);
var
  C: TCanvas;
  E: TZsFileEntry;
  R: TRect;
  Sub, Title: string;
  Playing: Boolean;
begin
  C := ListFiles.Canvas;
  if odSelected in State then
    C.Brush.Color := C_UI_SEL_BG
  else
    C.Brush.Color := C_MX_WELL;
  C.FillRect(Rect);
  if (Index < 0) or (Index >= Length(FShown)) then
    Exit;
  E := FFiles[FShown[Index]];
  Playing := (FShown[Index] = FPrevIdx) and FPrevWasActive;
  if odSelected in State then
  begin
    C.Brush.Color := C_UI_ACCENT;
    C.FillRect(System.Types.Rect(Rect.Left, Rect.Top + Sc(4), Rect.Left + Sc(3), Rect.Bottom - Sc(4)));
  end;
  C.Brush.Style := bsClear;
  UiSetFont(C.Font, 9, C_UI_TEXT);
  if odSelected in State then
    C.Font.Color := C_UI_SEL_TEXT;
  Title := ExtractFileName(E.Path);
  if Playing then
  begin
    C.Font.Color := C_UI_ACCENT;
    Title := #$25B6' ' + Title;
  end;
  R := System.Types.Rect(Rect.Left + Sc(10), Rect.Top + Sc(2), Rect.Right - Sc(6), Rect.Top + Sc(19));
  DrawText(C.Handle, PChar(Title), -1, R, DT_LEFT or DT_SINGLELINE or DT_VCENTER or DT_END_ELLIPSIS or DT_NOPREFIX);
  UiSetFont(C.Font, 8, C_UI_MUTED);
  Sub := ExtractFileDir(Copy(E.Path, Length(IncludeTrailingPathDelimiter(FFolder)) + 1, MaxInt));
  R := System.Types.Rect(Rect.Left + Sc(10), Rect.Top + Sc(18), Rect.Right - Sc(6), Rect.Bottom - Sc(2));
  DrawText(C.Handle, PChar(Sub), -1, R, DT_LEFT or DT_SINGLELINE or DT_VCENTER or DT_PATH_ELLIPSIS or DT_NOPREFIX);
  C.Brush.Style := bsSolid;
end;

function TZsForm.SelectedFileIdx: Integer;
var
  I: Integer;
begin
  Result := -1;
  I := ListFiles.ItemIndex;
  if (I >= 0) and (I < Length(FShown)) then
    Result := FShown[I];
end;

function TZsForm.SelectedFile: string;
var
  I: Integer;
begin
  I := SelectedFileIdx;
  if I >= 0 then
    Result := FFiles[I].Path
  else
    Result := '';
end;

// Klick oder Pfeiltaste in der Liste: kurz warten, dann vorhoeren
procedure TZsForm.ListClick(Sender: TObject);
begin
  if not KeyPrevOn.Checked then
    Exit;
  FPrevTimer.Enabled := False;
  FPrevTimer.Enabled := True;
end;

// Pegel beim Vorhoeren (eigene Stimme im Wiedergabe-Thread)
procedure TZsForm.PrevGainChange(Sender: TObject);
begin
  if KnobPrev.Value <= -60 then
    ReadPrev.SetText(#$2212#$221E, C_UI_TEXT)
  else
    ReadPrev.SetText(FmtSigned(KnobPrev.Value, 0) + ' dB', C_UI_TEXT);
  if FEngine <> nil then
    FEngine.SetPreviewGain(DbToLin(KnobPrev.Value));
end;

procedure TZsForm.PrevTimerTick(Sender: TObject);
begin
  FPrevTimer.Enabled := False;
  if SelectedFile <> '' then
    StartPreviewFile(SelectedFile);
end;

procedure TZsForm.StartPreviewFile(const AFileName: string);
var
  Err: string;
  Info: TS2400NameInfo;
  Speed: Double;
  R0: TZsRow;
  Buf: TArray<Single>;
begin
  if FEngine = nil then
  begin
    OpenDevice;
    if FEngine = nil then
      Exit;
  end;
  if AFileName <> FPrevFile then
  begin
    if not S2400LoadAudio(AFileName, FPrevAudio, Err) then
    begin
      FPrevFile := '';
      FStatusOk := False;
      FStatusMsg := ExtractFileName(AFileName) + ': ' + Err;
      FStatusUntil := GetTickCount64 + 6000;
      UpdateDisplay;
      Exit;
    end;
    FPrevFile := AFileName;
    Info := S2400ParseSampleName(AFileName);
    if Info.Bpm > 0 then
      FPrevBpm := Info.Bpm
    else
      FPrevBpm := S2400BpmFromLength(FPrevAudio.Frames, FPrevAudio.Rate);
  end;
  // im Tempo: wie eine weitere Spur (folgt Spur 1), sonst Original
  Speed := 1;
  if KeyPrevTempo.Checked then
  begin
    Speed := FSpeed;
    if FRows.Count > 0 then
    begin
      R0 := FRows[0];
      if R0.HasAudio and (R0.Bpm > 0) and (FPrevBpm > 0) then
        Speed := R0.Bpm * FSpeed / FPrevBpm;
    end;
    if Speed < 0.25 then Speed := 0.25;
    if Speed > 4 then Speed := 4;
  end;
  if KeyPrevTempo.Checked then
    Buf := S2400RenderTrack(FPrevAudio, 0, 1, PitchComp, Speed, FDevRate)
  else
    Buf := S2400RenderTrack(FPrevAudio, 0, 1, 0, Speed, FDevRate);
  FEngine.StartPreview(Buf);
  FPrevIdx := SelectedFileIdx;
  FPrevWasActive := True;
  ListFiles.Invalidate;
end;

procedure TZsForm.ListDblClick(Sender: TObject);
begin
  FPrevTimer.Enabled := False;
  if SelectedFile <> '' then
  begin
    if FEngine <> nil then
      FEngine.StopPreview;
    // leere letzte Spur zuerst fuellen, sonst neue Spur
    if (FRows.Count > 0) and not FRows[FRows.Count - 1].HasAudio then
    begin
      LoadInto(FRows[FRows.Count - 1], SelectedFile);
      SelectRow(FRows[FRows.Count - 1]);
    end
    else
      AddTrack(SelectedFile);
  end;
end;

procedure TZsForm.ListKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_RETURN) and (SelectedFile <> '') then
  begin
    if ssShift in Shift then
      ReplaceTrackClick(nil)
    else
      ListDblClick(nil);
    Key := 0;
  end;
end;

procedure TZsForm.NewTrackClick(Sender: TObject);
begin
  if SelectedFile <> '' then
    AddTrack(SelectedFile);
end;

procedure TZsForm.ReplaceTrackClick(Sender: TObject);
begin
  if SelectedFile = '' then
    Exit;
  if FSel <> nil then
    LoadInto(FSel, SelectedFile)
  else
    AddTrack(SelectedFile);
end;

// ---------------------------------------------------------------------------
// Einstellungen
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Einzelsounds: Drumloop an den Anschlaegen zerlegen, anhoeren, speichern
// (gespeichert wird der Klang wie gehoert: mit Plattenspieler und Pitch)
// ---------------------------------------------------------------------------

procedure TZsForm.SliceModeClick(Sender: TObject);
var
  C: TControl;
  IsOn: Boolean;
begin
  IsOn := KeySliceMode.Checked;
  for C in FEdNormal do
    C.Visible := not IsOn;
  for C in FEdSlice do
    C.Visible := IsOn;
  EditWave.SliceMode := IsOn;
  FSliceActive := -1;
  if IsOn and (FSel <> nil) and FSel.HasAudio and not FSel.SlicesValid then
    DetectSlices(FSel);
  UpdateSliceUi;
end;

procedure TZsForm.DetectSlices(ARow: TZsRow);
var
  S0, S1, I: Integer;
  Onsets: TArray<Integer>;
  F: Double;
  Kept: TArray<Double>;
begin
  if (ARow = nil) or not ARow.HasAudio then
    Exit;
  if ARow.SliceManual then
  begin
    // manuell: vorhandene Marken im (evtl. neuen) Bereich behalten
    Kept := [ARow.MarkS];
    for I := 1 to High(ARow.Slices) do
      if (ARow.Slices[I] > Kept[High(Kept)]) and (ARow.Slices[I] < ARow.MarkE) then
        Kept := Kept + [ARow.Slices[I]];
    ARow.Slices := Kept;
    SetLength(ARow.SliceSel, Length(Kept));
    ARow.SlicesValid := True;
    Exit;
  end;
  Screen.Cursor := crHourGlass;
  try
    S0 := Round(ARow.MarkS * ARow.Audio.Frames);
    S1 := Round(ARow.MarkE * ARow.Audio.Frames);
    Onsets := S2400DetectOnsets(ARow.Audio, S0, S1, ARow.SliceSens, ARow.SliceThr);
  finally
    Screen.Cursor := crDefault;
  end;
  ARow.Slices := [ARow.MarkS];
  for I := 0 to High(Onsets) do
  begin
    F := Onsets[I] / ARow.Audio.Frames;
    // auf den Nulldurchgang davor (nur fuer die Spur im Editor bekannt)
    if KeySnap.Checked and (ARow = FSel) then
      F := EditWave.SnapFrac(F, -1);
    if (F > ARow.Slices[High(ARow.Slices)] + 32 / ARow.Audio.Frames) and (F < ARow.MarkE) then
      ARow.Slices := ARow.Slices + [F];
  end;
  SetLength(ARow.SliceSel, Length(ARow.Slices));
  for I := 0 to High(ARow.SliceSel) do
    ARow.SliceSel[I] := False;
  ARow.SlicesValid := True;
end;

procedure TZsForm.UpdateSliceUi;
var
  I, N: Integer;
  Ev: TNotifyEvent;
begin
  if KeySliceMode.Checked then
    LabelEditHint.Caption := Tr('Strg+Klick = w'#$00E4'hlen '#$00B7' Doppelklick = Marke + '#$00B7' Rechtsklick/Entf = Marke '#$2212,
      'Ctrl+click = select '#$00B7' double-click = marker + '#$00B7' right-click/Del = marker '#$2212)
  else
    LabelEditHint.Caption := Tr('Rad = Zoom '#$00B7' Umschalt+Rad = schieben '#$00B7' Doppelklick = alles',
      'Wheel = zoom '#$00B7' Shift+wheel = scroll '#$00B7' double-click = all');
  if not KeySliceMode.Checked then
    Exit;
  if (FSel <> nil) and FSel.HasAudio and FSel.SlicesValid then
  begin
    if FSliceActive > High(FSel.Slices) then
      FSliceActive := -1;
    if FSliceLast > High(FSel.Slices) then
      FSliceLast := -1;
    EditWave.SetSlices(FSel.Slices, FSel.SliceSel, FSliceActive);
    Pads.SetPads(Length(FSel.Slices), FSel.SliceSel, FSliceActive);
    N := 0;
    for I := 0 to High(FSel.SliceSel) do
      if FSel.SliceSel[I] then
        Inc(N);
    ReadSlices.SetText(Format(Tr('%d Sounds '#$00B7' %d gew'#$00E4'hlt', '%d hits '#$00B7' %d selected'),
      [Length(FSel.Slices), N]), C_UI_TEXT);
    Ev := KnobSens.OnChange;
    KnobSens.OnChange := nil;
    KnobThr.OnChange := nil;
    KnobSens.Value := FSel.SliceSens;
    KnobThr.Value := FSel.SliceThr;
    KnobSens.OnChange := Ev;
    KnobThr.OnChange := Ev;
    KeySliceManual.Checked := FSel.SliceManual;
    KnobSens.Enabled := not FSel.SliceManual;
    KnobThr.Enabled := not FSel.SliceManual;
    if FSel.SliceManual then
    begin
      LabelSens.Font.Color := C_UI_MUTED;
      LabelThr.Font.Color := C_UI_MUTED;
      ReadThr.SetText(FmtSigned(FSel.SliceThr, 0) + ' dB', C_UI_MUTED);
    end
    else
    begin
      LabelSens.Font.Color := C_MX_SCALE;
      LabelThr.Font.Color := C_MX_SCALE;
      ReadThr.SetText(FmtSigned(FSel.SliceThr, 0) + ' dB', C_UI_TEXT);
    end;
  end
  else
  begin
    EditWave.SetSlices(nil, nil, -1);
    Pads.SetPads(0, nil, -1);
    ReadSlices.SetText(#$2014, C_UI_MUTED);
    ReadThr.SetText(#$2014, C_UI_MUTED);
    KeySliceManual.Checked := False;
  end;
end;

function TZsForm.RenderSlice(ARow: TZsRow; AIdx, ARate: Integer): TArray<Single>;
var
  S, E: Double;
begin
  Result := nil;
  if (ARow = nil) or not ARow.HasAudio or (AIdx < 0) or (AIdx > High(ARow.Slices)) or (ARate <= 0) then
    Exit;
  S := ARow.Slices[AIdx];
  if AIdx < High(ARow.Slices) then
    E := ARow.Slices[AIdx + 1]
  else
    E := ARow.MarkE;
  Result := S2400RenderTrack(ARow.Audio, S, E, ARow.KnobPitch.Value + ARow.Cents / 100 + PitchComp, RowSpeed(ARow), ARate);
end;

// Klick: anhoeren; mit Strg: aus-/abwaehlen
procedure TZsForm.SliceHit(AIdx: Integer; AToggle: Boolean);
var
  Buf: TArray<Single>;
begin
  if (FSel = nil) or not FSel.HasAudio or (AIdx < 0) or (AIdx > High(FSel.Slices)) then
    Exit;
  FSliceLast := AIdx;
  if AToggle then
  begin
    FSel.SliceSel[AIdx] := not FSel.SliceSel[AIdx];
    UpdateSliceUi;
    Exit;
  end;
  if FEngine = nil then
  begin
    OpenDevice;
    if FEngine = nil then
      Exit;
  end;
  Buf := RenderSlice(FSel, AIdx, FDevRate);
  if Buf = nil then
    Exit;
  FPrevIdx := -1;           // keine Markierung in der Sample-Liste
  ListFiles.Invalidate;
  FEngine.StartPreview(Buf, True, DbToLin(FSel.KnobGain.Value));
  FSliceActive := AIdx;
  UpdateSliceUi;
end;

// Marke am Anfang von Sound AIdx loeschen: er verschmilzt mit dem davor
procedure TZsForm.DeleteSliceMark(AIdx: Integer);
begin
  if (FSel = nil) or not FSel.HasAudio or (AIdx <= 0) or (AIdx > High(FSel.Slices)) then
    Exit;
  Delete(FSel.Slices, AIdx, 1);
  Delete(FSel.SliceSel, AIdx, 1);
  FSel.SliceManual := True;
  FSliceActive := -1;
  FSliceLast := AIdx - 1;
  UpdateSliceUi;
end;

procedure TZsForm.PadClick(Sender: TObject);
begin
  SliceHit(Pads.Clicked, Pads.ClickCtrl);
end;

procedure TZsForm.EditSliceClick(Sender: TObject);
begin
  SliceHit(EditWave.ClickedSlice, EditWave.ClickCtrl);
end;

procedure TZsForm.EditSlicesChanged(Sender: TObject);
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  FSel.Slices := Copy(EditWave.Slices);
  FSel.SliceSel := Copy(EditWave.SliceSelection);
  FSel.SliceManual := True;   // von Hand bearbeitet: Knoepfe ueberschreiben nichts mehr
  SetLength(FSel.SliceSel, Length(FSel.Slices));
  FSliceActive := -1;
  UpdateSliceUi;
end;

procedure TZsForm.SliceSensChange(Sender: TObject);
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  FSel.SliceSens := KnobSens.Value;
  FSel.SliceThr := KnobThr.Value;
  if FSel.SliceManual then
  begin
    UpdateSliceUi;
    Exit;
  end;
  DetectSlices(FSel);
  FSliceActive := -1;
  UpdateSliceUi;
end;

procedure TZsForm.SliceManualClick(Sender: TObject);
begin
  if (FSel = nil) or not FSel.HasAudio then
  begin
    KeySliceManual.Checked := False;
    Exit;
  end;
  FSel.SliceManual := KeySliceManual.Checked;
  // zurueck auf automatisch: neu erkennen (Hand-Marken gehen dabei verloren)
  if not FSel.SliceManual then
    DetectSlices(FSel);
  FSliceActive := -1;
  UpdateSliceUi;
end;

procedure TZsForm.SliceClearClick(Sender: TObject);
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  FSel.SliceManual := True;
  FSel.Slices := [FSel.MarkS];
  FSel.SliceSel := [False];
  FSel.SlicesValid := True;
  FSliceActive := -1;
  FSliceLast := -1;
  UpdateSliceUi;
end;

procedure TZsForm.SliceSelClick(Sender: TObject);
var
  I: Integer;
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  for I := 0 to High(FSel.SliceSel) do
    FSel.SliceSel[I] := TZsKey(Sender).Tag = 1;
  UpdateSliceUi;
end;

procedure TZsForm.SliceSaveClick(Sender: TObject);
var
  D: TFileOpenDialog;
  Dir, Base, Path, Err, FirstErr: string;
  I, N, Ok, Num: Integer;
  Buf: TArray<Single>;
begin
  if (FSel = nil) or not FSel.HasAudio then
    Exit;
  N := 0;
  for I := 0 to High(FSel.SliceSel) do
    if FSel.SliceSel[I] then
      Inc(N);
  if N = 0 then
  begin
    ShowStatus(Tr('Keine Sounds gew'#$00E4'hlt (Strg+Klick auf ein Pad oder ALLE)',
      'No hits selected (Ctrl+click a pad, or ALL)'), False);
    Exit;
  end;
  D := TFileOpenDialog.Create(nil);
  try
    D.Title := Tr('Wohin sollen die Einzelsounds gespeichert werden?', 'Where should the single hits be saved?');
    D.OkButtonLabel := Tr('Hier speichern', 'Save here');
    D.Options := [fdoPickFolders, fdoPathMustExist, fdoForceFileSystem];
    if (FSliceDir <> '') and DirectoryExists(FSliceDir) then
      D.DefaultFolder := FSliceDir
    else
      D.DefaultFolder := StackFolder;
    if not D.Execute(Handle) then
      Exit;
    Dir := D.FileName;
  finally
    D.Free;
  end;
  FSliceDir := Dir;
  SaveSettings;

  Base := ChangeFileExt(ExtractFileName(FSel.FileName), '');
  Ok := 0;
  FirstErr := '';
  Screen.Cursor := crHourGlass;
  try
    for I := 0 to High(FSel.Slices) do
    begin
      if not FSel.SliceSel[I] then
        Continue;
      // in der Rate der Datei, mit Plattenspieler und Pitch
      Buf := RenderSlice(FSel, I, FSel.Audio.Rate);
      if Buf = nil then
        Continue;
      Path := TPath.Combine(Dir, Format('%s_%.2d.wav', [Base, I + 1]));
      Num := 2;
      while FileExists(Path) do
      begin
        Path := TPath.Combine(Dir, Format('%s_%.2d (%d).wav', [Base, I + 1, Num]));
        Inc(Num);
      end;
      if S2400SaveWav24(Path, Buf, Length(Buf) div 2, FSel.Audio.Rate, Err) then
        Inc(Ok)
      else if FirstErr = '' then
        FirstErr := Err;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  if FirstErr <> '' then
    ShowStatus(Format(Tr('%d von %d gespeichert: %s', '%d of %d saved: %s'), [Ok, N, FirstErr]), False)
  else
    ShowStatus(Format(Tr('%d Einzelsounds gespeichert in %s', '%d single hits saved in %s'), [Ok, Dir]), True);
end;

// ---------------------------------------------------------------------------
// Stack speichern / laden (.s2400stack, INI-Text in UTF-8)
//
//   [Stack]   Version, Turntable (0..3), Loop, Tracks
//   [TrackN]  File, Start, End (0..1 der Datei), Bpm, BpmSource, Pitch (HT),
//             Cents, Gain (dB), Mute, Solo
// Die Samples selbst werden nicht kopiert, nur ihr Pfad. Fehlt eine Datei,
// wird im Ordner der Stack-Datei und im Sample-Ordner nach dem Namen gesucht.
// ---------------------------------------------------------------------------

const
  C_STACK_EXT = '.s2400stack';

function StackFloatStr(AValue: Double): string;
begin
  Result := FloatToStr(AValue, TFormatSettings.Invariant);
end;

function StackFloat(AIni: TCustomIniFile; const ASection, AName: string; ADefault: Double): Double;
begin
  Result := StrToFloatDef(AIni.ReadString(ASection, AName, ''), ADefault, TFormatSettings.Invariant);
end;

function Clamp01(AValue: Double): Double;
begin
  Result := AValue;
  if Result < 0 then
    Result := 0
  else if Result > 1 then
    Result := 1;
end;

procedure TZsForm.ShowStatus(const AMsg: string; AOk: Boolean);
begin
  FStatusMsg := AMsg;
  FStatusOk := AOk;
  FStatusUntil := GetTickCount64 + 5000;
  UpdateDisplay;
end;

function TZsForm.StackFolder: string;
begin
  // nur Startordner der Dialoge: zuletzt benutzt, sonst "Dokumente"
  Result := FStackDir;
  if (Result = '') or not DirectoryExists(Result) then
    Result := TPath.GetDocumentsPath;
end;

function TZsForm.FindStackFile(const AFileName, AStackDir: string): string;
var
  NameOnly: string;
  E: TZsFileEntry;
begin
  Result := '';
  if AFileName = '' then
    Exit;
  // nur ein Name (Sample liegt im Stack-Ordner)
  if TPath.IsRelativePath(AFileName) and (AStackDir <> '') and FileExists(TPath.Combine(AStackDir, AFileName)) then
    Exit(TPath.Combine(AStackDir, AFileName));
  if not TPath.IsRelativePath(AFileName) and FileExists(AFileName) then
    Exit(AFileName);
  NameOnly := ExtractFileName(AFileName);
  if (AStackDir <> '') and FileExists(IncludeTrailingPathDelimiter(AStackDir) + NameOnly) then
    Exit(IncludeTrailingPathDelimiter(AStackDir) + NameOnly);
  // Splice verschiebt gelegentlich: im Sample-Ordner nach dem Namen suchen
  for E in FFiles do
    if SameText(ExtractFileName(E.Path), NameOnly) then
      Exit(E.Path);
end;

procedure TZsForm.ClearRows;
var
  R: TZsRow;
begin
  while FRows.Count > 0 do
  begin
    R := FRows[FRows.Count - 1];
    if FEngine <> nil then
      FEngine.RemoveVoice(FRows.Count - 1);
    FRows.Delete(FRows.Count - 1);
    R.Free;
  end;
  FSel := nil;
  RowsBox.VertScrollBar.Position := 0;
  LayoutRows;
end;

function SlicesToStr(const A: TArray<Double>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
  begin
    if I > 0 then
      Result := Result + ';';
    Result := Result + FloatToStr(A[I], TFormatSettings.Invariant);
  end;
end;

function SelToStr(const A: TArray<Boolean>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(A) do
    if A[I] then
      Result := Result + '1'
    else
      Result := Result + '0';
end;

// Marken aus der Stack-Datei: aufsteigend, im Bereich, erste = Bereichsanfang
function StrToSlices(const S: string; AMarkS, AMarkE: Double; out A: TArray<Double>): Boolean;
var
  Parts: TArray<string>;
  P: string;
  V: Double;
begin
  A := nil;
  Result := False;
  if Trim(S) = '' then
    Exit;
  Parts := S.Split([';']);
  for P in Parts do
  begin
    V := StrToFloatDef(Trim(P), -1, TFormatSettings.Invariant);
    if (V < AMarkS - 1E-9) or (V >= AMarkE) then
      Continue;
    if (Length(A) > 0) and (V <= A[High(A)]) then
      Continue;
    A := A + [V];
  end;
  if Length(A) = 0 then
    Exit;
  A[0] := AMarkS;
  Result := True;
end;

function StrToSel(const S: string; ACount: Integer): TArray<Boolean>;
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 0 to ACount - 1 do
    Result[I] := (I < Length(S)) and (S[I + 1] = '1');
end;

// gewaehlte Einzelsounds aller Spuren nach "<Stack> Einzelsounds\" neben der
// Stack-Datei (wie gehoert, 24 Bit, Rate der Datei). Alte Dateien von uns
// ("Spur *.wav") werden vorher entfernt, damit der Ordner zum Stack passt.
function TZsForm.SaveStackSlices(const AStackFile: string; out AError: string): Integer;
var
  R: TZsRow;
  Dir, Base, Path, Err, F: string;
  I, Total: Integer;
  Buf: TArray<Single>;
begin
  Result := 0;
  AError := '';
  Total := 0;
  for R in FRows do
    if R.HasAudio and R.SlicesValid then
      for I := 0 to High(R.SliceSel) do
        if R.SliceSel[I] then
          Inc(Total);
  Dir := TPath.Combine(ExtractFileDir(AStackFile),
    ChangeFileExt(ExtractFileName(AStackFile), '') + Tr(' Einzelsounds', ' single hits'));
  if Total = 0 then
    Exit;
  Screen.Cursor := crHourGlass;
  try
    try
      ForceDirectories(Dir);
      for F in TDirectory.GetFiles(Dir, 'Spur *.wav') do
        System.SysUtils.DeleteFile(F);
      for F in TDirectory.GetFiles(Dir, 'Track *.wav') do
        System.SysUtils.DeleteFile(F);
    except
      on E: Exception do
      begin
        AError := E.Message;
        Exit;
      end;
    end;
    for R in FRows do
    begin
      if not R.HasAudio or not R.SlicesValid then
        Continue;
      Base := ChangeFileExt(ExtractFileName(R.FileName), '');
      for I := 0 to High(R.Slices) do
      begin
        if (I > High(R.SliceSel)) or not R.SliceSel[I] then
          Continue;
        Buf := RenderSlice(R, I, R.Audio.Rate);
        if Buf = nil then
          Continue;
        Path := TPath.Combine(Dir, Format(Tr('Spur %d - %s_%.2d.wav', 'Track %d - %s_%.2d.wav'), [R.Index + 1, Base, I + 1]));
        if S2400SaveWav24(Path, Buf, Length(Buf) div 2, R.Audio.Rate, Err) then
          Inc(Result)
        else if AError = '' then
          AError := Err;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

// Ziel fuer die Kopie eines Samples im Stack-Ordner: gleicher Name; liegt dort
// schon eine gleich grosse Datei, wird sie benutzt, sonst " (2)" usw.
function StackCopyTarget(const ADir, ASource: string; out AExists: Boolean): string;
var
  Base, Ext: string;
  N: Integer;
begin
  Base := ChangeFileExt(ExtractFileName(ASource), '');
  Ext := ExtractFileExt(ASource);
  Result := TPath.Combine(ADir, Base + Ext);
  N := 2;
  AExists := False;
  while FileExists(Result) do
  begin
    if TFile.GetSize(Result) = TFile.GetSize(ASource) then
    begin
      AExists := True;
      Exit;
    end;
    Result := TPath.Combine(ADir, Format('%s (%d)%s', [Base, N, Ext]));
    Inc(N);
  end;
end;

function SameDir(const A, B: string): Boolean;
begin
  Result := SameText(ExcludeTrailingPathDelimiter(ExpandFileName(A)), ExcludeTrailingPathDelimiter(ExpandFileName(B)));
end;

// Alles in den gewaehlten Ordner: Stack-Datei, Kopien der benutzten Samples
// (Pfade in der Datei dann nur als Name) und "<Stack> Einzelsounds\"
procedure TZsForm.SaveStack(const AFileName: string);
var
  Ini: TMemIniFile;
  R: TZsRow;
  Sec, Err, Dir, Dst: string;
  I, Rpm, N, Copied: Integer;
  Exists: Boolean;
begin
  Rpm := 0;
  Copied := 0;
  Dir := ExtractFileDir(AFileName);
  for I := 0 to C_RPM_COUNT - 1 do
    if KeyRpm[I].Checked then
      Rpm := I;
  try
    // Samples in den Stack-Ordner kopieren (sofern sie nicht schon dort liegen)
    Screen.Cursor := crHourGlass;
    try
      for R in FRows do
        if R.HasAudio and (R.FileName <> '') and FileExists(R.FileName) and not SameDir(ExtractFileDir(R.FileName), Dir) then
        begin
          Dst := StackCopyTarget(Dir, R.FileName, Exists);
          if not Exists then
          begin
            TFile.Copy(R.FileName, Dst, False);
            Inc(Copied);
          end;
          R.FileName := Dst;   // die Spur arbeitet ab jetzt mit der Kopie
        end;
    finally
      Screen.Cursor := crDefault;
    end;
    Ini := TMemIniFile.Create(AFileName, TEncoding.UTF8);
    try
      Ini.Clear;
      Ini.WriteInteger('Stack', 'Version', 3);
      Ini.WriteInteger('Stack', 'Turntable', Rpm);
      Ini.WriteString('Stack', 'Tempo', StackFloatStr(FTempo));
      Ini.WriteBool('Stack', 'KeepPitch', FKeepPitch);
      Ini.WriteBool('Stack', 'Loop', KeyLoop.Checked);
      Ini.WriteInteger('Stack', 'Tracks', FRows.Count);
      for R in FRows do
      begin
        Sec := 'Track' + IntToStr(R.Index + 1);
        // im Stack-Ordner: nur der Name (Ordner bleibt verschiebbar)
        if (R.FileName <> '') and SameDir(ExtractFileDir(R.FileName), Dir) then
          Ini.WriteString(Sec, 'File', ExtractFileName(R.FileName))
        else
          Ini.WriteString(Sec, 'File', R.FileName);
        Ini.WriteString(Sec, 'Start', StackFloatStr(R.MarkS));
        Ini.WriteString(Sec, 'End', StackFloatStr(R.MarkE));
        Ini.WriteString(Sec, 'Bpm', StackFloatStr(R.Bpm));
        Ini.WriteInteger(Sec, 'BpmSource', Ord(R.BpmSource));
        Ini.WriteInteger(Sec, 'Pitch', R.KnobPitch.Value);
        Ini.WriteInteger(Sec, 'Cents', R.Cents);
        Ini.WriteInteger(Sec, 'Gain', R.KnobGain.Value);
        Ini.WriteBool(Sec, 'Mute', R.KeyMute.Checked);
        Ini.WriteBool(Sec, 'Solo', R.KeySolo.Checked);
        // Einzelsounds: Marken, Auswahl, Empfindlichkeit
        if R.HasAudio and R.SlicesValid and (Length(R.Slices) > 0) then
        begin
          Ini.WriteInteger(Sec, 'SliceSens', R.SliceSens);
          Ini.WriteInteger(Sec, 'SliceThr', R.SliceThr);
          Ini.WriteBool(Sec, 'SliceManual', R.SliceManual);
          Ini.WriteString(Sec, 'Slices', SlicesToStr(R.Slices));
          Ini.WriteString(Sec, 'SliceSel', SelToStr(R.SliceSel));
        end;
      end;
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
    begin
      ShowStatus(Tr('Stack nicht gespeichert: ', 'Stack not saved: ') + E.Message, False);
      Exit;
    end;
  end;
  FStackDir := ExtractFileDir(AFileName);
  FStackName := ChangeFileExt(ExtractFileName(AFileName), '');
  SaveSettings;
  // gewaehlte Einzelsounds in einen eigenen Ordner neben der Stack-Datei
  N := SaveStackSlices(AFileName, Err);
  if Err <> '' then
    ShowStatus(Tr('Stack gespeichert, Einzelsounds nicht: ', 'Stack saved, single hits not: ') + Err, False)
  else
    ShowStatus(Format(Tr('Stack gespeichert in %s (%d Samples kopiert, %d Einzelsounds)',
      'Stack saved in %s (%d samples copied, %d single hits)'), [Dir, Copied, N]), True);
  UpdateDisplay;
end;

procedure TZsForm.LoadStack(const AFileName: string);
var
  Ini: TMemIniFile;
  R: TZsRow;
  Sec, F, Found: string;
  I, N, Rpm, Src, Missing: Integer;
  B: Double;
  Ev: TNotifyEvent;
  Sl: TArray<Double>;
begin
  if not FileExists(AFileName) then
    Exit;
  Missing := 0;
  try
    Ini := TMemIniFile.Create(AFileName, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      ShowStatus(Tr('Stack nicht lesbar: ', 'Stack not readable: ') + E.Message, False);
      Exit;
    end;
  end;
  try
    if not Ini.SectionExists('Stack') then
    begin
      ShowStatus(Tr('Keine Stack-Datei: ', 'Not a stack file: ') + ExtractFileName(AFileName), False);
      Exit;
    end;
    if FEngine <> nil then
    begin
      FEngine.StopPlay;
      FEngine.StopPreview;
    end;
    KeyAudition.Checked := False;
    ClearRows;

    // Plattenspieler und Schleife
    Rpm := Ini.ReadInteger('Stack', 'Turntable', 0);
    if (Rpm < 0) or (Rpm >= C_RPM_COUNT) then
      Rpm := 0;
    for I := 0 to C_RPM_COUNT - 1 do
      KeyRpm[I].Checked := I = Rpm;
    FRpm := Rpm;
    // Stack-Tempo (ab 1.5.2 "Tempo"; 1.5.1 schrieb "Speed" = Tempo x Stufe)
    FTempo := 1;
    B := StackFloat(Ini, 'Stack', 'Tempo', 0);
    if B <= 0 then
      B := StackFloat(Ini, 'Stack', 'Speed', 0) / C_RPM_FACTOR[Rpm];
    if (B >= 0.25) and (B <= 4) then
      FTempo := B;
    FSpeed := FTempo * C_RPM_FACTOR[FRpm];
    FKeepPitch := Ini.ReadBool('Stack', 'KeepPitch', False);
    KeyKeepPitch.Checked := FKeepPitch;
    KeyLoop.Checked := Ini.ReadBool('Stack', 'Loop', KeyLoop.Checked);
    if FEngine <> nil then
      FEngine.SetLoop(KeyLoop.Checked);

    N := Ini.ReadInteger('Stack', 'Tracks', 0);
    if N > C_MAX_TRACKS then
      N := C_MAX_TRACKS;
    FBulk := True;
    try
      for I := 1 to N do
      begin
        Sec := 'Track' + IntToStr(I);
        R := AddTrack('');
        if R = nil then
          Break;
        F := Ini.ReadString(Sec, 'File', '');
        if F <> '' then
        begin
          Found := FindStackFile(F, ExtractFileDir(AFileName));
          if (Found = '') or not LoadInto(R, Found) then
          begin
            R.FileName := F;   // Zeile zeigt "FEHLT: ..."
            Inc(Missing);
          end;
        end;
        if R.HasAudio then
        begin
          R.MarkS := Clamp01(StackFloat(Ini, Sec, 'Start', 0));
          R.MarkE := Clamp01(StackFloat(Ini, Sec, 'End', 1));
          if R.MarkE <= R.MarkS then
          begin
            R.MarkS := 0;
            R.MarkE := 1;
          end;
          R.Wave.SetMarks(R.MarkS, R.MarkE);
          B := StackFloat(Ini, Sec, 'Bpm', R.Bpm);
          Src := Ini.ReadInteger(Sec, 'BpmSource', Ord(R.BpmSource));
          if (B >= 0) and (Src >= 0) and (Src <= Ord(High(TZsBpmSource))) then
          begin
            R.Bpm := B;
            R.BpmSource := TZsBpmSource(Src);
          end;
          R.Cents := EnsureRange(Ini.ReadInteger(Sec, 'Cents', 0), -50, 50);
          // Einzelsounds (ab Version 2)
          R.SliceSens := EnsureRange(Ini.ReadInteger(Sec, 'SliceSens', 50), 0, 100);
          R.SliceThr := EnsureRange(Ini.ReadInteger(Sec, 'SliceThr', -45), -60, 0);
          R.SliceManual := Ini.ReadBool(Sec, 'SliceManual', False);
          if StrToSlices(Ini.ReadString(Sec, 'Slices', ''), R.MarkS, R.MarkE, Sl) then
          begin
            R.Slices := Sl;
            R.SliceSel := StrToSel(Ini.ReadString(Sec, 'SliceSel', ''), Length(Sl));
            R.SlicesValid := True;
          end;
        end;
        // Knoepfe setzen, ohne die Ereignisse auszuloesen
        Ev := R.KnobPitch.OnChange;
        R.KnobPitch.OnChange := nil;
        R.KnobPitch.Value := Ini.ReadInteger(Sec, 'Pitch', 0);
        R.KnobPitch.OnChange := Ev;
        Ev := R.KnobGain.OnChange;
        R.KnobGain.OnChange := nil;
        R.KnobGain.Value := Ini.ReadInteger(Sec, 'Gain', 0);
        R.KnobGain.OnChange := Ev;
        R.KeyMute.Checked := Ini.ReadBool(Sec, 'Mute', False);
        R.KeySolo.Checked := Ini.ReadBool(Sec, 'Solo', False);
      end;
    finally
      FBulk := False;
    end;
  finally
    Ini.Free;
  end;

  // jetzt alle Spuren mit den geladenen Werten rechnen
  for R in FRows do
    RenderRow(R);
  ApplyMix;
  if FRows.Count > 0 then
  begin
    SelectRow(FRows[0]);
    RowsBox.ScrollInView(FRows[0]);
  end
  else
    SelectRow(nil);
  FStackDir := ExtractFileDir(AFileName);
  FStackName := ChangeFileExt(ExtractFileName(AFileName), '');
  SaveSettings;
  if Missing > 0 then
    ShowStatus(Format(Tr('Stack geladen, %d Datei(en) fehlen', 'Stack loaded, %d file(s) missing'), [Missing]), False)
  else
    ShowStatus(Tr('Stack geladen: ', 'Stack loaded: ') + ExtractFileName(AFileName), True);
end;

// Splice-Stack (Export "Stems"): ZIP-Datei oder ein Stem aus dem entpackten
// Ordner. Bei einer ZIP fragt ein Ordner-Dialog, wohin die Stems kommen; sie
// bleiben dort, damit ein spaeter gespeicherter .s2400stack sie wiederfindet.
// Jeder Stem wird eine Spur, in der Reihenfolge des Stacks.
type
  TStem = record
    Path: string;
    Info: TS2400StemInfo;
  end;

procedure TZsForm.ImportSplice(const AFileName: string);
var
  Stems: TList<TStem>;
  St: TStem;
  Zip: TZipFile;
  FolderDlg: TFileOpenDialog;
  Dest, Dir, F: string;
  I, Skipped, Missing: Integer;
  R: TZsRow;
begin
  Stems := TList<TStem>.Create;
  try
    Missing := 0;
    try
      if SameText(ExtractFileExt(AFileName), '.zip') then
      begin
        // Speicherort fragt der Nutzer selbst an (Stems landen direkt dort)
        FolderDlg := TFileOpenDialog.Create(nil);
        try
          FolderDlg.Title := Tr('Wohin sollen die Stems gespeichert werden?', 'Where should the stems be saved?');
          FolderDlg.OkButtonLabel := Tr('Hier speichern', 'Save here');
          FolderDlg.Options := [fdoPickFolders, fdoPathMustExist, fdoForceFileSystem];
          if (FImportDir <> '') and DirectoryExists(FImportDir) then
            FolderDlg.DefaultFolder := FImportDir
          else
            FolderDlg.DefaultFolder := StackFolder;
          if not FolderDlg.Execute(Handle) then
            Exit;
          Dest := FolderDlg.FileName;
        finally
          FolderDlg.Free;
        end;
        FImportDir := Dest;
        SaveSettings;
        Zip := TZipFile.Create;
        try
          Zip.Open(AFileName, zmRead);
          for I := 0 to Zip.FileCount - 1 do
          begin
            // nur der Dateiname zaehlt (Unterordner in der ZIP flach entpacken)
            F := ExtractFileName(StringReplace(Zip.FileNames[I], '/', '\', [rfReplaceAll]));
            if (F = '') or not S2400IsAudioFile(F) or not S2400SpliceStem(F, St.Info) then
              Continue;
            Zip.Extract(I, Dest, False);
            St.Path := TPath.Combine(Dest, F);
            if FileExists(St.Path) then
              Stems.Add(St);
          end;
          Zip.Close;
        finally
          Zip.Free;
        end;
      end
      else
      begin
        // ein Stem aus dem entpackten Ordner: alle Stems desselben Stacks
        if not S2400SpliceStem(AFileName, St.Info) then
        begin
          ShowStatus(Tr('Kein Splice-Stem (Name "<Stack> - 87 BPM - 1 - ...")',
            'Not a Splice stem (name "<stack> - 87 BPM - 1 - ...")'), False);
          Exit;
        end;
        Dir := ExtractFileDir(AFileName);
        for F in TDirectory.GetFiles(Dir) do
          if S2400IsAudioFile(F) and S2400SpliceStem(F, St.Info) then
          begin
            St.Path := F;
            Stems.Add(St);
          end;
        if S2400SpliceStem(AFileName, St.Info) then
          for I := Stems.Count - 1 downto 0 do
            if not SameText(Stems[I].Info.Stack, St.Info.Stack) then
              Stems.Delete(I);
      end;
    except
      on E: Exception do
      begin
        ShowStatus(Tr('Splice-Export nicht lesbar: ', 'Splice export not readable: ') + E.Message, False);
        Exit;
      end;
    end;
    if Stems.Count = 0 then
    begin
      ShowStatus(Tr('Keine Splice-Stems gefunden (in Splice: Export '#$2192' Stems)',
        'No Splice stems found (in Splice: Export '#$2192' Stems)'), False);
      Exit;
    end;
    Stems.Sort(TComparer<TStem>.Construct(
      function(const A, B: TStem): Integer
      begin
        Result := A.Info.Number - B.Info.Number;
      end));
    Skipped := 0;
    while Stems.Count > C_MAX_TRACKS do
    begin
      Stems.Delete(Stems.Count - 1);
      Inc(Skipped);
    end;

    if FEngine <> nil then
    begin
      FEngine.StopPlay;
      FEngine.StopPreview;
    end;
    KeyAudition.Checked := False;
    ClearRows;
    // Splice hat Tempo und Tonart schon angeglichen: Plattenspieler auf Original
    for I := 0 to C_RPM_COUNT - 1 do
      KeyRpm[I].Checked := I = 0;
    FRpm := 0;
    FTempo := 1;
    FSpeed := 1;
    FBulk := True;
    try
      for St in Stems do
      begin
        R := AddTrack('');
        if R = nil then
          Break;
        if not LoadInto(R, St.Path) then
        begin
          R.FileName := St.Path;
          Inc(Missing);
        end;
      end;
    finally
      FBulk := False;
    end;
    for R in FRows do
      RenderRow(R);
    ApplyMix;
    if FRows.Count > 0 then
    begin
      SelectRow(FRows[0]);
      RowsBox.ScrollInView(FRows[0]);
    end;
    FStackName := Stems[0].Info.Stack;
    if Missing > 0 then
      ShowStatus(Format(Tr('Splice-Stack geladen, %d Datei(en) nicht lesbar', 'Splice stack loaded, %d file(s) not readable'),
        [Missing]), False)
    else if Skipped > 0 then
      ShowStatus(Format(Tr('Splice-Stack geladen, %d Stems '#$00FC'ber 8 weggelassen', 'Splice stack loaded, %d stems beyond 8 left out'),
        [Skipped]), False)
    else
      ShowStatus(Format(Tr('Splice-Stack geladen: %s (%d Spuren, %s BPM)', 'Splice stack loaded: %s (%d tracks, %s BPM)'),
        [Stems[0].Info.Stack, FRows.Count, FmtNum(Stems[0].Info.Bpm, 0)]), True);
  finally
    Stems.Free;
  end;
end;

// moderne Windows-Dateidialoge (TFileSaveDialog/TFileOpenDialog); TSaveDialog
// und TOpenDialog fielen hier auf den alten Dialog im XP-Stil zurueck
procedure TZsForm.StackSaveClick(Sender: TObject);
var
  D: TFileSaveDialog;
  StackName: string;
begin
  if FRows.Count = 0 then
  begin
    ShowStatus(Tr('Keine Spuren zum Speichern', 'No tracks to save'), False);
    Exit;
  end;
  StackName := FStackName;
  if (StackName = '') and (FRows[0].FileName <> '') then
    StackName := ChangeFileExt(ExtractFileName(FRows[0].FileName), '');
  if StackName = '' then
    StackName := 'Stack';
  D := TFileSaveDialog.Create(nil);
  try
    D.Title := Tr('Stack speichern', 'Save stack');
    with D.FileTypes.Add do
    begin
      DisplayName := Tr('S2400-Stack', 'S2400 stack');
      FileMask := '*' + C_STACK_EXT;
    end;
    D.DefaultExtension := Copy(C_STACK_EXT, 2, MaxInt);
    D.DefaultFolder := StackFolder;
    D.FileName := StackName;
    D.Options := [fdoOverWritePrompt, fdoPathMustExist, fdoForceFileSystem];
    if D.Execute(Handle) then
      SaveStack(D.FileName);
  finally
    D.Free;
  end;
end;

procedure TZsForm.StackLoadClick(Sender: TObject);
var
  D: TFileOpenDialog;
begin
  D := TFileOpenDialog.Create(nil);
  try
    D.Title := Tr('Stack laden', 'Load stack');
    with D.FileTypes.Add do
    begin
      DisplayName := Tr('S2400-Stack oder Splice-Export', 'S2400 stack or Splice export');
      FileMask := '*' + C_STACK_EXT + ';*.zip;*.wav';
    end;
    with D.FileTypes.Add do
    begin
      DisplayName := Tr('S2400-Stack', 'S2400 stack');
      FileMask := '*' + C_STACK_EXT;
    end;
    with D.FileTypes.Add do
    begin
      DisplayName := Tr('Splice-Stack (Export '#$201E'Stems'#$201C', ZIP oder ein Stem)', 'Splice stack (export "Stems", ZIP or one stem)');
      FileMask := '*.zip;*.wav';
    end;
    D.DefaultFolder := StackFolder;
    D.Options := [fdoFileMustExist, fdoPathMustExist, fdoForceFileSystem];
    if D.Execute(Handle) then
    begin
      if SameText(ExtractFileExt(D.FileName), C_STACK_EXT) then
        LoadStack(D.FileName)
      else
        ImportSplice(D.FileName);
    end;
  finally
    D.Free;
  end;
end;

procedure TZsForm.LoadSettings;
var
  Reg: TRegistry;
begin
  FFolder := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly(C_REG_KEY) then
    begin
      if Reg.ValueExists('Folder') then
        FFolder := Reg.ReadString('Folder');
      if Reg.ValueExists('DeviceId') then
        FDevId := Reg.ReadString('DeviceId');
      if Reg.ValueExists('Loop') then
        KeyLoop.Checked := Reg.ReadInteger('Loop') <> 0;
      if Reg.ValueExists('Preroll') then
        KeyPreroll.Checked := Reg.ReadInteger('Preroll') <> 0;
      if Reg.ValueExists('PreviewOn') then
        KeyPrevOn.Checked := Reg.ReadInteger('PreviewOn') <> 0
      else
        KeyPrevOn.Checked := True;
      if Reg.ValueExists('PreviewTempo') then
        KeyPrevTempo.Checked := Reg.ReadInteger('PreviewTempo') <> 0
      else
        KeyPrevTempo.Checked := True;
      if Reg.ValueExists('PreviewGain') then
        KnobPrev.Value := Reg.ReadInteger('PreviewGain');
      if Reg.ValueExists('Snap') then
        KeySnap.Checked := Reg.ReadInteger('Snap') <> 0;
      if Reg.ValueExists('StackFolder') then
        FStackDir := Reg.ReadString('StackFolder');
      if Reg.ValueExists('ImportFolder') then
        FImportDir := Reg.ReadString('ImportFolder');
      if Reg.ValueExists('SliceFolder') then
        FSliceDir := Reg.ReadString('SliceFolder');
    end
    else
    begin
      KeyPrevOn.Checked := True;
      KeyPrevTempo.Checked := True;
    end;
  finally
    Reg.Free;
  end;
  if (FFolder = '') or not DirectoryExists(FFolder) then
    FFolder := DefaultSpliceFolder;
end;

procedure TZsForm.SaveSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey(C_REG_KEY, True) then
    begin
      Reg.WriteString('Folder', FFolder);
      Reg.WriteString('DeviceId', FDevId);
      Reg.WriteInteger('Loop', Ord(KeyLoop.Checked));
      Reg.WriteInteger('Preroll', Ord(KeyPreroll.Checked));
      Reg.WriteInteger('PreviewOn', Ord(KeyPrevOn.Checked));
      Reg.WriteInteger('PreviewTempo', Ord(KeyPrevTempo.Checked));
      Reg.WriteInteger('Snap', Ord(KeySnap.Checked));
      Reg.WriteInteger('PreviewGain', KnobPrev.Value);
      Reg.WriteString('StackFolder', FStackDir);
      Reg.WriteString('ImportFolder', FImportDir);
      Reg.WriteString('SliceFolder', FSliceDir);
    end;
  finally
    Reg.Free;
  end;
end;

// ---------------------------------------------------------------------------

procedure ShowS2400Zuspieler;
begin
  if GZsForm <> nil then
  begin
    if IsIconic(GZsForm.Handle) then
      ShowWindow(GZsForm.Handle, SW_RESTORE);
    GZsForm.Show;
    SetForegroundWindow(GZsForm.Handle);
    Exit;
  end;
  GUiScale := Screen.PixelsPerInch / 96;
  UiGdiplusStart;
  try
    GZsForm := TZsForm.CreateZs(nil);
  except
    // Destroy (automatisch nach dem Fehler) hat UiGdiplusStop schon gerufen
    GZsForm := nil;
    raise;
  end;
  GZsForm.Show;
  SetForegroundWindow(GZsForm.Handle);
end;

procedure CloseS2400Zuspieler;
begin
  if GZsForm <> nil then
    GZsForm.Free; // Destroy setzt GZsForm zurueck
end;

procedure RunS2400ZuspielerApp;
begin
  ShowS2400Zuspieler;
  // eigene Nachrichtenschleife: das Fenster ist kein Application.MainForm
  while (GZsForm <> nil) and not Application.Terminated do
    Application.HandleMessage;
end;

end.
