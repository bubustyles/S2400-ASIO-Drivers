unit S2400Resampler;

// =============================================================================
// S2400Resampler.pas
//
// Hochwertiger Abtastraten-Umrechner fuer den S2400-ASIO-Treiber.
// Zwei Einsatzzwecke, ein Baustein:
//   1. feste Umrechnung, z.B. 48000 <-> 44100 Hz (Isla in 44,1-kHz-
//      Projekten - die Isla selbst kann ueber USB nur 48 kHz)
//   2. Takt-Angleichung zweier Geraete (Isla an UAD): Verhaeltnis ~1,
//      laufend per Correction um einige ppm nachgestellt
//
// Verfahren: Kaiser-gefenstertes Sinc-Filter, polyphasige Tabelle mit
// FPhases Phasen, lineare Interpolation zwischen benachbarten Phasen ->
// beliebiges, stufenlos verstellbares Verhaeltnis. Durchlass bis 20 kHz,
// volle Sperre ab der Nyquist-Grenze der kleineren Rate.
//
// Vor der Delphi-Fassung als Python-Referenzmodell (identischer
// Algorithmus) gemessen und danach mit S2400ResamplerTest.dpr bestaetigt
// (14.10.2026, Werte identisch):
//   48 -> 44,1 kHz: 152 Taps, Frequenzgang 20 Hz..20 kHz +/-0,0000 dB,
//                   THD+N 1 kHz -126,7 dB, Aliasing-Unterdrueckung >109 dB,
//                   Latenz 76 Eingangssamples = 1,58 ms
//   44,1 -> 48 kHz: 138 Taps, +/-0,0001 dB, THD+N 1 kHz -123,8 dB, 1,56 ms
//   48 -> 48 kHz mit +100 ppm Korrektur: 78 Taps, THD+N -122,6 dB, 0,8 ms
// (16 Bit selbst haben nur ~96 dB Rauschabstand.)
//
// Streaming: Push(Eingang) und Pull(Ausgang), Daten an der Schnittstelle
// interleaved als Single. INTERN liegt die Historie pro Kanal am Stueck
// ("planar"), damit das Skalarprodukt mit SSE vier Samples auf einmal
// laden kann (DotProductSse). Die Puffer werden im Konstruktor vorab
// angelegt, damit im Echtzeit-Betrieb normalerweise nichts alloziert wird.
// =============================================================================

{$POINTERMATH ON}
// Reiner Rechen-Code im Echtzeit-Pfad: unabhaengig von der Build-
// Konfiguration optimieren und ohne Bereichs-/Ueberlaufpruefungen
// uebersetzen. Korrektheit sichert S2400ResamplerTest.dpr ab.
{$OPTIMIZATION ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Math;

type
  TS2400Resampler = class
  private
    FChannels: Integer;
    FInRate: Double;
    FOutRate: Double;
    FPhases: Integer;
    FHalf: Integer;          // halbe Filterlaenge H (in Eingangssamples)
    FTaps: Integer;          // 2 * H
    FBeta: Double;
    FTable: TArray<Single>;  // (FPhases + 1) Zeilen a FTaps Koeffizienten
    FStep: Double;           // Eingangssamples pro Ausgangssample
    FCorrection: Double;     // Feinkorrektur (Takt-Angleichung), 1.0 = keine
    FBuf: TArray<Single>;    // Eingangs-Historie, planar: Kanal ch ab ch * FCap
    FCap: Integer;           // Kapazitaet in Frames pro Kanal
    FFrames: Integer;        // belegte Frames (pro Kanal)
    FTime: Double;           // Position des naechsten Ausgangssamples
    FCoef: TArray<Single>;   // interpolierte Koeffizientenzeile
    procedure EnsureCapacity(AFrames: Integer);
  public
    // AStopbandDb: Sperrdaempfung (Standard 100 dB)
    // APassbandHz: Durchlassbereich (Standard 20 kHz)
    // APhases: Tabellenaufloesung (Standard 512)
    // AReserveFrames: vorab reservierte Eingangs-Frames
    constructor Create(AChannels: Integer; AInRate, AOutRate: Double;
      AStopbandDb: Double = 100.0; APassbandHz: Double = 20000.0;
      APhases: Integer = 512; AReserveFrames: Integer = 8192);

    procedure Reset;

    // haengt AFrames interleavte Eingangsframes an
    procedure Push(AData: PSingle; AFrames: Integer);
    // wie viele Ausgangsframes jetzt erzeugt werden koennen
    function Available: Integer;
    // erzeugt bis zu AMaxFrames Ausgangsframes (interleaved), liefert die Anzahl
    function Pull(AData: PSingle; AMaxFrames: Integer): Integer;

    // Feinkorrektur des Verhaeltnisses: > 1 verbraucht den Eingang
    // schneller (z.B. 1.000012 = +12 ppm)
    property Correction: Double read FCorrection write FCorrection;

    property Channels: Integer read FChannels;
    property InRate: Double read FInRate;
    property OutRate: Double read FOutRate;
    property Taps: Integer read FTaps;
    property Beta: Double read FBeta;
    // algorithmische Verzoegerung in Eingangssamples
    property LatencyInputFrames: Integer read FHalf;
    // Eingangsframes, die gerade gepuffert sind (fuer Fuellstandsregelung)
    property BufferedInputFrames: Integer read FFrames;
    // noch nicht verbrauchte Eingangsframes (gepuffert minus aktuelle
    // Leseposition) - gehoert beim Verbund zum geregelten Fuellstand
    function PendingInputFrames: Double;
  end;

// Skalarprodukt zweier zusammenhaengender Single-Felder der Laenge N.
// DotProductSse: SSE, 8 Produkte pro Schleifendurchlauf (im Treiber benutzt).
// DotProductPascal: Referenz mit Double-Summe - nur fuer den Vergleichstest.
function DotProductSse(A, B: PSingle; N: NativeInt): Single;
function DotProductPascal(A, B: PSingle; N: Integer): Double;

implementation

// -----------------------------------------------------------------------
// Skalarprodukt
// -----------------------------------------------------------------------

// Win64-Aufrufkonvention: A = RCX, B = RDX, N = R8, Ergebnis in XMM0.
// XMM0..XMM5 sind laut Win64-ABI fluechtig und duerfen frei benutzt werden.
// Zwei unabhaengige Teilsummen (XMM0/XMM1) je 4 Lanes, danach horizontale
// Summe, Rest (N mod 8) skalar.
function DotProductSse(A, B: PSingle; N: NativeInt): Single;
asm
  .NOFRAME
  xorps   xmm0, xmm0
  xorps   xmm1, xmm1
  mov     rax, r8
  shr     rax, 3
  test    rax, rax
  jz      @Reduce
@Loop8:
  movups  xmm2, [rcx]
  movups  xmm3, [rdx]
  mulps   xmm2, xmm3
  addps   xmm0, xmm2
  movups  xmm4, [rcx + 16]
  movups  xmm5, [rdx + 16]
  mulps   xmm4, xmm5
  addps   xmm1, xmm4
  add     rcx, 32
  add     rdx, 32
  dec     rax
  jnz     @Loop8
@Reduce:
  addps   xmm0, xmm1
  movaps  xmm1, xmm0
  shufps  xmm1, xmm1, $4E
  addps   xmm0, xmm1
  movaps  xmm1, xmm0
  shufps  xmm1, xmm1, $B1
  addps   xmm0, xmm1
  and     r8, 7
  jz      @Done
@Loop1:
  movss   xmm1, dword ptr [rcx]
  mulss   xmm1, dword ptr [rdx]
  addss   xmm0, xmm1
  add     rcx, 4
  add     rdx, 4
  dec     r8
  jnz     @Loop1
@Done:
end;

function DotProductPascal(A, B: PSingle; N: Integer): Double;
var
  K: Integer;
begin
  Result := 0;
  for K := 0 to N - 1 do
    Result := Result + A[K] * B[K];
end;

// modifizierte Besselfunktion 0. Ordnung (Reihenentwicklung) fuer das
// Kaiser-Fenster
function BesselI0(X: Double): Double;
var
  S, T: Double;
  K: Integer;
begin
  S := 1.0;
  T := 1.0;
  K := 1;
  repeat
    T := T * Sqr(X / (2.0 * K));
    S := S + T;
    Inc(K);
  until T < 1E-12 * S;
  Result := S;
end;

// -----------------------------------------------------------------------
// TS2400Resampler
// -----------------------------------------------------------------------

constructor TS2400Resampler.Create(AChannels: Integer; AInRate, AOutRate: Double;
  AStopbandDb: Double; APassbandHz: Double; APhases: Integer; AReserveFrames: Integer);
var
  FsMin, StopHz, PassHz, FPass, FStop, DeltaF, Fc, C, NTaps, I0Beta: Double;
  P, K: Integer;
  Tau, X, W, Ct, S, Sum: Double;
  Row: Integer;
begin
  inherited Create;
  if (AChannels < 1) or (AInRate <= 0) or (AOutRate <= 0) or (APhases < 2) then
    raise EArgumentException.Create('TS2400Resampler: ungueltige Parameter');

  FChannels := AChannels;
  FInRate := AInRate;
  FOutRate := AOutRate;
  FPhases := APhases;
  FCorrection := 1.0;
  FStep := AInRate / AOutRate;

  // Filterentwurf - alle Frequenzen in Zyklen pro Eingangssample
  FsMin := Min(AInRate, AOutRate);
  StopHz := FsMin / 2.0;
  PassHz := APassbandHz;
  if PassHz >= StopHz then
    PassHz := 0.9 * StopHz;
  FPass := PassHz / AInRate;
  FStop := StopHz / AInRate;
  DeltaF := FStop - FPass;
  Fc := (FPass + FStop) / 2.0;   // -6-dB-Punkt
  C := 2.0 * Fc;                 // sinc-Skalierung
  NTaps := (AStopbandDb - 7.95) / (14.36 * DeltaF);   // Kaiser-Formel
  FHalf := Ceil(NTaps / 2.0);
  FTaps := 2 * FHalf;
  if AStopbandDb > 50 then
    FBeta := 0.1102 * (AStopbandDb - 8.7)
  else
    FBeta := 0.5842 * Power(AStopbandDb - 21, 0.4) + 0.07886 * (AStopbandDb - 21);
  I0Beta := BesselI0(FBeta);

  // Tabelle T[p][k] = K(p/P + H - 1 - k), p = 0..P
  SetLength(FTable, (FPhases + 1) * FTaps);
  for P := 0 to FPhases do
  begin
    Row := P * FTaps;
    Sum := 0;
    for K := 0 to FTaps - 1 do
    begin
      Tau := P / FPhases + FHalf - 1 - K;
      X := Tau / FHalf;
      if Abs(X) >= 1.0 then
        W := 0.0
      else
        W := BesselI0(FBeta * Sqrt(1.0 - X * X)) / I0Beta;
      Ct := C * Tau;
      if Ct = 0.0 then
        S := 1.0
      else
        S := Sin(Pi * Ct) / (Pi * Ct);
      FTable[Row + K] := C * S * W;
      Sum := Sum + C * S * W;
    end;
    // jede Phase auf exakte Gleichspannungsverstaerkung 1 normieren
    for K := 0 to FTaps - 1 do
      FTable[Row + K] := FTable[Row + K] / Sum;
  end;

  SetLength(FCoef, FTaps);
  FCap := AReserveFrames + FTaps + 1024;
  SetLength(FBuf, FCap * FChannels);
  Reset;
end;

procedure TS2400Resampler.Reset;
var
  Ch: Integer;
begin
  // H Nullen Vorlauf je Kanal, damit die ersten Ausgangssamples volle
  // Historie haben
  for Ch := 0 to FChannels - 1 do
    FillChar((PSingle(Pointer(FBuf)) + Ch * FCap)^, FHalf * SizeOf(Single), 0);
  FFrames := FHalf;
  FTime := FHalf;
end;

procedure TS2400Resampler.EnsureCapacity(AFrames: Integer);
var
  NewCap, Ch: Integer;
  NewBuf: TArray<Single>;
begin
  // waechst nur im Ausnahmefall (z.B. Pull wurde lange nicht aufgerufen)
  if AFrames <= FCap then
    Exit;
  NewCap := AFrames + 4096;
  SetLength(NewBuf, NewCap * FChannels);
  for Ch := 0 to FChannels - 1 do
    Move((PSingle(Pointer(FBuf)) + Ch * FCap)^, (PSingle(Pointer(NewBuf)) + Ch * NewCap)^,
      FFrames * SizeOf(Single));
  FBuf := NewBuf;
  FCap := NewCap;
end;

procedure TS2400Resampler.Push(AData: PSingle; AFrames: Integer);
var
  Ch, I, C: Integer;
  Src, Dst: PSingle;
begin
  if AFrames <= 0 then
    Exit;
  EnsureCapacity(FFrames + AFrames);
  // interleaved -> planar
  C := FChannels;
  for Ch := 0 to C - 1 do
  begin
    Src := AData + Ch;
    Dst := PSingle(Pointer(FBuf)) + Ch * FCap + FFrames;
    for I := 0 to AFrames - 1 do
    begin
      Dst^ := Src^;
      Inc(Dst);
      Inc(Src, C);
    end;
  end;
  Inc(FFrames, AFrames);
end;

function TS2400Resampler.PendingInputFrames: Double;
begin
  Result := FFrames - FTime;
end;

function TS2400Resampler.Available: Integer;
var
  St, LastOk: Double;
begin
  St := FStep * FCorrection;
  // benoetigt: floor(t) + H <= Frames - 1
  LastOk := FFrames - 1 - FHalf;
  if FTime > LastOk then
    Exit(0);
  Result := Trunc((LastOk - FTime) / St) + 1;
end;

function TS2400Resampler.Pull(AData: PSingle; AMaxFrames: Integer): Integer;
var
  St, Frac, PF, A: Double;
  N, P, K, Ch, J0, Drop, C: Integer;
  R0, R1, Cf, Dst, BufBase: PSingle;
begin
  Result := 0;
  St := FStep * FCorrection;
  C := FChannels;
  Cf := PSingle(Pointer(FCoef));
  BufBase := PSingle(Pointer(FBuf));
  Dst := AData;

  while Result < AMaxFrames do
  begin
    N := Trunc(FTime); // FTime ist immer >= 0
    if N + FHalf > FFrames - 1 then
      Break;

    // Koeffizientenzeile zwischen den beiden benachbarten Phasen interpolieren
    Frac := FTime - N;
    PF := Frac * FPhases;
    P := Trunc(PF);
    A := PF - P;
    if P >= FPhases then
    begin
      P := FPhases - 1;
      A := 1.0;
    end;
    R0 := PSingle(Pointer(FTable)) + P * FTaps;
    R1 := R0 + FTaps;
    for K := 0 to FTaps - 1 do
      Cf[K] := R0[K] + A * (R1[K] - R0[K]);

    // Faltung pro Kanal: Eingangsframes J0 .. J0 + Taps - 1 liegen dank
    // planarer Ablage am Stueck -> SSE-Skalarprodukt
    J0 := N - FHalf + 1;
    for Ch := 0 to C - 1 do
    begin
      Dst^ := DotProductSse(BufBase + Ch * FCap + J0, Cf, FTaps);
      Inc(Dst);
    end;

    Inc(Result);
    FTime := FTime + St;
  end;

  // verbrauchte Frames verwerfen (alles vor floor(t) - H + 1)
  Drop := Trunc(FTime) - FHalf + 1;
  if Drop > FFrames then
    Drop := FFrames;
  if Drop > 0 then
  begin
    for Ch := 0 to C - 1 do
      Move((BufBase + Ch * FCap + Drop)^, (BufBase + Ch * FCap)^,
        (FFrames - Drop) * SizeOf(Single));
    Dec(FFrames, Drop);
    FTime := FTime - Drop;
  end;
end;

end.
