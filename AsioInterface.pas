unit AsioInterface;

// =============================================================================
// AsioInterface.pas
//
// Delphi-�bersetzung der Steinberg ASIO 2.3 Interface-Definition
// (asio.h / iasiodrv.h aus dem Steinberg ASIO SDK 2.3).
//
// Enth�lt:
//   - alle grundlegenden ASIO-Typen (ASIOBool, ASIOSampleRate, ASIOError, ...)
//   - ASIOSampleType-Konstanten
//   - TASIOClockSource, TASIOChannelInfo, TASIOBufferInfo
//   - TASIOTimeStamp, TASIOSamples, TASIOTimeInfo, TASIOTimeCode, TASIOTime
//   - TASIOCallbacks (bufferSwitch, sampleRateDidChange, asioMessage,
//     bufferSwitchTimeInfo)
//   - asioMessage()- und future()-Selektoren
//   - erweiterte future()-Parameterstrukturen (Input-Monitor, Transport,
//     Channel-Controls, IoFormat/DSD)
//   - das COM-Interface IASIO selbst
//
// WICHTIG zur 64-Bit-Ausrichtung:
//   - "long"/"unsigned long" aus dem C++-Header ist auf Windows (LLP64) immer
//     32 Bit breit - unabh�ngig von 32/64-Bit-Build. Deshalb werden diese
//     Felder konsequent auf LongInt/LongWord (=> immer 4 Byte in Delphi)
//     abgebildet, NICHT auf NativeInt/Integer-Aliase.
//   - "void*"-Felder (z.B. Buffers[2]) werden auf Pointer abgebildet, der auf
//     Win64 automatisch 8 Byte breit ist - genau wie beim C++-Pendant.
//   - ASIOSampleType wird bewusst NICHT als Pascal-Enum, sondern als
//     LongInt-Typ mit Konstanten definiert, damit die Gr��e unabh�ngig von
//     MINENUMSIZE-Einstellungen garantiert 4 Byte betr�gt.
//   - Die ALIGN-8-Direktive weiter unten erzwingt explizit die gleiche
//     natural-alignment-Regel wie der MSVC-x64-Compiler (gr��tes Feld = 8
//     Byte -> 8-Byte-Ausrichtung), unabh�ngig von projektweiten
//     Alignment-Einstellungen.
//   - Alle COM-Methoden von IASIO sind "stdcall" deklariert; auf Win64 bildet
//     der Delphi-Compiler das korrekt auf die x64-Calling-Convention ab.
//   - Die Callback-Funktionszeiger in TASIOCallbacks sind "cdecl" (Standard-
//     Aufrufkonvention des Steinberg-Referenzcodes f�r freie Funktionen ohne
//     explizite Konvention).
//
// Hinweis: Die GUID von IASIO (siehe IID_ASIO weiter unten) ist in ALLEN
// ASIO-Treibern identisch (Steinberg verwendet hier historisch die IID von
// IMarshal wieder) - sie ist Teil der ASIO-Spezifikation und darf nicht
// ge�ndert werden. Die CLSID des eigentlichen Treiber-COM-Objekts
// (S2400AsioDriver) ist NICHT Teil dieser Unit - sie muss vom Projekt selbst
// eindeutig neu generiert werden (z.B. �ber "GUID erzeugen" in der IDE) und
// geh�rt in die Implementierungs-Unit des Treiberobjekts sowie in die
// Registry-Registrierung.
// =============================================================================

interface

uses
  Windows;

{$MINENUMSIZE 4}
{$ALIGN 8}

// -----------------------------------------------------------------------
// Grundlegende ASIO-Typen
// -----------------------------------------------------------------------
type
  TASIOBool       = LongInt;   // C: typedef long ASIOBool;
  TASIOSampleRate = Double;    // C: typedef double ASIOSampleRate;
  TASIOError      = LongInt;   // C: typedef long ASIOError;
  TASIOSampleType = LongInt;   // C: enum ASIOSampleType (siehe unten)

const
  ASIOFalse: TASIOBool = 0;
  ASIOTrue:  TASIOBool = 1;

// -----------------------------------------------------------------------
// ASIOError - R�ckgabewerte
// -----------------------------------------------------------------------
const
  ASE_OK               = 0;                  // Erfolg
  ASE_SUCCESS          = LongInt($3F4847A0); // eindeutiger Erfolgswert f�r ASIOFuture()
  ASE_NotPresent       = -1000;              // Hardware nicht vorhanden/verf�gbar
  ASE_HWMalfunction    = -999;               // Hardware-Fehlfunktion
  ASE_InvalidParameter = -998;               // ung�ltiger Eingabeparameter
  ASE_InvalidMode      = -997;               // Hardware in ung�ltigem Modus
  ASE_SPNotAdvancing   = -996;               // Sample-Position bewegt sich nicht
  ASE_NoClock          = -995;               // kein Sample-Clock ermittelbar
  ASE_NoMemory         = -994;               // nicht genug Speicher

// -----------------------------------------------------------------------
// ASIOSampleType - Abtastformate der Puffer
// -----------------------------------------------------------------------
const
  ASIOSTInt16MSB    : TASIOSampleType = 0;
  ASIOSTInt24MSB    : TASIOSampleType = 1;   // auch f�r 20 Bit verwendet
  ASIOSTInt32MSB    : TASIOSampleType = 2;
  ASIOSTFloat32MSB  : TASIOSampleType = 3;   // IEEE 754, 32 Bit
  ASIOSTFloat64MSB  : TASIOSampleType = 4;   // IEEE 754, 64 Bit

  ASIOSTInt32MSB16  : TASIOSampleType = 8;   // 32 Bit Container, 16 Bit Daten
  ASIOSTInt32MSB18  : TASIOSampleType = 9;   // 32 Bit Container, 18 Bit Daten
  ASIOSTInt32MSB20  : TASIOSampleType = 10;  // 32 Bit Container, 20 Bit Daten
  ASIOSTInt32MSB24  : TASIOSampleType = 11;  // 32 Bit Container, 24 Bit Daten

  ASIOSTInt16LSB    : TASIOSampleType = 16;
  ASIOSTInt24LSB    : TASIOSampleType = 17;  // auch f�r 20 Bit verwendet
  ASIOSTInt32LSB    : TASIOSampleType = 18;
  ASIOSTFloat32LSB  : TASIOSampleType = 19;  // IEEE 754, 32 Bit (x86-Standard)
  ASIOSTFloat64LSB  : TASIOSampleType = 20;  // IEEE 754, 64 Bit (x86-Standard)

  ASIOSTInt32LSB16  : TASIOSampleType = 24;  // 32 Bit Container, 16 Bit Daten
  ASIOSTInt32LSB18  : TASIOSampleType = 25;  // 32 Bit Container, 18 Bit Daten
  ASIOSTInt32LSB20  : TASIOSampleType = 26;  // 32 Bit Container, 20 Bit Daten
  ASIOSTInt32LSB24  : TASIOSampleType = 27;  // 32 Bit Container, 24 Bit Daten

  // DSD-Formate
  ASIOSTDSDInt8LSB1 : TASIOSampleType = 32;  // 1 Bit, 8 Samples/Byte, LSB zuerst
  ASIOSTDSDInt8MSB1 : TASIOSampleType = 33;  // 1 Bit, 8 Samples/Byte, MSB zuerst
  ASIOSTDSDInt8NER8 : TASIOSampleType = 40;  // 8 Bit, 1 Sample/Byte

  ASIOSTLastEntry   : TASIOSampleType = 41;

// -----------------------------------------------------------------------
// 64-Bit-Hilfstypen (ASIOTimeStamp / ASIOSamples)
// In der ASIO-SDK bewusst als High/Low-DWORD-Paar definiert (nicht als
// nativer Int64), um mit �lteren Compilern kompatibel zu bleiben. Die
// Speicherlayout-Reihenfolge (hi zuerst, dann lo) muss exakt erhalten
// bleiben, da der Host-Treiber genau dieses Layout erwartet.
// -----------------------------------------------------------------------
type
  PASIOTimeStamp = ^TASIOTimeStamp;
  TASIOTimeStamp = record
    hi: LongWord;
    lo: LongWord;
  end;

  PASIOSamples = ^TASIOSamples;
  TASIOSamples = record
    hi: LongWord;
    lo: LongWord;
  end;

  // Komfort-Konvertierung hi/lo <-> Int64 (kein Bestandteil der ASIO-SDK,
  // aber n�tzlich f�r die Treiberimplementierung)
  function ASIOSamplesToInt64(const s: TASIOSamples): Int64; inline;
  procedure Int64ToASIOSamples(const value: Int64; out s: TASIOSamples); inline;
  function ASIOTimeStampToInt64(const t: TASIOTimeStamp): Int64; inline;
  procedure Int64ToASIOTimeStamp(const value: Int64; out t: TASIOTimeStamp); inline;

// -----------------------------------------------------------------------
// TASIOClockSource
// -----------------------------------------------------------------------
type
  PASIOClockSource = ^TASIOClockSource;
  TASIOClockSource = record
    index: LongInt;                 // Index in den vom Treiber gelieferten Clock-Quellen
    associatedChannel: LongInt;     // welcher Kanal geh�rt dazu (-1 falls keiner)
    associatedGroup: LongInt;       // welche Kanalgruppe geh�rt dazu
    isCurrentSource: TASIOBool;     // ASIOTrue, falls aktuell aktiv
    name: array[0..31] of AnsiChar; // z.B. "Internal", "Word Clock", "S/PDIF"
  end;

// -----------------------------------------------------------------------
// TASIOChannelInfo
// -----------------------------------------------------------------------
type
  PASIOChannelInfo = ^TASIOChannelInfo;
  TASIOChannelInfo = record
    channel: LongInt;               // Kanalindex, 0..numInputs-1 bzw. 0..numOutputs-1
    isInput: TASIOBool;             // ASIOTrue = Eingangskanal
    isActive: TASIOBool;            // ASIOTrue, falls in createBuffers() aktiviert
    channelGroup: LongInt;          // Kanalgruppe (Samplerate/Buffergr��e gruppenweise gleich)
    sampleType: TASIOSampleType;    // entspricht C-Feld "type"
    name: array[0..31] of AnsiChar; // Kanalname
  end;

// -----------------------------------------------------------------------
// TASIOBufferInfo
// -----------------------------------------------------------------------
type
  PASIOBufferInfo = ^TASIOBufferInfo;
  TASIOBufferInfo = record
    isInput: TASIOBool;       // vom Aufrufer gesetzt: ASIOTrue = Eingangskanal
    channelNum: LongInt;      // vom Aufrufer gesetzt: Kanalindex
    buffers: array[0..1] of Pointer; // vom Treiber gef�llt: Doppelpuffer [0]/[1]
  end;

// -----------------------------------------------------------------------
// AsioTimeInfo - Flags
// -----------------------------------------------------------------------
const
  kSystemTimeValid     = LongWord(1);
  kSamplePositionValid = LongWord(1 shl 1);
  kSampleRateValid     = LongWord(1 shl 2);
  kSpeedValid          = LongWord(1 shl 3);
  kSampleRateChanged   = LongWord(1 shl 4);
  kClockSourceChanged  = LongWord(1 shl 5);

type
  PASIOTimeInfo = ^TASIOTimeInfo;
  TASIOTimeInfo = record
    speed: Double;                    // absolute Geschwindigkeit (1.0 = nominal)
    systemTime: TASIOTimeStamp;       // Systemzeit zu samplePosition, in Nanosekunden
    samplePosition: TASIOSamples;
    sampleRate: TASIOSampleRate;      // aktuelle Samplerate
    flags: LongWord;                  // kSystemTimeValid, kSamplePositionValid, ...
    reserved: array[0..11] of AnsiChar;
  end;

// -----------------------------------------------------------------------
// ASIOTimeCode - Flags
// -----------------------------------------------------------------------
const
  kTcValid      = LongWord(1);
  kTcRunning    = LongWord(1 shl 1);
  kTcReverse    = LongWord(1 shl 2);
  kTcOnspeed    = LongWord(1 shl 3);
  kTcStill      = LongWord(1 shl 4);
  kTcSpeedValid = LongWord(1 shl 8);

type
  PASIOTimeCode = ^TASIOTimeCode;
  TASIOTimeCode = record
    speed: Double;                    // Geschwindigkeitsverh�ltnis zur Nominalgeschwindigkeit
    timeCodeSamples: TASIOSamples;    // Zeit in Samples
    flags: LongWord;                  // kTcValid, kTcRunning, ...
    future: array[0..63] of AnsiChar;
  end;

// -----------------------------------------------------------------------
// TASIOTime (Ein-/Ausgabeparameter von bufferSwitchTimeInfo)
// -----------------------------------------------------------------------
type
  PASIOTime = ^TASIOTime;
  TASIOTime = record
    reserved: array[0..3] of LongInt; // muss 0 sein
    timeInfo: TASIOTimeInfo;          // erforderlich
    timeCode: TASIOTimeCode;          // optional, g�ltig wenn timeCode.flags and kTcValid <> 0
  end;

// -----------------------------------------------------------------------
// ASIOCallbacks - vom Host beim createBuffers() �bergebene Callback-Tabelle
// Aufrufkonvention: cdecl (Standardkonvention des Steinberg-Referenzcodes
// f�r freie C-Funktionszeiger ohne explizite Konvention).
// -----------------------------------------------------------------------
type
  TASIOBufferSwitchProc = procedure(doubleBufferIndex: LongInt;
    directProcess: TASIOBool); cdecl;

  TASIOSampleRateDidChangeProc = procedure(sRate: TASIOSampleRate); cdecl;

  TASIOMessageProc = function(selector: LongInt; value: LongInt;
    message: Pointer; opt: PDouble): LongInt; cdecl;

  TASIOBufferSwitchTimeInfoProc = function(params: PASIOTime;
    doubleBufferIndex: LongInt; directProcess: TASIOBool): PASIOTime; cdecl;

  PASIOCallbacks = ^TASIOCallbacks;
  TASIOCallbacks = record
    bufferSwitch: TASIOBufferSwitchProc;
    sampleRateDidChange: TASIOSampleRateDidChangeProc;
    asioMessage: TASIOMessageProc;
    bufferSwitchTimeInfo: TASIOBufferSwitchTimeInfoProc;
  end;

// -----------------------------------------------------------------------
// asioMessage() - Selektoren (2. Parameter von TASIOMessageProc)
// -----------------------------------------------------------------------
const
  kAsioSelectorSupported   = 1;  // R�ckfrage: wird <value> unterst�tzt? 1/0
  kAsioEngineVersion       = 2;  // liefert Host-ASIO-Version (>= 2)
  kAsioResetRequest        = 3;  // Treiber fordert Reset an
  kAsioBufferSizeChange    = 4;  // (aktuell nicht unterst�tzt, immer 0)
  kAsioResyncRequest       = 5;  // Treiber au�er Sync, Neustart n�tig
  kAsioLatenciesChanged    = 6;  // Latenzen haben sich ge�ndert
  kAsioSupportsTimeInfo    = 7;  // Host unterst�tzt bufferSwitchTimeInfo()
  kAsioSupportsTimeCode    = 8;
  kAsioMMCCommand          = 9;  // unbenutzt
  kAsioSupportsInputMonitor  = 10;
  kAsioSupportsInputGain     = 11; // unbenutzt/undefiniert
  kAsioSupportsInputMeter    = 12; // unbenutzt/undefiniert
  kAsioSupportsOutputGain    = 13; // unbenutzt/undefiniert
  kAsioSupportsOutputMeter   = 14; // unbenutzt/undefiniert
  kAsioOverload              = 15; // Treiber hat Overload erkannt

// -----------------------------------------------------------------------
// future() - Selektoren (1. Parameter von IASIO.future)
// -----------------------------------------------------------------------
const
  kAsioEnableTimeCodeRead  = 1;   // keine Argumente
  kAsioDisableTimeCodeRead = 2;   // keine Argumente
  kAsioSetInputMonitor     = 3;   // PASIOInputMonitor in opt
  kAsioTransport           = 4;   // PASIOTransportParameters in opt
  kAsioSetInputGain        = 5;   // PASIOChannelControls in opt
  kAsioGetInputMeter       = 6;   // PASIOChannelControls in opt
  kAsioSetOutputGain       = 7;   // PASIOChannelControls in opt
  kAsioGetOutputMeter      = 8;   // PASIOChannelControls in opt
  kAsioCanInputMonitor     = 9;   // keine Argumente
  kAsioCanTimeInfo         = 10;
  kAsioCanTimeCode         = 11;
  kAsioCanTransport        = 12;
  kAsioCanInputGain        = 13;
  kAsioCanInputMeter       = 14;
  kAsioCanOutputGain       = 15;
  kAsioCanOutputMeter      = 16;
  kAsioOptionalOne         = 17;

  // DSD-Unterst�tzung
  kAsioSetIoFormat         = LongInt($23111961); // PASIOIoFormat in opt
  kAsioGetIoFormat         = LongInt($23111983); // PASIOIoFormat in opt
  kAsioCanDoIoFormat       = LongInt($23112004); // PASIOIoFormat in opt

  // Erweiterung: Dropout-Erkennung
  kAsioCanReportOverload   = LongInt($24042012); // ASE_SUCCESS falls unterst�tzt

  kAsioGetInternalBufferSamples = LongInt($25042012); // ASE_SUCCESS falls unterst�tzt

// -----------------------------------------------------------------------
// Erweiterte future()-Parameterstrukturen
// -----------------------------------------------------------------------
type
  PASIOInputMonitor = ^TASIOInputMonitor;
  TASIOInputMonitor = record
    input: LongInt;      // zu �berwachender Eingang (-1: alle)
    output: LongInt;     // vorgeschlagener Ausgang f�r das Monitoring
    gain: LongInt;        // vorgeschlagener Gain, 0..$7FFFFFFF (-unendlich .. +12 dB)
    state: TASIOBool;     // Ein/Aus
    pan: LongInt;          // vorgeschlagenes Panorama, 0 = ganz links, $7FFFFFFF = ganz rechts
  end;

  PASIOChannelControls = ^TASIOChannelControls;
  TASIOChannelControls = record
    channel: LongInt;      // Eingabe: Kanalindex
    isInput: TASIOBool;    // Eingabe
    gain: LongInt;          // Eingabe: anzuwendender Gain
    meter: LongInt;         // Ausgabe: gemessener Pegel
    future: array[0..31] of AnsiChar;
  end;

  PASIOTransportParameters = ^TASIOTransportParameters;
  TASIOTransportParameters = record
    command: LongInt;                       // siehe kTrans*-Konstanten
    samplePosition: TASIOSamples;
    track: LongInt;
    trackSwitches: array[0..15] of LongInt; // 512 Spuren Ein/Aus (Bitfeld)
    future: array[0..63] of AnsiChar;
  end;

const
  kTransStart       = 1;
  kTransStop        = 2;
  kTransLocate      = 3;  // zu samplePosition
  kTransPunchIn     = 4;
  kTransPunchOut    = 5;
  kTransArmOn       = 6;  // track
  kTransArmOff      = 7;  // track
  kTransMonitorOn   = 8;  // track
  kTransMonitorOff  = 9;  // track
  kTransArm         = 10; // trackSwitches
  kTransMonitor     = 11; // trackSwitches

type
  TASIOIoFormatType = LongInt;

const
  kASIOFormatInvalid: TASIOIoFormatType = -1;
  kASIOPCMFormat:     TASIOIoFormatType = 0;
  kASIODSDFormat:     TASIOIoFormatType = 1;

type
  PASIOIoFormat = ^TASIOIoFormat;
  TASIOIoFormat = record
    FormatType: TASIOIoFormatType;
    future: array[0..511] of AnsiChar;
  end;

// -----------------------------------------------------------------------
// IASIO - das eigentliche ASIO-COM-Interface
//
// GUID gem�� iasiodrv.h aus dem Steinberg ASIO SDK - identisch f�r ALLE
// ASIO-Treiber, nicht �ndern und nicht mit der treiberspezifischen CLSID
// verwechseln!
// -----------------------------------------------------------------------
const
  IID_ASIO: TGUID = '{00000003-0000-0000-C000-000000000046}';

type
  IASIO = interface(IUnknown)
    ['{00000003-0000-0000-C000-000000000046}']

    // Treiber initialisieren. sysHandle: unter Windows das Anwendungs-
    // Hauptfenster-Handle (HWND), vom Host �bergeben.
    function init(sysHandle: Pointer): TASIOBool; stdcall;

    // Treibername liefern; name muss auf einen Puffer von mind. 32 Byte zeigen.
    procedure getDriverName(name: PAnsiChar); stdcall;

    // Treiberversion liefern.
    function getDriverVersion: LongInt; stdcall;

    // letzte Fehlermeldung liefern; errorMessage muss auf einen Puffer von
    // mind. 124 Byte zeigen.
    procedure getErrorMessage(errorMessage: PAnsiChar); stdcall;

    // Verarbeitung starten/stoppen.
    function start: TASIOError; stdcall;
    function stop: TASIOError; stdcall;

    // Anzahl Ein-/Ausgangskan�le ermitteln.
    function getChannels(out numInputChannels, numOutputChannels: LongInt): TASIOError; stdcall;

    // aktuelle Latenzen (in Samples) ermitteln.
    function getLatencies(out inputLatency, outputLatency: LongInt): TASIOError; stdcall;

    // unterst�tzte Puffergr��en ermitteln.
    function getBufferSize(out minSize, maxSize, preferredSize, granularity: LongInt): TASIOError; stdcall;

    // pr�fen, ob eine Samplerate unterst�tzt wird.
    function canSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;

    // aktuelle Samplerate abfragen/setzen.
    function getSampleRate(out sampleRate: TASIOSampleRate): TASIOError; stdcall;
    function setSampleRate(sampleRate: TASIOSampleRate): TASIOError; stdcall;

    // verf�gbare Clock-Quellen ermitteln. clocks zeigt auf ein vom Aufrufer
    // bereitgestelltes Array; numSources gibt dessen Gr��e vor und liefert
    // die tats�chliche Anzahl zur�ck.
    function getClockSources(clocks: PASIOClockSource; var numSources: LongInt): TASIOError; stdcall;
    function setClockSource(reference: LongInt): TASIOError; stdcall;

    // aktuelle Sample-Position und zugeh�rige Systemzeit ermitteln.
    function getSamplePosition(out sPos: TASIOSamples; out tStamp: TASIOTimeStamp): TASIOError; stdcall;

    // Kanalinformationen ermitteln; info.channel und info.isInput m�ssen
    // vom Aufrufer vorbelegt werden.
    function getChannelInfo(var info: TASIOChannelInfo): TASIOError; stdcall;

    // Puffer f�r die �bergebenen Kan�le anlegen und Callback-Tabelle registrieren.
    function createBuffers(bufferInfos: PASIOBufferInfo; numChannels: LongInt;
      bufferSize: LongInt; const callbacks: TASIOCallbacks): TASIOError; stdcall;

    // zuvor angelegte Puffer wieder freigeben.
    function disposeBuffers: TASIOError; stdcall;

    // treibereigenes Konfigurationsfenster �ffnen.
    function controlPanel: TASIOError; stdcall;

    // Erweiterungsschnittstelle f�r Funktionen, die nicht Teil des
    // Kern-Interfaces sind (siehe future()-Selektoren oben).
    function future(selector: LongInt; opt: Pointer): TASIOError; stdcall;

    // im Output-Only-Timing-Modus: Treiber signalisieren, dass neue
    // Ausgabedaten bereitstehen.
    function outputReady: TASIOError; stdcall;
  end;

implementation

function ASIOSamplesToInt64(const s: TASIOSamples): Int64;
begin
  Result := (Int64(s.hi) shl 32) or Int64(s.lo);
end;

procedure Int64ToASIOSamples(const value: Int64; out s: TASIOSamples);
begin
  s.hi := LongWord(value shr 32);
  s.lo := LongWord(value and $FFFFFFFF);
end;

function ASIOTimeStampToInt64(const t: TASIOTimeStamp): Int64;
begin
  Result := (Int64(t.hi) shl 32) or Int64(t.lo);
end;

procedure Int64ToASIOTimeStamp(const value: Int64; out t: TASIOTimeStamp);
begin
  t.hi := LongWord(value shr 32);
  t.lo := LongWord(value and $FFFFFFFF);
end;

end.
