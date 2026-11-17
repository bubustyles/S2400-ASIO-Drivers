unit S2400AsioHost;

// =============================================================================
// S2400AsioHost.pas
//
// Baustein fuer den Verbund-Treiber ("S2400 Aggregate", Etappe A, 15.10.2026):
// laedt einen FREMDEN ASIO-Treiber (z.B. Universal Audio Thunderbolt) und
// betreibt ihn als Host - so wie es Ableton oder VB-Audio Matrix tun. Der
// fremde Treiber liefert damit den Takt fuer den ganzen Verbund.
//
// Ablauf wie im Steinberg-Referenz-Host (asiodrivers/asiolist):
//   - installierte Treiber stehen unter HKLM\SOFTWARE\ASIO\<Name>, Wert CLSID
//   - CoCreateInstance(CLSID, ..., IID = CLSID) - historische ASIO-Eigenheit,
//     die IID ist die CLSID selbst
//   - init -> getChannels/getBufferSize/getChannelInfo -> createBuffers ->
//     start ... stop -> disposeBuffers -> Freigabe
//
// Die ASIO-Rueckrufe haben keinen Kontext-Zeiger. Deshalb kann immer nur EIN
// Host-Objekt gleichzeitig aktiv sein (GActiveHost) - fuer den Verbund
// genuegt das, es gibt genau einen Taktgeber.
// =============================================================================

{$POINTERMATH ON}

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.Win.Registry,
  AsioInterface;

type
  TS2400AsioDriverInfo = record
    Name: string;
    Clsid: TGUID;
  end;

  // wird im Rueckruf-Thread des fremden Treibers aufgerufen; ATimeInfo kann
  // nil sein (Treiber ohne bufferSwitchTimeInfo)
  TS2400BufferSwitchEvent = procedure(ADoubleBufferIndex: Integer; ATimeInfo: PASIOTime) of object;

  // Meldung des fremden Treibers an seinen Host (kAsioResetRequest,
  // kAsioResyncRequest, kAsioLatenciesChanged; eine extern geaenderte
  // Samplerate wird als kAsioResetRequest gemeldet) - der Verbund reicht sie
  // an SEINEN Host weiter
  TS2400AsioMessageEvent = procedure(ASelector: LongInt) of object;

  TS2400AsioHost = class
  private
    FDriver: IASIO;
    FDriverName: string;
    FInputs: Integer;
    FOutputs: Integer;
    FMinSize, FMaxSize, FPreferredSize, FGranularity: Integer;
    FBufferSize: Integer;
    FSampleRate: Double;
    FInputLatency: Integer;
    FOutputLatency: Integer;
    FBufferInfos: TArray<TASIOBufferInfo>;   // erst alle Eingaenge, dann alle Ausgaenge
    FChannelInfos: TArray<TASIOChannelInfo>; // gleiche Reihenfolge
    FCallbacks: TASIOCallbacks;
    FBuffersCreated: Boolean;
    FRunning: Boolean;
    FLastError: string;
    FOnBufferSwitch: TS2400BufferSwitchEvent;
    FOnMessage: TS2400AsioMessageEvent;
    FResetRequested: Boolean;
    FLatenciesChanged: Boolean;
    FSupportsOutputReady: Boolean;
    procedure Fail(const AMsg: string);
  public
    destructor Destroy; override;

    // alle unter HKLM\SOFTWARE\ASIO registrierten Treiber
    class function ListDrivers: TArray<TS2400AsioDriverInfo>;
    // ersten Treiber, dessen Name ANamePart enthaelt (Gross/Klein egal)
    class function FindDriver(const ANamePart: string; out AInfo: TS2400AsioDriverInfo): Boolean;

    function Load(const AInfo: TS2400AsioDriverInfo; ASysHandle: Pointer): Boolean;
    procedure Unload;

    function SetSampleRate(ARate: Double): Boolean;
    // legt Puffer fuer ALLE Ein- und Ausgaenge an (ABufferSize 0 = bevorzugte Groesse)
    function CreateBuffers(ABufferSize: Integer = 0): Boolean;
    procedure DisposeBuffers;
    function Start: Boolean;
    procedure Stop;

    // Puffer eines Kanals fuer die aktuelle Haelfte des Doppelpuffers
    function InputBuffer(AChannel, AIndex: Integer): Pointer;
    function OutputBuffer(AChannel, AIndex: Integer): Pointer;
    function InputInfo(AChannel: Integer): TASIOChannelInfo;
    function OutputInfo(AChannel: Integer): TASIOChannelInfo;
    // nach dem Schreiben der Ausgaenge aufrufen (falls der Treiber es kann)
    procedure OutputReady;

    // direkt an den fremden Treiber durchgereicht (fuer den Verbund-Treiber)
    function CanSampleRate(ARate: Double): Boolean;
    function CurrentSampleRate: Double;
    function GetSamplePosition(out ASamplePos: TASIOSamples; out ATimeStamp: TASIOTimeStamp): TASIOError;
    procedure RefreshLatencies;
    // getChannelInfo des fremden Treibers (geht auch VOR CreateBuffers -
    // Name und Sample-Format eines Kanals)
    function QueryChannelInfo(var AInfo: TASIOChannelInfo): TASIOError;
    // oeffnet das Einstellungsfenster des fremden Treibers
    function ShowControlPanel: TASIOError;
    // future() des fremden Treibers (z.B. eigener Wahlschalter des Verbunds)
    function Future(ASelector: LongInt; AOpt: Pointer): TASIOError;
    function IsLoaded: Boolean;

    // nur fuer die globalen Rueckruf-Funktionen
    procedure HandleBufferSwitch(AIndex: Integer; ATimeInfo: PASIOTime);
    function HandleAsioMessage(ASelector, AValue: LongInt): LongInt;

    property DriverName: string read FDriverName;
    property Inputs: Integer read FInputs;
    property Outputs: Integer read FOutputs;
    property MinSize: Integer read FMinSize;
    property MaxSize: Integer read FMaxSize;
    property PreferredSize: Integer read FPreferredSize;
    property Granularity: Integer read FGranularity;
    property BufferSize: Integer read FBufferSize;
    property SampleRate: Double read FSampleRate;
    property InputLatency: Integer read FInputLatency;
    property OutputLatency: Integer read FOutputLatency;
    property Running: Boolean read FRunning;
    property LastError: string read FLastError;
    property OnBufferSwitch: TS2400BufferSwitchEvent read FOnBufferSwitch write FOnBufferSwitch;
    property OnMessage: TS2400AsioMessageEvent read FOnMessage write FOnMessage;
    // vom fremden Treiber gemeldet - der Verbund reicht das an seinen Host weiter
    property ResetRequested: Boolean read FResetRequested write FResetRequested;
    property LatenciesChanged: Boolean read FLatenciesChanged write FLatenciesChanged;
  end;

// ---------------------------------------------------------------------------
// Sample-Formate: Umwandlung ASIO-Puffer <-> Single (-1..+1)
// ---------------------------------------------------------------------------

// liefert False, wenn das Format nicht unterstuetzt wird
function AsioSampleTypeSupported(AType: TASIOSampleType): Boolean;
function AsioSampleTypeName(AType: TASIOSampleType): string;
// Bytes pro Sample (2, 3, 4 oder 8), 4 bei unbekanntem Typ
function AsioSampleBytes(AType: TASIOSampleType): Integer;
procedure AsioToFloat(ASrc: Pointer; AType: TASIOSampleType; ADst: System.PSingle; ACount: Integer);
procedure FloatToAsio(ASrc: System.PSingle; ADst: Pointer; AType: TASIOSampleType; ACount: Integer);

implementation

var
  GActiveHost: TS2400AsioHost = nil;

// ---------------------------------------------------------------------------
// globale Rueckrufe (cdecl, ohne Kontext - siehe Unit-Kopf)
// ---------------------------------------------------------------------------

procedure CbBufferSwitch(doubleBufferIndex: LongInt; directProcess: TASIOBool); cdecl;
begin
  if GActiveHost <> nil then
    GActiveHost.HandleBufferSwitch(doubleBufferIndex, nil);
end;

procedure CbSampleRateDidChange(sRate: TASIOSampleRate); cdecl;
begin
  // Rate wurde extern geaendert (z.B. Clock-Quelle) - der Verbund muss neu starten
  if GActiveHost <> nil then
    GActiveHost.HandleAsioMessage(kAsioResetRequest, 0);
end;

function CbAsioMessage(selector: LongInt; value: LongInt; message: Pointer; opt: PDouble): LongInt; cdecl;
begin
  if GActiveHost <> nil then
    Result := GActiveHost.HandleAsioMessage(selector, value)
  else
    Result := 0;
end;

function CbBufferSwitchTimeInfo(params: PASIOTime; doubleBufferIndex: LongInt;
  directProcess: TASIOBool): PASIOTime; cdecl;
begin
  if GActiveHost <> nil then
    GActiveHost.HandleBufferSwitch(doubleBufferIndex, params);
  Result := params;
end;

// ---------------------------------------------------------------------------
// TS2400AsioHost
// ---------------------------------------------------------------------------

destructor TS2400AsioHost.Destroy;
begin
  Unload;
  inherited Destroy;
end;

procedure TS2400AsioHost.Fail(const AMsg: string);
begin
  FLastError := AMsg;
end;

class function TS2400AsioHost.ListDrivers: TArray<TS2400AsioDriverInfo>;
var
  Reg: TRegistry;
  Names: TStringList;
  I: Integer;
  Info: TS2400AsioDriverInfo;
  S: string;
begin
  Result := nil;
  Reg := TRegistry.Create(KEY_READ);
  Names := TStringList.Create;
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if not Reg.OpenKeyReadOnly('SOFTWARE\ASIO') then
      Exit;
    Reg.GetKeyNames(Names);
    Reg.CloseKey;
    for I := 0 to Names.Count - 1 do
      if Reg.OpenKeyReadOnly('SOFTWARE\ASIO\' + Names[I]) then
      try
        if Reg.ValueExists('CLSID') then
        begin
          S := Reg.ReadString('CLSID');
          try
            Info.Clsid := StringToGUID(S);
            Info.Name := Names[I];
            Result := Result + [Info];
          except
            // ungueltige CLSID - Eintrag ueberspringen
          end;
        end;
      finally
        Reg.CloseKey;
      end;
  finally
    Names.Free;
    Reg.Free;
  end;
end;

class function TS2400AsioHost.FindDriver(const ANamePart: string; out AInfo: TS2400AsioDriverInfo): Boolean;
var
  D: TS2400AsioDriverInfo;
begin
  for D in ListDrivers do
    if Pos(UpperCase(ANamePart), UpperCase(D.Name)) > 0 then
    begin
      AInfo := D;
      Exit(True);
    end;
  Result := False;
end;

function TS2400AsioHost.Load(const AInfo: TS2400AsioDriverInfo; ASysHandle: Pointer): Boolean;
var
  HR: HResult;
  P: Pointer;
  NameBuf: array[0..127] of AnsiChar;
  MsgBuf: array[0..255] of AnsiChar;
  MinS, MaxS, PrefS, Gran, InLat, OutLat, NIn, NOut: LongInt;
  Rate: TASIOSampleRate;
begin
  Result := False;
  Unload;
  if GActiveHost <> nil then
  begin
    Fail('Es ist bereits ein fremder ASIO-Treiber geladen.');
    Exit;
  end;

  // historische ASIO-Eigenheit: IID = CLSID des Treibers
  P := nil;
  HR := CoCreateInstance(AInfo.Clsid, nil, CLSCTX_INPROC_SERVER, AInfo.Clsid, P);
  if (HR <> S_OK) or (P = nil) then
  begin
    Fail(Format('CoCreateInstance(%s) fehlgeschlagen, HRESULT $%.8x', [AInfo.Name, Cardinal(HR)]));
    Exit;
  end;
  Pointer(FDriver) := P; // uebernimmt die Referenz aus CoCreateInstance

  if FDriver.init(ASysHandle) = ASIOFalse then
  begin
    FillChar(MsgBuf, SizeOf(MsgBuf), 0);
    FDriver.getErrorMessage(@MsgBuf[0]);
    Fail(Format('init() von "%s" fehlgeschlagen: %s', [AInfo.Name, string(AnsiString(PAnsiChar(@MsgBuf[0])))]));
    FDriver := nil;
    Exit;
  end;

  FillChar(NameBuf, SizeOf(NameBuf), 0);
  FDriver.getDriverName(@NameBuf[0]);
  FDriverName := string(AnsiString(PAnsiChar(@NameBuf[0])));
  if FDriverName = '' then
    FDriverName := AInfo.Name;

  if FDriver.getChannels(NIn, NOut) <> ASE_OK then
  begin
    Fail('getChannels fehlgeschlagen');
    FDriver := nil;
    Exit;
  end;
  FInputs := NIn;
  FOutputs := NOut;

  if FDriver.getBufferSize(MinS, MaxS, PrefS, Gran) = ASE_OK then
  begin
    FMinSize := MinS; FMaxSize := MaxS; FPreferredSize := PrefS; FGranularity := Gran;
  end;
  if FDriver.getSampleRate(Rate) = ASE_OK then
    FSampleRate := Rate;
  if FDriver.getLatencies(InLat, OutLat) = ASE_OK then
  begin
    FInputLatency := InLat;
    FOutputLatency := OutLat;
  end;

  FSupportsOutputReady := FDriver.outputReady = ASE_OK;
  Result := True;
end;

procedure TS2400AsioHost.Unload;
begin
  Stop;
  DisposeBuffers;
  FDriver := nil; // gibt den fremden Treiber frei
  FInputs := 0;
  FOutputs := 0;
end;

function TS2400AsioHost.SetSampleRate(ARate: Double): Boolean;
begin
  Result := False;
  if FDriver = nil then
    Exit;
  if FDriver.canSampleRate(ARate) <> ASE_OK then
  begin
    Fail(Format('Treiber kann %.0f Hz nicht', [ARate]));
    Exit;
  end;
  if FDriver.setSampleRate(ARate) <> ASE_OK then
  begin
    Fail(Format('setSampleRate(%.0f) fehlgeschlagen', [ARate]));
    Exit;
  end;
  FSampleRate := ARate;
  Result := True;
end;

function TS2400AsioHost.CreateBuffers(ABufferSize: Integer): Boolean;
var
  I, N: Integer;
  Err: TASIOError;
  InLat, OutLat: LongInt;
begin
  Result := False;
  if FDriver = nil then
    Exit;
  DisposeBuffers;

  if ABufferSize <= 0 then
    ABufferSize := FPreferredSize;
  FBufferSize := ABufferSize;

  N := FInputs + FOutputs;
  SetLength(FBufferInfos, N);
  SetLength(FChannelInfos, N);
  for I := 0 to N - 1 do
  begin
    FillChar(FBufferInfos[I], SizeOf(TASIOBufferInfo), 0);
    FillChar(FChannelInfos[I], SizeOf(TASIOChannelInfo), 0);
    if I < FInputs then
    begin
      FBufferInfos[I].isInput := ASIOTrue;
      FBufferInfos[I].channelNum := I;
    end
    else
    begin
      FBufferInfos[I].isInput := ASIOFalse;
      FBufferInfos[I].channelNum := I - FInputs;
    end;
    FChannelInfos[I].channel := FBufferInfos[I].channelNum;
    FChannelInfos[I].isInput := FBufferInfos[I].isInput;
  end;

  FillChar(FCallbacks, SizeOf(FCallbacks), 0);
  FCallbacks.bufferSwitch := CbBufferSwitch;
  FCallbacks.sampleRateDidChange := CbSampleRateDidChange;
  FCallbacks.asioMessage := CbAsioMessage;
  FCallbacks.bufferSwitchTimeInfo := CbBufferSwitchTimeInfo;

  GActiveHost := Self; // vor createBuffers - manche Treiber rufen asioMessage sofort
  Err := FDriver.createBuffers(@FBufferInfos[0], N, FBufferSize, FCallbacks);
  if Err <> ASE_OK then
  begin
    GActiveHost := nil;
    Fail(Format('createBuffers(%d Kanaele, %d Frames) fehlgeschlagen, ASIOError %d', [N, FBufferSize, Err]));
    Exit;
  end;
  FBuffersCreated := True;

  for I := 0 to N - 1 do
    FDriver.getChannelInfo(FChannelInfos[I]);

  // Latenzen gelten erst nach createBuffers verbindlich
  if FDriver.getLatencies(InLat, OutLat) = ASE_OK then
  begin
    FInputLatency := InLat;
    FOutputLatency := OutLat;
  end;
  Result := True;
end;

procedure TS2400AsioHost.DisposeBuffers;
begin
  if FBuffersCreated and (FDriver <> nil) then
    FDriver.disposeBuffers;
  FBuffersCreated := False;
  if GActiveHost = Self then
    GActiveHost := nil;
end;

function TS2400AsioHost.Start: Boolean;
begin
  Result := False;
  if (FDriver = nil) or not FBuffersCreated then
    Exit;
  if FDriver.start <> ASE_OK then
  begin
    Fail('start() fehlgeschlagen');
    Exit;
  end;
  FRunning := True;
  Result := True;
end;

procedure TS2400AsioHost.Stop;
begin
  if FRunning and (FDriver <> nil) then
    FDriver.stop;
  FRunning := False;
end;

function TS2400AsioHost.InputBuffer(AChannel, AIndex: Integer): Pointer;
begin
  Result := FBufferInfos[AChannel].buffers[AIndex];
end;

function TS2400AsioHost.OutputBuffer(AChannel, AIndex: Integer): Pointer;
begin
  Result := FBufferInfos[FInputs + AChannel].buffers[AIndex];
end;

function TS2400AsioHost.InputInfo(AChannel: Integer): TASIOChannelInfo;
begin
  Result := FChannelInfos[AChannel];
end;

function TS2400AsioHost.OutputInfo(AChannel: Integer): TASIOChannelInfo;
begin
  Result := FChannelInfos[FInputs + AChannel];
end;

procedure TS2400AsioHost.OutputReady;
begin
  if FSupportsOutputReady and (FDriver <> nil) then
    FDriver.outputReady;
end;

function TS2400AsioHost.CanSampleRate(ARate: Double): Boolean;
begin
  Result := (FDriver <> nil) and (FDriver.canSampleRate(ARate) = ASE_OK);
end;

function TS2400AsioHost.CurrentSampleRate: Double;
var
  Rate: TASIOSampleRate;
begin
  if (FDriver <> nil) and (FDriver.getSampleRate(Rate) = ASE_OK) then
    FSampleRate := Rate;
  Result := FSampleRate;
end;

function TS2400AsioHost.GetSamplePosition(out ASamplePos: TASIOSamples;
  out ATimeStamp: TASIOTimeStamp): TASIOError;
begin
  if FDriver = nil then
  begin
    FillChar(ASamplePos, SizeOf(ASamplePos), 0);
    FillChar(ATimeStamp, SizeOf(ATimeStamp), 0);
    Exit(ASE_NotPresent);
  end;
  Result := FDriver.getSamplePosition(ASamplePos, ATimeStamp);
end;

procedure TS2400AsioHost.RefreshLatencies;
var
  InLat, OutLat: LongInt;
begin
  if (FDriver <> nil) and (FDriver.getLatencies(InLat, OutLat) = ASE_OK) then
  begin
    FInputLatency := InLat;
    FOutputLatency := OutLat;
  end;
end;

function TS2400AsioHost.QueryChannelInfo(var AInfo: TASIOChannelInfo): TASIOError;
begin
  if FDriver = nil then
    Exit(ASE_NotPresent);
  Result := FDriver.getChannelInfo(AInfo);
end;

function TS2400AsioHost.ShowControlPanel: TASIOError;
begin
  if FDriver = nil then
    Exit(ASE_NotPresent);
  Result := FDriver.controlPanel;
end;

function TS2400AsioHost.Future(ASelector: LongInt; AOpt: Pointer): TASIOError;
begin
  if FDriver = nil then
    Exit(ASE_NotPresent);
  Result := FDriver.future(ASelector, AOpt);
end;

function TS2400AsioHost.IsLoaded: Boolean;
begin
  Result := FDriver <> nil;
end;

procedure TS2400AsioHost.HandleBufferSwitch(AIndex: Integer; ATimeInfo: PASIOTime);
begin
  if Assigned(FOnBufferSwitch) then
    FOnBufferSwitch(AIndex, ATimeInfo);
end;

function TS2400AsioHost.HandleAsioMessage(ASelector, AValue: LongInt): LongInt;
begin
  Result := 0;
  case ASelector of
    kAsioSelectorSupported:
      case AValue of
        kAsioResetRequest, kAsioEngineVersion, kAsioResyncRequest,
        kAsioLatenciesChanged, kAsioSupportsTimeInfo:
          Result := 1;
      end;
    kAsioEngineVersion:
      Result := 2;
    kAsioResetRequest, kAsioResyncRequest:
      begin
        FResetRequested := True;
        if Assigned(FOnMessage) then
          FOnMessage(ASelector);
        Result := 1;
      end;
    kAsioLatenciesChanged:
      begin
        FLatenciesChanged := True;
        if Assigned(FOnMessage) then
          FOnMessage(ASelector);
        Result := 1;
      end;
    kAsioSupportsTimeInfo:
      Result := 1;
  end;
end;

// ---------------------------------------------------------------------------
// Sample-Formate
// ---------------------------------------------------------------------------

function AsioSampleTypeSupported(AType: TASIOSampleType): Boolean;
begin
  Result := (AType = ASIOSTInt16LSB) or (AType = ASIOSTInt24LSB) or (AType = ASIOSTInt32LSB) or
    (AType = ASIOSTFloat32LSB) or (AType = ASIOSTFloat64LSB) or (AType = ASIOSTInt32LSB16) or
    (AType = ASIOSTInt32LSB18) or (AType = ASIOSTInt32LSB20) or (AType = ASIOSTInt32LSB24);
end;

function AsioSampleTypeName(AType: TASIOSampleType): string;
begin
  if AType = ASIOSTInt16LSB then Result := 'Int16LSB'
  else if AType = ASIOSTInt24LSB then Result := 'Int24LSB'
  else if AType = ASIOSTInt32LSB then Result := 'Int32LSB'
  else if AType = ASIOSTFloat32LSB then Result := 'Float32LSB'
  else if AType = ASIOSTFloat64LSB then Result := 'Float64LSB'
  else if AType = ASIOSTInt32LSB16 then Result := 'Int32LSB16'
  else if AType = ASIOSTInt32LSB18 then Result := 'Int32LSB18'
  else if AType = ASIOSTInt32LSB20 then Result := 'Int32LSB20'
  else if AType = ASIOSTInt32LSB24 then Result := 'Int32LSB24'
  else Result := Format('Typ %d (nicht unterstuetzt)', [AType]);
end;

function AsioSampleBytes(AType: TASIOSampleType): Integer;
begin
  if AType = ASIOSTInt16LSB then
    Result := 2
  else if AType = ASIOSTInt24LSB then
    Result := 3
  else if AType = ASIOSTFloat64LSB then
    Result := 8
  else
    Result := 4;
end;

procedure AsioToFloat(ASrc: Pointer; AType: TASIOSampleType; ADst: System.PSingle; ACount: Integer);
var
  I: Integer;
  P8: PByte;
  V: Integer;
  Scale: Single;
begin
  if AType = ASIOSTFloat32LSB then
    Move(ASrc^, ADst^, ACount * SizeOf(Single))
  else if AType = ASIOSTFloat64LSB then
    for I := 0 to ACount - 1 do
      ADst[I] := PDouble(ASrc)[I]
  else if AType = ASIOSTInt16LSB then
    for I := 0 to ACount - 1 do
      ADst[I] := PSmallInt(ASrc)[I] * (1.0 / 32768.0)
  else if AType = ASIOSTInt24LSB then
  begin
    P8 := ASrc;
    for I := 0 to ACount - 1 do
    begin
      V := P8[0] or (P8[1] shl 8) or (ShortInt(P8[2]) shl 16);
      ADst[I] := V * (1.0 / 8388608.0);
      Inc(P8, 3);
    end;
  end
  else if AType = ASIOSTInt32LSB then
    for I := 0 to ACount - 1 do
      ADst[I] := PInteger(ASrc)[I] * (1.0 / 2147483648.0)
  else
  begin
    // 32-Bit-Container mit 16/18/20/24 gueltigen Bit (rechtsbuendig)
    if AType = ASIOSTInt32LSB16 then Scale := 1.0 / 32768.0
    else if AType = ASIOSTInt32LSB18 then Scale := 1.0 / 131072.0
    else if AType = ASIOSTInt32LSB20 then Scale := 1.0 / 524288.0
    else if AType = ASIOSTInt32LSB24 then Scale := 1.0 / 8388608.0
    else
    begin
      FillChar(ADst^, ACount * SizeOf(Single), 0); // unbekannt -> Stille
      Exit;
    end;
    for I := 0 to ACount - 1 do
      ADst[I] := PInteger(ASrc)[I] * Scale;
  end;
end;

// rundet und begrenzt auf [-AMax, AMax - 1]; NaN -> 0. Begrenzt wird NACH
// dem Runden: 0,99999 * 32768 rundet sonst auf 32768 und passt nicht mehr
// in 16 Bit.
function ClampToInt(F: Single; AMax: Double): Int64; inline;
var
  Lim: Int64;
begin
  Lim := Round(AMax);
  if F <> F then
    Exit(0);
  if F >= 1.0 then
    Exit(Lim - 1);
  if F <= -1.0 then
    Exit(-Lim);
  Result := Round(F * AMax);
  if Result > Lim - 1 then
    Result := Lim - 1
  else if Result < -Lim then
    Result := -Lim;
end;

procedure FloatToAsio(ASrc: System.PSingle; ADst: Pointer; AType: TASIOSampleType; ACount: Integer);
var
  I: Integer;
  P8: PByte;
  V: Integer;
begin
  if AType = ASIOSTFloat32LSB then
    Move(ASrc^, ADst^, ACount * SizeOf(Single))
  else if AType = ASIOSTFloat64LSB then
    for I := 0 to ACount - 1 do
      PDouble(ADst)[I] := ASrc[I]
  else if AType = ASIOSTInt16LSB then
    for I := 0 to ACount - 1 do
      PSmallInt(ADst)[I] := ClampToInt(ASrc[I], 32768.0)
  else if AType = ASIOSTInt24LSB then
  begin
    P8 := ADst;
    for I := 0 to ACount - 1 do
    begin
      V := ClampToInt(ASrc[I], 8388608.0);
      P8[0] := V and $FF;
      P8[1] := (V shr 8) and $FF;
      P8[2] := (V shr 16) and $FF;
      Inc(P8, 3);
    end;
  end
  else if AType = ASIOSTInt32LSB then
    for I := 0 to ACount - 1 do
      PInteger(ADst)[I] := ClampToInt(ASrc[I], 2147483648.0)
  else if AType = ASIOSTInt32LSB16 then
    for I := 0 to ACount - 1 do
      PInteger(ADst)[I] := ClampToInt(ASrc[I], 32768.0)
  else if AType = ASIOSTInt32LSB18 then
    for I := 0 to ACount - 1 do
      PInteger(ADst)[I] := ClampToInt(ASrc[I], 131072.0)
  else if AType = ASIOSTInt32LSB20 then
    for I := 0 to ACount - 1 do
      PInteger(ADst)[I] := ClampToInt(ASrc[I], 524288.0)
  else if AType = ASIOSTInt32LSB24 then
    for I := 0 to ACount - 1 do
      PInteger(ADst)[I] := ClampToInt(ASrc[I], 8388608.0)
  else
    FillChar(ADst^, ACount * 4, 0);
end;

end.
