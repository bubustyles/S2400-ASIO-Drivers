unit S2400WasapiOut;

// =============================================================================
// S2400WasapiOut.pas - Wiedergabe auf ein Windows-Audiogeraet per WASAPI
// (Etappe C des Verbunds, 30.10.2026: z.B. die Realtek-Onboard-Karte als
// zusaetzlicher Stereo-Ausgang)
//
//   - zuerst Exklusiv-Modus (geringe Latenz, bitgenau): Formate der Reihe
//     nach Float32, PCM 24-in-32, PCM 24, PCM 16 bei der Wunschrate (Rate des
//     Masters), sonst 48000/44100 Hz; Periode >= 5 ms
//   - sonst geteilter Modus mit dem Mix-Format des Geraets (Windows mischt
//     und rechnet selbst um)
//   - ereignisgesteuert: der Ausgabe-Thread wartet auf das Ereignis des
//     Geraets und fuellt dann WritableFrames Frames nach
//
// Die WASAPI-/MMDevice-Schnittstellen sind in der Delphi-RTL nicht
// enthalten; die Deklarationen stammen aus S2400WasapiEngine.pas (von Hand
// nach mmdeviceapi.h/audioclient.h uebersetzt, dort ausfuehrlich kommentiert).
// =============================================================================

{$POINTERMATH ON}

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.MMSystem,
  Winapi.PropSys,
  Winapi.Functiondiscovery,
  System.SysUtils,
  S2400Lang;

const
  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IMMDeviceEnumerator:  TGUID = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
  IID_IAudioClient:         TGUID = '{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}';
  IID_IAudioRenderClient:   TGUID = '{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}';

type
  PPWaveFormatEx = ^PWaveFormatEx;

  PWaveFormatExtensible = ^TWaveFormatExtensible;
  TWaveFormatExtensible = record
    Format: TWaveFormatEx;
    wValidBitsPerSample: Word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer;
      out ppInterface): HResult; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties: IPropertyStore): HResult; stdcall;
    function GetId(out ppstrId: PWideChar): HResult; stdcall;
    function GetState(out pdwState: DWORD): HResult; stdcall;
  end;

  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}']
    function GetCount(out pcDevices: UINT): HResult; stdcall;
    function Item(nDevice: UINT; out ppDevice: IMMDevice): HResult; stdcall;
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: Integer; dwStateMask: DWORD;
      out ppDevices: IMMDeviceCollection): HResult; stdcall;
    function GetDefaultAudioEndpoint(dataFlow: Integer; role: Integer;
      out ppEndpoint: IMMDevice): HResult; stdcall;
    function GetDevice(pwstrId: PWideChar; out ppDevice: IMMDevice): HResult; stdcall;
    function RegisterEndpointNotificationCallback(pClient: Pointer): HResult; stdcall;
    function UnregisterEndpointNotificationCallback(pClient: Pointer): HResult; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}']
    function Initialize(ShareMode: Integer; StreamFlags: DWORD;
      hnsBufferDuration, hnsPeriodicity: Int64; pFormat: PWaveFormatEx;
      AudioSessionGuid: PGUID): HResult; stdcall;
    function GetBufferSize(out pNumBufferFrames: UINT32): HResult; stdcall;
    function GetStreamLatency(out phnsLatency: Int64): HResult; stdcall;
    function GetCurrentPadding(out pNumPaddingFrames: UINT32): HResult; stdcall;
    function IsFormatSupported(ShareMode: Integer; pFormat: PWaveFormatEx;
      ppClosestMatch: PPWaveFormatEx): HResult; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWaveFormatEx): HResult; stdcall;
    function GetDevicePeriod(out phnsDefaultDevicePeriod, phnsMinimumDevicePeriod: Int64): HResult; stdcall;
    function Start: HResult; stdcall;
    function Stop: HResult; stdcall;
    function Reset: HResult; stdcall;
    function SetEventHandle(eventHandle: THandle): HResult; stdcall;
    function GetService(const riid: TGUID; out ppv): HResult; stdcall;
  end;

  IAudioRenderClient = interface(IUnknown)
    ['{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}']
    function GetBuffer(NumFramesRequested: UINT32; out ppData: PByte): HResult; stdcall;
    function ReleaseBuffer(NumFramesWritten: UINT32; dwFlags: DWORD): HResult; stdcall;
  end;

  TS2400WinDevice = record
    Id: string;    // Endpunkt-ID (bleibt ueber Neustarts gleich)
    Name: string;  // Anzeigename, z.B. "Lautsprecher (Realtek(R) Audio)"
  end;

  TS2400WinSampleKind = (wskFloat32, wskInt16, wskInt24, wskInt32);

  TS2400WasapiOut = class
  private
    FClient: IAudioClient;
    FRender: IAudioRenderClient;
    FEvent: THandle;
    FAbortEvent: THandle;
    FBufferFrames: Cardinal;
    FRate: Integer;
    FDevChannels: Integer;
    FKind: TS2400WinSampleKind;
    FBytesPerSample: Integer;
    FBytesPerFrame: Integer;
    FExclusive: Boolean;
    FStarted: Boolean;
    FLastError: string;
    FFormatText: string;
    procedure Fail(const AContext: string; AHR: HResult);
    function TryExclusive(const ADevice: IMMDevice; ARate: Integer): Boolean;
    function InitShared(const ADevice: IMMDevice): Boolean;
    function FinishInit: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    // alle aktiven Wiedergabe-Endpunkte (ruft COM; im Host-/Bedienthread)
    class function ListDevices: TArray<TS2400WinDevice>;

    // oeffnet das Geraet; AExclusive = zuerst Exklusiv-Modus versuchen
    function Open(const ADeviceId: string; APreferredRate: Integer; AExclusive: Boolean): Boolean;
    procedure Close;
    function Start: Boolean;
    procedure Stop;

    // --- Ausgabe-Thread ---
    // wartet auf das Ereignis des Geraets (False = Zeitueberschreitung/Abbruch)
    function WaitReady(ATimeoutMs: Cardinal): Boolean;
    // weckt ein wartendes WaitReady (vor dem Beenden des Threads)
    procedure Abort;
    // so viele Frames koennen jetzt geschrieben werden
    function WritableFrames: Integer;
    // schreibt AFrames Frames aus ASrc (interleaved Single, ASrcChannels
    // Kanaele; nil = Stille) in den Geraetepuffer
    function WriteFrames(ASrc: System.PSingle; AFrames, ASrcChannels: Integer): Boolean;

    property SampleRate: Integer read FRate;
    property BufferFrames: Cardinal read FBufferFrames;
    property Exclusive: Boolean read FExclusive;
    property DeviceChannels: Integer read FDevChannels;
    property FormatText: string read FFormatText;
    property LastError: string read FLastError;
  end;

implementation

function PropVariantClear(var pvar: TPropVariant): HResult; stdcall; external 'ole32.dll' name 'PropVariantClear';
procedure CoTaskMemFree(pv: Pointer); stdcall; external 'ole32.dll' name 'CoTaskMemFree';

const
  KSDATAFORMAT_SUBTYPE_PCM:        TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';

  eRender = 0;
  DEVICE_STATE_ACTIVE = DWORD($00000001);
  CLSCTX_ALL_ = DWORD($00000017);
  STGM_READ_ = DWORD(0);

  AUDCLNT_SHAREMODE_SHARED    = 0;
  AUDCLNT_SHAREMODE_EXCLUSIVE = 1;
  AUDCLNT_STREAMFLAGS_EVENTCALLBACK = DWORD($00040000);
  AUDCLNT_BUFFERFLAGS_SILENT = DWORD($00000002);
  AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED = HRESULT($88890019);

  WAVE_FORMAT_EXTENSIBLE_ = Word($FFFE);
  WAVE_FORMAT_PCM_        = Word(1);
  WAVE_FORMAT_IEEE_FLOAT_ = Word(3);

  REFTIMES_PER_SEC = Int64(10000000);
  C_MIN_EXCLUSIVE_PERIOD = Int64(50000);   // 5 ms
  C_SHARED_BUFFER = Int64(200000);         // 20 ms

// COM fuer den aufrufenden Thread sicherstellen (Host-Threads haben es in
// der Regel schon; RPC_E_CHANGED_MODE = bereits in anderem Modus - auch gut)
function EnsureCom: Boolean;
var
  HR: HResult;
begin
  HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  Result := (HR = S_OK) or (HR = S_FALSE);
end;

function CreateEnumerator(out AEnum: IMMDeviceEnumerator): HResult;
begin
  Result := CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL_,
    IID_IMMDeviceEnumerator, AEnum);
end;

function DeviceName(const ADevice: IMMDevice): string;
var
  Store: IPropertyStore;
  PV: TPropVariant;
begin
  Result := '';
  if ADevice.OpenPropertyStore(STGM_READ_, Store) <> S_OK then
    Exit;
  FillChar(PV, SizeOf(PV), 0);
  if Store.GetValue(PKEY_Device_FriendlyName, PV) = S_OK then
  begin
    if (PV.vt = VT_LPWSTR) and (PV.pwszVal <> nil) then
      Result := PV.pwszVal;
    PropVariantClear(PV);
  end;
end;

{ TS2400WasapiOut }

constructor TS2400WasapiOut.Create;
begin
  inherited Create;
  FAbortEvent := CreateEventW(nil, True, False, nil);
end;

destructor TS2400WasapiOut.Destroy;
begin
  Close;
  if FAbortEvent <> 0 then
    CloseHandle(FAbortEvent);
  inherited Destroy;
end;

procedure TS2400WasapiOut.Fail(const AContext: string; AHR: HResult);
begin
  FLastError := Format('%s fehlgeschlagen (HRESULT $%.8x)', [AContext, Cardinal(AHR)]);
end;

class function TS2400WasapiOut.ListDevices: TArray<TS2400WinDevice>;
var
  NeedUninit: Boolean;
  Enum: IMMDeviceEnumerator;
  Coll: IMMDeviceCollection;
  Dev: IMMDevice;
  Count: UINT;
  I: Integer;
  P: PWideChar;
  D: TS2400WinDevice;
begin
  Result := nil;
  NeedUninit := EnsureCom;
  try
    if CreateEnumerator(Enum) <> S_OK then
      Exit;
    if Enum.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE, Coll) <> S_OK then
      Exit;
    if Coll.GetCount(Count) <> S_OK then
      Exit;
    for I := 0 to Integer(Count) - 1 do
    begin
      if Coll.Item(I, Dev) <> S_OK then
        Continue;
      if Dev.GetId(P) <> S_OK then
        Continue;
      D.Id := P;
      CoTaskMemFree(P);
      D.Name := DeviceName(Dev);
      if D.Name = '' then
        D.Name := D.Id;
      Result := Result + [D];
    end;
  finally
    Dev := nil;
    Coll := nil;
    Enum := nil;
    if NeedUninit then
      CoUninitialize;
  end;
end;

function FillFormat(AChannels, ARate, ABits, AValid: Integer; AFloat, AExtensible: Boolean): TWaveFormatExtensible;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Format.nChannels := AChannels;
  Result.Format.nSamplesPerSec := ARate;
  Result.Format.wBitsPerSample := ABits;
  Result.Format.nBlockAlign := (ABits div 8) * AChannels;
  Result.Format.nAvgBytesPerSec := Cardinal(ARate) * Result.Format.nBlockAlign;
  if AExtensible then
  begin
    Result.Format.wFormatTag := WAVE_FORMAT_EXTENSIBLE_;
    Result.Format.cbSize := SizeOf(TWaveFormatExtensible) - SizeOf(TWaveFormatEx);
    Result.wValidBitsPerSample := AValid;
    Result.dwChannelMask := 3; // vorne links + rechts
    if AFloat then
      Result.SubFormat := KSDATAFORMAT_SUBTYPE_IEEE_FLOAT
    else
      Result.SubFormat := KSDATAFORMAT_SUBTYPE_PCM;
  end
  else
  begin
    if AFloat then
      Result.Format.wFormatTag := WAVE_FORMAT_IEEE_FLOAT_
    else
      Result.Format.wFormatTag := WAVE_FORMAT_PCM_;
    Result.Format.cbSize := 0;
  end;
end;

function TS2400WasapiOut.TryExclusive(const ADevice: IMMDevice; ARate: Integer): Boolean;
type
  TCand = record Bits, Valid: Integer; Float, Ext: Boolean; Kind: TS2400WinSampleKind; end;
const
  Cands: array[0..4] of TCand = (
    (Bits: 32; Valid: 32; Float: True;  Ext: True;  Kind: wskFloat32),
    (Bits: 32; Valid: 24; Float: False; Ext: True;  Kind: wskInt32),
    (Bits: 24; Valid: 24; Float: False; Ext: True;  Kind: wskInt24),
    (Bits: 16; Valid: 16; Float: False; Ext: True;  Kind: wskInt16),
    (Bits: 16; Valid: 16; Float: False; Ext: False; Kind: wskInt16));
var
  I: Integer;
  Fmt: TWaveFormatExtensible;
  Obj: IUnknown;
  Client: IAudioClient;
  HR: HResult;
  DefPeriod, MinPeriod, Period: Int64;
  BufFrames: UINT32;
begin
  Result := False;
  for I := 0 to High(Cands) do
  begin
    if ADevice.Activate(IID_IAudioClient, CLSCTX_ALL_, nil, Obj) <> S_OK then
      Exit;
    Client := Obj as IAudioClient;
    Fmt := FillFormat(2, ARate, Cands[I].Bits, Cands[I].Valid, Cands[I].Float, Cands[I].Ext);
    if Client.IsFormatSupported(AUDCLNT_SHAREMODE_EXCLUSIVE, @Fmt.Format, nil) <> S_OK then
      Continue;

    if Client.GetDevicePeriod(DefPeriod, MinPeriod) <> S_OK then
      MinPeriod := C_MIN_EXCLUSIVE_PERIOD;
    Period := MinPeriod;
    if Period < C_MIN_EXCLUSIVE_PERIOD then
      Period := C_MIN_EXCLUSIVE_PERIOD;

    HR := Client.Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      Period, Period, @Fmt.Format, nil);
    if HR = AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED then
    begin
      // laut Microsoft: verlangte Rahmenzahl holen, Periode neu, Client neu
      if Client.GetBufferSize(BufFrames) <> S_OK then
        Continue;
      Period := Round(BufFrames / ARate * REFTIMES_PER_SEC) + 1;
      Client := nil;
      if ADevice.Activate(IID_IAudioClient, CLSCTX_ALL_, nil, Obj) <> S_OK then
        Exit;
      Client := Obj as IAudioClient;
      HR := Client.Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        Period, Period, @Fmt.Format, nil);
    end;
    if HR <> S_OK then
    begin
      Fail('Initialize (exklusiv)', HR);
      Continue;
    end;

    FClient := Client;
    FRate := ARate;
    FDevChannels := 2;
    FKind := Cands[I].Kind;
    FBytesPerSample := Cands[I].Bits div 8;
    FBytesPerFrame := Fmt.Format.nBlockAlign;
    FExclusive := True;
    FFormatText := Format(Tr('exklusiv, %d Hz, %d/%d Bit', 'exclusive, %d Hz, %d/%d bit'), [ARate, Cands[I].Bits, Cands[I].Valid]);
    if Cands[I].Float then
      FFormatText := FFormatText + ' Float';
    Exit(True);
  end;
end;

function TS2400WasapiOut.InitShared(const ADevice: IMMDevice): Boolean;
var
  Obj: IUnknown;
  Client: IAudioClient;
  Mix: PWaveFormatEx;
  Ext: PWaveFormatExtensible;
  HR: HResult;
  IsFloat: Boolean;
begin
  Result := False;
  if ADevice.Activate(IID_IAudioClient, CLSCTX_ALL_, nil, Obj) <> S_OK then
    Exit;
  Client := Obj as IAudioClient;
  if Client.GetMixFormat(Mix) <> S_OK then
    Exit;
  try
    IsFloat := Mix^.wFormatTag = WAVE_FORMAT_IEEE_FLOAT_;
    if (Mix^.wFormatTag = WAVE_FORMAT_EXTENSIBLE_) and (Mix^.cbSize >= 22) then
    begin
      Ext := PWaveFormatExtensible(Mix);
      IsFloat := IsEqualGUID(Ext^.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    end;
    HR := Client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
      C_SHARED_BUFFER, 0, Mix, nil);
    if HR <> S_OK then
    begin
      Fail('Initialize (geteilt)', HR);
      Exit;
    end;
    FClient := Client;
    FRate := Mix^.nSamplesPerSec;
    FDevChannels := Mix^.nChannels;
    FBytesPerSample := Mix^.wBitsPerSample div 8;
    FBytesPerFrame := Mix^.nBlockAlign;
    if IsFloat and (FBytesPerSample = 4) then
      FKind := wskFloat32
    else if FBytesPerSample = 2 then
      FKind := wskInt16
    else if FBytesPerSample = 3 then
      FKind := wskInt24
    else
      FKind := wskInt32;
    FExclusive := False;
    FFormatText := Format(Tr('geteilt, %d Hz, %d Kan'#$00E4'le, %d Bit', 'shared, %d Hz, %d channels, %d bit'), [FRate, FDevChannels, Mix^.wBitsPerSample]);
    Result := True;
  finally
    CoTaskMemFree(Mix);
  end;
end;

function TS2400WasapiOut.FinishInit: Boolean;
var
  BufFrames: UINT32;
  HR: HResult;
  Obj: IUnknown;
begin
  Result := False;
  if FClient.GetBufferSize(BufFrames) <> S_OK then
    Exit;
  FBufferFrames := BufFrames;
  FEvent := CreateEventW(nil, False, False, nil);
  HR := FClient.SetEventHandle(FEvent);
  if HR <> S_OK then
  begin
    Fail('SetEventHandle', HR);
    Exit;
  end;
  HR := FClient.GetService(IID_IAudioRenderClient, Obj);
  if HR <> S_OK then
  begin
    Fail('GetService(IAudioRenderClient)', HR);
    Exit;
  end;
  FRender := Obj as IAudioRenderClient;
  Result := True;
end;

function TS2400WasapiOut.Open(const ADeviceId: string; APreferredRate: Integer; AExclusive: Boolean): Boolean;
var
  NeedUninit: Boolean;
  Enum: IMMDeviceEnumerator;
  Dev: IMMDevice;
  HR: HResult;
  Rates: array[0..2] of Integer;
  I: Integer;
  Ok: Boolean;
begin
  Result := False;
  Close;
  NeedUninit := EnsureCom;
  try
    HR := CreateEnumerator(Enum);
    if HR <> S_OK then
    begin
      Fail('MMDeviceEnumerator', HR);
      Exit;
    end;
    HR := Enum.GetDevice(PWideChar(ADeviceId), Dev);
    if HR <> S_OK then
    begin
      Fail('GetDevice', HR);
      Exit;
    end;

    Ok := False;
    if AExclusive then
    begin
      Rates[0] := APreferredRate;
      Rates[1] := 48000;
      Rates[2] := 44100;
      for I := 0 to High(Rates) do
        if (I = 0) or (Rates[I] <> APreferredRate) then
          if TryExclusive(Dev, Rates[I]) then
          begin
            Ok := True;
            Break;
          end;
    end;
    if not Ok then
      Ok := InitShared(Dev);
    if not Ok then
    begin
      if FLastError = '' then
        FLastError := 'Kein passendes Format';
      Exit;
    end;
    Result := FinishInit;
    if not Result then
      Close;
  finally
    Dev := nil;
    Enum := nil;
    // Die Objekte des Geraets sind frei-threaded (WASAPI) und bleiben auch
    // nach CoUninitialize dieses Threads gueltig, solange sie referenziert sind
    if NeedUninit then
      CoUninitialize;
  end;
end;

procedure TS2400WasapiOut.Close;
begin
  Stop;
  FRender := nil;
  FClient := nil;
  if FEvent <> 0 then
  begin
    CloseHandle(FEvent);
    FEvent := 0;
  end;
  FBufferFrames := 0;
end;

function TS2400WasapiOut.Start: Boolean;
begin
  Result := False;
  if (FClient = nil) or (FRender = nil) then
    Exit;
  if FStarted then
    Exit(True);
  ResetEvent(FAbortEvent);
  // mit Stille vorfuellen (verhindert Knacken beim Anlauf)
  WriteFrames(nil, WritableFrames, 2);
  if FClient.Start <> S_OK then
    Exit;
  FStarted := True;
  Result := True;
end;

procedure TS2400WasapiOut.Stop;
begin
  if FStarted and (FClient <> nil) then
  begin
    FClient.Stop;
    FClient.Reset;
  end;
  FStarted := False;
end;

function TS2400WasapiOut.WaitReady(ATimeoutMs: Cardinal): Boolean;
var
  H: array[0..1] of THandle;
begin
  if FEvent = 0 then
    Exit(False);
  H[0] := FEvent;
  H[1] := FAbortEvent;
  Result := WaitForMultipleObjects(2, @H[0], False, ATimeoutMs) = WAIT_OBJECT_0;
end;

procedure TS2400WasapiOut.Abort;
begin
  if FAbortEvent <> 0 then
    SetEvent(FAbortEvent);
end;

function TS2400WasapiOut.WritableFrames: Integer;
var
  Pad: UINT32;
begin
  Result := 0;
  if FClient = nil then
    Exit;
  if FExclusive then
    Result := FBufferFrames // exklusiv + Ereignis: jedes Mal den ganzen Puffer
  else if FClient.GetCurrentPadding(Pad) = S_OK then
    Result := Integer(FBufferFrames) - Integer(Pad);
end;

function ClampI(F: Single; AMax: Double): Integer; inline;
begin
  if F <> F then
    Exit(0);
  if F >= 1.0 then
    Exit(Round(AMax) - 1);
  if F <= -1.0 then
    Exit(-Round(AMax));
  Result := Round(F * AMax);
  if Result > Round(AMax) - 1 then
    Result := Round(AMax) - 1;
end;

function TS2400WasapiOut.WriteFrames(ASrc: System.PSingle; AFrames, ASrcChannels: Integer): Boolean;
var
  Data, P: PByte;
  F, C, V: Integer;
  S: Single;
begin
  Result := False;
  if (FRender = nil) or (AFrames <= 0) then
    Exit;
  if FRender.GetBuffer(AFrames, Data) <> S_OK then
    Exit;
  if ASrc = nil then
  begin
    FRender.ReleaseBuffer(AFrames, AUDCLNT_BUFFERFLAGS_SILENT);
    Exit(True);
  end;
  P := Data;
  for F := 0 to AFrames - 1 do
    for C := 0 to FDevChannels - 1 do
    begin
      if C < ASrcChannels then
        S := ASrc[F * ASrcChannels + C]
      else
        S := 0;
      case FKind of
        wskFloat32:
          System.PSingle(P)^ := S;
        wskInt16:
          PSmallInt(P)^ := ClampI(S, 32768.0);
        wskInt24:
          begin
            V := ClampI(S, 8388608.0);
            P[0] := V and $FF;
            P[1] := (V shr 8) and $FF;
            P[2] := (V shr 16) and $FF;
          end;
        wskInt32:
          PInteger(P)^ := ClampI(S, 2147483648.0);
      end;
      Inc(P, FBytesPerSample);
    end;
  Result := FRender.ReleaseBuffer(AFrames, 0) = S_OK;
end;

end.
