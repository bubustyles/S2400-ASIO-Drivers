unit S2400AggCore;

// =============================================================================
// S2400AggCore.pas - Verbund-Treiber "S2400 Aggregate" (Etappe B, 30.10.2026)
//
// Ein eigener ASIO-Treiber (eigene CLSID), der mehrere Geraete zu EINEM
// ASIO-Geraet zusammenfasst. Der Isla-Treiber "S2400 ASIO Driver" bleibt
// davon unberuehrt.
//
//   Master-Geraet: ein beliebiger installierter ASIO-Treiber (beim Nutzer die
//     UAD Apollo Thunderbolt, die per ADAT dem Heritage OST 8 folgt). Er gibt
//     Takt, Puffergroesse und Samplerate vor. Seine Kanaele gehen OHNE Kopie
//     an den Host: der Host bekommt direkt die Pufferzeiger des Masters.
//   ISLA S2400: ueber Kernel Streaming (S2400KsEngine) in einem eigenen
//     Echtzeit-Thread. Die Isla hat einen eigenen Quarz - sie wird ueber je
//     einen Zwischenspeicher (TS2400SpscFifo), einen Umrechner
//     (TS2400Resampler) und einen PI-Regler (TS2400DriftController) pro
//     Richtung laufend an den Master-Takt angeglichen.
//
// Kanal-Reihenfolge beim Host: erst alle Master-Kanaele, dann die Isla
// (10 Eingaenge, 2 Ausgaenge). Die Isla-Kanaele haben das Sample-Format des
// Masters (z.B. Int32LSB), damit der Host einheitliche Formate sieht.
//
// Takt-Angleichung (ausgelegt mit Referenz\drift_sim.py, offline geprueft mit
// S2400DriftTest.dpr):
//   Eingang: Isla-Thread schreibt jedes Paket (Float) mit dem Zeitstempel des
//     letzten Samples in die Capture-FIFO. Der Master-Rueckruf misst den
//     ZEITKONTINUIERLICHEN Fuellstand (FIFO + noch nicht verbrauchte
//     Umrechner-Frames + Zeit seit dem letzten Isla-Sample * 48000), der
//     Regler stellt die Korrektur des Umrechners nach.
//   Ausgang: spiegelbildlich - der Master-Rueckruf schreibt umgerechnete
//     Frames in die Render-FIFO, der Isla-Thread liest pro Paket; Fuellstand
//     = FIFO + Umrechner-Rest - Zeit seit dem letzten Isla-Lesen * 48000.
//   Jede Richtung hat ihren eigenen Regler; beide laufen auf dasselbe wahre
//   Taktverhaeltnis zu. Sollfuellstand = Isla-Paket + Master-Puffer +
//   Reserve (Normal 2 ms / Hoch 5 ms) + 64.
//   Gestartet wird jede Richtung erst, wenn ihre FIFO den Sollwert erreicht
//   hat (vorher Stille). Unterlaeufe werden als Stille geliefert, mitgezaehlt
//   und beim naechsten Lesen uebersprungen; verlorene Isla-Pakete fuellt der
//   Isla-Thread mit Stille auf - der Zeitbezug bleibt so sampelgenau.
//
// Isla-Monitoring (05.11.2026, Mixer und Matrix 06.11.2026): die
// umgerechneten Isla-Eingaenge (FCapOut) werden im Master-Rueckruf NACH dem
// Host mit Pegel und Panorama je Kanal auf beliebig viele Ausgangspaare des
// Masters gemischt (S2400AggMixer) - die Isla ist so auf den Monitoren zu hoeren, egal ob
// Live laeuft (dann zu Lives Ausgabe addiert) oder nur das Hilfsprogramm
// S2400 Monitor den Verbund offen haelt. Latenz = Isla-Eingangsweg + Ausgang
// des Masters, kein zusaetzlicher Puffer.
//
// Keine Logausgabe in den Echtzeit-Threads (nur Zaehler, Bilanz bei stop).
// Log: %TEMP%\S2400Aggregate.log
// =============================================================================

{$POINTERMATH ON}

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.AnsiStrings,
  System.Classes,
  System.Math,
  System.SyncObjs,
  System.Win.Registry,
  AsioInterface,
  S2400KsEngine,
  S2400Resampler,
  S2400DriftControl,
  S2400AsioHost,
  S2400WasapiOut,
  S2400ControlPanel,
  S2400AggPanel,
  S2400AggMixer,
  S2400MonitorLink,
  S2400Lang;

const
  // per Zufallsgenerator erzeugte, eindeutige CLSID des Verbund-Treibers.
  // NICHT aendern, ohne den Treiber neu zu registrieren.
  CLSID_S2400Aggregate: TGUID = '{D31D5326-E329-476A-B842-526DA5D39CB5}';

  S2400_AGG_DRIVER_NAME = 'S2400 Aggregate';
  S2400_AGG_DRIVER_VERSION = 1;

type
  TS2400AggDriver = class;

  // Echtzeit-Thread der Isla: vom Capture-Event der KS-Engine getaktet
  TS2400AggIslaThread = class(TThread)
  private
    FDriver: TS2400AggDriver;
  protected
    procedure Execute; override;
  public
    constructor Create(ADriver: TS2400AggDriver);
  end;

  // Ausgabe-Thread des Windows-Ausgangs (Etappe C): vom WASAPI-Ereignis
  // des Geraets getaktet
  TS2400AggWinThread = class(TThread)
  private
    FDriver: TS2400AggDriver;
  protected
    procedure Execute; override;
  public
    constructor Create(ADriver: TS2400AggDriver);
  end;

  TS2400AggDriver = class(TObject, IUnknown, IASIO)
  private
    FRefCount: Integer;
    FSysHandle: Pointer;
    FErrorMessage: string;

    // Einstellungen (HKCU\Software\S2400 Aggregate)
    FMasterName: string;
    FIslaEnabled: Boolean;
    FIslaPacket: Cardinal;
    FReserveMs: Integer;
    FAlignInputs: Boolean;        // Etappe E: Eingaenge von Master und Isla zeitgleich
    FIslaExtraIn: Integer;        // Wandler-/USB-Zeit der Isla (48-kHz-Frames, per Messung)
    FWinEnabled: Boolean;         // Etappe C: Windows-Ausgang (z.B. Realtek)
    FWinDeviceId: string;         // WASAPI-Endpunkt-ID
    FWinDeviceName: string;
    FWinExclusive: Boolean;       // zuerst Exklusiv-Modus versuchen
    FDevicesDirty: Boolean; // Geraete-Auswahl geaendert, beim naechsten Anlass neu laden

    // Isla-Monitoring mit Mixer und Matrix. Der Mixer (in welchem Programm
    // auch immer) schreibt in den gemeinsamen Speicher FShared; der Master-
    // Rueckruf uebernimmt neue Einstellungen, sobald sich FShared.Seq aendert,
    // und schreibt die Spitzenwerte fuer die Pegelanzeigen dorthin.
    FMix: TS2400MixSettings;
    FMixGainL, FMixGainR: array[0..C_MIX_CHANNELS - 1] of Single; // Pegel * Panorama
    FMonL, FMonR: TArray<Single>; // ein Master-Puffer je Seite
    FMonWritten: Cardinal;        // zuletzt beschriebene Paare (Bit p), nur Master-Rueckruf
    FShared: PS2400MixShared;     // nil = ohne Mixer (Speicher nicht angelegt)
    FSharedMap: THandle;
    FMixSeq: Integer;             // zuletzt uebernommener Stand von FShared.Seq
    FForeignMarker: THandle;      // S2400MonitorLink: "fremdes Programm haelt den Verbund"

    // Geraete
    FMaster: TS2400AsioHost;
    FIsla: TS2400KsEngine;        // nil = ohne Isla (abgewaehlt oder nicht gefunden)
    FMasterIn, FMasterOut: Integer;
    FIslaIn, FIslaOut: Integer;   // 0 = ohne Isla
    FIslaInType, FIslaOutType: TASIOSampleType;
    FMasterRate: Double;

    // Host-Puffer
    FBuffersCreated: Boolean;
    FActive: Boolean;
    FBufferInfos: PASIOBufferInfo;
    FNumBufferChannels: Integer;
    FCallbacks: TASIOCallbacks;
    FSupportsTimeInfo: Boolean;
    FBufferFrames: Integer;
    FIslaInBuf: TArray<Pointer>;  // [Kanal * 2 + Haelfte], vom Verbund angelegt
    FIslaOutBuf: TArray<Pointer>;
    FIslaInActive: TArray<Boolean>;
    FIslaOutActive: TArray<Boolean>;
    FMasterOutActive: TArray<Boolean>;

    // Laufzeitausgleich der Eingaenge (Etappe E): ist die Isla spaeter als
    // der Master, werden die Master-Eingaenge um FMasterInDelay Frames
    // verzoegert (dann mit Kopie statt direkt); ist der Master spaeter,
    // wird stattdessen der Sollfuellstand der Isla angehoben
    FMasterInDelay: Integer;      // Master-Frames
    FReportedInLatency: Integer;  // an den Host gemeldet
    FIslaInLatency: Integer;      // rechnerische Isla-Eingangslatenz (Master-Frames)
    FDelayRing: TArray<TBytes>;   // je Master-Eingang: (Verzoegerung + Puffer) Samples
    FDelayHostBuf: TArray<Pointer>; // [Kanal * 2 + Haelfte], an den Host gegeben
    FDelayBps: TArray<Integer>;   // Bytes pro Sample je Master-Eingang
    FDelayPos: Integer;           // Schreibposition im Ring (Samples)

    // Takt-Angleichung der Isla
    FIslaSync: Boolean;           // Isla eingebunden UND Umrechnung moeglich
    FIslaStreaming: Boolean;
    FIslaPacketFrames: Integer;
    FCapFifo, FRenFifo: TS2400SpscFifo;
    FCapRes, FRenRes: TS2400Resampler;
    FCapCtl, FRenCtl: TS2400DriftController;
    FCapTarget, FRenTarget: Double;
    FCapRunning: Boolean;         // nur Master-Rueckruf
    FRenRunning: Boolean;         // nur Isla-Thread (Master liest)
    FRenReadQpc: Int64;           // Isla-Thread: Zeitpunkt des letzten Lesens
    FLastSwitchQpc: Int64;
    FLastMasterPos: Int64;        // Sample-Position des letzten Master-Rueckrufs, -1 = unbekannt
    FIslaDroppedSeen: Int64;
    FQpcFreq: Int64;

    // Arbeitsspeicher (in createBuffers angelegt, im Echtzeitbetrieb fest)
    FIslaCapFloat: TArray<Single>; // ein Isla-Paket Eingang, interleaved
    FIslaRenFloat: TArray<Single>; // ein Isla-Paket Ausgang, interleaved
    FCapChunk: TArray<Single>;     // Nachschub fuer den Capture-Umrechner
    FCapOut: TArray<Single>;       // ein Master-Puffer Isla-Eingang, interleaved
    FChanTmp: TArray<Single>;      // ein Kanal eines Master-Puffers
    FRenIn: TArray<Single>;        // ein Master-Puffer Isla-Ausgang, interleaved
    FRenOut: TArray<Single>;       // Ausgabe des Render-Umrechners

    FIslaThread: TS2400AggIslaThread;

    // Windows-Ausgang (Etappe C): Master-Rueckruf -> Umrechner (Master-Rate
    // -> Geraeterate, eigener Regler) -> FIFO -> WASAPI-Thread. Keine
    // Laufzeitangleichung (Entscheidung 15.10.2026: Realtek ohne Ausgleich).
    FWin: TS2400WasapiOut;
    FWinOut: Integer;             // 0 oder 2 Kanaele beim Host
    FWinOutBuf: TArray<Pointer>;  // [Kanal * 2 + Haelfte]
    FWinOutActive: TArray<Boolean>;
    FWinSync: Boolean;            // Geraet offen, Angleichung bereit
    FWinStreaming: Boolean;
    FWinRunning: Boolean;         // nur WASAPI-Thread (Master liest)
    FWinFifo: TS2400SpscFifo;
    FWinRes: TS2400Resampler;
    FWinCtl: TS2400DriftController;
    FWinTarget: Double;           // Geraete-Frames
    FWinRate: Double;
    FWinReadQpc: Int64;           // WASAPI-Thread: Zeitpunkt des letzten Lesens
    FWinIn: TArray<Single>;       // ein Master-Puffer, interleaved Stereo
    FWinTmp: TArray<Single>;      // Ausgabe des Umrechners
    FWinDevBuf: TArray<Single>;   // ein Geraetepuffer, interleaved Stereo
    FWinThread: TS2400AggWinThread;
    FWinExceptions: Int64;
    FWinLevelMin, FWinLevelMax: Double;

    // Bilanz (nur Zaehler im Echtzeitbetrieb, Log bei stop)
    FSwitchCount: Int64;
    FSettleSwitches: Int64;
    FGateSwitches: Int64;         // erst ab so vielen Rueckrufen oeffnen die Zwischenspeicher
    FCapUnderSettle, FRenUnderSettle, FWinUnderSettle: Int64; // Stand nach C_SETTLE_SECONDS (-1 = noch nicht)
    // Ausgabe-Aussetzer waehrend einer Pause des Hosts/Masters (Live-Test
    // 30.10.2026: beim Laden eines Projekts blockiert Live den Rueckruf
    // einmal ~38 ms, die UAD laesst 7 Puffer aus und ist selbst stumm) -
    // nicht vom Verbund verursacht, daher nicht in der Anzeige
    FSwitchPeriodQpc: Int64;      // Dauer eines Master-Puffers in QPC-Ticks
    FRenHostUnder, FWinHostUnder: Int64;
    FMaxSwitchQpc: Int64;
    FCbExceptions: Int64;
    FIslaExceptions: Int64;
    FIslaPackets: Int64;
    FIslaGapFrames: Int64;
    FMasterGapEvents: Int64;      // vom Master ausgelassene Puffer (Host war zu langsam)
    FMasterGapFrames: Int64;
    FMasterGapMax: Int64;
    FCapLevelMin, FCapLevelMax: Double;
    FRenLevelMin, FRenLevelMax: Double;
    FCapLevelLast, FRenLevelLast: Double;

    procedure LoadSettings;
    procedure SaveSettings;
    function MasterCandidates: TArray<TS2400AsioDriverInfo>;
    function SelectableMasters: TArray<string>;
    function LoadDevices: Boolean;
    procedure UnloadDevices;
    function EnsureDevices: Boolean;
    function GetPanelStatus: TS2400AggStatus;
    function BufferInfoAt(Base: PASIOBufferInfo; Index: Integer): PASIOBufferInfo;
    procedure FreeIslaBuffers;
    procedure FreeDelayBuffers;
    procedure FreeSync;
    function IslaBaseTarget(ABufferFrames: Integer; ARate: Double): Double;
    procedure CalcAlignment(ABufferFrames: Integer; ARate: Double; AMasterInLatency: Integer;
      out AMasterDelay: Integer; out ACapExtra48: Double; out AIslaLatency, AReported: Integer);
    procedure BuildSync;
    procedure ApplyMasterInputDelay(AIndex: Integer);
    procedure ResetSync;
    procedure LogRunSummary;

    // Echtzeit
    procedure HandleMasterSwitch(ADoubleBufferIndex: Integer; ATimeInfo: PASIOTime);
    procedure HandleMasterMessage(ASelector: LongInt);
    function MasterGapFrames(ATimeInfo: PASIOTime): Int64;
    procedure CompensateMasterGap(AFrames: Int64; ANowQpc: Int64);
    procedure IslaCapturePart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
    procedure IslaRenderPart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
    procedure InvokeHost(AIndex: Integer; ATimeInfo: PASIOTime);
    procedure MeasureInputs;
    procedure MonitorPart(AIndex: Integer);
    procedure ClearMonitorPair(APair: Integer);
    procedure ClearMonitorPairs(AMask: Cardinal);
    procedure ApplyMix(const AMix: TS2400MixSettings);
    function MonitorPairNames: TArray<string>;
    procedure SyncMix;
    procedure PublishState;
    procedure OpenMixer(AOwner: HWND);
    function HostOverdue: Boolean;
    procedure IslaThreadLoop(AThread: TS2400AggIslaThread);
    procedure ProcessIslaPacket;

    // Windows-Ausgang (Etappe C)
    procedure FreeWinBuffers;
    procedure FreeWinSync;
    procedure BuildWinSync;
    procedure StopWinStreaming;
    procedure WinRenderPart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
    procedure WinThreadLoop(AThread: TS2400AggWinThread);
    procedure ProcessWinPacket;

    function DoInit(sysHandle: Pointer): TASIOBool;
    function DoStart: TASIOError;
    function DoStop: TASIOError;
    function DoCreateBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
      bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError;
    function DoDisposeBuffers: TASIOError;
    function DoControlPanel: TASIOError;
    function DoSetSampleRate(sampleRate: TASIOSampleRate): TASIOError;
    function DoGetChannelInfo(var info: TASIOChannelInfo): TASIOError;
  public
    constructor Create;
    destructor Destroy; override;

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

  TS2400AggClassFactory = class(TInterfacedObject, IClassFactory)
  public
    function CreateInstance(const unkOuter: IUnknown; const iid: TGUID; out obj): HResult; stdcall;
    function LockServer(fLock: BOOL): HResult; stdcall;
  end;

function DllGetClassObject(const CLSID, IID: TGUID; out Obj): HResult; stdcall;
function DllCanUnloadNow: HResult; stdcall;
function DllRegisterServer: HResult; stdcall;
function DllUnregisterServer: HResult; stdcall;

implementation

function RegDeleteTreeW(hKey: HKEY; lpSubKey: LPCWSTR): Longint; stdcall;
  external 'advapi32.dll' name 'RegDeleteTreeW';

const
  AVRT_PRIORITY_CRITICAL = 2;

function AvSetMmThreadCharacteristicsW(TaskName: LPCWSTR; var TaskIndex: DWORD): THandle; stdcall;
  external 'avrt.dll' name 'AvSetMmThreadCharacteristicsW';
function AvRevertMmThreadCharacteristics(AvrtHandle: THandle): BOOL; stdcall;
  external 'avrt.dll' name 'AvRevertMmThreadCharacteristics';
function AvSetMmThreadPriority(AvrtHandle: THandle; Priority: LongInt): BOOL; stdcall;
  external 'avrt.dll' name 'AvSetMmThreadPriority';

const
  C_SETTINGS_KEY = 'Software\S2400 Aggregate';
  C_ISLA_DRIVER_NAME = 'S2400 ASIO Driver'; // eigener Isla-Treiber: nie als Master (beide wuerden die Isla oeffnen)

  // automatische Master-Wahl, wenn noch keiner gespeichert ist (Reihenfolge = Vorrang)
  C_PREFERRED_MASTERS: array[0..3] of string = ('THUNDERBOLT', 'UNIVERSAL AUDIO', 'APOLLO', 'UAD');
  // nie automatisch waehlen (virtuelle Geraete, die den Verbund ggf. selbst hosten)
  C_NO_AUTO_MASTERS: array[0..2] of string = ('VB-AUDIO', 'VOICEMEETER', 'MATRIX');

  C_ISLA_RATE = 48000.0;
  C_FIFO_CAPACITY = 65536;     // Frames (1,4 s) - reicht auch fuer laengere Aussetzer
  C_CAP_CHUNK = 16;            // Nachschub-Portion fuer den Capture-Umrechner
  C_REN_CHUNK = 256;           // Ausgabe-Portion des Render-Umrechners
  C_SETTLE_SECONDS = 30;       // Fuellstands-Statistik erst nach dem Einschwingen
  // Zwischenspeicher oeffnen erst so lange nach dem Start: im Anlauf kommen
  // die Host-Rueckrufe unregelmaessig (Live-Tests 30.10.2026: dreimal genau
  // 11 Ausgabe-Aussetzer direkt nach dem Start der Audio-Engine)
  C_GATE_SECONDS = 1;
  C_RESERVE_NORMAL_MS = 2;
  C_RESERVE_HIGH_MS = 5;

var
  GObjectCount: Integer = 0;
  GLockCount: Integer = 0;

// -----------------------------------------------------------------------
// Hilfsfunktionen
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

procedure LogException(const AWhere: string; E: Exception);
begin
  S2400Log(Format('AUSNAHME in %s: %s: %s (Adresse %p)',
    [AWhere, E.ClassName, E.Message, ExceptAddr]));
end;

function NameContains(const AText, APart: string): Boolean;
begin
  Result := Pos(UpperCase(APart), UpperCase(AText)) > 0;
end;

function IsOwnDriver(const AName: string): Boolean;
begin
  Result := SameText(AName, S2400_AGG_DRIVER_NAME) or SameText(AName, C_ISLA_DRIVER_NAME);
end;

function Ppm(ACorrection: Double): Double;
begin
  Result := (ACorrection - 1.0) * 1E6;
end;

// -----------------------------------------------------------------------
// TS2400AggIslaThread
// -----------------------------------------------------------------------

constructor TS2400AggIslaThread.Create(ADriver: TS2400AggDriver);
begin
  // suspendiert erzeugen, gestartet wird NACH dem Konstruktor (siehe
  // TS2400StreamThread.Create im Isla-Treiber: Start im Konstruktor loest
  // EThread aus -> Absturz 0x0EEDFADE)
  inherited Create(True);
  FDriver := ADriver;
  FreeOnTerminate := False;
  Priority := tpTimeCritical;
end;

procedure TS2400AggIslaThread.Execute;
var
  MmcssHandle: THandle;
  MmcssTaskIndex: DWORD;
begin
  // alle Gleitkomma-Ausnahmen maskieren (Windows-Standard)
  SetMXCSR($1F80);
  Set8087CW($027F);

  MmcssTaskIndex := 0;
  MmcssHandle := AvSetMmThreadCharacteristicsW('Pro Audio', MmcssTaskIndex);
  if MmcssHandle <> 0 then
    AvSetMmThreadPriority(MmcssHandle, AVRT_PRIORITY_CRITICAL);
  try
    FDriver.IslaThreadLoop(Self);
  finally
    if MmcssHandle <> 0 then
      AvRevertMmThreadCharacteristics(MmcssHandle);
  end;
end;

// -----------------------------------------------------------------------
// TS2400AggDriver - Lebenszyklus, Einstellungen, Geraete
// -----------------------------------------------------------------------

constructor TS2400AggDriver.Create;
begin
  inherited Create;
  InterlockedIncrement(GObjectCount);
  S2400Log('TS2400AggDriver.Create');
  FIslaEnabled := True;
  FIslaPacket := C_ISLA_DEFAULT_BUFFER_SAMPLES;
  FReserveMs := C_RESERVE_HIGH_MS;
  FAlignInputs := True;
  FIslaExtraIn := 0;
  FWinEnabled := False;
  FWinExclusive := True;
  FMonWritten := 0;
  LoadSettings;
  // Mixer-Stand: aus dem gemeinsamen Speicher (gilt fuer alle Programme;
  // beim ersten Oeffnen aus der Registry vorbelegt)
  FShared := S2400MixSharedOpen(FSharedMap);
  if FShared <> nil then
  begin
    FMixSeq := FShared^.Seq;
    FMix := FShared^.Settings;
  end
  else
  begin
    S2400Log('HINWEIS: gemeinsamer Speicher fuer den Isla-Mixer nicht verfuegbar');
    FMix := S2400MixLoad;
  end;
  ApplyMix(FMix);
  if not QueryPerformanceFrequency(FQpcFreq) then
    FQpcFreq := 10000000;
  FIslaInType := ASIOSTInt32LSB;
  FIslaOutType := ASIOSTInt32LSB;
end;

destructor TS2400AggDriver.Destroy;
begin
  S2400Log('TS2400AggDriver.Destroy');
  stop;
  disposeBuffers;
  UnloadDevices;
  FreeSync;
  FreeWinSync;
  FreeWinBuffers;
  FreeDelayBuffers;
  S2400MixClearOwner(FShared);
  S2400MixSharedClose(FSharedMap, FShared);
  S2400ReleaseClaim(FForeignMarker); // S2400 Monitor darf wieder uebernehmen
  InterlockedDecrement(GObjectCount);
  inherited Destroy;
end;

procedure TS2400AggDriver.LoadSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKeyReadOnly(C_SETTINGS_KEY) then
      begin
        if Reg.ValueExists('MasterDriver') then
          FMasterName := Reg.ReadString('MasterDriver');
        if Reg.ValueExists('IslaEnabled') then
          FIslaEnabled := Reg.ReadInteger('IslaEnabled') <> 0;
        if Reg.ValueExists('IslaPacket') then
          FIslaPacket := NearestAllowedBufferSize(Cardinal(Reg.ReadInteger('IslaPacket')));
        if Reg.ValueExists('ReserveMs') then
          if Reg.ReadInteger('ReserveMs') <= C_RESERVE_NORMAL_MS then
            FReserveMs := C_RESERVE_NORMAL_MS
          else
            FReserveMs := C_RESERVE_HIGH_MS;
        if Reg.ValueExists('AlignInputs') then
          FAlignInputs := Reg.ReadInteger('AlignInputs') <> 0;
        if Reg.ValueExists('IslaExtraIn') then
          FIslaExtraIn := Reg.ReadInteger('IslaExtraIn');
        if Reg.ValueExists('WinEnabled') then
          FWinEnabled := Reg.ReadInteger('WinEnabled') <> 0;
        if Reg.ValueExists('WinDeviceId') then
          FWinDeviceId := Reg.ReadString('WinDeviceId');
        if Reg.ValueExists('WinDeviceName') then
          FWinDeviceName := Reg.ReadString('WinDeviceName');
        if Reg.ValueExists('WinExclusive') then
          FWinExclusive := Reg.ReadInteger('WinExclusive') <> 0;
        if FIslaExtraIn > C_MAX_EXTRA_LATENCY then
          FIslaExtraIn := C_MAX_EXTRA_LATENCY
        else if FIslaExtraIn < -C_MAX_EXTRA_LATENCY then
          FIslaExtraIn := -C_MAX_EXTRA_LATENCY;
      end;
    except
      on E: Exception do
        S2400Log('Einstellungen konnten nicht gelesen werden: ' + E.Message);
    end;
  finally
    Reg.Free;
  end;
  S2400Log(Format('Einstellungen: Master "%s", Isla %s, Isla-Paket %d, Reserve %d ms, ' +
    'Eingaenge angleichen %s, Korrektur Isla-Eingang %d',
    [FMasterName, BoolToStr(FIslaEnabled, True), FIslaPacket, FReserveMs,
     BoolToStr(FAlignInputs, True), FIslaExtraIn]));
end;

procedure TS2400AggDriver.SaveSettings;
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    try
      Reg.RootKey := HKEY_CURRENT_USER;
      if Reg.OpenKey(C_SETTINGS_KEY, True) then
      begin
        Reg.WriteString('MasterDriver', FMasterName);
        Reg.WriteInteger('IslaEnabled', Ord(FIslaEnabled));
        Reg.WriteInteger('IslaPacket', Integer(FIslaPacket));
        Reg.WriteInteger('ReserveMs', FReserveMs);
        Reg.WriteInteger('AlignInputs', Ord(FAlignInputs));
        Reg.WriteInteger('IslaExtraIn', FIslaExtraIn);
        Reg.WriteInteger('WinEnabled', Ord(FWinEnabled));
        Reg.WriteString('WinDeviceId', FWinDeviceId);
        Reg.WriteString('WinDeviceName', FWinDeviceName);
        Reg.WriteInteger('WinExclusive', Ord(FWinExclusive));
      end;
    except
      on E: Exception do
        S2400Log('Einstellungen konnten nicht gespeichert werden: ' + E.Message);
    end;
  finally
    Reg.Free;
  end;
end;

// Reihenfolge, in der Master-Treiber probiert werden: der gespeicherte, dann
// die bevorzugten (UAD), dann alle uebrigen ausser virtuellen Geraeten
function TS2400AggDriver.MasterCandidates: TArray<TS2400AsioDriverInfo>;
var
  All, List: TArray<TS2400AsioDriverInfo>;
  Used: TArray<Boolean>;
  I, K: Integer;
  Skip: Boolean;

  procedure Take(AIndex: Integer);
  begin
    if Used[AIndex] then
      Exit;
    Used[AIndex] := True;
    List := List + [All[AIndex]];
  end;

begin
  List := nil;
  All := TS2400AsioHost.ListDrivers;
  SetLength(Used, Length(All));
  for I := 0 to High(All) do
    Used[I] := IsOwnDriver(All[I].Name);

  if FMasterName <> '' then
    for I := 0 to High(All) do
      if SameText(All[I].Name, FMasterName) then
        Take(I);

  for K := 0 to High(C_PREFERRED_MASTERS) do
    for I := 0 to High(All) do
      if NameContains(All[I].Name, C_PREFERRED_MASTERS[K]) then
        Take(I);

  for I := 0 to High(All) do
  begin
    Skip := False;
    for K := 0 to High(C_NO_AUTO_MASTERS) do
      if NameContains(All[I].Name, C_NO_AUTO_MASTERS[K]) then
        Skip := True;
    if not Skip then
      Take(I);
  end;
  Result := List;
end;

function TS2400AggDriver.SelectableMasters: TArray<string>;
var
  D: TS2400AsioDriverInfo;
begin
  Result := nil;
  for D in TS2400AsioHost.ListDrivers do
    if not IsOwnDriver(D.Name) then
      Result := Result + [D.Name];
end;

function TS2400AggDriver.LoadDevices: Boolean;
var
  C: TS2400AsioDriverInfo;
  D: TS2400WinDevice;
  Loaded: Boolean;
  CI: TASIOChannelInfo;
begin
  Result := False;
  UnloadDevices;

  // haelt S2400 Monitor gerade UAD und Isla? Dann zuerst freigeben lassen
  case S2400ClaimFromMonitor(FForeignMarker) of
    crReleased:  S2400Log('S2400 Monitor hat den Verbund freigegeben');
    crTimeout:   S2400Log('HINWEIS: S2400 Monitor hat nicht innerhalb von 5 s freigegeben');
    crInMonitor: S2400Log('Verbund laeuft im Hilfsprogramm S2400 Monitor');
  end;

  // --- Master ---
  FMaster := TS2400AsioHost.Create;
  Loaded := False;
  for C in MasterCandidates do
  begin
    S2400Log('Master: versuche "' + C.Name + '"');
    if FMaster.Load(C, FSysHandle) then
    begin
      Loaded := True;
      S2400Log(Format('Master "%s" geladen: %d Ein / %d Aus, Puffer %d (min %d, max %d), %.0f Hz, Latenz %d/%d',
        [C.Name, FMaster.Inputs, FMaster.Outputs, FMaster.PreferredSize, FMaster.MinSize,
         FMaster.MaxSize, FMaster.SampleRate, FMaster.InputLatency, FMaster.OutputLatency]));
      if FMasterName = '' then
      begin
        FMasterName := C.Name;
        SaveSettings;
      end
      else if not SameText(FMasterName, C.Name) then
        S2400Log('HINWEIS: gespeicherter Master "' + FMasterName + '" nicht verfuegbar - Ersatz "' + C.Name + '"');
      Break;
    end;
    S2400Log('  nicht geladen: ' + FMaster.LastError);
  end;
  if not Loaded then
  begin
    FreeAndNil(FMaster);
    FErrorMessage := Tr('Kein Master-Ger'#$00E4't (ASIO) verf'#$00FC'gbar.', 'No master device (ASIO) available.');
    S2400Log('FEHLER: ' + FErrorMessage);
    Exit;
  end;
  FMaster.OnBufferSwitch := HandleMasterSwitch;
  FMaster.OnMessage := HandleMasterMessage;
  FMasterIn := FMaster.Inputs;
  FMasterOut := FMaster.Outputs;
  FMasterRate := FMaster.CurrentSampleRate;

  // Isla-Kanaele bekommen das Format der Master-Kanaele
  FIslaInType := ASIOSTInt32LSB;
  FIslaOutType := ASIOSTInt32LSB;
  if FMasterIn > 0 then
  begin
    FillChar(CI, SizeOf(CI), 0);
    CI.channel := 0;
    CI.isInput := ASIOTrue;
    if (FMaster.QueryChannelInfo(CI) = ASE_OK) and AsioSampleTypeSupported(CI.sampleType) then
      FIslaInType := CI.sampleType;
  end;
  if FMasterOut > 0 then
  begin
    FillChar(CI, SizeOf(CI), 0);
    CI.channel := 0;
    CI.isInput := ASIOFalse;
    if (FMaster.QueryChannelInfo(CI) = ASE_OK) and AsioSampleTypeSupported(CI.sampleType) then
      FIslaOutType := CI.sampleType;
  end;

  // --- Isla (optional - ohne sie laeuft der Verbund nur mit dem Master) ---
  FIslaIn := 0;
  FIslaOut := 0;
  if FIslaEnabled then
  begin
    FIsla := TS2400KsEngine.Create;
    FIsla.DesiredBufferSizeFrames := FIslaPacket;
    if FIsla.Open then
    begin
      FIslaIn := FIsla.InputChannels;
      FIslaOut := FIsla.OutputChannels;
      FIslaPacketFrames := FIsla.BufferSizeFrames;
      S2400Log(Format('Isla geoeffnet: %d Ein / %d Aus, Paket %d Frames, Format fuer den Host %s/%s',
        [FIslaIn, FIslaOut, FIslaPacketFrames, AsioSampleTypeName(FIslaInType), AsioSampleTypeName(FIslaOutType)]));
    end
    else
    begin
      S2400Log('Isla nicht verfuegbar - Verbund laeuft nur mit dem Master: ' + FIsla.LastError);
      FreeAndNil(FIsla);
    end;
  end;

  // --- Windows-Ausgang (optional; geoeffnet wird erst in createBuffers) ---
  FWinOut := 0;
  if FWinEnabled and (FWinDeviceId <> '') then
  begin
    for D in TS2400WasapiOut.ListDevices do
      if D.Id = FWinDeviceId then
      begin
        FWinOut := 2;
        FWinDeviceName := D.Name;
      end;
    if FWinOut > 0 then
      S2400Log('Windows-Ausgang eingebunden: ' + FWinDeviceName + ' (2 Ausgaenge)')
    else
      S2400Log('Windows-Ausgang nicht gefunden: ' + FWinDeviceName);
  end;

  // Namen der Ausgangspaare fuer den Mixer (auch fuer spaeter ohne Treiber)
  S2400MixSetPairNames(FShared, MonitorPairNames);

  FDevicesDirty := False;
  Result := True;
end;

procedure TS2400AggDriver.UnloadDevices;
begin
  if FIsla <> nil then
  begin
    FIsla.Close;
    FreeAndNil(FIsla);
  end;
  if FMaster <> nil then
  begin
    FMaster.Unload;
    FreeAndNil(FMaster);
  end;
  FMasterIn := 0;
  FMasterOut := 0;
  FIslaIn := 0;
  FIslaOut := 0;
  FWinOut := 0;
end;

// laedt die Geraete (neu), wenn noch keine geladen sind oder die Auswahl
// geaendert wurde - aber nie bei angelegten Puffern
function TS2400AggDriver.EnsureDevices: Boolean;
begin
  if (FMaster <> nil) and not FDevicesDirty then
    Exit(True);
  if FBuffersCreated then
    Exit(FMaster <> nil);
  Result := LoadDevices;
end;

// Live-Werte fuer das Einstellungsfenster (Etappe D). Wird im Bedienthread
// alle 250 ms aufgerufen und liest NUR zwischengespeicherte Werte - kein
// Aufruf in den fremden Master-Treiber, damit das Fenster ihn nie stoert.
function TS2400AggDriver.GetPanelStatus: TS2400AggStatus;
begin
  Result := Default(TS2400AggStatus);
  Result.Running := FActive;
  Result.MasterName := FMasterName;
  Result.IslaPresent := FIsla <> nil;
  if FMaster = nil then
    Exit;
  Result.MasterIn := FMasterIn;
  Result.MasterOut := FMasterOut;
  if FBuffersCreated then
  begin
    Result.SampleRate := FMasterRate;
    Result.BufferFrames := FBufferFrames;
    if FIslaSync then
      Result.InLatency := FReportedInLatency
    else
      Result.InLatency := FMaster.InputLatency;
  end
  else
  begin
    Result.SampleRate := FMaster.SampleRate;
    Result.BufferFrames := FMaster.PreferredSize;
    Result.InLatency := FMaster.InputLatency;
  end;
  Result.IslaSync := FIslaSync and FIslaStreaming;
  if FIslaSync then
  begin
    Result.CapPpm := Ppm(FCapCtl.Correction);
    Result.RenPpm := Ppm(FRenCtl.Correction);
    Result.CapLevel := FCapCtl.FilteredLevel;
    Result.RenLevel := FRenCtl.FilteredLevel;
    Result.CapTarget := FCapTarget;
    Result.RenTarget := FRenTarget;
    Result.CapUnderruns := FCapFifo.Underruns;
    Result.RenUnderruns := FRenFifo.Underruns - FRenHostUnder; // ohne Host-Pausen
  end;
  Result.WinPresent := FWinOut > 0;
  Result.WinName := FWinDeviceName;
  Result.WinSync := FWinSync and FWinStreaming;
  if FWinSync then
  begin
    Result.WinFormat := FWin.FormatText;
    Result.WinPpm := Ppm(FWinCtl.Correction);
    Result.WinLevel := FWinCtl.FilteredLevel;
    Result.WinTarget := FWinTarget;
    Result.WinUnderruns := FWinFifo.Underruns - FWinHostUnder; // ohne Host-Pausen
  end;
  if FShared <> nil then
    Result.MonEnabled := FShared^.Settings.Enabled // aktueller Stand des Mixers
  else
    Result.MonEnabled := FMix.Enabled;
  Result.MonActive := Result.MonEnabled and FIslaSync and FIslaStreaming;
  // Isla-Ton bis zum Master-Ausgang: Sollfuellstand des Eingangswegs (so alt
  // ist ein Sample, wenn es im Master-Puffer landet) + Ausgangslatenz des Masters
  if FIslaSync and FBuffersCreated and (FMasterRate > 0) then
    Result.MonLatencyMs := (FCapTarget + FIsla.InputHwLatencyFrames) * 1000 / C_ISLA_RATE +
      FMaster.OutputLatency * 1000 / FMasterRate;
end;

// Ausgangspaare des Masters fuer die Auswahl im Bedienfenster
function TS2400AggDriver.MonitorPairNames: TArray<string>;
var
  P: Integer;
  CI: TASIOChannelInfo;
  NameL, NameR: string;

  function ChannelName(ACh: Integer): string;
  begin
    FillChar(CI, SizeOf(CI), 0);
    CI.channel := ACh;
    CI.isInput := ASIOFalse;
    if FMaster.QueryChannelInfo(CI) = ASE_OK then
      Result := Trim(string(AnsiString(PAnsiChar(@CI.name[0]))))
    else
      Result := '';
  end;

begin
  Result := nil;
  if FMaster = nil then
    Exit;
  for P := 0 to FMasterOut div 2 - 1 do
  begin
    NameL := ChannelName(P * 2);
    NameR := ChannelName(P * 2 + 1);
    if (NameL <> '') or (NameR <> '') then
      Result := Result + [Format('%d/%d  %s / %s', [P * 2 + 1, P * 2 + 2, NameL, NameR])]
    else
      Result := Result + [Format('%d/%d', [P * 2 + 1, P * 2 + 2])];
  end;
end;

// Mixer-Stand uebernehmen (beim Laden und ueber SyncMix im Master-Rueckruf):
// erst die Faktoren, dann Ein/Aus und Matrix
procedure TS2400AggDriver.ApplyMix(const AMix: TS2400MixSettings);
var
  M: TS2400MixSettings;
  Ch: Integer;
  G, L, R: Single;
begin
  M := AMix;
  for Ch := 0 to C_MIX_CHANNELS - 1 do
  begin
    M.ChDb[Ch] := EnsureRange(M.ChDb[Ch], C_MIX_DB_MIN, C_MIX_DB_MAX);
    M.ChPan[Ch] := EnsureRange(M.ChPan[Ch], -C_MIX_PAN_MAX, C_MIX_PAN_MAX);
    if M.ChDb[Ch] <= C_MIX_DB_MIN then
      G := 0 // unterster Faderanschlag = stumm
    else
      G := Power(10, M.ChDb[Ch] / 20);
    S2400MixPanGains(M.ChPan[Ch], L, R);
    FMixGainL[Ch] := G * L;
    FMixGainR[Ch] := G * R;
  end;
  for Ch := 0 to C_MIX_CHANNELS - 1 do
  begin
    FMix.ChDb[Ch] := M.ChDb[Ch];
    FMix.ChPan[Ch] := M.ChPan[Ch];
    FMix.ChOn[Ch] := M.ChOn[Ch];
    FMix.ChRoute[Ch] := M.ChRoute[Ch];
  end;
  FMix.Enabled := M.Enabled;
end;

// neuer Mixer-Stand im gemeinsamen Speicher? (Master-Rueckruf, und nach dem
// Schliessen des Mixers) - ein Vergleich je Aufruf, uebernommen nur bei Aenderung
procedure TS2400AggDriver.SyncMix;
var
  Seq: Integer;
begin
  if FShared = nil then
    Exit;
  Seq := FShared^.Seq;
  if Seq = FMixSeq then
    Exit;
  FMixSeq := Seq;
  ApplyMix(FShared^.Settings);
end;

// Zustand fuer den Mixer veroeffentlichen (bei start/stop)
procedure TS2400AggDriver.PublishState;
var
  Lat: Double;
begin
  if FShared = nil then
    Exit;
  Lat := 0;
  if FIslaSync and FBuffersCreated and (FMasterRate > 0) and (FMaster <> nil) then
    Lat := (FCapTarget + FIsla.InputHwLatencyFrames) * 1000 / C_ISLA_RATE +
      FMaster.OutputLatency * 1000 / FMasterRate;
  S2400MixSetOwner(FShared, FActive, FIslaSync and FIslaStreaming, Lat);
end;

// Isla-Mixer zeigen (aus dem Einstellungsfenster); er spricht ueber den
// gemeinsamen Speicher mit dem Treiber, gespeichert wird beim Schliessen
procedure TS2400AggDriver.OpenMixer(AOwner: HWND);
begin
  ShowS2400AggMixer(AOwner);
  SyncMix; // falls die Audio-Engine gerade nicht laeuft
  S2400Log(Format('Isla-Mixer geschlossen: Monitoring %s', [BoolToStr(FMix.Enabled, True)]));
end;

function TS2400AggDriver.BufferInfoAt(Base: PASIOBufferInfo; Index: Integer): PASIOBufferInfo;
begin
  Result := PASIOBufferInfo(NativeUInt(Base) + NativeUInt(Index) * SizeOf(TASIOBufferInfo));
end;

procedure TS2400AggDriver.FreeIslaBuffers;
var
  I: Integer;
begin
  for I := 0 to High(FIslaInBuf) do
    if FIslaInBuf[I] <> nil then
      FreeMem(FIslaInBuf[I]);
  for I := 0 to High(FIslaOutBuf) do
    if FIslaOutBuf[I] <> nil then
      FreeMem(FIslaOutBuf[I]);
  FIslaInBuf := nil;
  FIslaOutBuf := nil;
  FIslaInActive := nil;
  FIslaOutActive := nil;
end;

procedure TS2400AggDriver.FreeSync;
begin
  FreeAndNil(FCapFifo);
  FreeAndNil(FRenFifo);
  FreeAndNil(FCapRes);
  FreeAndNil(FRenRes);
  FreeAndNil(FCapCtl);
  FreeAndNil(FRenCtl);
  FIslaSync := False;
end;

procedure TS2400AggDriver.FreeDelayBuffers;
var
  I: Integer;
begin
  for I := 0 to High(FDelayHostBuf) do
    if FDelayHostBuf[I] <> nil then
      FreeMem(FDelayHostBuf[I]);
  FDelayHostBuf := nil;
  FDelayRing := nil;
  FDelayBps := nil;
end;

// Sollfuellstand der Isla-FIFOs in 48-kHz-Frames: Isla-Paket + Master-Puffer
// + Reserve + 64 (siehe Unit-Kopf)
function TS2400AggDriver.IslaBaseTarget(ABufferFrames: Integer; ARate: Double): Double;
begin
  Result := FIslaPacketFrames + ABufferFrames * C_ISLA_RATE / ARate + FReserveMs * 48 + 64;
end;

// Laufzeitausgleich der Eingaenge (Etappe E). Eingangslatenz = Alter des
// ersten Samples im Puffer beim bufferSwitch (ASIO-Konvention).
//   Isla: der Regler haelt den zeitkontinuierlichen Fuellstand - genau die
//     Zahl der aufgenommenen, aber noch nicht umgerechneten Frames - auf dem
//     Sollwert; dazu die Wandler-/USB-Zeit der Isla (Treiber meldet 0, daher
//     per Messung als FIslaExtraIn).
//   Master: was er selbst meldet.
// Ist die Isla spaeter, werden die Master-Eingaenge um die Differenz
// verzoegert; ist der Master spaeter, wird der Isla-Sollwert angehoben.
// Gemeldet wird die gemeinsame Latenz, damit der Host Aufnahmen beider
// Geraete richtig aufs Raster legt (Live-Test 30.10.2026: Isla-Aufnahmen
// lagen hinter dem Raster, solange nur die Master-Latenz gemeldet wurde).
procedure TS2400AggDriver.CalcAlignment(ABufferFrames: Integer; ARate: Double; AMasterInLatency: Integer;
  out AMasterDelay: Integer; out ACapExtra48: Double; out AIslaLatency, AReported: Integer);
var
  LI48, LM48: Double;
begin
  AMasterDelay := 0;
  ACapExtra48 := 0;
  LI48 := IslaBaseTarget(ABufferFrames, ARate) + FIslaExtraIn;
  if FIsla <> nil then
    LI48 := LI48 + FIsla.InputHwLatencyFrames;
  LM48 := AMasterInLatency * C_ISLA_RATE / ARate;
  AIslaLatency := Round(LI48 * ARate / C_ISLA_RATE);
  AReported := AMasterInLatency;
  if not FAlignInputs then
    Exit;
  if LI48 >= LM48 then
  begin
    AMasterDelay := AIslaLatency - AMasterInLatency;
    if AMasterDelay < 0 then
      AMasterDelay := 0;
    AReported := AMasterInLatency + AMasterDelay;
  end
  else
  begin
    ACapExtra48 := LM48 - LI48;
    AIslaLatency := AMasterInLatency;
  end;
end;

// Umrechner, FIFOs, Regler und Arbeitsspeicher fuer die aktuelle Master-
// Rate und Puffergroesse anlegen, dazu den Laufzeitausgleich festlegen (in
// createBuffers, nicht im Echtzeitbetrieb)
procedure TS2400AggDriver.BuildSync;
var
  Base, CapExtra: Double;
  Delay, IslaLat, Reported: Integer;
begin
  FreeSync;
  FMasterInDelay := 0;
  FReportedInLatency := FMaster.InputLatency;
  FIslaInLatency := 0;
  if (FIsla = nil) or (FIslaIn + FIslaOut = 0) then
    Exit;
  if FMasterRate < 44000 then
  begin
    // Durchlass 20 kHz braucht mindestens 44,1 kHz auf beiden Seiten
    S2400Log(Format('Isla-Angleichung bei %.0f Hz nicht moeglich - Isla-Kanaele bleiben still', [FMasterRate]));
    Exit;
  end;

  FCapFifo := TS2400SpscFifo.Create(FIslaIn, C_FIFO_CAPACITY);
  FRenFifo := TS2400SpscFifo.Create(FIslaOut, C_FIFO_CAPACITY);
  FCapRes := TS2400Resampler.Create(FIslaIn, C_ISLA_RATE, FMasterRate);
  FRenRes := TS2400Resampler.Create(FIslaOut, FMasterRate, C_ISLA_RATE);

  Base := IslaBaseTarget(FBufferFrames, FMasterRate);
  CalcAlignment(FBufferFrames, FMasterRate, FMaster.InputLatency, Delay, CapExtra, IslaLat, Reported);
  FMasterInDelay := Delay;
  FReportedInLatency := Reported;
  FIslaInLatency := IslaLat;
  FCapTarget := Base + CapExtra;
  FRenTarget := Base;
  FCapCtl := TS2400DriftController.Create(FCapTarget);
  FRenCtl := TS2400DriftController.Create(FRenTarget);
  S2400Log(Format('Laufzeitausgleich (Eingaenge angleichen %s): Master-Eingang %d, Isla-Eingang %d ' +
    '(Korrektur %d) -> Master-Eingaenge %d Frames verzoegert, Isla-Sollwert +%.0f, gemeldet %d (%.2f ms)',
    [BoolToStr(FAlignInputs, True), FMaster.InputLatency, IslaLat, FIslaExtraIn, Delay, CapExtra,
     Reported, Reported * 1000 / FMasterRate]));

  SetLength(FIslaCapFloat, FIslaPacketFrames * FIslaIn);
  SetLength(FIslaRenFloat, FIslaPacketFrames * FIslaOut);
  SetLength(FCapChunk, C_CAP_CHUNK * FIslaIn);
  SetLength(FCapOut, FBufferFrames * FIslaIn);
  SetLength(FChanTmp, FBufferFrames);
  SetLength(FRenIn, FBufferFrames * FIslaOut);
  SetLength(FRenOut, C_REN_CHUNK * FIslaOut);
  SetLength(FMonL, FBufferFrames);
  SetLength(FMonR, FBufferFrames);

  FIslaSync := True;
  S2400Log(Format('Isla-Angleichung: Isla %d Hz -> Master %.0f Hz, Umrechner %d/%d Taps, ' +
    'Sollfuellstand %.0f Frames (%.2f ms), Regler Kp %.3e Ki %.3e',
    [Round(C_ISLA_RATE), FMasterRate, FCapRes.Taps, FRenRes.Taps, FCapTarget,
     FCapTarget * 1000 / C_ISLA_RATE, FCapCtl.Kp, FCapCtl.Ki]));
end;

procedure TS2400AggDriver.ResetSync;
begin
  FCapRunning := False;
  FRenRunning := False;
  FRenReadQpc := 0;
  FLastSwitchQpc := 0;
  FLastMasterPos := -1;
  FMasterGapEvents := 0;
  FMasterGapFrames := 0;
  FMasterGapMax := 0;
  FIslaDroppedSeen := 0;
  FSwitchCount := 0;
  FMaxSwitchQpc := 0;
  FCbExceptions := 0;
  FIslaExceptions := 0;
  FIslaPackets := 0;
  FIslaGapFrames := 0;
  FCapLevelMin := 1E12;
  FCapLevelMax := -1E12;
  FRenLevelMin := 1E12;
  FRenLevelMax := -1E12;
  FCapLevelLast := 0;
  FRenLevelLast := 0;
  if (FMasterRate > 0) and (FBufferFrames > 0) then
    FSettleSwitches := Round(C_SETTLE_SECONDS * FMasterRate / FBufferFrames)
  else
    FSettleSwitches := 0;
  if (FMasterRate > 0) and (FBufferFrames > 0) then
    FGateSwitches := Round(C_GATE_SECONDS * FMasterRate / FBufferFrames)
  else
    FGateSwitches := 0;
  FCapUnderSettle := -1;
  FRenUnderSettle := -1;
  FWinUnderSettle := -1;
  FRenHostUnder := 0;
  FWinHostUnder := 0;
  if (FMasterRate > 0) and (FBufferFrames > 0) then
    FSwitchPeriodQpc := Round(FQpcFreq * FBufferFrames / FMasterRate)
  else
    FSwitchPeriodQpc := FQpcFreq div 100;
  if not FIslaSync then
    Exit;
  FCapFifo.Reset;
  FRenFifo.Reset;
  FCapRes.Reset;
  FRenRes.Reset;
  FCapRes.Correction := 1.0;
  FRenRes.Correction := 1.0;
  FCapCtl.Reset;
  FRenCtl.Reset;
end;

// "(davon in den ersten 30 s: a, danach: b)"
function UnderSplitText(ATotal, AAtSettle: Int64): string;
begin
  if AAtSettle < 0 then
    Result := Format(' (Lauf kuerzer als %d s)', [C_SETTLE_SECONDS])
  else
    Result := Format(' (davon in den ersten %d s: %d, danach: %d)',
      [C_SETTLE_SECONDS, AAtSettle, ATotal - AAtSettle]);
end;

procedure TS2400AggDriver.LogRunSummary;
begin
  S2400Log(Format('Verbund-Bilanz: %d Master-Rueckrufe, laengster %.2f ms, Ausnahmen Master %d / Isla %d',
    [FSwitchCount, FMaxSwitchQpc * 1000 / FQpcFreq, FCbExceptions, FIslaExceptions]));
  S2400Log(Format('  Master: ausgelassene Puffer (Host zu langsam) %d mal, zusammen %d Frames, ' +
    'groesste Luecke %d Frames - fuer Isla/Windows-Ausgang ausgeglichen',
    [FMasterGapEvents, FMasterGapFrames, FMasterGapMax]));
  S2400Log(Format('  Ausgabe-Aussetzer waehrend Pausen des Hosts/Masters (nicht vom Verbund, ' +
    'nicht angezeigt): Isla-Ausgang %d, Windows-Ausgang %d', [FRenHostUnder, FWinHostUnder]));
  if FWinSync then
    S2400Log(Format('  Windows-Ausgang "%s" (%s): Unterlaeufe %d%s, Ueberlaeufe %d, Korrektur %.2f ppm, ' +
      'Fuellstand %.0f (Soll %.0f), nach %d s: min %.0f max %.0f, Ausnahmen %d',
      [FWinDeviceName, FWin.FormatText, FWinFifo.Underruns, UnderSplitText(FWinFifo.Underruns, FWinUnderSettle),
       FWinFifo.Overruns, Ppm(FWinCtl.Correction),
       FWinCtl.FilteredLevel, FWinTarget, C_SETTLE_SECONDS, FWinLevelMin, FWinLevelMax, FWinExceptions]));
  if not FIslaSync then
    Exit;
  S2400Log(Format('  Isla: %d Pakete, verlorene Pakete mit Stille ergaenzt: %d Frames',
    [FIslaPackets, FIslaGapFrames]));
  S2400Log(Format('  Eingang: Unterlaeufe %d%s, Ueberlaeufe %d, Korrektur %.2f ppm, Fuellstand %.0f (Soll %.0f), ' +
    'nach %d s: min %.0f max %.0f',
    [FCapFifo.Underruns, UnderSplitText(FCapFifo.Underruns, FCapUnderSettle), FCapFifo.Overruns, Ppm(FCapCtl.Correction), FCapCtl.FilteredLevel, FCapTarget,
     C_SETTLE_SECONDS, FCapLevelMin, FCapLevelMax]));
  S2400Log(Format('  Ausgang: Unterlaeufe %d%s, Ueberlaeufe %d, Korrektur %.2f ppm, Fuellstand %.0f (Soll %.0f), ' +
    'nach %d s: min %.0f max %.0f',
    [FRenFifo.Underruns, UnderSplitText(FRenFifo.Underruns, FRenUnderSettle), FRenFifo.Overruns, Ppm(FRenCtl.Correction), FRenCtl.FilteredLevel, FRenTarget,
     C_SETTLE_SECONDS, FRenLevelMin, FRenLevelMax]));
end;

// -----------------------------------------------------------------------
// Echtzeit: Isla-Thread
// -----------------------------------------------------------------------

// True, wenn der naechste Master-Rueckruf ueberfaellig ist - der Host oder
// der Master pausiert gerade (aus den Lese-Threads aufgerufen)
function TS2400AggDriver.HostOverdue: Boolean;
var
  NowQpc, Last: Int64;
begin
  Last := TInterlocked.Read(FLastSwitchQpc);
  QueryPerformanceCounter(NowQpc);
  Result := (Last <> 0) and (NowQpc - Last > (FSwitchPeriodQpc * 3) div 2);
end;

procedure TS2400AggDriver.IslaThreadLoop(AThread: TS2400AggIslaThread);
begin
  while not AThread.Terminated do
  begin
    if not FIsla.WaitForCaptureReady(200) then
      Continue;
    while not AThread.Terminated do
    begin
      try
        ProcessIslaPacket;
      except
        Inc(FIslaExceptions); // kein Logging im Echtzeit-Thread
      end;
      if not FIsla.CaptureMoreData then
        Break;
    end;
  end;
end;

procedure TS2400AggDriver.ProcessIslaPacket;
var
  Data, RData: PByte;
  Frames: Cardinal;
  P, InCh, OutCh, I, N: Integer;
  StampFirst, StampEnd, NowQpc, Dropped, Missing, Excess, Under: Int64;
  Src: PSmallInt;
  Dst: PSmallInt;
  F: Single;
  V: Integer;
  CapBuf, RenBuf: System.PSingle;
begin
  if not FIsla.ReadCaptureBuffer(Data, Frames) then
    Exit;
  Inc(FIslaPackets);
  P := FIslaPacketFrames;
  if Integer(Frames) < P then
    P := Frames;
  InCh := FIslaIn;
  OutCh := FIslaOut;
  CapBuf := System.PSingle(Pointer(FIslaCapFloat));
  RenBuf := System.PSingle(Pointer(FIslaRenFloat));

  // Zeitstempel: erstes Sample laut Treiber, sonst ersatzweise "jetzt"
  StampFirst := Int64(FIsla.LastCaptureQpc);
  if StampFirst = 0 then
  begin
    QueryPerformanceCounter(NowQpc);
    StampFirst := NowQpc - (Int64(P) * FQpcFreq) div Round(C_ISLA_RATE);
  end;
  StampEnd := StampFirst + (Int64(P) * FQpcFreq) div Round(C_ISLA_RATE);

  // verlorene Pakete (Thread zu spaet geweckt) mit Stille ergaenzen, damit
  // die FIFO der Zeit folgt; der Leser ueberspringt sie als Fehlmenge.
  // Auf der Ausgangsseite die entsprechende Menge verwerfen.
  Dropped := FIsla.DroppedCapturePackets;
  Missing := (Dropped - FIslaDroppedSeen) * FIslaPacketFrames;
  FIslaDroppedSeen := Dropped;
  if Missing > 0 then
  begin
    Inc(FIslaGapFrames, Missing);
    if Missing > C_FIFO_CAPACITY div 2 then
      Missing := C_FIFO_CAPACITY div 2;
    FillChar(CapBuf^, FIslaPacketFrames * InCh * SizeOf(Single), 0);
    while Missing > 0 do
    begin
      N := FIslaPacketFrames;
      if N > Missing then
        N := Integer(Missing);
      FCapFifo.Write(CapBuf, N, StampFirst);
      if FRenRunning then
        FRenFifo.Read(RenBuf, N);
      Dec(Missing, N);
    end;
  end;

  // Eingang: Int16 -> Float -> Capture-FIFO
  Src := PSmallInt(Data);
  for I := 0 to P * InCh - 1 do
    CapBuf[I] := Src[I] * (1.0 / 32768.0);
  FCapFifo.Write(CapBuf, P, StampEnd);

  // Ausgang: erst lesen, wenn die Render-FIFO den Sollwert erreicht hat -
  // und fruehestens C_GATE_SECONDS nach dem Start; was sich bis dahin
  // angesammelt hat, auf den Sollwert kuerzen (sonst zusaetzliche Latenz)
  if not FRenRunning and (FSwitchCount >= FGateSwitches) and (FRenFifo.Level >= Round(FRenTarget)) then
  begin
    Excess := FRenFifo.Level - Round(FRenTarget);
    while Excess > 0 do
    begin
      N := P;
      if N > Excess then
        N := Integer(Excess);
      FRenFifo.Read(RenBuf, N);
      Dec(Excess, N);
    end;
    FRenRunning := True;
  end;
  if FRenRunning then
  begin
    Under := FRenFifo.Underruns;
    FRenFifo.Read(RenBuf, P);
    if (FRenFifo.Underruns <> Under) and HostOverdue then
      Inc(FRenHostUnder);
  end
  else
    FillChar(RenBuf^, P * OutCh * SizeOf(Single), 0);
  TInterlocked.Exchange(FRenReadQpc, StampEnd);

  if not FIsla.WriteRenderBuffer(RData, FIslaPacketFrames) then
    Exit;
  Dst := PSmallInt(RData);
  for I := 0 to P * OutCh - 1 do
  begin
    F := RenBuf[I];
    if F <> F then
      V := 0
    else if F >= 32767.0 / 32768.0 then
      V := 32767
    else if F <= -1.0 then
      V := -32768
    else
      V := Round(F * 32768.0);
    Dst[I] := V;
  end;
  FIsla.ReleaseRenderBuffer;
end;

// -----------------------------------------------------------------------
// Windows-Ausgang (Etappe C)
// -----------------------------------------------------------------------

constructor TS2400AggWinThread.Create(ADriver: TS2400AggDriver);
begin
  inherited Create(True); // gestartet wird NACH dem Konstruktor (EThread!)
  FDriver := ADriver;
  FreeOnTerminate := False;
  Priority := tpTimeCritical;
end;

procedure TS2400AggWinThread.Execute;
var
  MmcssHandle: THandle;
  MmcssTaskIndex: DWORD;
begin
  SetMXCSR($1F80);
  Set8087CW($027F);
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  MmcssTaskIndex := 0;
  MmcssHandle := AvSetMmThreadCharacteristicsW('Pro Audio', MmcssTaskIndex);
  if MmcssHandle <> 0 then
    AvSetMmThreadPriority(MmcssHandle, AVRT_PRIORITY_CRITICAL);
  try
    FDriver.WinThreadLoop(Self);
  finally
    if MmcssHandle <> 0 then
      AvRevertMmThreadCharacteristics(MmcssHandle);
    CoUninitialize;
  end;
end;

procedure TS2400AggDriver.FreeWinBuffers;
var
  I: Integer;
begin
  for I := 0 to High(FWinOutBuf) do
    if FWinOutBuf[I] <> nil then
      FreeMem(FWinOutBuf[I]);
  FWinOutBuf := nil;
  FWinOutActive := nil;
end;

procedure TS2400AggDriver.FreeWinSync;
begin
  if FWin <> nil then
  begin
    FWin.Close;
    FreeAndNil(FWin);
  end;
  FreeAndNil(FWinFifo);
  FreeAndNil(FWinRes);
  FreeAndNil(FWinCtl);
  FWinSync := False;
end;

// Geraet oeffnen und Umrechner/FIFO/Regler anlegen (in createBuffers).
// Sollfuellstand in Geraete-Frames: ein Geraetepuffer (so viel holt der
// Thread hoechstens auf einmal) + ein Master-Puffer + Reserve + 64.
procedure TS2400AggDriver.BuildWinSync;
begin
  FreeWinSync;
  if FWinOut = 0 then
    Exit;
  if FMasterRate < 44000 then
  begin
    S2400Log(Format('Windows-Ausgang bei %.0f Hz nicht moeglich - Win-Kanaele bleiben still', [FMasterRate]));
    Exit;
  end;
  FWin := TS2400WasapiOut.Create;
  if not FWin.Open(FWinDeviceId, Round(FMasterRate), FWinExclusive) then
  begin
    S2400Log('Windows-Ausgang "' + FWinDeviceName + '" nicht geoeffnet: ' + FWin.LastError);
    FreeAndNil(FWin);
    Exit;
  end;
  FWinRate := FWin.SampleRate;
  FWinFifo := TS2400SpscFifo.Create(2, C_FIFO_CAPACITY);
  FWinRes := TS2400Resampler.Create(2, FMasterRate, FWinRate);
  FWinTarget := FWin.BufferFrames + FBufferFrames * FWinRate / FMasterRate +
    FReserveMs * FWinRate / 1000 + 64;
  FWinCtl := TS2400DriftController.Create(FWinTarget, 50, 0.9, 1, 1000, FWinRate);
  SetLength(FWinIn, FBufferFrames * 2);
  SetLength(FWinTmp, C_REN_CHUNK * 2);
  SetLength(FWinDevBuf, Integer(FWin.BufferFrames) * 2);
  if Length(FChanTmp) < FBufferFrames then
    SetLength(FChanTmp, FBufferFrames);
  FWinSync := True;
  S2400Log(Format('Windows-Ausgang "%s" geoeffnet: %s, Geraetepuffer %d Frames, %d Kanaele; ' +
    'Master %.0f Hz -> %.0f Hz, Sollfuellstand %.0f Frames (%.2f ms)',
    [FWinDeviceName, FWin.FormatText, FWin.BufferFrames, FWin.DeviceChannels, FMasterRate, FWinRate,
     FWinTarget, FWinTarget * 1000 / FWinRate]));
end;

procedure TS2400AggDriver.StopWinStreaming;
begin
  if FWinThread <> nil then
  begin
    FWinThread.Terminate;
    FWin.Abort;
    FWinThread.WaitFor;
    FreeAndNil(FWinThread);
  end;
  if FWinStreaming and (FWin <> nil) then
    FWin.Stop;
  FWinStreaming := False;
end;

procedure TS2400AggDriver.WinThreadLoop(AThread: TS2400AggWinThread);
begin
  while not AThread.Terminated do
  begin
    if not FWin.WaitReady(200) then
      Continue;
    if AThread.Terminated then
      Break;
    try
      ProcessWinPacket;
    except
      Inc(FWinExceptions); // kein Logging im Echtzeit-Thread
    end;
  end;
end;

// ein Geraetepuffer: erst lesen, wenn die FIFO den Sollwert erreicht hat,
// vorher Stille; Zeitpunkt des Lesens fuer den zeitkontinuierlichen
// Fuellstand merken (wie beim Isla-Ausgang)
procedure TS2400AggDriver.ProcessWinPacket;
var
  N, MaxN, K: Integer;
  NowQpc, Excess, Under: Int64;
  Buf: System.PSingle;
begin
  N := FWin.WritableFrames;
  if N <= 0 then
    Exit;
  MaxN := Length(FWinDevBuf) div 2;
  if N > MaxN then
    N := MaxN;
  if not FWinRunning and (FSwitchCount >= FGateSwitches) and (FWinFifo.Level >= Round(FWinTarget)) then
  begin
    Excess := FWinFifo.Level - Round(FWinTarget);
    while Excess > 0 do
    begin
      K := MaxN;
      if K > Excess then
        K := Integer(Excess);
      FWinFifo.Read(System.PSingle(Pointer(FWinDevBuf)), K);
      Dec(Excess, K);
    end;
    FWinRunning := True;
  end;
  Buf := System.PSingle(Pointer(FWinDevBuf));
  if FWinRunning then
  begin
    Under := FWinFifo.Underruns;
    FWinFifo.Read(Buf, N);
    if (FWinFifo.Underruns <> Under) and HostOverdue then
      Inc(FWinHostUnder);
    FWin.WriteFrames(Buf, N, 2);
  end
  else
    FWin.WriteFrames(nil, N, 2);
  QueryPerformanceCounter(NowQpc);
  TInterlocked.Exchange(FWinReadQpc, NowQpc);
end;

// im Master-Rueckruf: die Win-Ausgaenge des Hosts umrechnen und in die FIFO
procedure TS2400AggDriver.WinRenderPart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
var
  B, Ch, S, N, Guard: Integer;
  ReadQpc: Int64;
  Level: Double;
  Src, Dst: System.PSingle;
begin
  B := FBufferFrames;
  FillChar(FWinIn[0], B * 2 * SizeOf(Single), 0);
  for Ch := 0 to 1 do
  begin
    if not FWinOutActive[Ch] then
      Continue;
    Src := System.PSingle(Pointer(FChanTmp));
    AsioToFloat(FWinOutBuf[Ch * 2 + AIndex], FIslaOutType, Src, B);
    Dst := System.PSingle(Pointer(FWinIn)) + Ch;
    for S := 0 to B - 1 do
    begin
      Dst^ := Src[S];
      Inc(Dst, 2);
    end;
  end;

  ReadQpc := TInterlocked.Read(FWinReadQpc);
  if FWinRunning and (ReadQpc <> 0) then
  begin
    Level := FWinFifo.Level + FWinRes.PendingInputFrames * FWinRate / FMasterRate;
    if ANowQpc > ReadQpc then
      Level := Level - (ANowQpc - ReadQpc) * FWinRate / FQpcFreq;
    FWinRes.Correction := FWinCtl.Update(Level, ADt);
    if FSwitchCount > FSettleSwitches then
    begin
      if Level < FWinLevelMin then FWinLevelMin := Level;
      if Level > FWinLevelMax then FWinLevelMax := Level;
    end;
  end;

  FWinRes.Push(System.PSingle(Pointer(FWinIn)), B);
  Guard := 0;
  repeat
    N := FWinRes.Pull(System.PSingle(Pointer(FWinTmp)), C_REN_CHUNK);
    if N > 0 then
      FWinFifo.Write(System.PSingle(Pointer(FWinTmp)), N, ANowQpc);
    Inc(Guard);
  until (N <= 0) or (Guard > 64);
end;

// -----------------------------------------------------------------------
// Echtzeit: Master-Rueckruf (im Thread des Master-Treibers)
// -----------------------------------------------------------------------

// Hat der Host im Rueckruf zu lange gebraucht (Live-Lauf 30.10.2026: einmal
// 26 ms bei 5,3-ms-Puffern), laesst der Master die verpassten Puffer aus -
// seine Sample-Position springt. Fuer die Isla ist in dieser Zeit niemand
// gekommen: Capture-FIFO dauerhaft zu voll, Render-FIFO dauerhaft zu leer
// (Folge damals: Regler 25 s am Anschlag, 8443 Ausgabe-Unterlaeufe).
// Liefert die Anzahl ausgelassener Master-Frames (0 = keine Luecke).
function TS2400AggDriver.MasterGapFrames(ATimeInfo: PASIOTime): Int64;
var
  Pos: Int64;
  SP: TASIOSamples;
  TS: TASIOTimeStamp;
begin
  Result := 0;
  Pos := -1;
  if (ATimeInfo <> nil) and ((ATimeInfo^.timeInfo.flags and kSamplePositionValid) <> 0) then
    Pos := ASIOSamplesToInt64(ATimeInfo^.timeInfo.samplePosition)
  else if FMaster.GetSamplePosition(SP, TS) = ASE_OK then
    Pos := ASIOSamplesToInt64(SP);
  if Pos < 0 then
    Exit;
  if FLastMasterPos >= 0 then
  begin
    Result := Pos - FLastMasterPos - FBufferFrames;
    // nur plausible Spruenge (bis 2 s) - alles andere ist ein Neustart o.ae.
    if (Result < 0) or (Result > 2 * Round(FMasterRate)) then
      Result := 0;
    // ausgelassen werden immer ganze Puffer; kleines Zittern der gemeldeten
    // Position (manche Treiber) darf nicht als Luecke zaehlen
    Result := Round(Result / FBufferFrames) * FBufferFrames;
  end;
  FLastMasterPos := Pos;
  if Result > 0 then
  begin
    Inc(FMasterGapEvents);
    Inc(FMasterGapFrames, Result);
    if Result > FMasterGapMax then
      FMasterGapMax := Result;
  end;
end;

// ausgelassene Master-Frames fuer die Isla nachbilden: Eingang so viel
// verwerfen, Ausgang so viel Stille nachschieben - wie bei verlorenen
// Isla-Paketen bleibt der Zeitbezug erhalten, der Regler merkt nichts
procedure TS2400AggDriver.CompensateMasterGap(AFrames: Int64; ANowQpc: Int64);
var
  M48, MWin, Left: Int64;
  N: Integer;
begin
  if FIslaSync and FIslaStreaming then
  begin
    M48 := Round(AFrames * C_ISLA_RATE / FMasterRate);
    if M48 > C_FIFO_CAPACITY div 2 then
      M48 := C_FIFO_CAPACITY div 2;

    if FCapRunning then
    begin
      Left := M48;
      while Left > 0 do
      begin
        N := C_CAP_CHUNK;
        if N > Left then
          N := Integer(Left);
        FCapFifo.Read(System.PSingle(Pointer(FCapChunk)), N);
        Dec(Left, N);
      end;
    end;

    FillChar(FRenOut[0], C_REN_CHUNK * FIslaOut * SizeOf(Single), 0);
    Left := M48;
    while Left > 0 do
    begin
      N := C_REN_CHUNK;
      if N > Left then
        N := Integer(Left);
      FRenFifo.Write(System.PSingle(Pointer(FRenOut)), N, ANowQpc);
      Dec(Left, N);
    end;
  end;

  // Windows-Ausgang: dieselbe Zeit als Stille nachschieben
  if FWinSync and FWinStreaming then
  begin
    MWin := Round(AFrames * FWinRate / FMasterRate);
    if MWin > C_FIFO_CAPACITY div 2 then
      MWin := C_FIFO_CAPACITY div 2;
    FillChar(FWinTmp[0], C_REN_CHUNK * 2 * SizeOf(Single), 0);
    Left := MWin;
    while Left > 0 do
    begin
      N := C_REN_CHUNK;
      if N > Left then
        N := Integer(Left);
      FWinFifo.Write(System.PSingle(Pointer(FWinTmp)), N, ANowQpc);
      Dec(Left, N);
    end;
  end;
end;

procedure TS2400AggDriver.IslaCapturePart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
var
  B, InCh, Ch, S, N: Integer;
  Stamp, Excess: Int64;
  Level, Corr: Double;
  Src, Dst: System.PSingle;
begin
  B := FBufferFrames;
  InCh := FIslaIn;

  if not FCapRunning and (FSwitchCount >= FGateSwitches) and (FCapFifo.Level >= Round(FCapTarget)) then
  begin
    // Ueberschuss ueber dem Sollwert verwerfen, damit der Regler nicht
    // erst minutenlang abbauen muss (max. 1000 ppm = 48 Frames/s)
    Excess := FCapFifo.Level - Round(FCapTarget);
    while Excess > 0 do
    begin
      N := C_CAP_CHUNK;
      if N > Excess then
        N := Integer(Excess);
      FCapFifo.Read(System.PSingle(Pointer(FCapChunk)), N);
      Dec(Excess, N);
    end;
    FCapRunning := True;
    FCapCtl.Reset;
  end;

  if FCapRunning then
  begin
    // zeitkontinuierlicher Fuellstand (siehe Unit-Kopf)
    Level := FCapFifo.Level + FCapRes.PendingInputFrames;
    Stamp := FCapFifo.LastStampQpc;
    if (Stamp <> 0) and (ANowQpc > Stamp) then
      Level := Level + (ANowQpc - Stamp) * C_ISLA_RATE / FQpcFreq;
    Corr := FCapCtl.Update(Level, ADt);
    FCapRes.Correction := Corr;
    FCapLevelLast := Level;
    if FSwitchCount > FSettleSwitches then
    begin
      if Level < FCapLevelMin then FCapLevelMin := Level;
      if Level > FCapLevelMax then FCapLevelMax := Level;
    end;

    while FCapRes.Available < B do
    begin
      FCapFifo.Read(System.PSingle(Pointer(FCapChunk)), C_CAP_CHUNK);
      FCapRes.Push(System.PSingle(Pointer(FCapChunk)), C_CAP_CHUNK);
    end;
    N := FCapRes.Pull(System.PSingle(Pointer(FCapOut)), B);
    if N < B then
      FillChar(FCapOut[N * InCh], (B - N) * InCh * SizeOf(Single), 0);
  end
  else
    FillChar(FCapOut[0], B * InCh * SizeOf(Single), 0);

  // interleaved -> die vom Host belegten Isla-Eingaenge (Master-Format)
  for Ch := 0 to InCh - 1 do
  begin
    if not FIslaInActive[Ch] then
      Continue;
    Src := System.PSingle(Pointer(FCapOut)) + Ch;
    Dst := System.PSingle(Pointer(FChanTmp));
    for S := 0 to B - 1 do
    begin
      Dst[S] := Src^;
      Inc(Src, InCh);
    end;
    FloatToAsio(Dst, FIslaInBuf[Ch * 2 + AIndex], FIslaInType, B);
  end;
end;

procedure TS2400AggDriver.IslaRenderPart(AIndex: Integer; ANowQpc: Int64; ADt: Double);
var
  B, OutCh, Ch, S, N, Guard: Integer;
  ReadQpc: Int64;
  Level, Corr: Double;
  Src, Dst: System.PSingle;
begin
  B := FBufferFrames;
  OutCh := FIslaOut;

  // vom Host belegte Isla-Ausgaenge -> interleaved Float
  FillChar(FRenIn[0], B * OutCh * SizeOf(Single), 0);
  for Ch := 0 to OutCh - 1 do
  begin
    if not FIslaOutActive[Ch] then
      Continue;
    Src := System.PSingle(Pointer(FChanTmp));
    AsioToFloat(FIslaOutBuf[Ch * 2 + AIndex], FIslaOutType, Src, B);
    Dst := System.PSingle(Pointer(FRenIn)) + Ch;
    for S := 0 to B - 1 do
    begin
      Dst^ := Src[S];
      Inc(Dst, OutCh);
    end;
  end;

  // Regler, sobald die Isla aus der Render-FIFO liest
  ReadQpc := TInterlocked.Read(FRenReadQpc);
  if FRenRunning and (ReadQpc <> 0) then
  begin
    Level := FRenFifo.Level + FRenRes.PendingInputFrames * C_ISLA_RATE / FMasterRate;
    if ANowQpc > ReadQpc then
      Level := Level - (ANowQpc - ReadQpc) * C_ISLA_RATE / FQpcFreq;
    Corr := FRenCtl.Update(Level, ADt);
    FRenRes.Correction := Corr;
    FRenLevelLast := Level;
    if FSwitchCount > FSettleSwitches then
    begin
      if Level < FRenLevelMin then FRenLevelMin := Level;
      if Level > FRenLevelMax then FRenLevelMax := Level;
    end;
  end;

  FRenRes.Push(System.PSingle(Pointer(FRenIn)), B);
  Guard := 0;
  repeat
    N := FRenRes.Pull(System.PSingle(Pointer(FRenOut)), C_REN_CHUNK);
    if N > 0 then
      FRenFifo.Write(System.PSingle(Pointer(FRenOut)), N, ANowQpc);
    Inc(Guard);
  until (N <= 0) or (Guard > 64);
end;

// Master-Eingaenge um FMasterInDelay Frames verzoegert an den Host geben:
// aktuellen Puffer in den Ring schreiben, um die Verzoegerung versetzt
// wieder lesen. Ringlaenge = Verzoegerung + Puffer, dadurch liegen genau
// die benoetigten aelteren Samples noch im Ring.
procedure TS2400AggDriver.ApplyMasterInputDelay(AIndex: Integer);
var
  Ch, Bps, RingLen, B, ReadPos, First: Integer;
  Ring, Src, Dst: PByte;
begin
  B := FBufferFrames;
  RingLen := FMasterInDelay + B;
  ReadPos := (FDelayPos - FMasterInDelay + RingLen) mod RingLen;
  for Ch := 0 to FMasterIn - 1 do
  begin
    Bps := FDelayBps[Ch];
    Ring := PByte(Pointer(FDelayRing[Ch]));
    Src := PByte(FMaster.InputBuffer(Ch, AIndex));
    Dst := PByte(FDelayHostBuf[Ch * 2 + AIndex]);
    if Src = nil then
      Continue;

    // schreiben (ggf. in zwei Teilen ueber das Ringende)
    First := RingLen - FDelayPos;
    if First > B then
      First := B;
    Move(Src^, (Ring + FDelayPos * Bps)^, First * Bps);
    if First < B then
      Move((Src + First * Bps)^, Ring^, (B - First) * Bps);

    // verzoegert lesen
    First := RingLen - ReadPos;
    if First > B then
      First := B;
    Move((Ring + ReadPos * Bps)^, Dst^, First * Bps);
    if First < B then
      Move(Ring^, (Dst + First * Bps)^, (B - First) * Bps);
  end;
  FDelayPos := (FDelayPos + B) mod RingLen;
end;

procedure TS2400AggDriver.InvokeHost(AIndex: Integer; ATimeInfo: PASIOTime);
var
  TI: TASIOTime;
  SP: TASIOSamples;
  TS: TASIOTimeStamp;
begin
  if FSupportsTimeInfo and Assigned(FCallbacks.bufferSwitchTimeInfo) then
  begin
    if ATimeInfo <> nil then
      FCallbacks.bufferSwitchTimeInfo(ATimeInfo, AIndex, ASIOFalse)
    else
    begin
      // Master liefert nur bufferSwitch - Zeitinformation selbst erfragen
      FillChar(TI, SizeOf(TI), 0);
      TI.timeInfo.sampleRate := FMasterRate;
      TI.timeInfo.flags := kSampleRateValid;
      if FMaster.GetSamplePosition(SP, TS) = ASE_OK then
      begin
        TI.timeInfo.samplePosition := SP;
        TI.timeInfo.systemTime := TS;
        TI.timeInfo.flags := TI.timeInfo.flags or kSystemTimeValid or kSamplePositionValid;
      end;
      FCallbacks.bufferSwitchTimeInfo(@TI, AIndex, ASIOFalse);
    end;
  end
  else if Assigned(FCallbacks.bufferSwitch) then
    FCallbacks.bufferSwitch(AIndex, ASIOFalse);
end;

// Pegelanzeigen des Mixers: Spitzenwert je Isla-Kanal (vor Fader und
// Matrix), seit dem letzten Abruf durch den Mixer
procedure TS2400AggDriver.MeasureInputs;
var
  B, InCh, N, Ch, S: Integer;
  Src: System.PSingle;
  P, V: Single;
begin
  if FShared = nil then
    Exit;
  B := FBufferFrames;
  InCh := FIslaIn;
  N := Min(InCh, C_MIX_CHANNELS);
  Src := System.PSingle(Pointer(FCapOut));
  for Ch := 0 to N - 1 do
  begin
    P := FShared^.InPeak[Ch];
    for S := 0 to B - 1 do
    begin
      V := Abs(Src[S * InCh + Ch]);
      if V > P then
        P := V;
    end;
    FShared^.InPeak[Ch] := P;
  end;
end;

// Isla-Monitoring mit Matrix: fuer jedes Ausgangspaar des Masters, auf das
// mindestens ein eingeschalteter Isla-Kanal geroutet ist, die Kanaele (aus
// FCapOut, schon auf Master-Takt und -Rate umgerechnet) mit Pegel und
// Panorama summieren. Belegt der Host das Paar selbst, wird addiert, sonst
// ueberschrieben. Paare, die nicht mehr beschrieben werden, werden stumm
// geschaltet. Laeuft NACH dem Host-Rueckruf.
procedure TS2400AggDriver.MonitorPart(AIndex: Integer);
var
  B, InCh, N, Pairs, P, Ch, S, Side, OutCh: Integer;
  Used, Bit: Cardinal;
  GL, GR, X, Pk: Single;
  Src, Mon, Tmp: System.PSingle;
  Buf: Pointer;
  T: TASIOSampleType;
begin
  B := FBufferFrames;
  InCh := FIslaIn;
  N := Min(InCh, C_MIX_CHANNELS);
  Pairs := Min(FMasterOut div 2, C_MIX_MAX_PAIRS);

  // welche Paare werden gebraucht?
  Used := 0;
  if FMix.Enabled then
    for Ch := 0 to N - 1 do
      if FMix.ChOn[Ch] then
        Used := Used or FMix.ChRoute[Ch];
  if Pairs < 32 then
    Used := Used and ((Cardinal(1) shl Pairs) - 1);

  // nicht mehr gebrauchte Paare nicht weiterklingen lassen
  ClearMonitorPairs(FMonWritten and not Used);
  FMonWritten := Used;
  if Used = 0 then
    Exit;

  Src := System.PSingle(Pointer(FCapOut));
  for P := 0 to Pairs - 1 do
  begin
    Bit := Cardinal(1) shl P;
    if (Used and Bit) = 0 then
      Continue;
    FillChar(FMonL[0], B * SizeOf(Single), 0);
    FillChar(FMonR[0], B * SizeOf(Single), 0);
    for Ch := 0 to N - 1 do
    begin
      if not FMix.ChOn[Ch] or ((FMix.ChRoute[Ch] and Bit) = 0) then
        Continue;
      GL := FMixGainL[Ch];
      GR := FMixGainR[Ch];
      if (GL = 0) and (GR = 0) then
        Continue;
      for S := 0 to B - 1 do
      begin
        X := Src[S * InCh + Ch];
        FMonL[S] := FMonL[S] + X * GL;
        FMonR[S] := FMonR[S] + X * GR;
      end;
    end;

    for Side := 0 to 1 do
    begin
      OutCh := P * 2 + Side;
      if Side = 0 then
        Mon := System.PSingle(Pointer(FMonL))
      else
        Mon := System.PSingle(Pointer(FMonR));
      Buf := FMaster.OutputBuffer(OutCh, AIndex);
      if Buf = nil then
        Continue;
      T := FMaster.OutputInfo(OutCh).sampleType;
      if FMasterOutActive[OutCh] then
      begin
        Tmp := System.PSingle(Pointer(FChanTmp));
        AsioToFloat(Buf, T, Tmp, B);
        for S := 0 to B - 1 do
          Tmp[S] := Tmp[S] + Mon[S];
        Mon := Tmp;
      end;
      FloatToAsio(Mon, Buf, T, B);
      // Pegelanzeige des Ausgangs (was der Master tatsaechlich spielt)
      if FShared <> nil then
      begin
        Pk := FShared^.OutPeak[OutCh];
        for S := 0 to B - 1 do
        begin
          X := Abs(Mon[S]);
          if X > Pk then
            Pk := X;
        end;
        FShared^.OutPeak[OutCh] := Pk;
      end;
    end;
  end;
end;

procedure TS2400AggDriver.ClearMonitorPairs(AMask: Cardinal);
var
  P: Integer;
begin
  if AMask = 0 then
    Exit;
  for P := 0 to C_MIX_MAX_PAIRS - 1 do
    if (AMask and (Cardinal(1) shl P)) <> 0 then
      ClearMonitorPair(P);
end;

// vom Monitoring beschriebene, aber vom Host nicht belegte Ausgaenge stumm
// schalten (beide Haelften - sonst spielt der Master den letzten Puffer endlos)
procedure TS2400AggDriver.ClearMonitorPair(APair: Integer);
var
  Side, OutCh, H: Integer;
  Buf: Pointer;
begin
  if APair < 0 then
    Exit;
  for Side := 0 to 1 do
  begin
    OutCh := APair * 2 + Side;
    if (OutCh >= FMasterOut) or FMasterOutActive[OutCh] then
      Continue;
    for H := 0 to 1 do
    begin
      Buf := FMaster.OutputBuffer(OutCh, H);
      if Buf <> nil then
        FillChar(Buf^, FBufferFrames * AsioSampleBytes(FMaster.OutputInfo(OutCh).sampleType), 0);
    end;
  end;
end;

procedure TS2400AggDriver.HandleMasterSwitch(ADoubleBufferIndex: Integer; ATimeInfo: PASIOTime);
var
  T0, T1, Gap: Int64;
  Dt: Double;
begin
  QueryPerformanceCounter(T0);
  try
    if FLastSwitchQpc <> 0 then
      Dt := (T0 - FLastSwitchQpc) / FQpcFreq
    else
      Dt := FBufferFrames / FMasterRate;
    FLastSwitchQpc := T0;
    Inc(FSwitchCount);
    if FSwitchCount = FSettleSwitches then
    begin
      if FIslaSync then
      begin
        FCapUnderSettle := FCapFifo.Underruns;
        FRenUnderSettle := FRenFifo.Underruns;
      end;
      if FWinSync then
        FWinUnderSettle := FWinFifo.Underruns;
    end;

    // vom Master ausgelassene Puffer erkennen und fuer Isla/Windows-Ausgang ausgleichen
    Gap := MasterGapFrames(ATimeInfo);
    if Gap > 0 then
      CompensateMasterGap(Gap, T0);

    if FIslaSync and FIslaStreaming then
      IslaCapturePart(ADoubleBufferIndex, T0, Dt);

    if FMasterInDelay > 0 then
      ApplyMasterInputDelay(ADoubleBufferIndex);

    InvokeHost(ADoubleBufferIndex, ATimeInfo);

    if FIslaSync and FIslaStreaming then
    begin
      SyncMix; // neuer Stand aus dem Mixer (gleich in welchem Programm)?
      MeasureInputs;
      MonitorPart(ADoubleBufferIndex); // schaltet auch abgewaehlte Paare stumm
    end
    else if FMonWritten <> 0 then
    begin
      ClearMonitorPairs(FMonWritten);
      FMonWritten := 0;
    end;

    if FIslaSync and FIslaStreaming then
      IslaRenderPart(ADoubleBufferIndex, T0, Dt);

    if FWinSync and FWinStreaming then
      WinRenderPart(ADoubleBufferIndex, T0, Dt);

    FMaster.OutputReady;
  except
    Inc(FCbExceptions); // kein Logging im Echtzeit-Thread
  end;
  QueryPerformanceCounter(T1);
  if (FSwitchCount > 50) and (T1 - T0 > FMaxSwitchQpc) then
    FMaxSwitchQpc := T1 - T0;
end;

// Meldungen des Masters an den Host des Verbunds weiterreichen
procedure TS2400AggDriver.HandleMasterMessage(ASelector: LongInt);
var
  Msg: TASIOMessageProc;
begin
  try
    if ASelector = kAsioLatenciesChanged then
      FMaster.RefreshLatencies;
    Msg := FCallbacks.asioMessage;
    if Assigned(Msg) then
      Msg(ASelector, 0, nil, nil);
  except
    Inc(FCbExceptions);
  end;
end;

// -----------------------------------------------------------------------
// IUnknown
// -----------------------------------------------------------------------

function TS2400AggDriver.QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
var
  EffectiveIID: TGUID;
begin
  // ASIO-Hosts fragen mit der Treiber-CLSID statt der IASIO-GUID an
  if IsEqualGUID(IID, CLSID_S2400Aggregate) then
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
end;

function TS2400AggDriver._AddRef: Integer; stdcall;
begin
  Result := InterlockedIncrement(FRefCount);
end;

function TS2400AggDriver._Release: Integer; stdcall;
begin
  Result := InterlockedDecrement(FRefCount);
  if Result = 0 then
    Destroy;
end;

// -----------------------------------------------------------------------
// IASIO - Implementierungen
// -----------------------------------------------------------------------

function TS2400AggDriver.DoInit(sysHandle: Pointer): TASIOBool;
begin
  FSysHandle := sysHandle;
  S2400Log('IASIO.init() aufgerufen');
  if not EnsureDevices then
    Exit(ASIOFalse);
  S2400Log(Format('IASIO.init() erfolgreich: %d Ein / %d Aus (Master %d/%d, Isla %d/%d, Windows-Ausgang %d)',
    [FMasterIn + FIslaIn, FMasterOut + FIslaOut + FWinOut, FMasterIn, FMasterOut, FIslaIn, FIslaOut, FWinOut]));
  Result := ASIOTrue;
end;

function TS2400AggDriver.DoStart: TASIOError;
var
  Ch, H, Bytes: Integer;
  P: Pointer;
begin
  if FActive then
    Exit(ASE_OK);
  if (FMaster = nil) or not FBuffersCreated then
    Exit(ASE_InvalidMode);

  // vom Host nicht belegte Master-Ausgaenge einmalig stumm schalten
  for Ch := 0 to FMasterOut - 1 do
    if not FMasterOutActive[Ch] then
    begin
      Bytes := FBufferFrames * AsioSampleBytes(FMaster.OutputInfo(Ch).sampleType);
      for H := 0 to 1 do
      begin
        P := FMaster.OutputBuffer(Ch, H);
        if P <> nil then
          FillChar(P^, Bytes, 0);
      end;
    end;

  FSupportsTimeInfo := Assigned(FCallbacks.asioMessage) and
    (FCallbacks.asioMessage(kAsioSupportsTimeInfo, 0, nil, nil) = 1);

  ResetSync;
  FMonWritten := 0; // nicht belegte Master-Ausgaenge sind eben stumm geschaltet

  // Verzoegerungsringe der Master-Eingaenge mit Stille beginnen
  FDelayPos := 0;
  for Ch := 0 to High(FDelayRing) do
    if Length(FDelayRing[Ch]) > 0 then
      FillChar(FDelayRing[Ch][0], Length(FDelayRing[Ch]), 0);

  // erst der Master (er gibt ab sofort den Takt; die Isla-Kanaele sind bis
  // FIslaStreaming still), dann die Isla. So kann die Capture-FIFO nicht
  // volllaufen, waehrend der Master noch anlaeuft.
  FIslaStreaming := False;
  if not FMaster.Start then
  begin
    FErrorMessage := FMaster.LastError;
    S2400Log('FEHLER in start(): ' + FErrorMessage);
    Exit(ASE_HWMalfunction);
  end;
  FActive := True;

  if FIslaSync then
  begin
    if FIsla.StartStreaming then
    begin
      FIslaThread := TS2400AggIslaThread.Create(Self);
      FIslaThread.Start; // erst NACH dem Konstruktor
      FIslaStreaming := True;
    end
    else
      S2400Log('Isla-Streaming nicht gestartet - Isla-Kanaele bleiben still: ' + FIsla.LastError);
  end;

  // Windows-Ausgang: Zwischenspeicher leer, Geraet mit Stille starten
  FWinStreaming := False;
  if FWinSync then
  begin
    FWinFifo.Reset;
    FWinRes.Reset;
    FWinRes.Correction := 1.0;
    FWinCtl.Reset;
    FWinRunning := False;
    FWinReadQpc := 0;
    FWinExceptions := 0;
    FWinLevelMin := 1E12;
    FWinLevelMax := -1E12;
    if FWin.Start then
    begin
      FWinThread := TS2400AggWinThread.Create(Self);
      FWinThread.Start; // erst NACH dem Konstruktor
      FWinStreaming := True;
    end
    else
      S2400Log('Windows-Ausgang startet nicht - Win-Kanaele bleiben still');
  end;

  SyncMix;      // Stand des Mixers seit dem Laden uebernehmen
  PublishState; // der Mixer zeigt: laeuft, in welchem Programm, Latenz
  S2400Log(Format('IASIO.start() OK (TimeInfo=%s, Isla=%s, Windows-Ausgang=%s)',
    [BoolToStr(FSupportsTimeInfo, True), BoolToStr(FIslaStreaming, True), BoolToStr(FWinStreaming, True)]));
  Result := ASE_OK;
end;

function TS2400AggDriver.DoStop: TASIOError;
begin
  if not FActive then
    Exit(ASE_OK);

  // zuerst der Master (danach kommen keine Rueckrufe mehr), dann die Isla
  if FMaster <> nil then
    FMaster.Stop;
  if FIslaThread <> nil then
  begin
    FIslaThread.Terminate;
    FIsla.AbortStreaming;
    FIslaThread.WaitFor;
    FreeAndNil(FIslaThread);
  end;
  if FIslaStreaming then
    FIsla.StopStreaming;
  FIslaStreaming := False;
  StopWinStreaming;
  FActive := False;
  PublishState;

  LogRunSummary;
  S2400Log('IASIO.stop()');
  Result := ASE_OK;
end;

function TS2400AggDriver.DoCreateBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
  bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError;
var
  I, Ch, InBytes, OutBytes: Integer;
  Info: PASIOBufferInfo;
begin
  if not EnsureDevices then
    Exit(ASE_NotPresent);
  if (bufferInfos = nil) or (numChannels <= 0) then
    Exit(ASE_InvalidParameter);
  if FBuffersCreated then
    disposeBuffers;

  // Kanalnummern pruefen, BEVOR irgendetwas angelegt wird
  for I := 0 to numChannels - 1 do
  begin
    Info := BufferInfoAt(bufferInfos, I);
    Info^.buffers[0] := nil;
    Info^.buffers[1] := nil;
    if Info^.isInput <> 0 then
    begin
      if (Info^.channelNum < 0) or (Info^.channelNum >= FMasterIn + FIslaIn) then
        Exit(ASE_InvalidParameter);
    end
    else if (Info^.channelNum < 0) or (Info^.channelNum >= FMasterOut + FIslaOut + FWinOut) then
      Exit(ASE_InvalidParameter);
  end;

  // Master legt Puffer fuer ALLE seine Kanaele an (er gibt die Groesse vor)
  if not FMaster.CreateBuffers(bufferSize) then
  begin
    FErrorMessage := FMaster.LastError;
    S2400Log('createBuffers: Master lehnt ab: ' + FErrorMessage);
    Exit(ASE_InvalidMode);
  end;
  FBufferFrames := bufferSize;
  FMasterRate := FMaster.CurrentSampleRate;

  SetLength(FMasterOutActive, FMasterOut);
  for Ch := 0 to FMasterOut - 1 do
    FMasterOutActive[Ch] := False;

  // Takt-Angleichung + Laufzeitausgleich festlegen (bestimmt FMasterInDelay)
  BuildSync;

  // Master-Eingaenge verzoegern? Dann bekommt der Host eigene Puffer
  FreeDelayBuffers;
  if FMasterInDelay > 0 then
  begin
    SetLength(FDelayRing, FMasterIn);
    SetLength(FDelayBps, FMasterIn);
    SetLength(FDelayHostBuf, FMasterIn * 2);
    for Ch := 0 to FMasterIn - 1 do
    begin
      FDelayBps[Ch] := AsioSampleBytes(FMaster.InputInfo(Ch).sampleType);
      SetLength(FDelayRing[Ch], (FMasterInDelay + bufferSize) * FDelayBps[Ch]);
      FDelayHostBuf[Ch * 2] := AllocMem(bufferSize * FDelayBps[Ch]);
      FDelayHostBuf[Ch * 2 + 1] := AllocMem(bufferSize * FDelayBps[Ch]);
    end;
  end;

  // Isla-Puffer (im Format des Masters) fuer alle Isla-Kanaele anlegen
  FreeIslaBuffers;
  SetLength(FIslaInBuf, FIslaIn * 2);
  SetLength(FIslaOutBuf, FIslaOut * 2);
  SetLength(FIslaInActive, FIslaIn);
  SetLength(FIslaOutActive, FIslaOut);
  InBytes := bufferSize * AsioSampleBytes(FIslaInType);
  OutBytes := bufferSize * AsioSampleBytes(FIslaOutType);
  for I := 0 to High(FIslaInBuf) do
    FIslaInBuf[I] := AllocMem(InBytes);
  for I := 0 to High(FIslaOutBuf) do
    FIslaOutBuf[I] := AllocMem(OutBytes);
  for Ch := 0 to FIslaIn - 1 do
    FIslaInActive[Ch] := False;
  for Ch := 0 to FIslaOut - 1 do
    FIslaOutActive[Ch] := False;

  // Puffer des Windows-Ausgangs (ebenfalls im Format des Masters)
  FreeWinBuffers;
  SetLength(FWinOutBuf, FWinOut * 2);
  SetLength(FWinOutActive, FWinOut);
  for I := 0 to High(FWinOutBuf) do
    FWinOutBuf[I] := AllocMem(OutBytes);
  for Ch := 0 to FWinOut - 1 do
    FWinOutActive[Ch] := False;

  // Master-Kanaele: die Puffer des Masters selbst (ohne Kopie), ausser die
  // Eingaenge werden fuer den Laufzeitausgleich verzoegert
  for I := 0 to numChannels - 1 do
  begin
    Info := BufferInfoAt(bufferInfos, I);
    Ch := Info^.channelNum;
    if Info^.isInput <> 0 then
    begin
      if (Ch < FMasterIn) and (FMasterInDelay > 0) then
      begin
        Info^.buffers[0] := FDelayHostBuf[Ch * 2];
        Info^.buffers[1] := FDelayHostBuf[Ch * 2 + 1];
      end
      else if Ch < FMasterIn then
      begin
        Info^.buffers[0] := FMaster.InputBuffer(Ch, 0);
        Info^.buffers[1] := FMaster.InputBuffer(Ch, 1);
      end
      else
      begin
        Dec(Ch, FMasterIn);
        FIslaInActive[Ch] := True;
        Info^.buffers[0] := FIslaInBuf[Ch * 2];
        Info^.buffers[1] := FIslaInBuf[Ch * 2 + 1];
      end;
    end
    else
    begin
      if Ch < FMasterOut then
      begin
        FMasterOutActive[Ch] := True;
        Info^.buffers[0] := FMaster.OutputBuffer(Ch, 0);
        Info^.buffers[1] := FMaster.OutputBuffer(Ch, 1);
      end
      else if Ch < FMasterOut + FIslaOut then
      begin
        Dec(Ch, FMasterOut);
        FIslaOutActive[Ch] := True;
        Info^.buffers[0] := FIslaOutBuf[Ch * 2];
        Info^.buffers[1] := FIslaOutBuf[Ch * 2 + 1];
      end
      else
      begin
        Dec(Ch, FMasterOut + FIslaOut);
        FWinOutActive[Ch] := True;
        Info^.buffers[0] := FWinOutBuf[Ch * 2];
        Info^.buffers[1] := FWinOutBuf[Ch * 2 + 1];
      end;
    end;
  end;

  FBufferInfos := bufferInfos;
  FNumBufferChannels := numChannels;
  FCallbacks := callbacks;
  FBuffersCreated := True;

  // Windows-Ausgang oeffnen (Exklusiv-Modus belegt das Geraet, solange die
  // Puffer bestehen)
  BuildWinSync;

  S2400Log(Format('createBuffers: %d Kanaele, %d Frames, %.0f Hz', [numChannels, bufferSize, FMasterRate]));
  Result := ASE_OK;
end;

function TS2400AggDriver.DoDisposeBuffers: TASIOError;
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
    Info^.buffers[0] := nil;
    Info^.buffers[1] := nil;
  end;
  FreeIslaBuffers;
  FreeDelayBuffers;
  FreeWinBuffers;
  FreeWinSync;
  FMasterInDelay := 0;
  if FMaster <> nil then
    FMaster.DisposeBuffers;

  FBufferInfos := nil;
  FNumBufferChannels := 0;
  FBuffersCreated := False;
  FillChar(FCallbacks, SizeOf(FCallbacks), 0);
  Result := ASE_OK;
end;

function TS2400AggDriver.DoControlPanel: TASIOError;
var
  OldS, NewS: TS2400AggSettings;
  DevicesChanged, ReserveChanged: Boolean;
  R: TS2400AggPanelResult;
  T0: UInt64;
begin
  OldS := Default(TS2400AggSettings);
  OldS.Master := FMasterName;
  if (FMaster <> nil) and (OldS.Master = '') then
    OldS.Master := FMaster.DriverName;
  OldS.IslaEnabled := FIslaEnabled;
  OldS.IslaPacket := FIslaPacket;
  OldS.ReserveHigh := FReserveMs >= C_RESERVE_HIGH_MS;
  OldS.AlignInputs := FAlignInputs;
  OldS.IslaExtraIn := FIslaExtraIn;
  OldS.WinEnabled := FWinEnabled;
  OldS.WinDeviceId := FWinDeviceId;
  OldS.WinExclusive := FWinExclusive;
  NewS := OldS;

  // der Isla-Mixer (Knopf im Fenster) gilt sofort und speichert selbst
  T0 := GetTickCount64;
  R := ShowS2400AggPanel(HWND(FSysHandle),
    function: TS2400AggStatus
    begin
      Result := GetPanelStatus;
    end,
    SelectableMasters, TS2400WasapiOut.ListDevices,
    procedure(AOwner: HWND)
    begin
      OpenMixer(AOwner);
    end,
    NewS);
  S2400Log(Format('Einstellungsfenster geschlossen nach %.1f s (Ergebnis %d: 0 = Abbrechen, 1 = OK, 2 = Master-Fenster)',
    [(GetTickCount64 - T0) / 1000, Ord(R)]));
  if R = aprCancel then
    Exit(ASE_OK);

  // Geraete-Auswahl aendert die Kanalzahl -> Geraete neu laden
  DevicesChanged := not SameText(NewS.Master, FMasterName) or (NewS.IslaEnabled <> FIslaEnabled) or
    (NewS.IslaPacket <> FIslaPacket) or (NewS.WinEnabled <> FWinEnabled) or
    (NewS.WinDeviceId <> FWinDeviceId);
  // Reserve, Laufzeitausgleich und Exklusiv-Modus bestimmen Sollwerte,
  // Verzoegerung, gemeldete Latenz bzw. das Oeffnen des Geraets -> der Host
  // muss die Puffer neu anlegen
  ReserveChanged := (NewS.ReserveHigh <> OldS.ReserveHigh) or (NewS.AlignInputs <> FAlignInputs) or
    (NewS.IslaExtraIn <> FIslaExtraIn) or (NewS.WinExclusive <> FWinExclusive);

  FMasterName := NewS.Master;
  FIslaEnabled := NewS.IslaEnabled;
  FIslaPacket := NewS.IslaPacket;
  if NewS.ReserveHigh then
    FReserveMs := C_RESERVE_HIGH_MS
  else
    FReserveMs := C_RESERVE_NORMAL_MS;
  FAlignInputs := NewS.AlignInputs;
  FIslaExtraIn := NewS.IslaExtraIn;
  FWinEnabled := NewS.WinEnabled;
  FWinDeviceId := NewS.WinDeviceId;
  FWinExclusive := NewS.WinExclusive;
  SaveSettings;

  if DevicesChanged or ReserveChanged then
  begin
    S2400Log(Format('Control Panel: Master "%s", Isla %s, Paket %d, Reserve %d ms, ' +
      'Eingaenge angleichen %s, Korrektur Isla-Eingang %d, Windows-Ausgang %s (exklusiv %s) - Neustart noetig',
      [FMasterName, BoolToStr(FIslaEnabled, True), FIslaPacket, FReserveMs,
       BoolToStr(FAlignInputs, True), FIslaExtraIn, BoolToStr(FWinEnabled, True),
       BoolToStr(FWinExclusive, True)]));
    if FActive then
      stop;
    if DevicesChanged then
    begin
      FDevicesDirty := True;
      if not FBuffersCreated then
        EnsureDevices; // sonst beim naechsten createBuffers nach dem Reset
    end;
    if Assigned(FCallbacks.asioMessage) then
      FCallbacks.asioMessage(kAsioResetRequest, 0, nil, nil);
  end;

  if (R = aprMasterPanel) and (FMaster <> nil) then
    FMaster.ShowControlPanel;
  Result := ASE_OK;
end;

function TS2400AggDriver.DoSetSampleRate(sampleRate: TASIOSampleRate): TASIOError;
begin
  if FMaster = nil then
    Exit(ASE_NotPresent);
  if Abs(sampleRate - FMaster.CurrentSampleRate) < 0.5 then
    Exit(ASE_OK);
  if not FMaster.CanSampleRate(sampleRate) then
    Exit(ASE_NoClock);
  S2400Log(Format('setSampleRate: %.0f -> %.0f Hz', [FMaster.CurrentSampleRate, sampleRate]));
  if FActive then
    stop;
  if not FMaster.SetSampleRate(sampleRate) then
  begin
    FErrorMessage := FMaster.LastError;
    Exit(ASE_NoClock);
  end;
  FMasterRate := sampleRate;
  // Umrechner und Sollwerte haengen an der Rate -> Host soll neu anlegen
  if FBuffersCreated and Assigned(FCallbacks.asioMessage) then
    FCallbacks.asioMessage(kAsioResetRequest, 0, nil, nil);
  Result := ASE_OK;
end;

function TS2400AggDriver.DoGetChannelInfo(var info: TASIOChannelInfo): TASIOError;
var
  Ch: Integer;
begin
  if FMaster = nil then
    Exit(ASE_NotPresent);
  Ch := info.channel;
  if info.isInput <> 0 then
  begin
    if (Ch < 0) or (Ch >= FMasterIn + FIslaIn) then
      Exit(ASE_InvalidParameter);
    if Ch < FMasterIn then
      Exit(FMaster.QueryChannelInfo(info));
    Dec(Ch, FMasterIn);
    info.isActive := BoolToAsio(FBuffersCreated and (Ch <= High(FIslaInActive)) and FIslaInActive[Ch]);
    info.channelGroup := 1;
    info.sampleType := FIslaInType;
    CopyToAnsiBuffer(Format('S2400 In %d', [Ch + 1]), @info.name[0], 32);
  end
  else
  begin
    if (Ch < 0) or (Ch >= FMasterOut + FIslaOut + FWinOut) then
      Exit(ASE_InvalidParameter);
    if Ch < FMasterOut then
      Exit(FMaster.QueryChannelInfo(info));
    if Ch < FMasterOut + FIslaOut then
    begin
      Dec(Ch, FMasterOut);
      info.isActive := BoolToAsio(FBuffersCreated and (Ch <= High(FIslaOutActive)) and FIslaOutActive[Ch]);
      info.channelGroup := 1;
      info.sampleType := FIslaOutType;
      CopyToAnsiBuffer(Format('S2400 Out %d', [Ch + 1]), @info.name[0], 32);
    end
    else
    begin
      Dec(Ch, FMasterOut + FIslaOut);
      info.isActive := BoolToAsio(FBuffersCreated and (Ch <= High(FWinOutActive)) and FWinOutActive[Ch]);
      info.channelGroup := 2;
      info.sampleType := FIslaOutType;
      CopyToAnsiBuffer(Format('Win Out %d', [Ch + 1]), @info.name[0], 32);
    end;
  end;
  Result := ASE_OK;
end;

// -----------------------------------------------------------------------
// IASIO - Einstiegspunkte (nie eine Delphi-Ausnahme in den Host)
// -----------------------------------------------------------------------

function TS2400AggDriver.init(sysHandle: Pointer): TASIOBool; stdcall;
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

procedure TS2400AggDriver.getDriverName(name: PAnsiChar); stdcall;
begin
  CopyToAnsiBuffer(S2400_AGG_DRIVER_NAME, name, 32);
end;

function TS2400AggDriver.getDriverVersion: LongInt; stdcall;
begin
  Result := S2400_AGG_DRIVER_VERSION;
end;

procedure TS2400AggDriver.getErrorMessage(errorMessage: PAnsiChar); stdcall;
begin
  CopyToAnsiBuffer(FErrorMessage, errorMessage, 124);
end;

function TS2400AggDriver.start: TASIOError; stdcall;
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

function TS2400AggDriver.stop: TASIOError; stdcall;
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

function TS2400AggDriver.getChannels(out numInputChannels, numOutputChannels: LongInt): TASIOError; stdcall;
begin
  numInputChannels := 0;
  numOutputChannels := 0;
  try
    if not EnsureDevices then
      Exit(ASE_NotPresent);
    numInputChannels := FMasterIn + FIslaIn;
    numOutputChannels := FMasterOut + FIslaOut + FWinOut;
    Result := ASE_OK;
  except
    on E: Exception do
    begin
      LogException('getChannels', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AggDriver.getLatencies(out inputLatency, outputLatency: LongInt): TASIOError; stdcall;
var
  Delay, IslaLat, Reported: Integer;
  CapExtra: Double;
begin
  inputLatency := 0;
  outputLatency := 0;
  try
    if FMaster = nil then
      Exit(ASE_NotPresent);
    // Eingang: gemeinsame Latenz nach dem Laufzeitausgleich (siehe
    // CalcAlignment); vor createBuffers mit der bevorzugten Puffergroesse
    // geschaetzt. Ausgang: der Master (Isla-Ausgaenge werden nicht
    // angeglichen - das wuerde jedes Mithoeren verzoegern).
    FMaster.RefreshLatencies;
    inputLatency := FMaster.InputLatency;
    outputLatency := FMaster.OutputLatency;
    if FBuffersCreated then
    begin
      if FIslaSync then
        inputLatency := FReportedInLatency;
    end
    else if (FIsla <> nil) and (FMaster.CurrentSampleRate >= 44000) then
    begin
      CalcAlignment(FMaster.PreferredSize, FMaster.CurrentSampleRate, FMaster.InputLatency,
        Delay, CapExtra, IslaLat, Reported);
      inputLatency := Reported;
    end;
    Result := ASE_OK;
  except
    on E: Exception do
    begin
      LogException('getLatencies', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AggDriver.getBufferSize(out minSize, maxSize, preferredSize, granularity: LongInt): TASIOError; stdcall;
begin
  minSize := 0;
  maxSize := 0;
  preferredSize := 0;
  granularity := 0;
  try
    if not EnsureDevices then
      Exit(ASE_NotPresent);
    // der Master gibt die Puffergroesse vor
    minSize := FMaster.MinSize;
    maxSize := FMaster.MaxSize;
    preferredSize := FMaster.PreferredSize;
    granularity := FMaster.Granularity;
    Result := ASE_OK;
  except
    on E: Exception do
    begin
      LogException('getBufferSize', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AggDriver.canSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
begin
  try
    if (FMaster <> nil) and FMaster.CanSampleRate(sampleRate) then
      Result := ASE_OK
    else
      Result := ASE_NoClock;
  except
    Result := ASE_NoClock;
  end;
end;

function TS2400AggDriver.getSampleRate(out sampleRate: TASIOSampleRate): TASIOError; stdcall;
begin
  sampleRate := 0;
  try
    if FMaster = nil then
      Exit(ASE_NotPresent);
    sampleRate := FMaster.CurrentSampleRate;
    Result := ASE_OK;
  except
    Result := ASE_HWMalfunction;
  end;
end;

function TS2400AggDriver.setSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;
begin
  try
    Result := DoSetSampleRate(sampleRate);
  except
    on E: Exception do
    begin
      LogException('setSampleRate', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AggDriver.getClockSources(clocks: PASIOClockSource; var numSources: LongInt): TASIOError; stdcall;
begin
  if (clocks = nil) or (numSources < 1) then
  begin
    numSources := 0;
    Exit(ASE_OK);
  end;
  // einzige Taktquelle: das Master-Geraet
  FillChar(clocks^, SizeOf(TASIOClockSource), 0);
  clocks^.index := 0;
  clocks^.associatedChannel := -1;
  clocks^.associatedGroup := -1;
  clocks^.isCurrentSource := ASIOTrue;
  CopyToAnsiBuffer('Master', @clocks^.name[0], 32);
  numSources := 1;
  Result := ASE_OK;
end;

function TS2400AggDriver.setClockSource(reference: LongInt): TASIOError; stdcall;
begin
  if reference = 0 then
    Result := ASE_OK
  else
    Result := ASE_InvalidParameter;
end;

function TS2400AggDriver.getSamplePosition(out sPos: TASIOSamples; out tStamp: TASIOTimeStamp): TASIOError; stdcall;
begin
  try
    if FMaster = nil then
    begin
      FillChar(sPos, SizeOf(sPos), 0);
      FillChar(tStamp, SizeOf(tStamp), 0);
      Exit(ASE_NotPresent);
    end;
    Result := FMaster.GetSamplePosition(sPos, tStamp);
  except
    Result := ASE_HWMalfunction;
  end;
end;

function TS2400AggDriver.getChannelInfo(var info: TASIOChannelInfo): TASIOError; stdcall;
begin
  try
    Result := DoGetChannelInfo(info);
  except
    on E: Exception do
    begin
      LogException('getChannelInfo', E);
      Result := ASE_HWMalfunction;
    end;
  end;
end;

function TS2400AggDriver.createBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
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

function TS2400AggDriver.disposeBuffers: TASIOError; stdcall;
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

function TS2400AggDriver.controlPanel: TASIOError; stdcall;
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

function TS2400AggDriver.future(selector: LongInt; opt: Pointer): TASIOError; stdcall;
begin
  if selector = kAsioCanTimeInfo then
    Result := ASE_SUCCESS
  else if selector = C_S2400_FUTURE_OPEN_MIXER then
  begin
    // eigener Wahlschalter: S2400 Monitor oeffnet damit den Isla-Mixer
    try
      OpenMixer(HWND(FSysHandle));
      Result := ASE_SUCCESS;
    except
      on E: Exception do
      begin
        LogException('future(OpenMixer)', E);
        Result := ASE_HWMalfunction;
      end;
    end;
  end
  else
    Result := ASE_NotPresent;
end;

function TS2400AggDriver.outputReady: TASIOError; stdcall;
begin
  // nicht noetig: der Verbund ruft outputReady des Masters selbst auf,
  // sobald der Host-Rueckruf zurueck ist
  Result := ASE_NotPresent;
end;

// -----------------------------------------------------------------------
// TS2400AggClassFactory und COM-Exporte
// -----------------------------------------------------------------------

function TS2400AggClassFactory.CreateInstance(const unkOuter: IUnknown; const iid: TGUID; out obj): HResult; stdcall;
var
  Driver: TS2400AggDriver;
  Unk: IUnknown;
  RequestedIID: TGUID;
begin
  Pointer(obj) := nil;
  if unkOuter <> nil then
    Exit(CLASS_E_NOAGGREGATION);
  try
    Driver := TS2400AggDriver.Create;
    Unk := Driver;
    if IsEqualGUID(iid, CLSID_S2400Aggregate) then
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

function TS2400AggClassFactory.LockServer(fLock: BOOL): HResult; stdcall;
begin
  if fLock then
    InterlockedIncrement(GLockCount)
  else
    InterlockedDecrement(GLockCount);
  Result := S_OK;
end;

function DllGetClassObject(const CLSID, IID: TGUID; out Obj): HResult; stdcall;
var
  Factory: TS2400AggClassFactory;
  Unk: IUnknown;
begin
  Pointer(Obj) := nil;
  if not IsEqualGUID(CLSID, CLSID_S2400Aggregate) then
    Exit(CLASS_E_CLASSNOTAVAILABLE);
  try
    Factory := TS2400AggClassFactory.Create;
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
  ClsidStr := GUIDToString(CLSID_S2400Aggregate);

  Ok := WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr, '', S2400_AGG_DRIVER_NAME);
  Ok := Ok and WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr + '\InprocServer32', '', ModulePath);
  Ok := Ok and WriteRegStringValue(HKEY_CLASSES_ROOT, 'CLSID\' + ClsidStr + '\InprocServer32', 'ThreadingModel', 'Both');
  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_AGG_DRIVER_NAME, '', S2400_AGG_DRIVER_NAME);
  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_AGG_DRIVER_NAME, 'CLSID', ClsidStr);
  Ok := Ok and WriteRegStringValue(HKEY_LOCAL_MACHINE, 'SOFTWARE\ASIO\' + S2400_AGG_DRIVER_NAME, 'Description', S2400_AGG_DRIVER_NAME);

  if Ok then
    Result := S_OK
  else
    Result := SELFREG_E_CLASS;
end;

function DllUnregisterServer: HResult; stdcall;
var
  ClsidStr: string;
begin
  ClsidStr := GUIDToString(CLSID_S2400Aggregate);
  RegDeleteTreeW(HKEY_CLASSES_ROOT, PWideChar('CLSID\' + ClsidStr));
  RegDeleteTreeW(HKEY_LOCAL_MACHINE, PWideChar('SOFTWARE\ASIO\' + S2400_AGG_DRIVER_NAME));
  Result := S_OK;
end;

initialization
  // eigenes Log, damit es sich nicht mit dem des Isla-Treibers mischt
  S2400LogFileName := 'S2400Aggregate.log';
  S2400Log('S2400Aggregate.dll geladen von: ' + ParamStr(0));
end.
