unit S2400ZsDsp;

// =============================================================================
// S2400ZsDsp.pas - Rechenteil des Isla-Zuspielers (08.11.2026)
//
//   Plattenspieler  schneller/langsamer abspielen = Tempo und Tonhoehe
//                   gemeinsam (wie 33 -> 45 U/min). Umsetzung als
//                   Abtastraten-Umrechnung mit S2400Resampler (Kaiser-Sinc,
//                   mit Tiefpass vor dem Beschleunigen - kein Aliasing).
//   Pitch           Tonhoehe aendern, Tempo bleibt: zuerst die Laenge per
//                   WSOLA um den Faktor 2^(HT/12) strecken, dann um denselben
//                   Faktor schneller abspielen. Beide Schritte zusammen mit
//                   dem Plattenspieler in EINER Umrechnung.
//   Tonart          Chroma (FFT, Energie je Halbton-Klasse) gegen die Profile
//                   nach Krumhansl-Kessler (24 Tonarten)
//   Tempo           aus der Laenge eines Loops (ganze Zahl von Schlaegen,
//                   Ergebnis zwischen 70 und 140 BPM)
//
// Alles wird vorab fertig gerechnet (die Samples sind kurz); die Wiedergabe
// liest dann nur noch den fertigen Puffer in der Rate des Ausgabegeraets.
// =============================================================================

{$POINTERMATH ON}
{$OPTIMIZATION ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

interface

uses
  System.SysUtils,
  System.Math,
  S2400AudioFile;

// fertiger Wiedergabepuffer (Stereo interleaved, Rate AOutRate):
// Bereich AStart..AEnd (Anteile 0..1 der Datei), Pitch in Halbtoenen
// (Tempo bleibt), ASpeed = Plattenspieler-Faktor (1 = Original)
function S2400RenderTrack(const AAudio: TS2400Audio; AStart, AEnd, ASemis, ASpeed: Double;
  AOutRate: Integer): TArray<Single>;

// Tonart messen; False = keine eindeutige Tonart (z.B. Drums)
function S2400DetectKey(const AAudio: TS2400Audio; out APc: Integer; out AMinor: Boolean): Boolean;

// Tempo aus der Laenge (0 = kein Loop erkennbar, z.B. One-Shot)
function S2400BpmFromLength(AFrames, ARate: Integer): Double;

// Huellkurve fuer die Wellenform: AColumns Spitzenwerte 0..1
function S2400Envelope(const AAudio: TS2400Audio; AColumns: Integer): TArray<Single>;

// Anschlaege (Einzelsounds) in einem Drumloop: Frames im Bereich
// AStart..AEnd (Frames der Datei), aufsteigend, ohne AStart selbst.
// ASens 0..100: hoeher = auch schwaechere Anstiege (Ghost Notes, weiche Toene)
// AThrDb -60..0: Schwelle - nur Schlaege, die hoechstens so weit unter dem
// lautesten liegen (-20 = nur die lauten, -60 = fast alles)
function S2400DetectOnsets(const AAudio: TS2400Audio; AStart, AEnd, ASens, AThrDb: Integer): TArray<Integer>;

implementation

uses
  S2400Resampler;

// ---------------------------------------------------------------------------
// Plattenspieler: Umrechnung mit Geschwindigkeitsfaktor
// ---------------------------------------------------------------------------

function ResampleSpeed(const ASrc: TArray<Single>; AFrames, ASrcRate: Integer; ASpeed: Double;
  AOutRate: Integer): TArray<Single>;
var
  R: TS2400Resampler;
  InRate: Double;
  Zero: TArray<Single>;
  Want, Got: Integer;
begin
  Result := nil;
  if AFrames <= 0 then
    Exit;
  InRate := ASrcRate * ASpeed;
  if Abs(InRate - AOutRate) < 0.01 then
    Exit(Copy(ASrc, 0, AFrames * 2));
  // 80 dB Sperrdaempfung reichen (die Isla sampelt mit 12 Bit, ~72 dB) und
  // halten das Filter kurz; Durchlass bis 18 kHz
  R := TS2400Resampler.Create(2, InRate, AOutRate, 80.0, 18000.0, 512, AFrames + 64);
  try
    R.Push(System.PSingle(Pointer(ASrc)), AFrames);
    SetLength(Zero, (R.LatencyInputFrames + 64) * 2);
    R.Push(System.PSingle(Pointer(Zero)), R.LatencyInputFrames + 64);
    Want := Ceil(AFrames * (AOutRate / InRate));
    SetLength(Result, (Want + 1) * 2);
    Got := R.Pull(System.PSingle(Pointer(Result)), Want);
    SetLength(Result, Got * 2);
  finally
    R.Free;
  end;
end;

// ---------------------------------------------------------------------------
// WSOLA: Laenge um AAlpha strecken, Tonhoehe bleibt
// ---------------------------------------------------------------------------

function StretchWsola(const ASrc: TArray<Single>; AFrames, ARate: Integer; AAlpha: Double): TArray<Single>;
var
  N, Hs, Delta, G, Lp, OutFrames, OutTotal, K, P, Prev, Nominal, Natural, Cand, Best, J, Lo, Hi, Idx: Integer;
  Xm, Xs, Win, OutBuf: TArray<Single>;
  Score, BestScore, C, E, W, NatE: Double;
  PM: System.PSingle;
begin
  if (AFrames <= 0) or (Abs(AAlpha - 1) < 1E-5) then
    Exit(Copy(ASrc, 0, AFrames * 2));

  // Rahmen ~46 ms, halbe Ueberlappung, Suchbereich +-1/4 Rahmen
  if ARate <= 50000 then N := 2048
  else if ARate <= 100000 then N := 4096
  else N := 8192;
  Hs := N div 2;
  Delta := N div 4;
  G := N + Delta;              // Schutzbereich vorn und hinten (Nullen)

  // Eingang: Hs Nullen vor dem Signal (damit der Anfang voll zaehlt),
  // in "gepolsterten" Koordinaten liegt Index i bei Array-Index i + G
  Lp := AFrames + Hs;
  SetLength(Xm, Lp + 2 * G + N);
  SetLength(Xs, (Lp + 2 * G + N) * 2);
  for J := 0 to AFrames - 1 do
  begin
    Idx := J + Hs + G;
    Xs[2 * Idx] := ASrc[2 * J];
    Xs[2 * Idx + 1] := ASrc[2 * J + 1];
    Xm[Idx] := 0.5 * (ASrc[2 * J] + ASrc[2 * J + 1]);
  end;

  SetLength(Win, N);
  for J := 0 to N - 1 do
    Win[J] := 0.5 - 0.5 * Cos(2 * Pi * J / N); // periodisches Hann: Summe bei Hs-Versatz = 1

  OutFrames := Round(AFrames * AAlpha);
  OutTotal := OutFrames + Hs;
  SetLength(OutBuf, (OutTotal + N + Hs) * 2);
  PM := System.PSingle(Pointer(Xm)) + G;

  K := 0;
  Prev := 0;
  while K * Hs < OutTotal do
  begin
    if K = 0 then
      P := 0
    else
    begin
      Nominal := Round(K * Hs / AAlpha);
      Natural := Prev + Hs;
      if Nominal > Lp then
        Nominal := Lp;
      Lo := Nominal - Delta;
      Hi := Nominal + Delta;
      // natuerliche Fortsetzung still -> keine Suche
      NatE := 0;
      J := 0;
      while J < Hs do
      begin
        NatE := NatE + Sqr(PM[Natural + J]);
        Inc(J, 4);
      end;
      if NatE < 1E-9 then
        P := Nominal
      else
      begin
        // grob: jeder 4. Versatz, jedes 4. Sample
        Best := Nominal;
        BestScore := -1E30;
        Cand := Lo;
        while Cand <= Hi do
        begin
          C := 0;
          E := 0;
          J := 0;
          while J < Hs do
          begin
            W := PM[Cand + J];
            C := C + W * PM[Natural + J];
            E := E + W * W;
            Inc(J, 4);
          end;
          Score := C / Sqrt(E + 1E-9);
          if Score > BestScore then
          begin
            BestScore := Score;
            Best := Cand;
          end;
          Inc(Cand, 4);
        end;
        // fein: +-3 um das grobe Ergebnis, alle Samples
        P := Best;
        BestScore := -1E30;
        for Cand := Max(Lo, Best - 3) to Min(Hi, Best + 3) do
        begin
          C := 0;
          E := 0;
          for J := 0 to Hs - 1 do
          begin
            W := PM[Cand + J];
            C := C + W * PM[Natural + J];
            E := E + W * W;
          end;
          Score := C / Sqrt(E + 1E-9);
          if Score > BestScore then
          begin
            BestScore := Score;
            P := Cand;
          end;
        end;
      end;
    end;

    // gefensterter Rahmen dazu (Ueberlappen und Addieren)
    for J := 0 to N - 1 do
    begin
      W := Win[J];
      Idx := P + J + G;
      OutBuf[2 * (K * Hs + J)] := OutBuf[2 * (K * Hs + J)] + W * Xs[2 * Idx];
      OutBuf[2 * (K * Hs + J) + 1] := OutBuf[2 * (K * Hs + J) + 1] + W * Xs[2 * Idx + 1];
    end;
    Prev := P;
    Inc(K);
  end;

  // die vorgesetzten Hs Nullen wieder weg
  Result := Copy(OutBuf, 2 * Hs, 2 * OutFrames);
end;

function S2400RenderTrack(const AAudio: TS2400Audio; AStart, AEnd, ASemis, ASpeed: Double;
  AOutRate: Integer): TArray<Single>;
var
  S0, S1, N, I, F, FadeIn, FadeOut: Integer;
  Region, Stretched: TArray<Single>;
  Alpha, G: Double;
begin
  Result := nil;
  if (AAudio.Frames <= 0) or (AOutRate <= 0) or (ASpeed <= 0) then
    Exit;
  if AStart < 0 then AStart := 0;
  if AEnd > 1 then AEnd := 1;
  S0 := Trunc(AStart * AAudio.Frames);
  S1 := Round(AEnd * AAudio.Frames);
  if S1 > AAudio.Frames then
    S1 := AAudio.Frames;
  N := S1 - S0;
  if N < 32 then
    Exit;
  Region := Copy(AAudio.Data, 2 * S0, 2 * N);

  // kurze Blende an gesetzten Marken (kein Knacken an der Schleifennaht);
  // am echten Dateianfang/-ende bleibt der Einsatz unangetastet
  FadeIn := 0;
  FadeOut := 0;
  if S0 > 0 then
    FadeIn := AAudio.Rate div 1000;        // 1 ms
  if S1 < AAudio.Frames then
    FadeOut := 3 * AAudio.Rate div 1000;   // 3 ms
  for I := 0 to Min(FadeIn, N) - 1 do
  begin
    G := I / FadeIn;
    Region[2 * I] := Region[2 * I] * G;
    Region[2 * I + 1] := Region[2 * I + 1] * G;
  end;
  for I := 0 to Min(FadeOut, N) - 1 do
  begin
    F := N - 1 - I;
    G := I / FadeOut;
    Region[2 * F] := Region[2 * F] * G;
    Region[2 * F + 1] := Region[2 * F + 1] * G;
  end;

  if Abs(ASemis) > 0.001 then
  begin
    Alpha := Power(2, ASemis / 12);
    Stretched := StretchWsola(Region, N, AAudio.Rate, Alpha);
    Region := nil;
    Result := ResampleSpeed(Stretched, Length(Stretched) div 2, AAudio.Rate, ASpeed * Alpha, AOutRate);
  end
  else
    Result := ResampleSpeed(Region, N, AAudio.Rate, ASpeed, AOutRate);
end;

// ---------------------------------------------------------------------------
// FFT (radix 2, in place)
// ---------------------------------------------------------------------------

procedure Fft(var Re, Im: TArray<Double>; N: Integer);
var
  I, J, K, M, Step: Integer;
  T, Ang, WR, WI, CR, CI, TR, TI: Double;
begin
  J := 0;
  for I := 0 to N - 2 do
  begin
    if I < J then
    begin
      T := Re[I]; Re[I] := Re[J]; Re[J] := T;
      T := Im[I]; Im[I] := Im[J]; Im[J] := T;
    end;
    K := N shr 1;
    while (K >= 1) and (J >= K) do
    begin
      Dec(J, K);
      K := K shr 1;
    end;
    Inc(J, K);
  end;
  Step := 1;
  while Step < N do
  begin
    Ang := -Pi / Step;
    WR := Cos(Ang);
    WI := Sin(Ang);
    M := 0;
    while M < N do
    begin
      CR := 1;
      CI := 0;
      for K := 0 to Step - 1 do
      begin
        I := M + K;
        J := I + Step;
        TR := CR * Re[J] - CI * Im[J];
        TI := CR * Im[J] + CI * Re[J];
        Re[J] := Re[I] - TR;
        Im[J] := Im[I] - TI;
        Re[I] := Re[I] + TR;
        Im[I] := Im[I] + TI;
        T := CR * WR - CI * WI;
        CI := CR * WI + CI * WR;
        CR := T;
      end;
      Inc(M, 2 * Step);
    end;
    Step := Step * 2;
  end;
end;

// ---------------------------------------------------------------------------
// Tonart
// ---------------------------------------------------------------------------

const
  C_PROFILE_MAJOR: array[0..11] of Double = (6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88);
  C_PROFILE_MINOR: array[0..11] of Double = (6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17);

function Correlate(const AChroma: array of Double; const AProfile: array of Double; ARoot: Integer): Double;
var
  I: Integer;
  MA, MB, SAB, SAA, SBB, A, B: Double;
begin
  MA := 0;
  MB := 0;
  for I := 0 to 11 do
  begin
    MA := MA + AChroma[(I + ARoot) mod 12];
    MB := MB + AProfile[I];
  end;
  MA := MA / 12;
  MB := MB / 12;
  SAB := 0;
  SAA := 0;
  SBB := 0;
  for I := 0 to 11 do
  begin
    A := AChroma[(I + ARoot) mod 12] - MA;
    B := AProfile[I] - MB;
    SAB := SAB + A * B;
    SAA := SAA + A * A;
    SBB := SBB + B * B;
  end;
  if (SAA <= 0) or (SBB <= 0) then
    Exit(0);
  Result := SAB / Sqrt(SAA * SBB);
end;

function S2400DetectKey(const AAudio: TS2400Audio; out APc: Integer; out AMinor: Boolean): Boolean;
var
  N, Hop, Frames, Pos, I, K, Pc, Root: Integer;
  Re, Im, Win, BinPc: TArray<Double>;
  Chroma: array[0..11] of Double;
  F, Midi, Mag, Total, R, BestR, SecondR: Double;
begin
  Result := False;
  APc := -1;
  AMinor := False;
  if AAudio.Frames < AAudio.Rate div 2 then
    Exit; // unter 0,5 s: keine Aussage
  if AAudio.Rate <= 50000 then N := 8192 else N := 16384;
  Hop := N div 2;
  Frames := Min(AAudio.Frames, AAudio.Rate * 30);
  SetLength(Re, N);
  SetLength(Im, N);
  SetLength(Win, N);
  for I := 0 to N - 1 do
    Win[I] := 0.5 - 0.5 * Cos(2 * Pi * I / N);
  // Halbton-Klasse je FFT-Bin (nur 100 Hz .. 2,1 kHz, -1 = ignorieren)
  SetLength(BinPc, N div 2);
  for K := 0 to N div 2 - 1 do
  begin
    F := K * AAudio.Rate / N;
    if (F < 100) or (F > 2100) then
      BinPc[K] := -1
    else
    begin
      Midi := 69 + 12 * Log2(F / 440);
      BinPc[K] := ((Round(Midi) mod 12) + 12) mod 12;
    end;
  end;
  FillChar(Chroma, SizeOf(Chroma), 0);
  Total := 0;
  Pos := 0;
  repeat
    for I := 0 to N - 1 do
    begin
      if Pos + I < Frames then
        Re[I] := Win[I] * 0.5 * (AAudio.Data[2 * (Pos + I)] + AAudio.Data[2 * (Pos + I) + 1])
      else
        Re[I] := 0;
      Im[I] := 0;
    end;
    Fft(Re, Im, N);
    for K := 1 to N div 2 - 1 do
      if BinPc[K] >= 0 then
      begin
        Mag := Sqrt(Re[K] * Re[K] + Im[K] * Im[K]);
        Pc := Round(BinPc[K]);
        Chroma[Pc] := Chroma[Pc] + Mag;
        Total := Total + Mag;
      end;
    Inc(Pos, Hop);
  until Pos >= Frames;
  if Total < 1E-3 then
    Exit;

  BestR := -2;
  SecondR := -2;
  for Root := 0 to 11 do
  begin
    R := Correlate(Chroma, C_PROFILE_MAJOR, Root);
    if R > BestR then
    begin
      SecondR := BestR;
      BestR := R;
      APc := Root;
      AMinor := False;
    end
    else if R > SecondR then
      SecondR := R;
    R := Correlate(Chroma, C_PROFILE_MINOR, Root);
    if R > BestR then
    begin
      SecondR := BestR;
      BestR := R;
      APc := Root;
      AMinor := True;
    end
    else if R > SecondR then
      SecondR := R;
  end;
  // nur eindeutige Ergebnisse anzeigen (Drums haben ein flaches Chroma)
  Result := BestR >= 0.65;
  if not Result then
    APc := -1;
end;

function S2400BpmFromLength(AFrames, ARate: Integer): Double;
var
  L, B: Double;
  N: Integer;
begin
  Result := 0;
  if (ARate <= 0) or (AFrames <= 0) then
    Exit;
  L := AFrames / ARate;
  if L < 1.0 then
    Exit; // One-Shot
  N := 1;
  while N <= 256 do
  begin
    B := 60 * N / L;
    if (B >= 70) and (B < 140) then
      Exit(B);
    N := N * 2;
  end;
end;

function S2400Envelope(const AAudio: TS2400Audio; AColumns: Integer): TArray<Single>;
var
  C, I, I0, I1: Integer;
  M, V: Single;
begin
  Result := nil;
  if (AAudio.Frames <= 0) or (AColumns <= 0) then
    Exit;
  SetLength(Result, AColumns);
  for C := 0 to AColumns - 1 do
  begin
    I0 := Int64(C) * AAudio.Frames div AColumns;
    I1 := Int64(C + 1) * AAudio.Frames div AColumns;
    if I1 <= I0 then
      I1 := I0 + 1;
    if I1 > AAudio.Frames then
      I1 := AAudio.Frames;
    M := 0;
    for I := I0 to I1 - 1 do
    begin
      V := Abs(AAudio.Data[2 * I]);
      if V > M then M := V;
      V := Abs(AAudio.Data[2 * I + 1]);
      if V > M then M := V;
    end;
    if M > 1 then
      M := 1;
    Result[C] := M;
  end;
end;

// ---------------------------------------------------------------------------
// Anschlaege: Pegelanstieg je ~5 ms, einmal breitbandig und einmal ueber die
// erste Differenz (betont Hoehen - so fallen auch Hi-Hats auf, die im
// Ausklang einer Bassdrum liegen). Danach Feinlage auf das Sample genau.
// ---------------------------------------------------------------------------

function S2400DetectOnsets(const AAudio: TS2400Audio; AStart, AEnd, ASens, AThrDb: Integer): TArray<Integer>;
const
  C_MAX_ONSETS = 64;
var
  Hop, Win, NH, K, I, I0, I1, MinGap, LastOn, Best, Back: Integer;
  Lf, Lh, Nov: TArray<Double>;
  Ef, Eh, M, Prev, MaxF, MaxH, Thr, FloorDb, Rf, Rh, Pk, V: Double;

  function MonoAt(AI: Integer): Double;
  begin
    Result := 0.5 * (AAudio.Data[2 * AI] + AAudio.Data[2 * AI + 1]);
  end;

begin
  Result := nil;
  if AStart < 0 then AStart := 0;
  if AEnd > AAudio.Frames then AEnd := AAudio.Frames;
  if (AAudio.Rate <= 0) or (AEnd - AStart < 1024) then
    Exit;
  if ASens < 0 then ASens := 0;
  if ASens > 100 then ASens := 100;

  Hop := AAudio.Rate div 200;          // 5 ms
  if Hop < 64 then Hop := 64;
  Win := 2 * Hop;
  NH := (AEnd - AStart - Win) div Hop;
  if NH < 3 then
    Exit;
  SetLength(Lf, NH);
  SetLength(Lh, NH);
  SetLength(Nov, NH);
  MaxF := -200;
  MaxH := -200;
  for K := 0 to NH - 1 do
  begin
    I0 := AStart + K * Hop;
    Ef := 0;
    Eh := 0;
    Prev := MonoAt(I0);
    for I := I0 to I0 + Win - 1 do
    begin
      M := MonoAt(I);
      Ef := Ef + M * M;
      Eh := Eh + Sqr(M - Prev);
      Prev := M;
    end;
    Lf[K] := 10 * Log10(Ef / Win + 1E-12);
    Lh[K] := 10 * Log10(Eh / Win + 1E-12);
    if Lf[K] > MaxF then MaxF := Lf[K];
    if Lh[K] > MaxH then MaxH := Lh[K];
  end;

  // Empfindlichkeit: noetiger Pegelanstieg, 0 = 12 dB (nur deutliche
  // Schlaege), 100 = 2 dB (auch Ghost Notes). Schwelle: wie weit unter dem
  // lautesten ein Schlag noch zaehlt.
  Thr := 12 - 0.1 * ASens;
  if AThrDb > 0 then AThrDb := 0;
  if AThrDb < -60 then AThrDb := -60;
  FloorDb := -AThrDb;
  for K := 2 to NH - 1 do
  begin
    Rf := Lf[K] - Min(Lf[K - 1], Lf[K - 2]);
    Rh := Lh[K] - Min(Lh[K - 1], Lh[K - 2]);
    if (Rf < Thr) or (Lf[K] < MaxF - FloorDb) then
      Rf := 0;
    if (Rh < Thr) or (Lh[K] < MaxH - FloorDb) then
      Rh := 0;
    Nov[K] := Max(Rf, Rh);
  end;

  MinGap := (AAudio.Rate * 45) div 1000;   // 45 ms: Flams zaehlen als ein Schlag
  LastOn := AStart;
  Back := AAudio.Rate div 1000;            // 1 ms vor den Einsatz
  for K := 2 to NH - 2 do
  begin
    if (Nov[K] <= 0) or (Nov[K] < Nov[K - 1]) or (Nov[K] < Nov[K + 1]) then
      Continue;
    // Feinlage: erstes Sample ueber 30 % der Spitze im Umfeld
    I0 := AStart + (K - 1) * Hop;
    I1 := AStart + (K + 1) * Hop + Win;
    if I1 > AEnd then I1 := AEnd;
    Pk := 0;
    for I := I0 to I1 - 1 do
    begin
      V := Abs(MonoAt(I));
      if V > Pk then Pk := V;
    end;
    if Pk <= 0 then
      Continue;
    Best := I0;
    for I := I0 to I1 - 1 do
      if Abs(MonoAt(I)) >= 0.3 * Pk then
      begin
        Best := I;
        Break;
      end;
    Best := Best - Back;
    if Best - LastOn < MinGap then
      Continue;
    Result := Result + [Best];
    LastOn := Best;
    if Length(Result) >= C_MAX_ONSETS then
      Break;
  end;
end;

end.
