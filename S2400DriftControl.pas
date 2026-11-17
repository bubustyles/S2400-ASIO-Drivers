unit S2400DriftControl;

// =============================================================================
// S2400DriftControl.pas
//
// Bausteine fuer den Verbund-Treiber, Etappe B (30.10.2026): ein Geraet mit
// eigenem Quarz (die Isla) laeuft im Takt eines Master-Geraets mit (z.B. UAD
// Apollo, die ihrerseits dem Heritage per ADAT folgt).
//
//   TS2400DriftController - PI-Regler auf den tiefpassgefilterten,
//     ZEITKONTINUIERLICHEN Fuellstand; liefert die Feinkorrektur fuer
//     TS2400Resampler.Correction (Verhaeltnis ~1, einige ppm)
//   TS2400SpscFifo - sperrfreier Zwischenspeicher fuer genau EINEN
//     Schreiber (Isla-Thread) und EINEN Leser (Master-Rueckruf); keiner
//     wartet je auf den anderen. Bei Unterlauf wird die Fehlmenge als
//     Stille geliefert, MITGEZAEHLT und beim naechsten Lesen uebersprungen -
//     der Zeitbezug bleibt sampelgenau, der Regler wird nicht gestoert.
//
// Ausgelegt und getestet mit Referenz\drift_sim.py (30.10.2026):
//   Regelkreis 2. Ordnung, Periode 50 s, Daempfung 0,9, Tiefpass 1 s:
//   Kp = 2*zeta*wn/48000, Ki = wn^2/48000 (wn = 2*pi/50 s)
//   -> eingeschwungen auf 1 ppm nach 10..37 s, Mittelfehler < 0,1 ppm,
//      Restschwankung 3..15 ppm (unhoerbar, ~0,02 Cent)
//   Sollfuellstand = P + B + Reserve + 64 (P = Isla-Paket, B = Master-
//   Puffer). Reserve "Hoch" 5 ms: 0 Aussetzer bei 2-ms-Ausreissern (0,1 %)
//   und 4-ms-Ausreissern (0,01 %); "Normal" 2 ms: wenige Aussetzer.
//   Wichtig (erster Versuch): der Fuellstand muss zeitkontinuierlich
//   gemessen werden (gepufferte Frames + Zeit seit dem letzten Paket *
//   Rate), sonst tastet die Messung den Saegezahn aus P und B ab und der
//   Regler jagt Scheinschwankungen hinterher (30..180 ppm).
// =============================================================================

{$POINTERMATH ON}
{$OPTIMIZATION ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  TS2400DriftController = class
  private
    FTarget: Double;
    FKp, FKi: Double;
    FTau: Double;
    FLimit: Double;
    FLevel: Double;
    FHaveLevel: Boolean;
    FInteg: Double;
    FCorrection: Double;
  public
    // ATargetFrames: Sollfuellstand; APeriodS/AZeta: Regelkreis-Auslegung;
    // ATauS: Tiefpass des Fuellstands; ALimitPpm: maximale Korrektur
    constructor Create(ATargetFrames: Double; APeriodS: Double = 50.0;
      AZeta: Double = 0.9; ATauS: Double = 1.0; ALimitPpm: Double = 1000.0;
      ANominalRate: Double = 48000.0);
    procedure Reset;
    // ALevelFrames: zeitkontinuierlicher Fuellstand; ADtSeconds: Zeit seit
    // dem letzten Aufruf. Liefert die neue Korrektur (1.0 = keine).
    function Update(ALevelFrames, ADtSeconds: Double): Double;

    property Target: Double read FTarget write FTarget;
    property Correction: Double read FCorrection;
    property FilteredLevel: Double read FLevel;
    property Kp: Double read FKp;
    property Ki: Double read FKi;
  end;

  // Ringpuffer fuer interleavte Single-Frames. Schreib-/Lesezaehler laufen
  // als Int64 immer weiter (kein Ueberlauf in der Praxis), die Position im
  // Ring ist Zaehler mod Kapazitaet.
  TS2400SpscFifo = class
  private
    FChannels: Integer;
    FCapacity: Integer;           // Frames
    FData: TArray<Single>;
    FWriteCount: Int64;           // nur vom Schreiber veraendert
    FReadCount: Int64;            // nur vom Leser veraendert
    FDeficit: Int64;              // nur vom Leser: als Stille gelieferte, noch zu ueberspringende Frames
    FLastStampQpc: Int64;         // nur vom Schreiber: Zeitpunkt, bis zu dem Daten geschrieben sind
    FUnderruns: Int64;            // nur vom Leser
    FOverruns: Int64;             // nur vom Schreiber
  public
    constructor Create(AChannels, ACapacityFrames: Integer);
    procedure Reset;

    // --- Schreiber (genau ein Thread) ---
    // schreibt AFrames Frames; AStampQpc = QPC-Zeitpunkt, zu dem das LETZTE
    // geschriebene Sample aufgenommen wurde (fuer den zeitkontinuierlichen
    // Fuellstand). Liefert False bei Ueberlauf (Daten verworfen).
    function Write(AData: System.PSingle; AFrames: Integer; AStampQpc: Int64): Boolean;

    // --- Leser (genau ein Thread) ---
    // gepufferte Frames abzueglich offener Fehlmenge (kann negativ sein)
    function Level: Int64;
    // liest genau AFrames Frames; fehlende werden als Stille geliefert und
    // als Fehlmenge gemerkt (Result = tatsaechlich gelesene Frames)
    function Read(AData: System.PSingle; AFrames: Integer): Integer;
    // QPC-Zeitpunkt des zuletzt geschriebenen Samples (vom Schreiber)
    function LastStampQpc: Int64;

    property Channels: Integer read FChannels;
    property Capacity: Integer read FCapacity;
    property Underruns: Int64 read FUnderruns;
    property Overruns: Int64 read FOverruns;
  end;

implementation

// -----------------------------------------------------------------------
// TS2400DriftController
// -----------------------------------------------------------------------

constructor TS2400DriftController.Create(ATargetFrames, APeriodS, AZeta, ATauS,
  ALimitPpm, ANominalRate: Double);
var
  Wn: Double;
begin
  inherited Create;
  FTarget := ATargetFrames;
  Wn := 2 * Pi / APeriodS;
  FKi := Wn * Wn / ANominalRate;
  FKp := 2 * AZeta * Wn / ANominalRate;
  FTau := ATauS;
  FLimit := ALimitPpm * 1E-6;
  Reset;
end;

procedure TS2400DriftController.Reset;
begin
  FHaveLevel := False;
  FLevel := 0;
  FInteg := 0;
  FCorrection := 1.0;
end;

function TS2400DriftController.Update(ALevelFrames, ADtSeconds: Double): Double;
var
  A, Err, LimI, C: Double;
begin
  if not FHaveLevel then
  begin
    FLevel := ALevelFrames;
    FHaveLevel := True;
  end;
  if ADtSeconds < 0 then
    ADtSeconds := 0;
  A := ADtSeconds / (FTau + ADtSeconds);
  FLevel := FLevel + A * (ALevelFrames - FLevel);
  Err := FLevel - FTarget;
  // Bedingte Integration (Anti-Windup): steht der Regler am Anschlag und
  // zeigt der Fehler in dieselbe Richtung, NICHT weiter aufintegrieren.
  // Sonst schiesst der Regler nach einem zu vollen/leeren Start ueber das
  // Ziel hinaus und der Speicher laeuft leer - S2400DriftTest 30.10.2026:
  // 682 Unterlaeufe im Anlauf (P=256, B=512); drift-Simulation: 1487..2224
  // ohne, 0 mit bedingter Integration bei 300..1200 Frames Startfehler.
  C := FKp * Err + FKi * (FInteg + Err * ADtSeconds);
  if not ((Abs(C) >= FLimit) and ((C > 0) = (Err > 0))) then
    FInteg := FInteg + Err * ADtSeconds;
  // zusaetzlich: Integralanteil allein darf die Grenze nicht ueberschreiten
  LimI := FLimit / FKi;
  if FInteg > LimI then
    FInteg := LimI
  else if FInteg < -LimI then
    FInteg := -LimI;
  C := FKp * Err + FKi * FInteg;
  if C > FLimit then
    C := FLimit
  else if C < -FLimit then
    C := -FLimit;
  FCorrection := 1.0 + C;
  Result := FCorrection;
end;

// -----------------------------------------------------------------------
// TS2400SpscFifo
// -----------------------------------------------------------------------

var
  GFenceDummy: Integer;

// vollstaendige Speicherbarriere (LOCK-praefixierter Zugriff): Daten
// werden sichtbar, BEVOR der Zaehler sie freigibt
procedure Fence; inline;
begin
  TInterlocked.Exchange(GFenceDummy, 0);
end;

constructor TS2400SpscFifo.Create(AChannels, ACapacityFrames: Integer);
begin
  inherited Create;
  FChannels := AChannels;
  FCapacity := ACapacityFrames;
  SetLength(FData, FChannels * FCapacity);
  Reset;
end;

procedure TS2400SpscFifo.Reset;
begin
  FWriteCount := 0;
  FReadCount := 0;
  FDeficit := 0;
  FLastStampQpc := 0;
  FUnderruns := 0;
  FOverruns := 0;
end;

function TS2400SpscFifo.Write(AData: System.PSingle; AFrames: Integer; AStampQpc: Int64): Boolean;
var
  W, R: Int64;
  Pos, First: Integer;
begin
  W := FWriteCount;
  R := TInterlocked.Read(FReadCount);
  if W + AFrames - R > FCapacity then
  begin
    Inc(FOverruns);
    Exit(False);
  end;
  Pos := W mod FCapacity;
  First := FCapacity - Pos;
  if First > AFrames then
    First := AFrames;
  Move(AData^, (System.PSingle(Pointer(FData)) + Pos * FChannels)^, First * FChannels * SizeOf(Single));
  if First < AFrames then
    Move((AData + First * FChannels)^, System.PSingle(Pointer(FData))^,
      (AFrames - First) * FChannels * SizeOf(Single));
  FLastStampQpc := AStampQpc;
  Fence;
  TInterlocked.Exchange(FWriteCount, W + AFrames); // freigeben
  Result := True;
end;

function TS2400SpscFifo.Level: Int64;
begin
  Result := TInterlocked.Read(FWriteCount) - FReadCount - FDeficit;
end;

function TS2400SpscFifo.LastStampQpc: Int64;
begin
  Result := TInterlocked.Read(FLastStampQpc);
end;

function TS2400SpscFifo.Read(AData: System.PSingle; AFrames: Integer): Integer;
var
  W, R, Avail, Skip: Int64;
  N, Pos, First: Integer;
begin
  W := TInterlocked.Read(FWriteCount);
  Fence;
  R := FReadCount;
  Avail := W - R;

  // zuerst offene Fehlmenge ueberspringen (diese Samples wurden bereits als
  // Stille ausgegeben - so bleibt der Zeitbezug sampelgenau)
  if FDeficit > 0 then
  begin
    Skip := FDeficit;
    if Skip > Avail then
      Skip := Avail;
    Inc(R, Skip);
    Dec(Avail, Skip);
    Dec(FDeficit, Skip);
  end;

  N := AFrames;
  if Avail < N then
    N := Avail;

  if N > 0 then
  begin
    Pos := R mod FCapacity;
    First := FCapacity - Pos;
    if First > N then
      First := N;
    Move((System.PSingle(Pointer(FData)) + Pos * FChannels)^, AData^, First * FChannels * SizeOf(Single));
    if First < N then
      Move(System.PSingle(Pointer(FData))^, (AData + First * FChannels)^,
        (N - First) * FChannels * SizeOf(Single));
    Inc(R, N);
  end;

  if N < AFrames then
  begin
    // Unterlauf: Rest als Stille, Fehlmenge merken
    FillChar((AData + N * FChannels)^, (AFrames - N) * FChannels * SizeOf(Single), 0);
    Inc(FDeficit, AFrames - N);
    Inc(FUnderruns);
  end;

  Fence;
  TInterlocked.Exchange(FReadCount, R); // Platz freigeben
  Result := N;
end;

end.
