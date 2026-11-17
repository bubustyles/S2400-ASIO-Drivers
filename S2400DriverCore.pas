unit S2400DriverCore;

// =============================================================================
// S2400DriverCore.pas
//
// Kern des ISLA-S2400-ASIO-Treibers: implementiert das IASIO-COM-Interface
// (siehe AsioInterface.pas), koppelt es an die Kernel-Streaming-Engine
// (S2400KsEngine.pas) und stellt die COM-Infrastruktur bereit, damit ASIO-
// Hosts (Ableton, Cubase, Reaper, ...) die DLL als ASIO-Treiber laden.
//
// Enthaelt:
//   - TS2400AsioDriver: die IASIO-Implementierung
//   - TS2400StreamThread: Echtzeit-Audio-Thread (vom Capture-Event der
//     KS-Engine getaktet: Paket lesen -> bufferSwitch -> Paket schreiben)
//   - TS2400ClassFactory + die vier COM-DLL-Exportfunktionen
//
// Stand 12.10.2026 - Umstellung von WASAPI auf Kernel Streaming:
//   - 10 Eingaenge, 2 Ausgaenge (vom Geraet per KS gemeldet), 16 Bit
//     (ASIOSTInt16LSB), ausschliesslich 48 kHz
//   - ASIO-Puffergroesse = Paketgroesse des KS-Ringpuffers; wird im Control
//     Panel gewaehlt und als einzige Groesse an den Host gemeldet
//     (getBufferSize: min = max = preferred)
//   - gemeldete Latenz = Puffer + vom Treiber gemeldete Hardware-Latenz +
//     einstellbare Korrektur (fuer exakten Sync, per Messung ermitteln)
//   - Zeitstempel fuer bufferSwitchTimeInfo/getSamplePosition: Aufnahme-
//     zeitpunkt des ersten Samples im Capture-Paket (vom Treiber per
//     GETREADPACKET geliefert), auf timeGetTime()-Basis in Nanosekunden
//     umgerechnet, wie es die ASIO-Spezifikation fuer systemTime vorsieht
//   - Einstellungen bleiben unter HKCU\Software\S2400 ASIO Driver erhalten
// =============================================================================

{$POINTERMATH ON} // Zeigerarithmetik auf System.PSingle fuer den 44,1-kHz-Pfad

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.MMSystem,
  System.SysUtils,
  System.AnsiStrings,
  System.Classes,
  System.Win.Registry,
  AsioInterface,
  S2400KsInterop,
  S2400KsEngine,
  S2400Resampler,
  S2400ControlPanel,
  S2400MonitorLink,
  S2400Lang;

const
  // per Zufallsgenerator erzeugte, eindeutige CLSID dieses Treibers.
  // NICHT aendern, ohne den Treiber neu zu registrieren.
  CLSID_S2400AsioDriver: TGUID = '{BD9CF68B-F112-4EF6-AF4E-EE570DBF2B20}';

  S2400_DRIVER_NAME = 'S2400 ASIO Driver';
  S2400_DRIVER_VERSION = 2; // 2 = Kernel-Streaming-Engine

type
  TS2400AsioDriver = class; // Vorwaertsdeklaration fuer TS2400StreamThread

  TS2400StreamThread = class(TThread)
  private
    FDriver: TS2400AsioDriver;
  protected
    procedure Execute; override;
  public
    constructor Create(ADriver: TS2400AsioDriver);
  end;

  // Waechter fuer das Wiedereinstecken der Isla: wird vom Streaming-Thread
  // gestartet, sobald die Verbindung verloren ging, prueft alle 0,5 s, ob
  // der KS-Filter wieder da ist, und bittet dann den Host per
  // kAsioResetRequest um einen Neustart. Die Bitte kommt bewusst aus
  // DIESEM Thread und nicht aus dem Streaming-Thread: manche Hosts stoppen
  // den Treiber noch innerhalb des Aufrufs - der Streaming-Thread wuerde
  // dann auf sich selbst warten (Deadlock).
  TS2400DeviceWatchThread = class(TThread)
  private
    FDriver: TS2400AsioDriver;
    FQuitEvent: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(ADriver: TS2400AsioDriver);
    destructor Destroy; override;
    procedure SignalQuit;
  end;

  TS2400AsioDriver = class(TObject, IUnknown, IASIO)
  private
    FRefCount: Integer; // manuelles IUnknown statt TInterfacedObject (siehe QueryInterface)
    FEngine: TS2400KsEngine;
    FSysHandle: Pointer;
    FForeignMarker: THandle;  // S2400MonitorLink: Isla gehoert gerade diesem Programm
    FActive: Boolean;
    FBuffersCreated: Boolean;

    // Einstellungen (Control Panel, in der Registry gespeichert)
    FDesiredBufferFrames: Cardinal;
    FExtraInputLatency: Integer;
    FExtraOutputLatency: Integer;

    FBufferSizeSamples: Cardinal; // tatsaechliche Paketgroesse der Engine
    FHostBufferFrames: Cardinal;  // vom Host in createBuffers angelegt

    FBufferInfos: PASIOBufferInfo;
    FNumBufferChannels: Integer;
    FCallbacks: TASIOCallbacks;
    FSupportsTimeInfo: Boolean;
    FDoubleBufferIndex: LongInt;

    // 44,1-kHz-Betrieb (15.10.2026): Die Isla laeuft ueber USB IMMER mit
    // 48 kHz. Waehlt der Host 44,1 kHz, rechnet der Treiber mit
    // TS2400Resampler um (fest 147:160, ein einziger Taktgeber -> keine
    // Regelung noetig) und liefert dem Host Float32.
    FHostRate: Double;            // vom Host gewaehlte Rate: 48000 oder 44100
    FCapRes: TS2400Resampler;     // 48 -> Host-Rate, alle Eingaenge
    FRenRes: TS2400Resampler;     // Host-Rate -> 48, alle Ausgaenge
    FCapFloat: TArray<Single>;    // ein Capture-Paket als Float, interleaved
    FCapFifo: TArray<Single>;     // umgerechnete Eingangsframes, interleaved
    FCapFifoFrames: Integer;
    FRenTmp: TArray<Single>;      // Host-Ausgabe eines Puffers, interleaved
    FRenFifo: TArray<Single>;     // umgerechnete Ausgangsframes (48 kHz)
    FRenFifoFrames: Integer;
    FRenUnderruns: Int64;
    // Zeitmessung im Streaming-Thread (QPC-Ticks), Bilanz in DoStop
    FCycleCount: Int64;
    FLastCycleQpc: Int64;
    FMaxCycleGapQpc: Int64;
    FMaxCallbackQpc: Int64;
    FSlowCallbacks: Int64;
    FPacketQpc: Int64; // Dauer eines Pakets in QPC-Ticks

    // Sample-Position/Zeitstempel: FSamplePosition zaehlt fortlaufend,
    // FSwitch* ist das konsistente Paar des zuletzt ausgeloesten bufferSwitch
    FSamplePosition: Int64;
    FSwitchSamplePosition: Int64;
    FSwitchTimeNs: Int64;

    FInputActive: array[0..C_ISLA_MAX_INPUT_CHANNELS - 1] of Boolean;
    FOutputActive: array[0..C_ISLA_MAX_OUTPUT_CHANNELS - 1] of Boolean;

    FErrorMessage: string;
    FStreamThread: TS2400StreamThread;

    // Erkennen von Ausstecken/Wiedereinstecken der Isla
    FWatchThread: TS2400DeviceWatchThread;
    FDeviceLost: Boolean;      // Streaming-Thread hat Verbindungsverlust erkannt
    FNeedsReopen: Boolean;     // KS-Pins sind ungueltig, vor dem naechsten Start neu oeffnen
    FHadSuccess: Boolean;      // seit dem Start mindestens ein Paket erfolgreich verarbeitet
    FLastSuccessTick: UInt64;  // GetTickCount64 des letzten erfolgreichen Zyklus

    // Zeitbasis: QPC-Praezision, timeGetTime()-Bezug (ASIO-Spezifikation)
    FQpcFrequency: Int64;
    FStartQpc: Int64;
    FStartTimeNs: Int64;

    function BufferInfoAt(Base: PASIOBufferInfo; Index: Integer): PASIOBufferInfo;
    procedure FreePartialBuffers(Base: PASIOBufferInfo; UpToIndex: Integer);
    function QpcToSystemTimeNs(AQpc: Int64): Int64;
    function CurrentSystemTimeNs: Int64;
    function BuildInfoText: string;
    procedure LoadSettings;
    procedure SaveSettings;

    // eigentliche Implementierungen - die gleichnamigen IASIO-Methoden
    // rufen sie nur in einem try/except auf, damit NIE eine Delphi-
    // Ausnahme in den Host durchschlaegt (Matrix-Absturz 12.10.2026 mit
    // Ausnahmecode 0x0EEDFADE = unbehandelte Delphi-Ausnahme)
    function DoInit(sysHandle: Pointer): TASIOBool;
    function DoStart: TASIOError;
    function DoStop: TASIOError;
    function DoCreateBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
      bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError;
    function DoDisposeBuffers: TASIOError;
    function DoControlPanel: TASIOError;

    // Ausstecken/Wiedereinstecken (siehe TS2400DeviceWatchThread)
    procedure CheckDeviceLoss;      // vom Streaming-Thread
    procedure RequestHostReset;     // vom Waechter-Thread
    procedure StopWatcher;
    function ReopenEngineIfNeeded: Boolean;

    // 44,1-kHz-Betrieb
    function IsResampling: Boolean;
    function HostBufferSize: Cardinal;
    function HostSampleBytes: Integer;
    procedure EnsureResamplers;
    procedure ResetResampling;
    procedure FreeResampling;
    procedure ProcessResampled(ACaptureData: PByte; AFrames: Cardinal; out ACallbackQpc: Int64);
    procedure DeinterleaveFloatInput;
    procedure FeedHostOutputToResampler;
    procedure WriteRenderResampled;

    // nur fuer TS2400StreamThread bestimmt (gleiche Unit -> "private" genuegt)
    function ProcessCycle: Boolean;
    procedure DeinterleaveInput(ACaptureData: PByte; AFrames: Cardinal);
    procedure InterleaveOutput;
    procedure InvokeHostBufferSwitch;
  public
    constructor Create;
    destructor Destroy; override;

    // IUnknown - von Hand implementiert (protokollierbar, siehe QueryInterface)
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    function _AddRef: Integer; stdcall;
    function _Release: Integer; stdcall;

    // IASIO
    function init(sysHandle: Pointer): TASIOBool; stdcall;
    procedure getDriverName(name: PAnsiChar); stdcall;
    function getDriverVersion: LongInt; stdcall;
    procedure getErrorMessage(errorMessage: PAnsiChar); stdcall;
    function start: TASIOError; stdcall;
    function stop: TASIOError; stdcall;
    function getChannels(out numInputChannels, numOutputChannels: LongInt): TASIOError; stdcall;
    function getLatencies(out inputLatency, outputLatency: LongInt): TASIOError; stdcall;
    function getBufferSize(out minSize, maxSize, preferredSize, granularity: LongInt): TASIOError; stdcall;
    function canSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
    function getSampleRate(out sampleRate: TASIOSampleRate): TASIOError; stdcall;
    function setSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
    function getClockSources(clocks: PASIOClockSource; var numSources: LongInt): TASIOError; stdcall;
    function setClockSource(reference: LongInt): TASIOError; stdcall;
    function getSamplePosition(out sPos: TASIOSamples; out tStamp: TASIOTimeStamp): TASIOError; stdcall;
    function getChannelInfo(var info: TASIOChannelInfo): TASIOError; stdcall;
    function createBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
      bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError; stdcall;
    function disposeBuffers: TASIOError; stdcall;
    function controlPanel: TASIOError; stdcall;
    function future(selector: LongInt; opt: Pointer): TASIOError; stdcall;
    function outputReady: TASIOError; stdcall;
  end;

  TS2400ClassFactory = class(TInterfacedObject, IClassFactory)
  public
    function CreateInstance(const unkOuter: IUnknown; const iid: TGUID; out obj): HResult; stdcall;
    function LockServer(fLock: BOOL): HResult; stdcall;
  end;

// Standard-COM-DLL-Exportfunktionen (siehe exports in S2400AsioDriver.dpr)
function DllGetClassObject(const CLSID, IID: TGUID; out Obj): HResult; stdcall;
function DllCanUnloadNow: HResult; stdcall;
function DllRegisterServer: HResult; stdcall;
function DllUnregisterServer: HResult; stdcall;

implementation

// RegDeleteTreeW ist in dieser RTL-Version nicht deklariert (advapi32.dll
// seit Windows Vista).
function RegDeleteTreeW(hKey: HKEY; lpSubKey: LPCWSTR): Longint; stdcall;
  external 'advapi32.dll' name 'RegDeleteTreeW';

// MMCSS (Multimedia Class Scheduler Service): registriert den Streaming-
// Thread als zeitkritischen "Pro Audio"-Thread.
const
  AVRT_PRIORITY_CRITICAL = 2;

function AvSetMmThreadCharacteristicsW(TaskName: LPCWSTR; var TaskIndex: DWORD): THandle; stdcall;
  external 'avrt.dll' name 'AvSetMmThreadCharacteristicsW';
function AvRevertMmThreadCharacteristics(AvrtHandle: THandle): BOOL; stdcall;
  external 'avrt.dll' name 'AvRevertMmThreadCharacteristics';
function AvSetMmThreadPriority(AvrtHandle: THandle; Priority: LongInt): BOOL; stdcall;
  external 'avrt.dll' name 'AvSetMmThreadPriority';

const
  C_SETTINGS_KEY = 'Software\S2400 ASIO Driver';

  // Anlaufzyklen, die bei der Zeitmessung ignoriert werden
  C_TIMING_WARMUP = 50;

  // so lange ohne erfolgreichen Zyklus gilt die Isla als ausgesteckt
  C_DEVICE_LOST_MS = 500;

  // Filterverzoegerung der Umrechner bei 48 <-> 44,1 kHz (Standard-
  // Parameter von TS2400Resampler, gemessen mit S2400ResamplerTest am
  // 14.10.2026): 48 -> 44,1: 76 Eingangsframes (48 kHz),
  // 44,1 -> 48: 69 Eingangsframes (Host-Rate)
  C_CAPRES_DELAY_48K = 76;
  C_RENRES_DELAY_HOST = 69;

  // Vorlauf der Ausgabe im 44,1-kHz-Betrieb ZUSAETZLICH zu einem Paket.
  // Ein Paket Vorlauf allein war zu knapp: Test 15.10.2026 ergab 75
  // Ausgabe-Unterlaeufe (Anlaufphase). Eine exakte Zaehl-Simulation des
  // Pfads (gleiche Logik wie Resampler/FIFOs, ganzzahlig 160/147) ergab fuer
  // ALLE Paketgroessen 96..512 als Minimum "Paket + 152" (152 = Filterlaenge
  // 48 -> 44,1); dazu 32 Frames Reserve -> 0 Unterlaeufe, min. Fuellstand
  // >= 32 Frames.
  C_RENDER_PREFILL_EXTRA = 152 + 32;

var
  // Referenzzaehler fuer DllCanUnloadNow
  GObjectCount: Integer = 0;
  GLockCount: Integer = 0;

// -----------------------------------------------------------------------
// kleine Hilfsfunktionen
// -----------------------------------------------------------------------

function BoolToAsio(B: Boolean): TASIOBool; inline;
begin
  if B then
    Result := ASIOTrue
  else
    Result := ASIOFalse;
end;

procedure CopyToAnsiBuffer(const S: string; Buffer: PAnsiChar; MaxLen: Integer);
var
  A: AnsiString;
begin
  if (Buffer = nil) or (MaxLen <= 0) then
    Exit;
  A := AnsiString(S);
  System.AnsiStrings.StrPLCopy(Buffer, A, MaxLen - 1);
end;

function WriteRegStringValue(RootKey: HKEY; const SubKey, ValueName, Value: string): Boolean;
var
  Key: HKEY;
begin
  Result := False;
  if RegCreateKeyExW(RootKey, PWideChar(SubKey), 0, nil, REG_OPTION_NON_VOLATILE,
    KEY_WRITE, nil, Key, nil) <> ERROR_SUCCESS then
    Exit;
  try
    Result := RegSetValueExW(Key, PWideChar(ValueName), 0, REG_SZ,
      Pointer(PWideChar(Value)), (Length(Value) + 1) * SizeOf(WideChar)) = ERROR_SUCCESS;
  finally
    RegCloseKey(Key);
  end;
end;

function GetThisModuleFileName: string;
var
  Buffer: array[0..MAX_PATH] of WideChar;
begin
  if GetModuleFileNameW(HInstance, Buffer, MAX_PATH) = 0 then
    Result := ''
  else
    Result := PWideChar(@Buffer[0]);
end;

function SamplesToMs(ASamples: Integer): Double;
begin
  Result := ASamples * 1000.0 / C_ISLA_SAMPLE_RATE;
end;

procedure LogException(const AWhere: string; E: Exception);
begin
  S2400Log(Format('AUSNAHME in %s: %s: %s (Adresse %p)',
    [AWhere, E.ClassName, E.Message, ExceptAddr]));
end;

// -----------------------------------------------------------------------
// TS2400StreamThread
// -----------------------------------------------------------------------

constructor TS2400StreamThread.Create(ADriver: TS2400AsioDriver);
begin
  // suspendiert erstellen, damit FDriver gesetzt ist, bevor Execute laeuft.
  // WICHTIG: hier NICHT Start aufrufen! TThread.AfterConstruction prueft
  // nach dem Konstruktor FCreateSuspended - das hat ein Start im
  // Konstruktor bereits zurueckgesetzt, also versucht Delphi den laufenden
  // Thread ein zweites Mal zu starten und loest EThread aus ("Cannot call
  // Start on a running or suspended thread"). Genau diese Ausnahme flog am
  // 12.10.2026 aus IASIO.start() in Ableton/Matrix (Absturz, Code
  // 0x0EEDFADE). Gestartet wird deshalb erst nach dem Konstruktor in DoStart.
  inherited Create(True);
  FDriver := ADriver;
  FreeOnTerminate := False;
  Priority := tpTimeCritical;
end;

procedure TS2400StreamThread.Execute;
var
  MmcssHandle: THandle;
  MmcssTaskIndex: DWORD;
begin
  // ALLE Gleitkomma-Ausnahmen maskieren (Windows-Standard: MXCSR = $1F80,
  // x87 = $027F). Delphi-Threads starten mit teilweise SCHARFEN Ausnahmen
  // (ungueltige Operation, Division durch null, Ueberlauf). In diesem
  // Thread laeuft ueber bufferSwitch die komplette Audioverarbeitung des
  // Hosts - dessen DSP-Code verlaesst sich darauf, dass z.B. 0/0 still NaN
  // liefert. Ohne Maskierung loest die CPU dort eine Ausnahme aus und der
  // Host stuerzt ab (Ableton 12.10.2026: "serious program error" direkt
  // beim ersten Zyklus).
  SetMXCSR($1F80);
  Set8087CW($027F);

  MmcssTaskIndex := 0;
  MmcssHandle := AvSetMmThreadCharacteristicsW('Pro Audio', MmcssTaskIndex);
  if MmcssHandle <> 0 then
    AvSetMmThreadPriority(MmcssHandle, AVRT_PRIORITY_CRITICAL)
  else
    S2400Log(Format('WARNUNG: AvSetMmThreadCharacteristics("Pro Audio") fehlgeschlagen ' +
      '(Fehlercode %d) - Streaming-Thread laeuft ohne MMCSS-Priorisierung.', [GetLastError]));

  try
    // getaktet vom Capture-Event der KS-Engine (ein Event pro Paket).
    // Meldet der Treiber MoreData (Thread lag zurueck), werden die
    // aufgelaufenen Pakete ohne Warten nacheinander verarbeitet, damit die
    // Sample-Position luecken- und driftfrei bleibt.
    while not Terminated do
    begin
      if not FDriver.FEngine.WaitForCaptureReady(200) then
      begin
        // Timeout: kommt laenger nichts, ist die Isla vermutlich
        // ausgesteckt worden (siehe CheckDeviceLoss)
        if not Terminated then
          FDriver.CheckDeviceLoss;
        Continue;
      end;

      while not Terminated do
      begin
        try
          if not FDriver.ProcessCycle then
            Break;
        except
          on E: Exception do
          begin
            // einmal protokollieren und den Thread beenden (Audio steht
            // dann, aber der Host stuerzt nicht ab)
            LogException('Streaming-Thread', E);
            Exit;
          end;
        end;
        if not FDriver.FEngine.CaptureMoreData then
          Break;
      end;

      // auch wenn Events kommen, das Lesen aber dauerhaft scheitert
      FDriver.CheckDeviceLoss;
    end;
  finally
    if MmcssHandle <> 0 then
      AvRevertMmThreadCharacteristics(MmcssHandle);
  end;
end;

// -----------------------------------------------------------------------
// TS2400DeviceWatchThread
// -----------------------------------------------------------------------

constructor TS2400DeviceWatchThread.Create(ADriver: TS2400AsioDriver);
begin
  // suspendiert erzeugen, gestartet wird vom Aufrufer (NICHT im Konstruktor,
  // siehe TS2400StreamThread.Create)
  inherited Create(True);
  FDriver := ADriver;
  FreeOnTerminate := False;
  FQuitEvent := CreateEventW(nil, True, False, nil);
end;

destructor TS2400DeviceWatchThread.Destroy;
begin
  inherited Destroy; // wartet bei laufendem Thread auf dessen Ende
  if FQuitEvent <> 0 then
    CloseHandle(FQuitEvent);
end;

procedure TS2400DeviceWatchThread.SignalQuit;
begin
  if FQuitEvent <> 0 then
    SetEvent(FQuitEvent);
end;

procedure TS2400DeviceWatchThread.Execute;
var
  Paths: TStringList;
  I: Integer;
  Present: Boolean;
begin
  Paths := TStringList.Create;
  try
    while not Terminated do
    begin
      if WaitForSingleObject(FQuitEvent, 500) = WAIT_OBJECT_0 then
        Exit;

      FindKsDevicePaths(KSCATEGORY_CAPTURE, VID_ISLA_S2400, PID_ISLA_S2400, Paths);
      Present := False;
      for I := 0 to Paths.Count - 1 do
        if Pos('MSFT_WAVE', UpperCase(Paths[I])) > 0 then
          Present := True;

      if Present then
      begin
        S2400Log('Isla wieder angeschlossen - in 1 s Neustart-Anforderung an den Host');
        // Windows/USB-Audiotreiber etwas Zeit geben, das Geraet fertig
        // einzurichten, sonst schlaegt das Oeffnen der Pins ggf. fehl
        if WaitForSingleObject(FQuitEvent, 1000) = WAIT_OBJECT_0 then
          Exit;
        // WICHTIG: nach diesem Aufruf FDriver NICHT mehr anfassen - der
        // Host kann den Treiber darin bereits gestoppt oder freigegeben haben
        FDriver.RequestHostReset;
        Exit;
      end;
    end;
  finally
    Paths.Free;
  end;
end;

// -----------------------------------------------------------------------
// TS2400AsioDriver - Lebenszyklus
// -----------------------------------------------------------------------

constructor TS2400AsioDriver.Create;
begin
  inherited Create;
  InterlockedIncrement(GObjectCount);
  S2400Log('TS2400AsioDriver.Create');

  FDesiredBufferFrames := C_ISLA_DEFAULT_BUFFER_SAMPLES;
  FExtraInputLatency := 0;
  FExtraOutputLatency := 0;
  // Vorgabe 48 kHz - LoadSettings uebernimmt ggf. die im Control Panel
  // gespeicherte Rate; waehlt der Host per setSampleRate eine Rate, gilt die
  FHostRate := C_ISLA_SAMPLE_RATE;
  LoadSettings;
  FBufferSizeSamples := FDesiredBufferFrames;

  // Zeitbasis: QPC und timeGetTime() moeglichst gleichzeitig festhalten
  if not QueryPerformanceFrequency(FQpcFrequency) then
    FQpcFrequency := 0;
  QueryPerformanceCounter(FStartQpc);
  FStartTimeNs := Int64(timeGetTime) * 1000000;
  FSwitchTimeNs := FStartTimeNs;
end;

destructor TS2400AsioDriver.Destroy;
begin
  S2400Log('TS2400AsioDriver.Destroy');
  stop;
  disposeBuffers;
  StopWatcher; // falls noch einer laeuft (z.B. Host beendet, waehrend die Isla fehlt)
  FreeResampling;

  if FEngine <> nil then
  begin
    FEngine.Close;
    FreeAndNil(FEngine);
  end;
  S2400ReleaseClaim(FForeignMarker); // S2400 Monitor darf die Isla wieder nehmen

  InterlockedDecrement(GObjectCount);
  inherited Destroy;
end;

procedure TS2400AsioDriver.LoadSettings;
var
  Reg: TRegistry;
  V: Integer;
begin
  Reg := TRegistry.Create(KEY_READ);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKeyReadOnly(C_SETTINGS_KEY) then
      begin
        if Reg.ValueExists('BufferFrames') then
        begin
          V := Reg.ReadInteger('BufferFrames');
          if (V >= 16) and (V <= 2048) then
          begin
            // nur gemessen saubere Groessen zulassen (z.B. alte 128 -> 144,
            // siehe C_S2400_BUFFER_OPTIONS)
            FDesiredBufferFrames := NearestAllowedBufferSize(Cardinal(V));
            if FDesiredBufferFrames <> Cardinal(V) then
              S2400Log(Format('Gespeicherte Puffergroesse %d ist nicht zulaessig - verwende %d',
                [V, FDesiredBufferFrames]));
          end;
        end;
        if Reg.ValueExists('ExtraInputLatency') then
          FExtraInputLatency := Reg.ReadInteger('ExtraInputLatency');
        if Reg.ValueExists('ExtraOutputLatency') then
          FExtraOutputLatency := Reg.ReadInteger('ExtraOutputLatency');
        if Reg.ValueExists('SampleRate') and (Reg.ReadInteger('SampleRate') = 44100) then
          FHostRate := 44100;
      end;
    except
      on E: Exception do
        S2400Log('Einstellungen konnten nicht gelesen werden: ' + E.Message);
    end;
  finally
    Reg.Free;
  end;
  S2400Log(Format('Einstellungen: Puffer %d Frames, Latenz-Korrektur Ein %d / Aus %d',
    [FDesiredBufferFrames, FExtraInputLatency, FExtraOutputLatency]));
end;

procedure TS2400AsioDriver.SaveSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKey(C_SETTINGS_KEY, True) then
      begin
        Reg.WriteInteger('BufferFrames', Integer(FDesiredBufferFrames));
        Reg.WriteInteger('ExtraInputLatency', FExtraInputLatency);
        Reg.WriteInteger('ExtraOutputLatency', FExtraOutputLatency);
        Reg.WriteInteger('SampleRate', Round(FHostRate));
      end;
    except
      on E: Exception do
        S2400Log('Einstellungen konnten nicht gespeichert werden: ' + E.Message);
    end;
  finally
    Reg.Free;
  end;
end;

function TS2400AsioDriver.QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
var
  EffectiveIID: TGUID;
begin
  // Viele ASIO-Hosts (bestaetigt fuer Ableton und VB-Audio Matrix) fragen
  // mit der Treiber-CLSID statt der IASIO-GUID an (historische Eigenheit).
  if IsEqualGUID(IID, CLSID_S2400AsioDriver) then
    EffectiveIID := IID_ASIO
  else
    EffectiveIID := IID;

  if GetInterface(EffectiveIID, Obj) then
    Result := S_OK
  else
  begin
    Pointer(Obj) := nil;
    Result := E_NOINTERFACE;
  end;

  S2400Log(Format('TS2400AsioDriver.QueryInterface(%s) -> HRESULT $%.8x',
    [GUIDToString(IID), Cardinal(Result)]));
end;

function TS2400AsioDriver._AddRef: Integer; stdcall;
begin
  Result := InterlockedIncrement(FRefCount);
end;

function TS2400AsioDriver._Release: Integer; stdcall;
begin
  Result := InterlockedDecrement(FRefCount);
  if Result = 0 then
    Destroy;
end;

// rechnet einen QPC-Wert in Nanosekunden auf timeGetTime()-Basis um -
// ueber Sekunden/Rest, damit Int64 auch nach Stunden nicht ueberlaeuft
function TS2400AsioDriver.QpcToSystemTimeNs(AQpc: Int64): Int64;
var
  Delta, Seconds, Remainder: Int64;
begin
  if FQpcFrequency = 0 then
    Exit(Int64(timeGetTime) * 1000000);
  Delta := AQpc - FStartQpc;
  Seconds := Delta div FQpcFrequency;
  Remainder := Delta mod FQpcFrequency;
  Result := FStartTimeNs + Seconds * 1000000000 + (Remainder * 1000000000) div FQpcFrequency;
end;

function TS2400AsioDriver.CurrentSystemTimeNs: Int64;
var
  NowQpc: Int64;
begin
  QueryPerformanceCounter(NowQpc);
  Result := QpcToSystemTimeNs(NowQpc);
end;

function TS2400AsioDriver.BufferInfoAt(Base: PASIOBufferInfo; Index: Integer): PASIOBufferInfo;
begin
  Result := PASIOBufferInfo(NativeUInt(Base) + NativeUInt(Index) * SizeOf(TASIOBufferInfo));
end;

procedure TS2400AsioDriver.FreePartialBuffers(Base: PASIOBufferInfo; UpToIndex: Integer);
var
  J: Integer;
  Info: PASIOBufferInfo;
begin
  for J := 0 to UpToIndex - 1 do
  begin
    Info := BufferInfoAt(Base, J);
    if Info^.buffers[0] <> nil then
      FreeMem(Info^.buffers[0]);
    if Info^.buffers[1] <> nil then
      FreeMem(Info^.buffers[1]);
    Info^.buffers[0] := nil;
    Info^.buffers[1] := nil;
  end;
end;

function TS2400AsioDriver.BuildInfoText: string;
var
  InLat, OutLat: LongInt;
  RateText: string;
begin
  if (FEngine = nil) or not FEngine.IsOpen then
    Exit(Tr('ISLA S2400 ist nicht ge'#$00F6'ffnet.', 'ISLA S2400 is not open.') + #13#10 + FErrorMessage);

  getLatencies(InLat, OutLat);
  if IsResampling then
    RateText := Format(Tr('Host %.1f kHz (Umrechnung im Treiber, Isla l'#$00E4'uft mit 48 kHz)',
      'Host %.1f kHz (converted in the driver, the Isla runs at 48 kHz)'),
      [FHostRate / 1000])
  else
    RateText := Tr('48 kHz / 16 Bit ohne Umrechnung', '48 kHz / 16 bit, no conversion');
  Result := Format(Tr(
    'ISLA S2400 - Kernel Streaming, %d Eing'#$00E4'nge / %d Ausg'#$00E4'nge'#13#10 +
    '%s'#13#10 +
    'Isla-Paket: %d Samples (%.2f ms), Host-Puffer: %d Samples'#13#10 +
    'Gemeldete Latenz: Eingang %d Samples (%.2f ms), Ausgang %d Samples (%.2f ms)',
    'ISLA S2400 - Kernel Streaming, %d inputs / %d outputs'#13#10 +
    '%s'#13#10 +
    'Isla packet: %d samples (%.2f ms), host buffer: %d samples'#13#10 +
    'Reported latency: input %d samples (%.2f ms), output %d samples (%.2f ms)'),
    [FEngine.InputChannels, FEngine.OutputChannels, RateText,
     FBufferSizeSamples, SamplesToMs(FBufferSizeSamples), HostBufferSize,
     InLat, InLat * 1000 / FHostRate, OutLat, OutLat * 1000 / FHostRate]);
end;

// -----------------------------------------------------------------------
// TS2400AsioDriver - Ausstecken/Wiedereinstecken der Isla
// -----------------------------------------------------------------------

// vom Streaming-Thread: kommt seit C_DEVICE_LOST_MS kein Paket mehr,
// obwohl es vorher lief, gilt die Isla als getrennt. Dann wird NICHT sofort
// ein Host-Reset angefordert (der Host wuerde den Treiber neu laden, das
// scheitert ohne Geraet, und niemand bemerkt mehr das Wiedereinstecken),
// sondern der Waechter-Thread gestartet.
procedure TS2400AsioDriver.CheckDeviceLoss;
begin
  try
    if FDeviceLost or not FHadSuccess then
      Exit;
    if GetTickCount64 - FLastSuccessTick < C_DEVICE_LOST_MS then
      Exit;

    FDeviceLost := True;
    FNeedsReopen := True;
    S2400Log(Format('Isla-Verbindung verloren (seit %d ms keine Pakete) - warte auf Wiedereinstecken',
      [GetTickCount64 - FLastSuccessTick]));

    // ein evtl. noch vorhandener, beendeter Waechter eines frueheren
    // Verlusts wird vorher aufgeraeumt (laeuft nie in diesem Thread)
    if FWatchThread <> nil then
    begin
      FWatchThread.SignalQuit;
      FWatchThread.Terminate;
      FWatchThread.WaitFor;
      FreeAndNil(FWatchThread);
    end;
    FWatchThread := TS2400DeviceWatchThread.Create(Self);
    FWatchThread.Start;
  except
    on E: Exception do
      LogException('CheckDeviceLoss', E);
  end;
end;

// vom Waechter-Thread, wenn die Isla wieder da ist
procedure TS2400AsioDriver.RequestHostReset;
var
  Msg: TASIOMessageProc;
begin
  Msg := FCallbacks.asioMessage; // lokale Kopie - der Host kann die Puffer
                                 // (und damit FCallbacks) im Aufruf freigeben
  if Assigned(Msg) then
  begin
    S2400Log('Sende kAsioResetRequest an den Host (Isla wieder verbunden)');
    Msg(kAsioResetRequest, 0, nil, nil);
  end
  else
    S2400Log('Kein Host-Callback vorhanden - Treiber bitte im Host neu starten');
end;

procedure TS2400AsioDriver.StopWatcher;
begin
  if FWatchThread = nil then
    Exit;

  if FWatchThread.ThreadID = GetCurrentThreadId then
  begin
    // Der Host reagiert SYNCHRON auf die Reset-Anforderung, wir laufen also
    // gerade im Waechter selbst - nicht auf uns selbst warten (Deadlock),
    // sondern den Thread sich nach dem Ende selbst freigeben lassen
    FWatchThread.FreeOnTerminate := True;
    FWatchThread := nil;
    Exit;
  end;

  FWatchThread.SignalQuit;
  FWatchThread.Terminate;
  FWatchThread.WaitFor;
  FreeAndNil(FWatchThread);
end;

// oeffnet die KS-Verbindung neu, wenn die Isla zwischendurch getrennt war
// (die alten Pin-Handles sind dann ungueltig). Wird in init, createBuffers
// und start aufgerufen, weil Hosts nach einem Reset unterschiedlich viel
// davon erneut aufrufen.
function TS2400AsioDriver.ReopenEngineIfNeeded: Boolean;
begin
  Result := True;
  if not FNeedsReopen or (FEngine = nil) then
    Exit;

  S2400Log('Isla war getrennt - oeffne die Verbindung neu');
  FEngine.Close;
  FEngine.DesiredBufferSizeFrames := FDesiredBufferFrames;
  Result := FEngine.Open;
  if Result then
  begin
    FBufferSizeSamples := FEngine.BufferSizeFrames;
    FNeedsReopen := False;
    FDeviceLost := False;
    S2400Log('Verbindung zur Isla wiederhergestellt');
  end
  else
    FErrorMessage := FEngine.LastError;
end;

// -----------------------------------------------------------------------
// TS2400AsioDriver - Streaming (nur vom TS2400StreamThread genutzt)
// -----------------------------------------------------------------------

function TS2400AsioDriver.ProcessCycle: Boolean;
var
  CaptureData: PByte;
  Frames: Cardinal;
  T0, T1, T2, Gap, Callback: Int64;
begin
  Result := False;
  if not FBuffersCreated then
    Exit;

  // kein neues Capture-Paket -> diesen Zyklus komplett auslassen (kein
  // bufferSwitch, sonst laeuft die Sample-Position der Hardware davon)
  if not FEngine.ReadCaptureBuffer(CaptureData, Frames) then
    Exit;

  // Zeitmessung statt Logging (Logging im Echtzeit-Thread kostet ~6 ms
  // und hat am 13.10.2026 selbst Pakete verloren). Ausgewertet wird erst
  // ab dem C_TIMING_WARMUP-ten Zyklus, damit der Anlauf nicht zaehlt.
  QueryPerformanceCounter(T0);
  Inc(FCycleCount);
  if (FCycleCount > C_TIMING_WARMUP) and (FLastCycleQpc <> 0) then
  begin
    Gap := T0 - FLastCycleQpc;
    if Gap > FMaxCycleGapQpc then
      FMaxCycleGapQpc := Gap;
  end;
  FLastCycleQpc := T0;

  if IsResampling then
    // 44,1 kHz: 0..2 Host-Rueckrufe pro Paket (siehe ProcessResampled)
    ProcessResampled(CaptureData, Frames, Callback)
  else
  begin
    // 48 kHz: genau ein Host-Rueckruf pro Paket, ohne Umrechnung
    DeinterleaveInput(CaptureData, Frames);
    QueryPerformanceCounter(T1);
    InvokeHostBufferSwitch;
    QueryPerformanceCounter(T2);
    Callback := T2 - T1;
    InterleaveOutput;
    FDoubleBufferIndex := 1 - FDoubleBufferIndex;
  end;

  if FCycleCount > C_TIMING_WARMUP then
  begin
    if Callback > FMaxCallbackQpc then
      FMaxCallbackQpc := Callback;
    if Callback > FPacketQpc then
      Inc(FSlowCallbacks);
  end;

  // fuer die Erkennung des Aussteckens (CheckDeviceLoss)
  FHadSuccess := True;
  FLastSuccessTick := GetTickCount64;
  Result := True;
end;

// -----------------------------------------------------------------------
// 44,1-kHz-Betrieb: Umrechnung im Treiber
// -----------------------------------------------------------------------

function TS2400AsioDriver.IsResampling: Boolean;
begin
  Result := Abs(FHostRate - C_ISLA_SAMPLE_RATE) >= 0.5;
end;

// Host-Puffergroesse: bei 48 kHz = Paketgroesse; bei 44,1 kHz die
// entsprechende Dauer (144 -> 132,3), auf eine gerade Zahl gerundet. Die
// Zwischenspeicher gleichen aus, dass das nicht exakt aufgeht (mal 0, mal
// 2 Host-Rueckrufe pro Paket statt 1).
function TS2400AsioDriver.HostBufferSize: Cardinal;
begin
  if not IsResampling then
    Exit(FBufferSizeSamples);
  Result := 2 * Cardinal(Round(FBufferSizeSamples * FHostRate / C_ISLA_SAMPLE_RATE / 2));
  if Result < 16 then
    Result := 16;
end;

// Bytes pro Sample in den Host-Puffern: Int16 bei 48 kHz (bitgenau wie die
// Isla), Float32 bei 44,1 kHz (keine Genauigkeitsverluste durch die
// Umrechnung)
function TS2400AsioDriver.HostSampleBytes: Integer;
begin
  if IsResampling then
    Result := 4
  else
    Result := C_ISLA_BYTES_PER_SAMPLE;
end;

procedure TS2400AsioDriver.FreeResampling;
begin
  FreeAndNil(FCapRes);
  FreeAndNil(FRenRes);
  FCapFloat := nil;
  FCapFifo := nil;
  FRenTmp := nil;
  FRenFifo := nil;
  FCapFifoFrames := 0;
  FRenFifoFrames := 0;
end;

// legt Umrechner und Zwischenspeicher passend zu Rate, Kanaelen und
// Puffergroessen an (Filterberechnung dauert einige ms - deshalb NICHT im
// Echtzeit-Thread, sondern in createBuffers/start)
procedure TS2400AsioDriver.EnsureResamplers;
var
  P, B, InCh, OutCh: Integer;
begin
  if not IsResampling then
  begin
    FreeResampling;
    Exit;
  end;
  InCh := FEngine.InputChannels;
  OutCh := FEngine.OutputChannels;
  P := FBufferSizeSamples;
  B := HostBufferSize;

  if (FCapRes = nil) or (FCapRes.OutRate <> FHostRate) or (FCapRes.Channels <> InCh) or
     (FRenRes = nil) or (FRenRes.Channels <> OutCh) then
  begin
    FreeResampling;
    FCapRes := TS2400Resampler.Create(InCh, C_ISLA_SAMPLE_RATE, FHostRate);
    FRenRes := TS2400Resampler.Create(OutCh, FHostRate, C_ISLA_SAMPLE_RATE);
    S2400Log(Format('Umrechnung aktiv: Isla 48000 Hz <-> Host %.0f Hz, Host-Puffer %d Frames, ' +
      'Filter %d/%d Taps', [FHostRate, B, FCapRes.Taps, FRenRes.Taps]));
  end;

  SetLength(FCapFloat, P * InCh);
  SetLength(FCapFifo, (B + 2 * P + 256) * InCh);
  SetLength(FRenTmp, B * OutCh);
  SetLength(FRenFifo, (8 * P + 2 * B + 256) * OutCh);
end;

// vor jedem Start: Umrechner leeren, Zwischenspeicher zuruecksetzen und die
// Ausgabe mit einem Paket Stille vorbelegen, damit sie im Anlauf (bevor der
// erste Host-Puffer umgerechnet ist) nicht leerlaeuft
procedure TS2400AsioDriver.ResetResampling;
begin
  if (FCapRes = nil) or (FRenRes = nil) then
    Exit;
  FCapRes.Reset;
  FRenRes.Reset;
  FCapFifoFrames := 0;
  FillChar(FRenFifo[0], Length(FRenFifo) * SizeOf(Single), 0);
  FRenFifoFrames := FBufferSizeSamples + C_RENDER_PREFILL_EXTRA;
  FRenUnderruns := 0;
end;

// Ein Isla-Paket (48 kHz) im 44,1-kHz-Betrieb verarbeiten:
//  1. Paket -> Float -> Umrechner 48 -> 44,1
//  2. je volle Host-Puffer: in die Host-Puffer verteilen, bufferSwitch,
//     Host-Ausgabe -> Umrechner 44,1 -> 48
//  3. umgerechnete Ausgabe in die Render-FIFO, ein Paket an die Isla
procedure TS2400AsioDriver.ProcessResampled(ACaptureData: PByte; AFrames: Cardinal;
  out ACallbackQpc: Int64);
const
  Scale16 = 1.0 / 32768.0;
var
  InCh, OutCh, I, N, Got, Space, B: Integer;
  Src: PSmallInt;
  Dst: System.PSingle;
  T1, T2: Int64;
begin
  ACallbackQpc := 0;
  InCh := FEngine.InputChannels;
  OutCh := FEngine.OutputChannels;
  B := FHostBufferFrames;

  // 1. Capture-Paket nach Float und in den Umrechner
  Src := PSmallInt(ACaptureData);
  Dst := System.PSingle(Pointer(FCapFloat));
  N := Integer(AFrames) * InCh;
  for I := 0 to N - 1 do
  begin
    Dst^ := Src^ * Scale16;
    Inc(Dst);
    Inc(Src);
  end;
  FCapRes.Push(System.PSingle(Pointer(FCapFloat)), AFrames);

  // 2. umgerechnete Frames sammeln, je volle Host-Puffer ein bufferSwitch
  repeat
    Space := Length(FCapFifo) div InCh - FCapFifoFrames;
    Got := FCapRes.Pull(System.PSingle(Pointer(FCapFifo)) + FCapFifoFrames * InCh, Space);
    Inc(FCapFifoFrames, Got);
    while FCapFifoFrames >= B do
    begin
      DeinterleaveFloatInput;
      QueryPerformanceCounter(T1);
      InvokeHostBufferSwitch;
      QueryPerformanceCounter(T2);
      Inc(ACallbackQpc, T2 - T1);
      FeedHostOutputToResampler;
      FDoubleBufferIndex := 1 - FDoubleBufferIndex;

      Dec(FCapFifoFrames, B);
      if FCapFifoFrames > 0 then
        Move((System.PSingle(Pointer(FCapFifo)) + B * InCh)^, System.PSingle(Pointer(FCapFifo))^,
          FCapFifoFrames * InCh * SizeOf(Single));
    end;
  until Got = 0;

  // 3. umgerechnete Host-Ausgabe in die Render-FIFO holen
  Space := Length(FRenFifo) div OutCh - FRenFifoFrames;
  Got := FRenRes.Pull(System.PSingle(Pointer(FRenFifo)) + FRenFifoFrames * OutCh, Space);
  Inc(FRenFifoFrames, Got);

  WriteRenderResampled;
end;

procedure TS2400AsioDriver.DeinterleaveFloatInput;
var
  I, S, InCh, B: Integer;
  Info: PASIOBufferInfo;
  Src, Dst: System.PSingle;
begin
  InCh := FEngine.InputChannels;
  B := FHostBufferFrames;
  for I := 0 to FNumBufferChannels - 1 do
  begin
    Info := BufferInfoAt(FBufferInfos, I);
    if Info^.isInput = 0 then
      Continue;
    Src := System.PSingle(Pointer(FCapFifo)) + Info^.channelNum;
    Dst := System.PSingle(Info^.buffers[FDoubleBufferIndex]);
    for S := 0 to B - 1 do
    begin
      Dst^ := Src^;
      Inc(Dst);
      Inc(Src, InCh);
    end;
  end;
end;

procedure TS2400AsioDriver.FeedHostOutputToResampler;
var
  I, S, OutCh, B: Integer;
  Info: PASIOBufferInfo;
  Src, Dst: System.PSingle;
begin
  OutCh := FEngine.OutputChannels;
  B := FHostBufferFrames;
  // nicht vom Host belegte Ausgaenge bleiben still
  FillChar(FRenTmp[0], B * OutCh * SizeOf(Single), 0);
  for I := 0 to FNumBufferChannels - 1 do
  begin
    Info := BufferInfoAt(FBufferInfos, I);
    if Info^.isInput <> 0 then
      Continue;
    Src := System.PSingle(Info^.buffers[FDoubleBufferIndex]);
    Dst := System.PSingle(Pointer(FRenTmp)) + Info^.channelNum;
    for S := 0 to B - 1 do
    begin
      Dst^ := Src^;
      Inc(Src);
      Inc(Dst, OutCh);
    end;
  end;
  FRenRes.Push(System.PSingle(Pointer(FRenTmp)), B);
end;

// ein Geraete-Paket (48 kHz, Int16) aus der Render-FIFO schreiben
procedure TS2400AsioDriver.WriteRenderResampled;
var
  RenderData: PByte;
  Frames: Cardinal;
  OutCh, N, I: Integer;
  Src: System.PSingle;
  Dst: PSmallInt;
  V: Integer;
  F: Single;
begin
  Frames := FEngine.BufferSizeFrames;
  if not FEngine.WriteRenderBuffer(RenderData, Frames) then
    Exit;

  OutCh := FEngine.OutputChannels;
  N := Integer(Frames);
  if N > FRenFifoFrames then
  begin
    // Unterlauf: mit Stille auffuellen (sollte nach dem Anlauf nicht vorkommen)
    FillChar(RenderData^, Frames * Cardinal(FEngine.BytesPerFrameRender), 0);
    N := FRenFifoFrames;
    Inc(FRenUnderruns);
  end;

  Src := System.PSingle(Pointer(FRenFifo));
  Dst := PSmallInt(RenderData);
  for I := 0 to N * OutCh - 1 do
  begin
    // erst begrenzen, dann runden - so koennen auch NaN/Unendlich vom Host
    // keine Bereichsverletzung ausloesen (NaN <> NaN -> Stille)
    F := Src^;
    if F <> F then
      V := 0
    else if F >= 32767.0 / 32768.0 then
      V := 32767
    else if F <= -1.0 then
      V := -32768
    else
      V := Round(F * 32768.0);
    Dst^ := V;
    Inc(Src);
    Inc(Dst);
  end;

  Dec(FRenFifoFrames, N);
  if FRenFifoFrames > 0 then
    Move((System.PSingle(Pointer(FRenFifo)) + N * OutCh)^, System.PSingle(Pointer(FRenFifo))^,
      FRenFifoFrames * OutCh * SizeOf(Single));

  FEngine.ReleaseRenderBuffer;
end;

procedure TS2400AsioDriver.DeinterleaveInput(ACaptureData: PByte; AFrames: Cardinal);
var
  I, S, Count, Stride: Integer;
  Info: PASIOBufferInfo;
  Src, Dst: PSmallInt;
begin
  Count := AFrames;
  if Cardinal(Count) > FHostBufferFrames then
    Count := FHostBufferFrames;
  Stride := FEngine.InputChannels; // Samples pro Frame (16 Bit interleaved)

  for I := 0 to FNumBufferChannels - 1 do
  begin
    Info := BufferInfoAt(FBufferInfos, I);
    if Info^.isInput = 0 then
      Continue;

    Src := PSmallInt(ACaptureData);
    Inc(Src, Info^.channelNum);
    Dst := PSmallInt(Info^.buffers[FDoubleBufferIndex]);
    for S := 0 to Count - 1 do
    begin
      Dst^ := Src^;
      Inc(Dst);
      Inc(Src, Stride);
    end;
  end;
end;

procedure TS2400AsioDriver.InterleaveOutput;
var
  I, S, Count, Stride: Integer;
  Info: PASIOBufferInfo;
  Src, Dst: PSmallInt;
  RenderData: PByte;
  Frames: Cardinal;
begin
  Frames := FEngine.BufferSizeFrames;
  if not FEngine.WriteRenderBuffer(RenderData, Frames) then
    Exit;

  // nicht vom Host belegte Ausgangskanaele mit Stille fuellen
  FillChar(RenderData^, Frames * Cardinal(FEngine.BytesPerFrameRender), 0);

  Count := Frames;
  if Cardinal(Count) > FHostBufferFrames then
    Count := FHostBufferFrames;
  Stride := FEngine.OutputChannels;

  for I := 0 to FNumBufferChannels - 1 do
  begin
    Info := BufferInfoAt(FBufferInfos, I);
    if Info^.isInput <> 0 then
      Continue;

    Src := PSmallInt(Info^.buffers[FDoubleBufferIndex]);
    Dst := PSmallInt(RenderData);
    Inc(Dst, Info^.channelNum);
    for S := 0 to Count - 1 do
    begin
      Dst^ := Src^;
      Inc(Src);
      Inc(Dst, Stride);
    end;
  end;

  FEngine.ReleaseRenderBuffer;
end;

procedure TS2400AsioDriver.InvokeHostBufferSwitch;
var
  TimeInfo: TASIOTime;
  Qpc: UInt64;
begin
  // Zeitstempel = Aufnahmezeitpunkt des ersten Samples dieses Pakets
  // (vom Treiber), sonst ersatzweise "jetzt"
  Qpc := FEngine.LastCaptureQpc;
  if Qpc <> 0 then
    FSwitchTimeNs := QpcToSystemTimeNs(Int64(Qpc))
  else
    FSwitchTimeNs := CurrentSystemTimeNs;
  FSwitchSamplePosition := FSamplePosition;

  if FSupportsTimeInfo and Assigned(FCallbacks.bufferSwitchTimeInfo) then
  begin
    FillChar(TimeInfo, SizeOf(TimeInfo), 0);
    TimeInfo.timeInfo.flags := kSystemTimeValid or kSamplePositionValid or kSampleRateValid;
    TimeInfo.timeInfo.sampleRate := FHostRate;
    Int64ToASIOSamples(FSwitchSamplePosition, TimeInfo.timeInfo.samplePosition);
    Int64ToASIOTimeStamp(FSwitchTimeNs, TimeInfo.timeInfo.systemTime);

    FCallbacks.bufferSwitchTimeInfo(@TimeInfo, FDoubleBufferIndex, ASIOFalse);
  end
  else if Assigned(FCallbacks.bufferSwitch) then
    FCallbacks.bufferSwitch(FDoubleBufferIndex, ASIOFalse);

  Inc(FSamplePosition, FHostBufferFrames);
end;

// -----------------------------------------------------------------------
// TS2400AsioDriver - IASIO
// -----------------------------------------------------------------------

function TS2400AsioDriver.DoInit(sysHandle: Pointer): TASIOBool;
begin
  FSysHandle := sysHandle;
  S2400Log('IASIO.init() aufgerufen');

  if FEngine = nil then
    FEngine := TS2400KsEngine.Create;

  // war die Isla zwischendurch getrennt, sind die alten Pins ungueltig
  if not ReopenEngineIfNeeded then
  begin
    S2400Log('FEHLER in init() beim Neuverbinden: ' + FErrorMessage);
    Exit(ASIOFalse);
  end;

  if not FEngine.IsOpen then
  begin
    // haelt S2400 Monitor die Isla ueber den Verbund? Dann zuerst freigeben lassen
    case S2400ClaimFromMonitor(FForeignMarker) of
      crReleased: S2400Log('S2400 Monitor hat die Isla freigegeben');
      crTimeout:  S2400Log('HINWEIS: S2400 Monitor hat nicht innerhalb von 5 s freigegeben');
    end;
    FEngine.DesiredBufferSizeFrames := FDesiredBufferFrames;
    if not FEngine.Open then
    begin
      FErrorMessage := FEngine.LastError;
      S2400Log('FEHLER in init(): ' + FErrorMessage);
      Exit(ASIOFalse);
    end;
    FBufferSizeSamples := FEngine.BufferSizeFrames;
  end;

  S2400Log(Format('IASIO.init() erfolgreich: %d Ein / %d Aus, Puffer %d Frames',
    [FEngine.InputChannels, FEngine.OutputChannels, FBufferSizeSamples]));
  Result := ASIOTrue;
end;

procedure TS2400AsioDriver.getDriverName(name: PAnsiChar); stdcall;
begin
  CopyToAnsiBuffer(S2400_DRIVER_NAME, name, 32);
end;

function TS2400AsioDriver.getDriverVersion: LongInt; stdcall;
begin
  Result := S2400_DRIVER_VERSION;
end;

procedure TS2400AsioDriver.getErrorMessage(errorMessage: PAnsiChar); stdcall;
begin
  S2400Log('IASIO.getErrorMessage() -> "' + FErrorMessage + '"');
  CopyToAnsiBuffer(FErrorMessage, errorMessage, 124);
end;

function TS2400AsioDriver.DoStart: TASIOError;
begin
  if FActive then
    Exit(ASE_OK);

  // war die Isla zwischendurch getrennt, sind die alten Pins ungueltig
  if not ReopenEngineIfNeeded then
  begin
    S2400Log('FEHLER in start() beim Neuverbinden: ' + FErrorMessage);
    Exit(ASE_HWMalfunction);
  end;

  if (FEngine = nil) or not FEngine.IsOpen then
    Exit(ASE_NotPresent);
  if not FBuffersCreated then
    Exit(ASE_InvalidMode);
  if FHostBufferFrames <> HostBufferSize then
  begin
    // Puffergroesse wurde im Control Panel geaendert, der Host hat seine
    // Puffer aber noch nicht neu angelegt (Reset steht aus)
    FErrorMessage := Format(Tr('Puffergr'#$00F6#$00DF'e ge'#$00E4'ndert (%d statt %d) - bitte Treiber neu laden.',
      'Buffer size changed (%d instead of %d) - please reload the driver.'),
      [HostBufferSize, FHostBufferFrames]);
    S2400Log('start() abgelehnt: ' + FErrorMessage);
    Exit(ASE_InvalidMode);
  end;
  if FActive then
    Exit(ASE_OK);

  FDoubleBufferIndex := 0;
  FSamplePosition := 0;
  FSwitchSamplePosition := 0;
  FCycleCount := 0;
  FLastCycleQpc := 0;
  FMaxCycleGapQpc := 0;
  FMaxCallbackQpc := 0;
  FSlowCallbacks := 0;
  FPacketQpc := (FQpcFrequency * Int64(FBufferSizeSamples)) div C_ISLA_SAMPLE_RATE;
  FDeviceLost := False;
  FHadSuccess := False;
  FLastSuccessTick := GetTickCount64;

  // 44,1 kHz: Umrechner sicherstellen (z.B. nach Neuverbinden der Isla) und
  // Zwischenspeicher fuer den neuen Lauf zuruecksetzen
  EnsureResamplers;
  ResetResampling;

  FSupportsTimeInfo := Assigned(FCallbacks.asioMessage) and
    (FCallbacks.asioMessage(kAsioSupportsTimeInfo, 0, nil, nil) = 1);

  if not FEngine.StartStreaming then
  begin
    FErrorMessage := FEngine.LastError;
    S2400Log('FEHLER in start(): ' + FErrorMessage);
    Exit(ASE_HWMalfunction);
  end;

  FStreamThread := TS2400StreamThread.Create(Self);
  FStreamThread.Start; // erst NACH dem Konstruktor (siehe TS2400StreamThread.Create)
  FActive := True;
  S2400Log(Format('IASIO.start() OK (TimeInfo=%s)', [BoolToStr(FSupportsTimeInfo, True)]));
  Result := ASE_OK;
end;

function TS2400AsioDriver.DoStop: TASIOError;
begin
  if not FActive then
    Exit(ASE_OK);

  if FStreamThread <> nil then
  begin
    FStreamThread.Terminate;
    if FEngine <> nil then
      FEngine.AbortStreaming; // weckt ein blockierendes WaitForCaptureReady
    FStreamThread.WaitFor;
    FreeAndNil(FStreamThread);
  end;

  // erst NACH dem Streaming-Thread (der startet den Waechter)
  StopWatcher;

  if FEngine <> nil then
    FEngine.StopStreaming;

  FActive := False;

  // Zeit-Bilanz des Laufs (ohne die ersten C_TIMING_WARMUP Zyklen):
  // Host-Rueckruf laenger als ein Paket -> der Host (z.B. Matrix) war zu
  // langsam; grosse Luecke zwischen Zyklen -> der Thread wurde von
  // Windows zu spaet geweckt
  if FQpcFrequency > 0 then
    S2400Log(Format('  Zeiten: %d Zyklen, Paket = %.2f ms, Host-bufferSwitch max %.2f ms, ' +
      '%d mal laenger als ein Paket, groesste Luecke zwischen Zyklen %.2f ms',
      [FCycleCount, FPacketQpc * 1000 / FQpcFrequency, FMaxCallbackQpc * 1000 / FQpcFrequency,
       FSlowCallbacks, FMaxCycleGapQpc * 1000 / FQpcFrequency]));
  if IsResampling then
    S2400Log(Format('  Umrechnung %.0f Hz: Ausgabe-Unterlaeufe %d (sollte 0 sein)',
      [FHostRate, FRenUnderruns]));

  S2400Log('IASIO.stop()');
  Result := ASE_OK;
end;

function TS2400AsioDriver.getChannels(out numInputChannels, numOutputChannels: LongInt): TASIOError; stdcall;
begin
  if (FEngine = nil) or not FEngine.IsOpen then
  begin
    numInputChannels := 0;
    numOutputChannels := 0;
    Exit(ASE_NotPresent);
  end;
  numInputChannels := FEngine.InputChannels;
  numOutputChannels := FEngine.OutputChannels;
  Result := ASE_OK;
end;

function TS2400AsioDriver.getLatencies(out inputLatency, outputLatency: LongInt): TASIOError; stdcall;
begin
  if (FEngine = nil) or not FEngine.IsOpen then
  begin
    inputLatency := 0;
    outputLatency := 0;
    Exit(ASE_NotPresent);
  end;

  // Eingang: das erste Sample eines Pakets ist beim bufferSwitch genau eine
  // Paketlaenge alt (+ Hardware-Anteil). Ausgang: geschrieben wird das
  // Paket NACH dem gerade laufenden, es startet also spaetestens eine
  // Paketlaenge spaeter (+ Hardware-Anteil). Dazu die im Control Panel
  // eingestellte Korrektur aus der Messung.
  if not IsResampling then
  begin
    inputLatency := LongInt(FBufferSizeSamples) + FEngine.InputHwLatencyFrames + FExtraInputLatency;
    outputLatency := LongInt(FBufferSizeSamples) + FEngine.OutputHwLatencyFrames + FExtraOutputLatency;
  end
  else
  begin
    // 44,1 kHz, alles in Host-Frames. Eingang: Paket + Filterverzoegerung
    // des Umrechners (beides bei 48 kHz, umgerechnet) + Wartezeit im
    // Zwischenspeicher (bis ein Host-Puffer voll ist). Ausgang: Host-Puffer
    // + Filterverzoegerung (bei Host-Rate) + Vorlauf der Ausgabe (1 Paket)
    // + das Paket an die Isla. Rechnerischer Wert - per Klick-Test pruefen
    // und ggf. ueber die Latenz-Korrektur angleichen.
    inputLatency := LongInt(HostBufferSize) +
      Round((FBufferSizeSamples + C_CAPRES_DELAY_48K + FEngine.InputHwLatencyFrames) *
        FHostRate / C_ISLA_SAMPLE_RATE) + FExtraInputLatency;
    outputLatency := LongInt(HostBufferSize) + C_RENRES_DELAY_HOST +
      Round((2 * FBufferSizeSamples + C_RENDER_PREFILL_EXTRA + FEngine.OutputHwLatencyFrames) *
        FHostRate / C_ISLA_SAMPLE_RATE) + FExtraOutputLatency;
  end;
  if inputLatency < 0 then
    inputLatency := 0;
  if outputLatency < 0 then
    outputLatency := 0;
  Result := ASE_OK;
end;

function TS2400AsioDriver.getBufferSize(out minSize, maxSize, preferredSize, granularity: LongInt): TASIOError; stdcall;
begin
  // genau eine Groesse: bei 48 kHz die Paketgroesse des KS-Ringpuffers (im
  // Control Panel waehlbar), bei 44,1 kHz die entsprechende Host-Groesse
  // (z.B. 144 -> 132). Der Host kann sie nicht frei waehlen.
  minSize := LongInt(HostBufferSize);
  maxSize := LongInt(HostBufferSize);
  preferredSize := LongInt(HostBufferSize);
  granularity := 0;
  Result := ASE_OK;
end;

function TS2400AsioDriver.canSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
begin
  // Die Isla selbst kann ueber USB nur 48 kHz (KSPROPERTY_PIN_DATARANGES).
  // 44,1 kHz bietet der Treiber per Umrechnung an.
  if (Abs(sampleRate - C_ISLA_SAMPLE_RATE) < 0.5) or (Abs(sampleRate - 44100) < 0.5) then
    Result := ASE_OK
  else
    Result := ASE_NoClock;
end;

function TS2400AsioDriver.getSampleRate(out sampleRate: TASIOSampleRate): TASIOError; stdcall;
begin
  sampleRate := FHostRate;
  Result := ASE_OK;
end;

function TS2400AsioDriver.setSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
var
  NewRate: Double;
begin
  try
    if Abs(sampleRate - C_ISLA_SAMPLE_RATE) < 0.5 then
      NewRate := C_ISLA_SAMPLE_RATE
    else if Abs(sampleRate - 44100) < 0.5 then
      NewRate := 44100
    else
    begin
      S2400Log(Format('setSampleRate(%.0f) abgelehnt - nur 48000 oder 44100 Hz m'#$00F6'glich', [sampleRate]));
      Exit(ASE_NoClock);
    end;

    if Abs(NewRate - FHostRate) < 0.5 then
      Exit(ASE_OK); // bereits eingestellt

    S2400Log(Format('setSampleRate: %.0f -> %.0f Hz', [FHostRate, NewRate]));
    // Rate, Host-Puffergroesse und Sample-Format haengen zusammen - laufendes
    // Streaming anhalten; hat der Host bereits Puffer angelegt, muss er sie
    // neu anlegen (Reset-Anforderung)
    if FActive then
      stop;
    FHostRate := NewRate;
    if FBuffersCreated and Assigned(FCallbacks.asioMessage) then
      FCallbacks.asioMessage(kAsioResetRequest, 0, nil, nil);
    Result := ASE_OK;
  except
    on E: Exception do
    begin
      LogException('setSampleRate', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.getClockSources(clocks: PASIOClockSource; var numSources: LongInt): TASIOError; stdcall;
begin
  if (clocks = nil) or (numSources < 1) then
  begin
    numSources := 0;
    Exit(ASE_OK);
  end;

  // einzige Taktquelle: die USB-Audio-Clock des Geraets
  FillChar(clocks^, SizeOf(TASIOClockSource), 0);
  clocks^.index := 0;
  clocks^.associatedChannel := -1;
  clocks^.associatedGroup := -1;
  clocks^.isCurrentSource := ASIOTrue;
  CopyToAnsiBuffer('Internal', @clocks^.name[0], 32);
  numSources := 1;
  Result := ASE_OK;
end;

function TS2400AsioDriver.setClockSource(reference: LongInt): TASIOError; stdcall;
begin
  if reference = 0 then
    Result := ASE_OK
  else
    Result := ASE_InvalidParameter;
end;

function TS2400AsioDriver.getSamplePosition(out sPos: TASIOSamples; out tStamp: TASIOTimeStamp): TASIOError; stdcall;
begin
  // konsistentes Paar des zuletzt ausgeloesten bufferSwitch
  Int64ToASIOSamples(FSwitchSamplePosition, sPos);
  Int64ToASIOTimeStamp(FSwitchTimeNs, tStamp);
  Result := ASE_OK;
end;

function TS2400AsioDriver.getChannelInfo(var info: TASIOChannelInfo): TASIOError; stdcall;
var
  MaxChannels: Integer;
begin
  if (FEngine = nil) or not FEngine.IsOpen then
    Exit(ASE_NotPresent);

  if info.isInput <> 0 then
    MaxChannels := FEngine.InputChannels
  else
    MaxChannels := FEngine.OutputChannels;

  if (info.channel < 0) or (info.channel >= MaxChannels) then
    Exit(ASE_InvalidParameter);

  if info.isInput <> 0 then
    info.isActive := BoolToAsio(FInputActive[info.channel])
  else
    info.isActive := BoolToAsio(FOutputActive[info.channel]);

  info.channelGroup := 0;
  if IsResampling then
    info.sampleType := ASIOSTFloat32LSB // 44,1 kHz: Umrechnung, verlustfrei als Float
  else
    info.sampleType := ASIOSTInt16LSB;  // 48 kHz: bitgenau wie die Isla

  if info.isInput <> 0 then
    CopyToAnsiBuffer(Format('S2400 In %d', [info.channel + 1]), @info.name[0], 32)
  else
    CopyToAnsiBuffer(Format('S2400 Out %d', [info.channel + 1]), @info.name[0], 32);

  Result := ASE_OK;
end;

function TS2400AsioDriver.DoCreateBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
  bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError;
var
  I: Integer;
  Info: PASIOBufferInfo;
  ByteSize: Cardinal;
begin
  // war die Isla zwischendurch getrennt, sind die alten Pins ungueltig -
  // neu oeffnen (dafuer darf nicht gestreamt werden)
  if FNeedsReopen then
  begin
    if FActive then
      stop;
    if not ReopenEngineIfNeeded then
    begin
      S2400Log('FEHLER in createBuffers() beim Neuverbinden: ' + FErrorMessage);
      Exit(ASE_HWMalfunction);
    end;
  end;

  if (FEngine = nil) or not FEngine.IsOpen then
    Exit(ASE_NotPresent);
  if (bufferInfos = nil) or (numChannels <= 0) then
    Exit(ASE_InvalidParameter);

  if Cardinal(bufferSize) <> HostBufferSize then
  begin
    FErrorMessage := Format(Tr('Puffergr'#$00F6#$00DF'e %d nicht m'#$00F6'glich, nur %d (Control Panel).',
      'Buffer size %d not possible, only %d (control panel).'),
      [bufferSize, HostBufferSize]);
    S2400Log('createBuffers abgelehnt: ' + FErrorMessage);
    Exit(ASE_InvalidMode);
  end;

  if FBuffersCreated then
    disposeBuffers;

  FillChar(FInputActive, SizeOf(FInputActive), 0);
  FillChar(FOutputActive, SizeOf(FOutputActive), 0);
  ByteSize := Cardinal(bufferSize) * Cardinal(HostSampleBytes);

  for I := 0 to numChannels - 1 do
  begin
    Info := BufferInfoAt(bufferInfos, I);
    Info^.buffers[0] := nil;
    Info^.buffers[1] := nil;

    if Info^.isInput <> 0 then
    begin
      if (Info^.channelNum < 0) or (Info^.channelNum >= FEngine.InputChannels) then
      begin
        FreePartialBuffers(bufferInfos, I);
        Exit(ASE_InvalidParameter);
      end;
      FInputActive[Info^.channelNum] := True;
    end
    else
    begin
      if (Info^.channelNum < 0) or (Info^.channelNum >= FEngine.OutputChannels) then
      begin
        FreePartialBuffers(bufferInfos, I);
        Exit(ASE_InvalidParameter);
      end;
      FOutputActive[Info^.channelNum] := True;
    end;

    GetMem(Info^.buffers[0], ByteSize);
    GetMem(Info^.buffers[1], ByteSize);
    FillChar(Info^.buffers[0]^, ByteSize, 0);
    FillChar(Info^.buffers[1]^, ByteSize, 0);
  end;

  FBufferInfos := bufferInfos;
  FNumBufferChannels := numChannels;
  FCallbacks := callbacks;
  FHostBufferFrames := Cardinal(bufferSize);
  FBuffersCreated := True;

  // bei 44,1 kHz Umrechner und Zwischenspeicher anlegen (Filterberechnung
  // hier, nicht im Echtzeit-Thread)
  EnsureResamplers;

  S2400Log(Format('createBuffers: %d Kanaele, %d Frames, %.0f Hz, %d Bytes/Sample',
    [numChannels, bufferSize, FHostRate, HostSampleBytes]));
  Result := ASE_OK;
end;

function TS2400AsioDriver.DoDisposeBuffers: TASIOError;
var
  I: Integer;
  Info: PASIOBufferInfo;
begin
  if FActive then
    stop;

  if not FBuffersCreated then
    Exit(ASE_OK);

  for I := 0 to FNumBufferChannels - 1 do
  begin
    Info := BufferInfoAt(FBufferInfos, I);
    if Info^.buffers[0] <> nil then
      FreeMem(Info^.buffers[0]);
    if Info^.buffers[1] <> nil then
      FreeMem(Info^.buffers[1]);
    Info^.buffers[0] := nil;
    Info^.buffers[1] := nil;
  end;

  FBufferInfos := nil;
  FNumBufferChannels := 0;
  FHostBufferFrames := 0;
  FBuffersCreated := False;
  FillChar(FCallbacks, SizeOf(FCallbacks), 0);
  FillChar(FInputActive, SizeOf(FInputActive), 0);
  FillChar(FOutputActive, SizeOf(FOutputActive), 0);

  Result := ASE_OK;
end;

function TS2400AsioDriver.DoControlPanel: TASIOError;
var
  NewBuffer: Cardinal;
  NewExtraIn, NewExtraOut: Integer;
  NewRate: Double;
  BufferChanged, LatencyChanged, RateChanged: Boolean;
begin
  // vom Host synchron aus dem UI-Thread aufgerufen, blockiert bis zum
  // Schliessen des Dialogs (ASIO-Konvention)
  NewRate := FHostRate;
  NewBuffer := FDesiredBufferFrames;
  NewExtraIn := FExtraInputLatency;
  NewExtraOut := FExtraOutputLatency;

  if not ShowS2400ControlPanel(HWND(FSysHandle), BuildInfoText, NewRate, NewBuffer,
    NewExtraIn, NewExtraOut) then
    Exit(ASE_OK); // abgebrochen

  RateChanged := Abs(NewRate - FHostRate) >= 0.5;
  BufferChanged := NewBuffer <> FDesiredBufferFrames;
  LatencyChanged := (NewExtraIn <> FExtraInputLatency) or (NewExtraOut <> FExtraOutputLatency);

  // Samplerate ueber die regulaere IASIO-Methode umstellen: haelt ein
  // laufendes Streaming an und bittet den Host (bei angelegten Puffern) um
  // einen Neustart. Ob der Host die Wahl uebernimmt oder beim Neustart per
  // setSampleRate seine eigene Rate vorgibt, entscheidet der Host - beides
  // steht im Log.
  if RateChanged then
  begin
    S2400Log(Format('Control Panel: Samplerate %.0f Hz gewaehlt', [NewRate]));
    setSampleRate(NewRate);
  end;

  FDesiredBufferFrames := NewBuffer;
  FExtraInputLatency := NewExtraIn;
  FExtraOutputLatency := NewExtraOut;
  SaveSettings;

  if BufferChanged then
  begin
    S2400Log(Format('Control Panel: neue Puffergroesse %d Frames', [FDesiredBufferFrames]));
    // KS-Ringpuffer laesst sich nur beim Oeffnen der Pins festlegen ->
    // Streaming anhalten, Pins mit neuer Groesse neu oeffnen, Host-Reset
    if FActive then
      stop;
    if FEngine <> nil then
    begin
      FEngine.Close;
      FEngine.DesiredBufferSizeFrames := FDesiredBufferFrames;
      if FEngine.Open then
        FBufferSizeSamples := FEngine.BufferSizeFrames
      else
      begin
        FErrorMessage := FEngine.LastError;
        S2400Log('FEHLER beim Neuoeffnen: ' + FErrorMessage);
      end;
    end
    else
      FBufferSizeSamples := FDesiredBufferFrames;

    if Assigned(FCallbacks.asioMessage) then
      FCallbacks.asioMessage(kAsioResetRequest, 0, nil, nil);
  end
  else if LatencyChanged then
  begin
    S2400Log(Format('Control Panel: Latenz-Korrektur Ein %d / Aus %d', [FExtraInputLatency, FExtraOutputLatency]));
    if Assigned(FCallbacks.asioMessage) then
      FCallbacks.asioMessage(kAsioLatenciesChanged, 0, nil, nil);
  end;

  Result := ASE_OK;
end;

// -----------------------------------------------------------------------
// IASIO-Einstiegspunkte mit Ausnahmeschutz: eine Delphi-Ausnahme darf nie
// in den Host durchschlagen - sie wird protokolliert und als ASIO-Fehler
// gemeldet.
// -----------------------------------------------------------------------

function TS2400AsioDriver.init(sysHandle: Pointer): TASIOBool; stdcall;
begin
  try
    Result := DoInit(sysHandle);
  except
    on E: Exception do
    begin
      LogException('init', E);
      FErrorMessage := E.Message;
      Result := ASIOFalse;
    end;
  end;
end;

function TS2400AsioDriver.start: TASIOError; stdcall;
begin
  try
    Result := DoStart;
  except
    on E: Exception do
    begin
      LogException('start', E);
      FErrorMessage := E.Message;
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.stop: TASIOError; stdcall;
begin
  try
    Result := DoStop;
  except
    on E: Exception do
    begin
      LogException('stop', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.createBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
  bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError; stdcall;
begin
  try
    Result := DoCreateBuffers(bufferInfos, numChannels, bufferSize, callbacks);
  except
    on E: Exception do
    begin
      LogException('createBuffers', E);
      FErrorMessage := E.Message;
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.disposeBuffers: TASIOError; stdcall;
begin
  try
    Result := DoDisposeBuffers;
  except
    on E: Exception do
    begin
      LogException('disposeBuffers', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.controlPanel: TASIOError; stdcall;
begin
  try
    Result := DoControlPanel;
  except
    on E: Exception do
    begin
      LogException('controlPanel', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AsioDriver.future(selector: LongInt; opt: Pointer): TASIOError; stdcall;
begin
  case selector of
    kAsioCanTimeInfo:
      Result := ASE_SUCCESS;
  else
    Result := ASE_NotPresent;
  end;
end;

function TS2400AsioDriver.outputReady: TASIOError; stdcall;
begin
  // nicht implementiert: der Streaming-Thread schreibt das Ausgangspaket
  // ohnehin direkt nach dem bufferSwitch-Rueckruf
  Result := ASE_NotPresent;
end;

// -----------------------------------------------------------------------
// TS2400ClassFactory
// -----------------------------------------------------------------------

function TS2400ClassFactory.CreateInstance(const unkOuter: IUnknown; const iid: TGUID; out obj): HResult; stdcall;
var
  Driver: TS2400AsioDriver;
  Unk: IUnknown;
  RequestedIID: TGUID;
begin
  S2400Log(Format('CreateInstance aufgerufen: iid=%s', [GUIDToString(iid)]));

  Pointer(obj) := nil;

  if unkOuter <> nil then
    Exit(CLASS_E_NOAGGREGATION);

  try
    Driver := TS2400AsioDriver.Create;
    Unk := Driver; // haelt genau eine Referenz, solange diese Methode laeuft

    // ASIO-Hosts reichen oft die Treiber-CLSID statt der IASIO-GUID durch
    // (historische SDK-Eigenheit) - ohne Uebersetzung schlaegt das Laden fehl
    if IsEqualGUID(iid, CLSID_S2400AsioDriver) then
      RequestedIID := IID_ASIO
    else
      RequestedIID := iid;

    Result := Unk.QueryInterface(RequestedIID, obj);
  except
    on E: Exception do
    begin
      LogException('CreateInstance', E);
      Pointer(obj) := nil;
      Result := E_FAIL;
    end;
  end;
end;

function TS2400ClassFactory.LockServer(fLock: BOOL): HResult; stdcall;
begin
  if fLock then
    InterlockedIncrement(GLockCount)
  else
    InterlockedDecrement(GLockCount);
  Result := S_OK;
end;

// -----------------------------------------------------------------------
// COM-DLL-Exportfunktionen
// -----------------------------------------------------------------------

function DllGetClassObject(const CLSID, IID: TGUID; out Obj): HResult; stdcall;
var
  Factory: TS2400ClassFactory;
  Unk: IUnknown;
begin
  Pointer(Obj) := nil;
  S2400Log('DllGetClassObject aufgerufen');

  if not IsEqualGUID(CLSID, CLSID_S2400AsioDriver) then
    Exit(CLASS_E_CLASSNOTAVAILABLE);

  try
    Factory := TS2400ClassFactory.Create;
    Unk := Factory;
    Result := Unk.QueryInterface(IID, Obj);
  except
    on E: Exception do
    begin
      LogException('DllGetClassObject', E);
      Pointer(Obj) := nil;
      Result := E_FAIL;
    end;
  end;
end;

function DllCanUnloadNow: HResult; stdcall;
begin
  if (GObjectCount = 0) and (GLockCount = 0) then
    Result := S_OK
  else
    Result := S_FALSE;
end;

function DllRegisterServer: HResult; stdcall;
var
  ClsidStr, ModulePath: string;
  Ok: Boolean;
begin
  ModulePath := GetThisModuleFileName;
  if ModulePath = '' then
    Exit(SELFREG_E_CLASS);

  ClsidStr := GUIDToString(CLSID_S2400AsioDriver);

  Ok := WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr, '', S2400_DRIVER_NAME);
  Ok := Ok and WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr + '\InprocServer32', '', ModulePath);
  // "Both" statt "Apartment": ASIO-Hosts rufen Treibermethoden oft aus einem
  // anderen Thread auf; ohne Proxy/Stub wuerde COM das sonst verweigern
  Ok := Ok and WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr + '\InprocServer32', 'ThreadingModel', 'Both');

  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_DRIVER_NAME, '', S2400_DRIVER_NAME);
  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_DRIVER_NAME, 'CLSID', ClsidStr);
  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_DRIVER_NAME, 'Description', S2400_DRIVER_NAME);

  if Ok then
    Result := S_OK
  else
    Result := SELFREG_E_CLASS;
end;

function DllUnregisterServer: HResult; stdcall;
var
  ClsidStr: string;
begin
  ClsidStr := GUIDToString(CLSID_S2400AsioDriver);

  RegDeleteTreeW(HKEY_CLASSES_ROOT, PWideChar('CLSID\' + ClsidStr));
  RegDeleteTreeW(HKEY_LOCAL_MACHINE, PWideChar('SOFTWARE\ASIO\' + S2400_DRIVER_NAME));

  Result := S_OK;
end;

initialization
  // zeigt im Log, ob und von welchem Programm die DLL geladen wurde
  S2400Log('S2400AsioDriver.dll geladen von: ' + ParamStr(0));

end.
