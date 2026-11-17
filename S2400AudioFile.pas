unit S2400AudioFile;

// =============================================================================
// S2400AudioFile.pas - Audiodateien laden fuer den Isla-Zuspieler (08.11.2026)
//
//   WAV   PCM 8/16/24/32 Bit, Float 32/64 Bit, auch WAVE_FORMAT_EXTENSIBLE
//   AIFF  PCM 8/16/24/32 Bit (big endian)
//   AIFC  NONE, sowt (little endian), fl32, fl64
//
// Ergebnis immer Stereo, interleaved Single (Mono wird auf beide Seiten
// gelegt, bei mehr als zwei Kanaelen zaehlen die ersten beiden).
//
// Dazu: Tempo und Tonart aus dem Dateinamen. Splice schreibt beides fast
// immer hinein, z.B. "OS_SK_92_keys_loop_Cmin.wav", "Soul_Keys_Cm_92bpm.wav",
// "RU_drum_loop_88_A_minor.wav".
// =============================================================================

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math;

type
  TS2400Audio = record
    Rate: Integer;
    Frames: Integer;
    Data: TArray<Single>;   // Stereo, interleaved
  end;

  TS2400NameInfo = record
    Bpm: Double;            // 0 = nicht im Namen
    KeyPc: Integer;         // Tonart: 0 = C .. 11 = H; -1 = nicht im Namen
    Minor: Boolean;
  end;

  // Stem aus einem Splice-Stack-Export ("Stems"), Dateiname
  // "<Stack> - 87 BPM - 1 - Others - <Originalname>.wav". Splice hat alle
  // Stems schon auf Tempo und Tonart des Stacks gebracht, gleich lang, ab
  // Takt 1 (geprueft am Export "Shwing Mudslide", 09.11.2026).
  TS2400StemInfo = record
    Stack: string;          // Name des Stacks
    Bpm: Double;            // Tempo des Stacks
    Number: Integer;        // Reihenfolge im Stack (1..)
    Part: string;           // "Drums", "Others", "Bass" ...
  end;

function S2400LoadAudio(const AFileName: string; out AAudio: TS2400Audio; out AError: string): Boolean;
function S2400IsAudioFile(const AFileName: string): Boolean;
// Stereo-WAV schreiben, 24 Bit PCM (AData interleaved, -1..1)
function S2400SaveWav24(const AFileName: string; const AData: TArray<Single>; AFrames, ARate: Integer;
  out AError: string): Boolean;

function S2400ParseSampleName(const AFileName: string): TS2400NameInfo;
function S2400SpliceStem(const AFileName: string; out AInfo: TS2400StemInfo): Boolean;
// "C", "C#m", ... (APc < 0 = Gedankenstrich)
function S2400KeyName(APc: Integer; AMinor: Boolean): string;

implementation

uses
  S2400Lang;

const
  C_MAX_FILE_BYTES = 512 * 1024 * 1024;
  C_NOTE_NAMES: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');

function S2400IsAudioFile(const AFileName: string): Boolean;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(AFileName));
  Result := (E = '.wav') or (E = '.aif') or (E = '.aiff') or (E = '.aifc');
end;

function S2400KeyName(APc: Integer; AMinor: Boolean): string;
begin
  if (APc < 0) or (APc > 11) then
    Exit(#$2014);
  Result := C_NOTE_NAMES[APc];
  if AMinor then
    Result := Result + 'm';
end;

// ---------------------------------------------------------------------------
// Lesehilfen
// ---------------------------------------------------------------------------

function RdLE16(const B: TBytes; P: Integer): Integer; inline;
begin
  Result := SmallInt(B[P] or (B[P + 1] shl 8));
end;

function RdLE16U(const B: TBytes; P: Integer): Cardinal; inline;
begin
  Result := B[P] or (B[P + 1] shl 8);
end;

function RdLE32(const B: TBytes; P: Integer): Cardinal; inline;
begin
  Result := Cardinal(B[P]) or (Cardinal(B[P + 1]) shl 8) or (Cardinal(B[P + 2]) shl 16) or (Cardinal(B[P + 3]) shl 24);
end;

function RdBE16U(const B: TBytes; P: Integer): Cardinal; inline;
begin
  Result := (B[P] shl 8) or B[P + 1];
end;

function RdBE32(const B: TBytes; P: Integer): Cardinal; inline;
begin
  Result := (Cardinal(B[P]) shl 24) or (Cardinal(B[P + 1]) shl 16) or (Cardinal(B[P + 2]) shl 8) or Cardinal(B[P + 3]);
end;

function Tag4(const B: TBytes; P: Integer): AnsiString;
begin
  SetLength(Result, 4);
  Result[1] := AnsiChar(B[P]);
  Result[2] := AnsiChar(B[P + 1]);
  Result[3] := AnsiChar(B[P + 2]);
  Result[4] := AnsiChar(B[P + 3]);
end;

// 80-Bit-Gleitkommazahl (IEEE 754 extended, big endian) der AIFF-Rate
function RdExt80(const B: TBytes; P: Integer): Double;
var
  Expo: Integer;
  Mant: UInt64;
  I: Integer;
  Neg: Boolean;
begin
  Neg := (B[P] and $80) <> 0;
  Expo := ((B[P] and $7F) shl 8) or B[P + 1];
  Mant := 0;
  for I := 0 to 7 do
    Mant := (Mant shl 8) or B[P + 2 + I];
  if (Expo = 0) and (Mant = 0) then
    Exit(0);
  Result := Mant * Power(2, (Expo - 16383 - 63) * 1.0);
  if Neg then
    Result := -Result;
end;

type
  TSampleFmt = (sfInt, sfFloat);

// Rohdaten -> Stereo-Single
// ABig = big endian, AUnsigned8 = 8-Bit-Werte ohne Vorzeichen (WAV)
function Decode(const B: TBytes; AOfs, ABytes, AChannels, ABits: Integer; AFmt: TSampleFmt;
  ABig, AUnsigned8: Boolean; var AAudio: TS2400Audio; out AError: string): Boolean;
var
  BPS, FrameBytes, F, C, P, V: Integer;
  S: array[0..1] of Single;
  U32: Cardinal;
  U64: UInt64;
  D: Double;
  Sg: Single;
begin
  Result := False;
  BPS := ABits div 8;
  if (BPS < 1) or (BPS > 8) or (AChannels < 1) then
  begin
    AError := Tr('Unbekanntes Sample-Format', 'Unknown sample format');
    Exit;
  end;
  if (AFmt = sfFloat) and (BPS <> 4) and (BPS <> 8) then
  begin
    AError := Tr('Unbekanntes Float-Format', 'Unknown float format');
    Exit;
  end;
  if (AFmt = sfInt) and (BPS > 4) then
  begin
    AError := Tr('Unbekanntes Sample-Format', 'Unknown sample format');
    Exit;
  end;
  FrameBytes := BPS * AChannels;
  if AOfs + ABytes > Length(B) then
    ABytes := Length(B) - AOfs;
  AAudio.Frames := ABytes div FrameBytes;
  if AAudio.Frames <= 0 then
  begin
    AError := Tr('Die Datei enth'#$00E4'lt keine Audiodaten', 'The file contains no audio data');
    Exit;
  end;
  SetLength(AAudio.Data, AAudio.Frames * 2);
  for F := 0 to AAudio.Frames - 1 do
  begin
    for C := 0 to Min(AChannels, 2) - 1 do
    begin
      P := AOfs + F * FrameBytes + C * BPS;
      if AFmt = sfFloat then
      begin
        if BPS = 4 then
        begin
          if ABig then U32 := RdBE32(B, P) else U32 := RdLE32(B, P);
          Move(U32, Sg, 4);
          S[C] := Sg;
        end
        else
        begin
          U64 := 0;
          for V := 0 to 7 do
            if ABig then
              U64 := (U64 shl 8) or B[P + V]
            else
              U64 := U64 or (UInt64(B[P + V]) shl (8 * V));
          Move(U64, D, 8);
          S[C] := D;
        end;
      end
      else
        case BPS of
          1:
            if AUnsigned8 then
              S[C] := (B[P] - 128) / 128
            else
              S[C] := ShortInt(B[P]) / 128;
          2:
            if ABig then
              S[C] := SmallInt(RdBE16U(B, P)) / 32768
            else
              S[C] := RdLE16(B, P) / 32768;
          3:
            begin
              if ABig then
                V := (B[P] shl 16) or (B[P + 1] shl 8) or B[P + 2]
              else
                V := (B[P + 2] shl 16) or (B[P + 1] shl 8) or B[P];
              if V >= $800000 then
                V := V - $1000000;
              S[C] := V / 8388608;
            end;
          4:
            begin
              if ABig then U32 := RdBE32(B, P) else U32 := RdLE32(B, P);
              S[C] := Integer(U32) / 2147483648.0;
            end;
        end;
    end;
    if AChannels = 1 then
      S[1] := S[0];
    AAudio.Data[2 * F] := S[0];
    AAudio.Data[2 * F + 1] := S[1];
  end;
  Result := True;
end;

function LoadWav(const B: TBytes; var AAudio: TS2400Audio; out AError: string): Boolean;
var
  P, Size, Tag, Channels, Bits, DataOfs, DataBytes: Integer;
  HaveFmt: Boolean;
  Fmt: TSampleFmt;
  Id: AnsiString;
begin
  Result := False;
  HaveFmt := False;
  Channels := 0;
  Bits := 0;
  Tag := 0;
  DataOfs := -1;
  DataBytes := 0;
  P := 12;
  while P + 8 <= Length(B) do
  begin
    Id := Tag4(B, P);
    Size := Integer(RdLE32(B, P + 4));
    if (Size < 0) or (P + 8 + Int64(Size) > Length(B)) then
      Size := Length(B) - P - 8; // abgeschnittene Datei: Rest nehmen
    if Id = 'fmt ' then
    begin
      Tag := RdLE16U(B, P + 8);
      Channels := RdLE16U(B, P + 10);
      AAudio.Rate := RdLE32(B, P + 12);
      Bits := RdLE16U(B, P + 22);
      if (Tag = $FFFE) and (Size >= 40) then
        Tag := RdLE16U(B, P + 32); // erste zwei Bytes der SubFormat-GUID
      HaveFmt := True;
    end
    else if Id = 'data' then
    begin
      DataOfs := P + 8;
      DataBytes := Size;
    end;
    Inc(P, 8 + Size + (Size and 1));
  end;
  if not HaveFmt or (DataOfs < 0) then
  begin
    AError := Tr('WAV-Datei unvollst'#$00E4'ndig', 'Incomplete WAV file');
    Exit;
  end;
  case Tag of
    1: Fmt := sfInt;
    3: Fmt := sfFloat;
  else
    AError := Format(Tr('WAV-Format %d wird nicht unterst'#$00FC'tzt (komprimiert?)',
      'WAV format %d is not supported (compressed?)'), [Tag]);
    Exit;
  end;
  Result := Decode(B, DataOfs, DataBytes, Channels, Bits, Fmt, False, True, AAudio, AError);
end;

function LoadAiff(const B: TBytes; AIsAifc: Boolean; var AAudio: TS2400Audio; out AError: string): Boolean;
var
  P, Size, Channels, Bits, DataOfs, DataBytes, Offs: Integer;
  HaveComm, Big: Boolean;
  Fmt: TSampleFmt;
  Id, Comp: AnsiString;
begin
  Result := False;
  HaveComm := False;
  Channels := 0;
  Bits := 0;
  DataOfs := -1;
  DataBytes := 0;
  Comp := 'NONE';
  P := 12;
  while P + 8 <= Length(B) do
  begin
    Id := Tag4(B, P);
    Size := Integer(RdBE32(B, P + 4));
    if (Size < 0) or (P + 8 + Int64(Size) > Length(B)) then
      Size := Length(B) - P - 8;
    if Id = 'COMM' then
    begin
      Channels := RdBE16U(B, P + 8);
      Bits := RdBE16U(B, P + 14);
      AAudio.Rate := Round(RdExt80(B, P + 16));
      if AIsAifc and (Size >= 22) then
        Comp := Tag4(B, P + 26);
      HaveComm := True;
    end
    else if Id = 'SSND' then
    begin
      Offs := Integer(RdBE32(B, P + 8));
      DataOfs := P + 16 + Offs;
      DataBytes := Size - 8 - Offs;
    end;
    Inc(P, 8 + Size + (Size and 1));
  end;
  if not HaveComm or (DataOfs < 0) then
  begin
    AError := Tr('AIFF-Datei unvollst'#$00E4'ndig', 'Incomplete AIFF file');
    Exit;
  end;
  Big := True;
  Fmt := sfInt;
  if (Comp = 'NONE') or (Comp = 'twos') then
  else if Comp = 'sowt' then
    Big := False
  else if (Comp = 'fl32') or (Comp = 'FL32') then
  begin
    Fmt := sfFloat;
    Bits := 32;
  end
  else if (Comp = 'fl64') or (Comp = 'FL64') then
  begin
    Fmt := sfFloat;
    Bits := 64;
  end
  else
  begin
    AError := Format(Tr('AIFC-Kompression "%s" wird nicht unterst'#$00FC'tzt',
      'AIFC compression "%s" is not supported'), [string(Comp)]);
    Exit;
  end;
  // 12-/20-Bit-Daten liegen in ganzen Bytes
  Bits := ((Bits + 7) div 8) * 8;
  Result := Decode(B, DataOfs, DataBytes, Channels, Bits, Fmt, Big, False, AAudio, AError);
end;

function S2400LoadAudio(const AFileName: string; out AAudio: TS2400Audio; out AError: string): Boolean;
var
  FS: TFileStream;
  B: TBytes;
  Head, Form: AnsiString;
begin
  Result := False;
  AAudio := Default(TS2400Audio);
  AError := '';
  try
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      if (FS.Size < 12) or (FS.Size > C_MAX_FILE_BYTES) then
      begin
        AError := Tr('Datei zu klein oder zu gro'#$00DF, 'File too small or too large');
        Exit;
      end;
      SetLength(B, FS.Size);
      FS.ReadBuffer(B[0], Length(B));
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      AError := E.Message;
      Exit;
    end;
  end;
  Head := Tag4(B, 0);
  Form := Tag4(B, 8);
  if (Head = 'RIFF') and (Form = 'WAVE') then
    Result := LoadWav(B, AAudio, AError)
  else if (Head = 'FORM') and ((Form = 'AIFF') or (Form = 'AIFC')) then
    Result := LoadAiff(B, Form = 'AIFC', AAudio, AError)
  else
    AError := Tr('Kein WAV oder AIFF', 'Not a WAV or AIFF file');
  if Result and ((AAudio.Rate < 4000) or (AAudio.Rate > 384000)) then
  begin
    AError := Format(Tr('Ungew'#$00F6'hnliche Abtastrate %d Hz', 'Unusual sample rate %d Hz'), [AAudio.Rate]);
    Result := False;
  end;
  if not Result then
    AAudio := Default(TS2400Audio);
end;

function S2400SaveWav24(const AFileName: string; const AData: TArray<Single>; AFrames, ARate: Integer;
  out AError: string): Boolean;
var
  B: TBytes;
  DataBytes, P, I, V: Integer;
  S: Single;

  procedure PutTag(const ATag: AnsiString);
  var
    J: Integer;
  begin
    for J := 1 to 4 do
    begin
      B[P] := Byte(ATag[J]);
      Inc(P);
    end;
  end;

  procedure PutU32(AValue: Cardinal);
  begin
    B[P] := AValue and $FF;
    B[P + 1] := (AValue shr 8) and $FF;
    B[P + 2] := (AValue shr 16) and $FF;
    B[P + 3] := (AValue shr 24) and $FF;
    Inc(P, 4);
  end;

  procedure PutU16(AValue: Word);
  begin
    B[P] := AValue and $FF;
    B[P + 1] := (AValue shr 8) and $FF;
    Inc(P, 2);
  end;

begin
  Result := False;
  AError := '';
  if (AFrames <= 0) or (ARate <= 0) or (Length(AData) < 2 * AFrames) then
  begin
    AError := Tr('Keine Daten', 'No data');
    Exit;
  end;
  DataBytes := AFrames * 2 * 3;
  SetLength(B, 44 + DataBytes);
  P := 0;
  PutTag('RIFF');
  PutU32(36 + DataBytes);
  PutTag('WAVE');
  PutTag('fmt ');
  PutU32(16);
  PutU16(1);                 // PCM
  PutU16(2);                 // Stereo
  PutU32(ARate);
  PutU32(ARate * 2 * 3);
  PutU16(2 * 3);
  PutU16(24);
  PutTag('data');
  PutU32(DataBytes);
  for I := 0 to 2 * AFrames - 1 do
  begin
    S := AData[I];
    if S > 1 then S := 1;
    if S < -1 then S := -1;
    V := Round(S * 8388607);
    B[P] := V and $FF;
    B[P + 1] := (V shr 8) and $FF;
    B[P + 2] := (V shr 16) and $FF;
    Inc(P, 3);
  end;
  try
    with TFileStream.Create(AFileName, fmCreate) do
    try
      WriteBuffer(B[0], Length(B));
    finally
      Free;
    end;
    Result := True;
  except
    on E: Exception do
      AError := E.Message;
  end;
end;

// ---------------------------------------------------------------------------
// Tempo und Tonart aus dem Dateinamen
// ---------------------------------------------------------------------------

function IsDigits(const S: string): Boolean;
var
  C: Char;
begin
  Result := S <> '';
  for C in S do
    if not CharInSet(C, ['0'..'9']) then
      Exit(False);
end;

// "C", "C#", "Db", "F#m", "Ebmin", "Amaj", "Cminor" ...
// AStrict: ein einzelner Buchstabe ohne Zusatz zaehlt nicht
function ParseKeyToken(const T: string; AStrict: Boolean; out APc: Integer; out AMinor, AHasMode: Boolean): Boolean;
const
  Base: array['A'..'G'] of Integer = (9, 11, 0, 2, 4, 5, 7);
var
  L, Rest: string;
  P: Integer;
begin
  Result := False;
  AHasMode := False;
  AMinor := False;
  if (Length(T) < 1) or (Length(T) > 7) then
    Exit;
  if not CharInSet(T[1], ['A'..'G']) then
    Exit; // Grossbuchstabe verlangt (Woerter wie "bass", "dry" ausschliessen)
  APc := Base[T[1]];
  P := 2;
  if (P <= Length(T)) and (T[P] = '#') then
  begin
    APc := (APc + 1) mod 12;
    Inc(P);
  end
  else if (P <= Length(T)) and (T[P] = 'b') and ((Length(T) = P) or not CharInSet(T[P + 1], ['a'..'z']) or
    (Copy(T, P + 1, 1) = 'm')) then
  begin
    APc := (APc + 11) mod 12;
    Inc(P);
  end;
  Rest := Copy(T, P, MaxInt);
  L := LowerCase(Rest);
  if Rest = '' then
  begin
    if AStrict and (P = 2) then
      Exit;
  end
  else if (Rest = 'm') or (L = 'min') or (L = 'minor') or (L = 'moll') then
  begin
    AMinor := True;
    AHasMode := True;
  end
  else if (Rest = 'M') or (L = 'maj') or (L = 'major') or (L = 'dur') then
    AHasMode := True
  else
    Exit;
  Result := True;
end;

function S2400SpliceStem(const AFileName: string; out AInfo: TS2400StemInfo): Boolean;
var
  Parts: TArray<string>;
  I, J: Integer;
  S: string;
  V: Double;
begin
  Result := False;
  AInfo := Default(TS2400StemInfo);
  Parts := ChangeFileExt(ExtractFileName(AFileName), '').Split([' - ']);
  // der Stack-Name kann selbst " - " enthalten: "<Zahl> BPM" suchen, danach
  // Nummer, Teil und Originalname
  for I := 1 to High(Parts) - 3 do
  begin
    S := Parts[I];
    if (Length(S) < 5) or not SameText(Copy(S, Length(S) - 3, 4), ' BPM') then
      Continue;
    V := StrToFloatDef(Copy(S, 1, Length(S) - 4), 0, TFormatSettings.Invariant);
    if (V < 40) or (V > 250) or not IsDigits(Parts[I + 1]) then
      Continue;
    AInfo.Bpm := V;
    AInfo.Number := StrToIntDef(Parts[I + 1], 0);
    AInfo.Part := Parts[I + 2];
    AInfo.Stack := Parts[0];
    for J := 1 to I - 1 do
      AInfo.Stack := AInfo.Stack + ' - ' + Parts[J];
    Exit(True);
  end;
end;

function S2400ParseSampleName(const AFileName: string): TS2400NameInfo;
var
  Name, Cur, L, T: string;
  Tokens: TArray<string>;
  C: Char;
  I, Pc, V, BpmIdx: Integer;
  Minor, HasMode: Boolean;
  Mode: string;
  Stem: TS2400StemInfo;
begin
  Result.Bpm := 0;
  Result.KeyPc := -1;
  Result.Minor := False;
  // Splice-Stem: Tempo des Stacks gilt; die Tonart im Originalnamen kann
  // falsch sein (Splice transponiert auf die Tonart des Stacks) -> messen
  if S2400SpliceStem(AFileName, Stem) then
  begin
    Result.Bpm := Stem.Bpm;
    Exit;
  end;
  Name := ChangeFileExt(ExtractFileName(AFileName), '');

  // Woerter trennen: alles ausser Buchstaben, Ziffern und '#'
  Tokens := nil;
  Cur := '';
  for C in Name do
    if CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '#']) then
      Cur := Cur + C
    else
    begin
      if Cur <> '' then
        Tokens := Tokens + [Cur];
      Cur := '';
    end;
  if Cur <> '' then
    Tokens := Tokens + [Cur];

  // Tempo: "92bpm" / "bpm92" zuerst, sonst eine Zahl 60..200 ("92")
  BpmIdx := -1;
  for I := 0 to High(Tokens) do
  begin
    L := LowerCase(Tokens[I]);
    if (Length(L) > 3) and L.EndsWith('bpm') and IsDigits(Copy(L, 1, Length(L) - 3)) then
      T := Copy(L, 1, Length(L) - 3)
    else if (Length(L) > 3) and L.StartsWith('bpm') and IsDigits(Copy(L, 4, MaxInt)) then
      T := Copy(L, 4, MaxInt)
    else if (L = 'bpm') and (I > 0) and IsDigits(Tokens[I - 1]) then
      T := Tokens[I - 1]
    else
      Continue;
    V := StrToIntDef(T, 0);
    if (V >= 40) and (V <= 250) then
    begin
      Result.Bpm := V;
      BpmIdx := I;
      Break;
    end;
  end;
  if Result.Bpm = 0 then
    for I := 0 to High(Tokens) do
      if IsDigits(Tokens[I]) and (Length(Tokens[I]) in [2, 3]) and (Tokens[I][1] <> '0') then
      begin
        V := StrToInt(Tokens[I]);
        if (V >= 60) and (V <= 200) then
        begin
          Result.Bpm := V;
          BpmIdx := I;
          Break;
        end;
      end;

  // Tonart: Wort mit Vorzeichen oder Zusatz ("C#m", "Ebmin", "Amaj"),
  // "C minor" (zwei Woerter) oder ein einzelner Grossbuchstabe direkt
  // neben dem Tempo ("..._92_C_...")
  for I := High(Tokens) downto 0 do
  begin
    T := Tokens[I];
    if ParseKeyToken(T, True, Pc, Minor, HasMode) then
    begin
      Result.KeyPc := Pc;
      Result.Minor := Minor;
      Exit;
    end;
    if (I < High(Tokens)) and ParseKeyToken(T, False, Pc, Minor, HasMode) and not HasMode then
    begin
      Mode := LowerCase(Tokens[I + 1]);
      if (Mode = 'minor') or (Mode = 'min') or (Mode = 'moll') or (Mode = 'major') or (Mode = 'maj') or (Mode = 'dur') then
      begin
        Result.KeyPc := Pc;
        Result.Minor := (Mode = 'minor') or (Mode = 'min') or (Mode = 'moll');
        Exit;
      end;
    end;
  end;
  if BpmIdx >= 0 then
    for I := BpmIdx - 1 to BpmIdx + 1 do
      if (I >= 0) and (I <= High(Tokens)) and (I <> BpmIdx) and (Length(Tokens[I]) <= 2) and
        ParseKeyToken(Tokens[I], False, Pc, Minor, HasMode) then
      begin
        Result.KeyPc := Pc;
        Result.Minor := Minor;
        Exit;
      end;
end;

end.
