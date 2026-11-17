unit S2400KsInterop;

// =============================================================================
// S2400KsInterop.pas
//
// Rohe Windows-Kernel-Streaming-(KS)-API, von Hand nach ks.h/ksmedia.h/
// ksproxy.h übersetzt (in der Delphi-RTL nicht enthalten). Grundlage für den
// Umstieg von WASAPI auf Kernel Streaming (siehe PROJEKT_STAND.md, Abschnitt
// "WASAPI Exclusive Mode" vom 07.09.2026): WASAPI-Capture blockiert bei der
// ISLA S2400 auf jedem versuchten Format vollständig (14 Kandidaten
// getestet), während Kernel Streaming direkt mit dem Filter-Treiber spricht
// und über KSPROPERTY_PIN_DATARANGES die TATSÄCHLICH unterstützten Formate
// abfragen kann - statt sie wie bei WASAPI blind zu erraten.
//
// Diese Unit enthält bewusst nur den Ausschnitt der KS-API, der für
// Geräte-/Pin-Enumeration und Property-Abfragen (Diagnose, Formatermittlung)
// nötig ist. Die eigentliche Stream-Instanziierung (KsCreatePin) und das
// Streaming selbst (IOCTL_KS_READ_STREAM/WRITE_STREAM) folgen erst, sobald
// die Diagnose (S2400KsDiag.dpr) die tatsächlichen Datenbereiche der ISLA
// S2400 auf echter Hardware bestätigt hat - siehe PROJEKT_STAND.md.
// =============================================================================

interface

uses
  Winapi.Windows,
  Winapi.ActiveX,
  Winapi.MMSystem,  // TWaveFormatEx (WAVEFORMATEX) - Standardformat fuer die
                     // "msft_wave"-Pins, siehe BuildWaveConnectBuffer
  System.SysUtils,
  System.Classes;

{$MINENUMSIZE 4}
{$ALIGN 8}

// -----------------------------------------------------------------------
// Geräte-spezifisch (gleiche Werte wie WinUsbEngine.pas/S2400WasapiEngine.pas)
// -----------------------------------------------------------------------
const
  VID_ISLA_S2400: Word = $0483;
  PID_ISLA_S2400: Word = $A21D;

// -----------------------------------------------------------------------
// KS-Kategorien (ksmedia.h) - jeder Audio-Endpunkt registriert sich unter
// einer oder mehreren dieser Geräteschnittstellen-GUIDs.
// -----------------------------------------------------------------------
const
  KSCATEGORY_AUDIO:   TGUID = '{6994AD04-93EF-11D0-A3CC-00A0C9223196}';
  KSCATEGORY_RENDER:  TGUID = '{65E8773E-8F56-11D0-A3B9-00A0C9223196}';
  KSCATEGORY_CAPTURE: TGUID = '{65E8773D-8F56-11D0-A3B9-00A0C9223196}';

  KSPROPSETID_Pin: TGUID = '{8C134960-51AD-11CF-878A-94F801C10000}';

  // KSPROPSETID_RtAudio (ksmedia.h) - WaveRT/"Looped Streaming"-Properties.
  // Am 17.09.2026 gegen Microsoft Learn verifiziert, nachdem sich zeigte,
  // dass die ISLA S2400 ihre "msft_wave"-Pins mit
  // KSINTERFACE_STANDARD_LOOPED_STREAMING verbindet - dieser Modus nutzt
  // GAR KEINE IOCTL_KS_WRITE_STREAM/READ_STREAM-Paketuebertragung (die
  // schlug konsequent mit ERROR_INVALID_FUNCTION fehl), sondern einen
  // einmalig angeforderten, in den Prozess eingeblendeten Ringpuffer plus
  // ein Positions-Register.
  KSPROPSETID_RtAudio: TGUID = '{A855A48C-2F78-4729-9051-1968746B9EEF}';
  // enum KSPROPERTY_RTAUDIO (ksmedia.h) - vollstaendige, gegen Microsoft
  // Learn verifizierte Reihenfolge; nur die ersten paar Werte werden hier
  // gebraucht.
  KSPROPERTY_RTAUDIO_GETPOSITIONFUNCTION      = 0;
  KSPROPERTY_RTAUDIO_BUFFER                   = 1;
  KSPROPERTY_RTAUDIO_HWLATENCY                = 2;
  KSPROPERTY_RTAUDIO_POSITIONREGISTER         = 3;
  KSPROPERTY_RTAUDIO_CLOCKREGISTER            = 4;
  KSPROPERTY_RTAUDIO_BUFFER_WITH_NOTIFICATION = 5;
  // 6..8 und 11 am 12.10.2026 gegen Microsoft Learn (ne-ksmedia-
  // ksproperty_rtaudio) verifiziert - vollstaendige Enum-Reihenfolge.
  KSPROPERTY_RTAUDIO_REGISTER_NOTIFICATION_EVENT   = 6;
  KSPROPERTY_RTAUDIO_UNREGISTER_NOTIFICATION_EVENT = 7;
  KSPROPERTY_RTAUDIO_QUERY_NOTIFICATION_SUPPORT    = 8;
  KSPROPERTY_RTAUDIO_PACKETCOUNT              = 9;
  KSPROPERTY_RTAUDIO_PRESENTATION_POSITION    = 10;
  KSPROPERTY_RTAUDIO_GETREADPACKET            = 11;
  KSPROPERTY_RTAUDIO_SETWRITEPACKET           = 12;

  // KSPROPSETID_Audio / KSPROPERTY_AUDIO_POSITION (ksmedia.h) - Fallback
  // fuer den Fall, dass KSPROPERTY_RTAUDIO_POSITIONREGISTER nicht
  // unterstuetzt wird (bei der ISLA S2400 am 17.09.2026 bestaetigt: liefert
  // ERROR_NOT_SUPPORTED). Erfordert im Gegensatz zum Register einen echten
  // Kernel-Uebergang pro Abfrage, ist aber universell verfuegbar laut Doku.
  KSPROPSETID_Audio: TGUID = '{45FFAAA0-6E1B-11D0-BCF2-444553540000}';
  KSPROPERTY_AUDIO_POSITION = 4;

  KSDATAFORMAT_TYPE_AUDIO:             TGUID = '{73647561-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SUBTYPE_PCM_:           TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT_:    TGUID = '{00000003-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SPECIFIER_WAVEFORMATEX: TGUID = '{05589F81-C356-11CE-BF01-00AA0055595A}';

  // KSPROPERTY_PIN_* (ks.h, enum KSPROPERTY_PIN) - am 08.09.2026 gegen zwei
  // unabhaengige Quellen verifiziert (Windows-SDK-Header-Mirror UND
  // ReactOS-Quelltext, beide identisch). WICHTIG: KSPROPERTY_PIN_CINSTANCES
  // steht als ERSTES Enum-Mitglied (=0) VOR KSPROPERTY_PIN_CTYPES - die
  // urspruengliche Annahme (CTYPES=0) war um eins verschoben und die
  // Ursache des ersten fehlgeschlagenen Hardware-Tests.
  KSPROPERTY_PIN_CINSTANCES = 0;
  KSPROPERTY_PIN_CTYPES     = 1;
  KSPROPERTY_PIN_DATAFLOW   = 2;
  KSPROPERTY_PIN_DATARANGES = 3;
  KSPROPERTY_PIN_INTERFACES = 5;
  KSPROPERTY_PIN_MEDIUMS    = 6;

  KSPROPERTY_TYPE_GET = DWORD($00000001);
  KSPROPERTY_TYPE_SET = DWORD($00000002);

  // KSPIN_DATAFLOW (ks.h)
  KSPIN_DATAFLOW_IN  = 1; // Client schreibt in den Pin hinein  -> Render
  KSPIN_DATAFLOW_OUT = 2; // Pin liefert Daten an den Client    -> Capture

  // CTL_CODE-Bestandteile (devioctl.h) - FILE_DEVICE_KS am 08.09.2026 per
  // Web-Recherche gegen den echten Windows-SDK-Header verifiziert (Quelle:
  // devioctl.h, Windows SDK 10.0.16299.0): "#define FILE_DEVICE_KS
  // 0x0000002f". Vorheriger Wert ($23) war falsch geraten und f�hrte zu
  // ERROR_INVALID_FUNCTION bei jeder IOCTL_KS_PROPERTY-Abfrage.
  FILE_DEVICE_KS  = DWORD($0000002F);
  METHOD_NEITHER  = DWORD(3);
  FILE_ANY_ACCESS = DWORD(0);

// IOCTL_KS_PROPERTY = CTL_CODE(FILE_DEVICE_KS, 0, METHOD_NEITHER,
// FILE_ANY_ACCESS) = $00230003 - wird intern per CTL_CODE() berechnet
// (siehe IoctlKsProperty in der Implementation), nicht als Konstante
// exportiert, da er au�erhalb dieser Unit nicht gebraucht wird.
function CTL_CODE(ADeviceType, AFunction, AMethod, AAccess: DWORD): DWORD; inline;

type
  // KSIDENTIFIER/KSPROPERTY (ks.h) - "Set" ist in C der Feldname, in Delphi
  // wegen des reservierten Worts "set" (Property-Setter-Konvention) als
  // &Set escaped.
  TKSProperty = record
    &Set: TGUID;
    Id: ULONG;
    Flags: ULONG;
  end;
  PKSProperty = ^TKSProperty;

  // KSP_PIN (ks.h) - Eingabestruktur für pin-bezogene Property-Abfragen
  // (DATAFLOW, DATARANGES, ...). "Property" ist in Delphi ein reserviertes
  // Wort, daher hier als "Prop" benannt.
  TKSPPin = record
    Prop: TKSProperty; // entspricht C-Feld "Property"
    PinId: ULONG;
    Reserved: ULONG;
  end;
  PKSPPin = ^TKSPPin;

  // KSMULTIPLE_ITEM (ks.h) - Kopf einer variabel langen Liste (z.B. der von
  // KSPROPERTY_PIN_DATARANGES zurückgegebenen KSDATARANGE-Einträge).
  TKSMultipleItem = record
    Size: ULONG;  // Gesamtgröße inkl. dieses Headers
    Count: ULONG; // Anzahl der Einträge
  end;
  PKSMultipleItem = ^TKSMultipleItem;

  // KSDATARANGE (ks.h) - Basisstruktur, durch FormatSize variabel lang;
  // spezialisierte Formate (z.B. KSDATARANGE_AUDIO) hängen weitere Felder
  // dahinter an.
  TKSDataRange = record
    FormatSize: ULONG;
    Flags: ULONG;
    SampleSize: ULONG;
    Reserved: ULONG;
    MajorFormat: TGUID;
    SubFormat: TGUID;
    Specifier: TGUID;
  end;
  PKSDataRange = ^TKSDataRange;

  // KSDATARANGE_AUDIO (ksmedia.h) - die für uns entscheidende Struktur:
  // liefert direkt vom Treiber die TATSÄCHLICH unterstützten Kanal-/Bit-/
  // Sample-Rate-Bereiche eines Pins, statt sie wie bei WASAPI erraten zu
  // müssen.
  TKSDataRangeAudio = record
    DataRange: TKSDataRange;
    MaximumChannels: ULONG;
    MinimumBitsPerSample: ULONG;
    MaximumBitsPerSample: ULONG;
    MinimumSampleFrequency: ULONG;
    MaximumSampleFrequency: ULONG;
  end;
  PKSDataRangeAudio = ^TKSDataRangeAudio;

// -----------------------------------------------------------------------
// Pin-Instanziierung und Zustandssteuerung (KsCreatePin, KSPROPERTY_
// CONNECTION_STATE) - am 08.09.2026 gegen ZWEI unabhängige Quellen
// verifiziert: den öffentlichen ReactOS/mingw-w64-Header-Mirror (Struktur-
// Layouts) UND PortAudios WDM-KS-Backend (pa_win_wdmks.c, produktiv seit
// vielen Jahren im Einsatz) für den exakten DeviceIoControl-Aufrufstil bei
// KSPROPERTY_CONNECTION_STATE. Das eigentliche Datenstreaming (IOCTL_KS_
// WRITE_STREAM/READ_STREAM) folgt erst NACH Verifikation dieses Schritts
// auf echter Hardware - siehe PROJEKT_STAND.md.
// -----------------------------------------------------------------------
const
  KSPROPSETID_Connection: TGUID = '{1D58C920-AC9B-11CF-A5D6-28DB04C10000}';
  KSPROPERTY_CONNECTION_STATE = 0; // erstes Mitglied von enum KSPROPERTY_CONNECTION

  // KSSTATE (ks.h) - Zustandsübergänge MÜSSEN der Reihe nach durchlaufen
  // werden (STOP->ACQUIRE->PAUSE->RUN), ein Sprung direkt zu RUN wird vom
  // Treiber abgelehnt.
  KSSTATE_STOP    = 0;
  KSSTATE_ACQUIRE = 1;
  KSSTATE_PAUSE   = 2;
  KSSTATE_RUN     = 3;

  // KSINTERFACESETID_Standard / KSINTERFACE_STANDARD_* (ks.h)
  KSINTERFACESETID_Standard: TGUID = '{1A8766A0-62CE-11CF-A5D6-28DB04C10000}';
  KSINTERFACE_STANDARD_STREAMING        = 0;
  KSINTERFACE_STANDARD_LOOPED_STREAMING = 1;

  // KSMEDIUMSETID_Standard / KSMEDIUM_STANDARD_DEVIO (ks.h)
  KSMEDIUMSETID_Standard: TGUID = '{4747B320-62CE-11CF-A5D6-28DB04C10000}';
  KSMEDIUM_STANDARD_DEVIO = 0; // = KSMEDIUM_TYPE_ANYINSTANCE

  WAVE_FORMAT_PCM_ = Word(1);

type
  // KSPRIORITY (ks.h) - WICHTIG: KEIN KSIDENTIFIER-Layout (GUID+2xULONG),
  // sondern nur zwei ULONGs. Eine erste Fassung dieser Unit hatte das
  // fälschlich mit KSIDENTIFIER verwechselt (durch eine ungenaue
  // Zusammenfassung) - das wäre erst beim Testen als weiterer Offset-Fehler
  // aufgefallen, deshalb hier per Rohquelltext-Abruf gegengeprüft.
  TKSPriority = record
    PriorityClass: ULONG;
    PrioritySubClass: ULONG;
  end;

  // KSPIN_CONNECT (ks.h) - Interface/Medium haben beide dasselbe Layout wie
  // TKSProperty (GUID Set; ULONG Id; ULONG Flags - in ks.h "KSIDENTIFIER"
  // genannt), hier bewusst wiederverwendet statt dupliziert.
  TKSPinConnect = record
    Interface_: TKSProperty; // entspricht C-Feld "Interface" (reserviertes Wort in Delphi)
    Medium: TKSProperty;
    PinId: ULONG;
    PinToHandle: THandle;
    Priority: TKSPriority;
  end;
  PKSPinConnect = ^TKSPinConnect;

  TKSTime = record
    Time: Int64;
    Numerator: ULONG;
    Denominator: ULONG;
  end;

  // KSSTREAM_HEADER (ks.h) - "Reserved" existiert laut Header nur unter
  // _WIN64; da dieses Projekt ausschließlich Win64 baut, wird es hier immer
  // mitgeführt.
  TKSStreamHeader = record
    Size: ULONG;
    TypeSpecificFlags: ULONG;
    PresentationTime: TKSTime;
    Duration: Int64;
    FrameExtent: ULONG;
    DataUsed: ULONG;
    Data: Pointer;
    OptionsFlags: ULONG;
    Reserved: ULONG;
  end;
  PKSStreamHeader = ^TKSStreamHeader;

  // KSRTAUDIO_BUFFER_PROPERTY / KSRTAUDIO_BUFFER (ksmedia.h) - WaveRT-
  // Ringpuffer anfordern (KSPROPERTY_RTAUDIO_BUFFER). BaseAddress MUSS
  // laut Doku vom Client auf NULL gesetzt werden; der Treiber liefert die
  // tatsaechliche, in diesem Prozess direkt nutzbare virtuelle Adresse in
  // KSRTAUDIO_BUFFER.BufferAddress zurueck - kein weiteres Mapping noetig.
  TKSRtAudioBufferProperty = record
    Prop: TKSProperty; // entspricht C-Feld "Property"
    BaseAddress: Pointer;
    RequestedBufferSize: ULONG;
  end;

  TKSRtAudioBuffer = record
    BufferAddress: Pointer;
    ActualBufferSize: ULONG;
    CallMemoryBarrier: LongBool;
  end;

  // KSRTAUDIO_BUFFER_PROPERTY_WITH_NOTIFICATION (ksmedia.h, am 12.10.2026
  // gegen Microsoft Learn verifiziert). NotificationCount: 1 = Event am
  // Pufferende, 2 = Event in der Mitte UND am Ende des Ringpuffers.
  TKSRtAudioBufferPropertyWithNotification = record
    Prop: TKSProperty; // entspricht C-Feld "Property"
    BaseAddress: Pointer;
    RequestedBufferSize: ULONG;
    NotificationCount: ULONG;
  end;

  // KSRTAUDIO_NOTIFICATION_EVENT_PROPERTY (ksmedia.h, verifiziert) - fuer
  // KSPROPERTY_RTAUDIO_REGISTER/UNREGISTER_NOTIFICATION_EVENT. Kein
  // Property-Wert (Ausgabepuffer leer).
  TKSRtAudioNotificationEventProperty = record
    Prop: TKSProperty; // entspricht C-Feld "Property"
    NotificationEvent: THandle;
  end;

  // KSRTAUDIO_GETREADPACKET_INFO (ksmedia.h, verifiziert) - Antwort auf
  // KSPROPERTY_RTAUDIO_GETREADPACKET (paketbasierte Aufnahme).
  TKSRtAudioGetReadPacketInfo = record
    PacketNumber: ULONG;
    Flags: DWORD;
    PerformanceCounterValue: UInt64;
    MoreData: LongBool;
  end;

  // KSRTAUDIO_SETWRITEPACKET_INFO (ksmedia.h, am 12.10.2026 gegen Microsoft
  // Learn verifiziert) - Wert fuer KSPROPERTY_RTAUDIO_SETWRITEPACKET (SET).
  TKSRtAudioSetWritePacketInfo = record
    PacketNumber: ULONG;
    Flags: DWORD;
    EosPacketLength: ULONG;
  end;

  // KSRTAUDIO_HWLATENCY (ksmedia.h, verifiziert): FifoSize in Bytes,
  // ChipsetDelay/CodecDelay in 100-ns-Einheiten.
  TKSRtAudioHwLatency = record
    FifoSize: ULONG;
    ChipsetDelay: ULONG;
    CodecDelay: ULONG;
  end;

  // KSRTAUDIO_HWREGISTER_PROPERTY / KSRTAUDIO_HWREGISTER (ksmedia.h) -
  // Positions-/Takt-Register anfordern (KSPROPERTY_RTAUDIO_POSITIONREGISTER/
  // _CLOCKREGISTER). Register zeigt auf eine direkt lesbare Speicheradresse.
  TKSRtAudioHwRegisterProperty = record
    Prop: TKSProperty; // entspricht C-Feld "Property"
    BaseAddress: Pointer;
  end;

  TKSRtAudioHwRegister = record
    Register_: Pointer; // entspricht C-Feld "Register" (evtl. reserviertes Wort vermeiden)
    Width: ULONG;
    Numerator: UInt64;
    Denominator: UInt64;
    Accuracy: ULONG;
  end;

// fordert bei einem bereits auf mindestens KSSTATE_ACQUIRE geschalteten
// WaveRT-Pin den Ringpuffer an (KSPROPERTY_RTAUDIO_BUFFER, GET). Liefert
// bei Erfolg eine fuer DIESEN Prozess direkt gueltige Speicheradresse in
// ABuffer.BufferAddress - kein MapViewOfFile o.ae. noetig.
function GetRtAudioBuffer(APinHandle: THandle; ARequestedBufferSize: ULONG;
  out ABuffer: TKSRtAudioBuffer): Boolean;

// wie GetRtAudioBuffer, aber per KSPROPERTY_RTAUDIO_BUFFER_WITH_NOTIFICATION
// - Voraussetzung fuer RegisterNotificationEvent (Event-gesteuerter Betrieb,
// den auch PortAudio bevorzugt zuerst versucht). Muss wie GetRtAudioBuffer
// im Zustand KSSTATE_STOP angefordert werden.
function GetRtAudioBufferWithNotification(APinHandle: THandle;
  ARequestedBufferSize, ANotificationCount: ULONG;
  out ABuffer: TKSRtAudioBuffer): Boolean;

// fragt, ob der Treiber Event-Benachrichtigungen unterstuetzt
// (KSPROPERTY_RTAUDIO_QUERY_NOTIFICATION_SUPPORT, GET, Wert = BOOL).
function QueryNotificationSupport(APinHandle: THandle; out ASupported: LongBool): Boolean;

// registriert/deregistriert ein Win32-Event, das der Treiber im RUN-
// Zustand ein- bzw. zweimal pro Ringpuffer-Durchlauf signalisiert. Nur
// nach erfolgreichem GetRtAudioBufferWithNotification zulaessig.
function RegisterNotificationEvent(APinHandle: THandle; AEvent: THandle): Boolean;
function UnregisterNotificationEvent(APinHandle: THandle; AEvent: THandle): Boolean;

// paketbasierte Aufnahme (KSPROPERTY_RTAUDIO_GETREADPACKET): liefert, welches
// Paket im Ringpuffer zuletzt fertig befuellt wurde. GetLastError =
// ERROR_NOT_READY (21) bedeutet laut Doku "noch kein neues Paket".
function GetRtAudioReadPacket(APinHandle: THandle;
  out AInfo: TKSRtAudioGetReadPacketInfo): Boolean;

// KSPROPERTY_RTAUDIO_PACKETCOUNT (GET, Wert = ULONG): 1-basierte Anzahl
// vollstaendig an die Hardware uebertragener Pakete. Laut Doku: bei Zaehler N
// ist Paket N in Arbeit, der Client schreibt Paket N+1 (Lage im Puffer =
// (N+1) mod NotificationCount * Paketgroesse).
function GetRtAudioPacketCount(APinHandle: THandle; out ACount: ULONG): Boolean;

// KSPROPERTY_RTAUDIO_SETWRITEPACKET (SET): meldet dem Treiber, dass Paket
// APacketNumber fertig in den Ringpuffer geschrieben wurde. Laut Doku
// optional fuer den Treiber (er streamt auch ohne).
function SetRtAudioWritePacket(APinHandle: THandle; APacketNumber: ULONG): Boolean;

// KSPROPERTY_RTAUDIO_HWLATENCY (GET) - vom Treiber gemeldete Hardware-Latenz
function GetRtAudioHwLatency(APinHandle: THandle; out ALatency: TKSRtAudioHwLatency): Boolean;

// fordert das Positions-Register an (KSPROPERTY_RTAUDIO_POSITIONREGISTER,
// GET) - liefert eine direkt lesbare Speicheradresse, die den aktuellen
// Byte-Offset im Ringpuffer enthaelt. Laut Doku nur EINMAL pro Pin-
// Lebensdauer erfolgreich anforderbar.
function GetRtAudioPositionRegister(APinHandle: THandle;
  out AReg: TKSRtAudioHwRegister): Boolean;

// KSAUDIO_POSITION (ksmedia.h) - Fallback-Positionsabfrage, siehe
// KSPROPERTY_AUDIO_POSITION oben. Play-/WriteOffset sind bei
// KSINTERFACE_STANDARD_LOOPED_STREAMING Byte-Offsets INNERHALB des per
// GetRtAudioBuffer erhaltenen Ringpuffers (wrappen bei Erreichen des
// Puffer-Endes).
type
  TKSAudioPosition = record
    PlayOffset: UInt64;
    WriteOffset: UInt64;
  end;

// fragt die aktuelle Abspiel-/Schreibposition ab (KSPROPERTY_AUDIO_
// POSITION, GET) - braucht anders als das Positions-Register einen
// echten Kernel-Uebergang pro Aufruf, ist aber universell verfuegbar.
function GetAudioPosition(APinHandle: THandle; out APos: TKSAudioPosition): Boolean;

// KSAUDIO_PRESENTATION_POSITION (ksmedia.h) - zweiter Fallback, diesmal
// aus DEMSELBEN Property-Set wie GetRtAudioBuffer (KSPROPSETID_RtAudio),
// das bei dieser Hardware bereits nachweislich implementiert ist -
// anders als das komplett eigenstaendige KSPROPSETID_Audio (siehe
// GetAudioPosition), das mit ERROR_NOT_FOUND scheiterte.
type
  TKSAudioPresentationPosition = record
    PositionInBlocks: UInt64;
    QPCPosition: UInt64;
  end;

function GetRtAudioPresentationPosition(APinHandle: THandle;
  out APos: TKSAudioPresentationPosition): Boolean;

// KsCreatePin (ksuser.dll, siehe Microsoft Learn "KsCreatePin function") -
// sendet die Verbindungsanfrage (KSPIN_CONNECT + direkt dahinter im
// Speicher liegendes KSDATAFORMAT) an den Filter und liefert bei Erfolg
// (Rueckgabe 0 = STATUS_SUCCESS) ein Handle auf die neue Pin-Instanz.
function KsCreatePin(FilterHandle: THandle; Connect: PKSPinConnect;
  DesiredAccess: DWORD; out ConnectionHandle: THandle): LongInt; stdcall;
  external 'ksuser.dll' name 'KsCreatePin';

// Baut den zusammenhaengenden Speicherblock KSPIN_CONNECT + KSDATAFORMAT_
// WAVEFORMATEX (KSDATARANGE-Kopf + TWaveFormatEx), wie von KsCreatePin
// verlangt (siehe PortAudio pa_win_wdmks.c: "format data follows the
// connect structure in a single contiguous memory block").
function BuildWaveConnectBuffer(APinId: ULONG; AChannels: Word;
  ABitsPerSample: Word; ASampleRate: DWORD; const AInterfaceGuid: TGUID;
  AInterfaceId: ULONG; const AMediumGuid: TGUID; AMediumId: ULONG): TBytes;

// Oeffnet einen "Wave"-kompatiblen Pin (PCM/WAVEFORMATEX) am gegebenen
// Filter-Handle. Fragt VORHER selbst per KSPROPERTY_PIN_INTERFACES/_MEDIUMS
// ab, was der Pin tatsaechlich verlangt, statt "Standard/Streaming"
// anzunehmen (siehe Kommentar bei BuildWaveConnectBuffer). ADesiredAccess:
// GENERIC_WRITE fuer einen Render-Pin (Daten fliessen VOM Client IN den
// Pin), GENERIC_READ fuer einen Capture-Pin (Daten fliessen VOM Pin ZUM
// Client) - siehe KsCreatePin-Doku.
function OpenWavePin(AFilterHandle: THandle; APinId: ULONG; AChannels: Word;
  ABitsPerSample: Word; ASampleRate: DWORD; ADesiredAccess: DWORD;
  out APinHandle: THandle; out ARawStatus: LongInt): Boolean;

// setzt den KS-Zustand eines Pins EINZELN (keine Sequenzpruefung - siehe
// SetPinStateSequential fuer den vollstaendigen STOP->ACQUIRE->PAUSE->RUN-
// Ablauf, der laut KS-Spezifikation zwingend eingehalten werden muss).
// ALog (optional, nil erlaubt) erhaelt eine Zeile pro Einzelversuch
// (Pufferform + Ergebnis) - siehe Implementierung fuer den Hintergrund.
function SetPinState(APinHandle: THandle; AState: ULONG; ALog: TStrings): Boolean;

// liest den TATSAECHLICHEN Zustand des Pins vom Treiber zurueck
// (KSPROPERTY_CONNECTION_STATE, GET).
function GetPinState(APinHandle: THandle; out AState: ULONG): Boolean;

// durchlaeuft alle Zwischenzustaende zwischen dem aktuellen (als AFromState
// angenommenen) und dem gewuenschten Zielzustand der Reihe nach und liest
// nach JEDEM Schritt den echten Zustand per GetPinState zurueck - schlaegt
// fehl beim ersten nicht erfolgreichen oder nicht bestaetigten Uebergang.
function SetPinStateSequential(APinHandle: THandle; AFromState, AToState: ULONG;
  ALog: TStrings): Boolean;

// -----------------------------------------------------------------------
// Stream-Datenuebertragung (IOCTL_KS_WRITE_STREAM/IOCTL_KS_READ_STREAM) -
// gegen Microsoft Learn verifiziert (ni-ks-ioctl_ks_write_stream/
// ni-ks-ioctl_ks_read_stream, 17.09.2026): Eingabepuffer ist bei BEIDEN
// ein KSSTREAM_HEADER (Data-Feld zeigt auf den eigentlichen Audio-Byte-
// Puffer). Fuer WRITE ist laut Doku KEIN Ausgabepuffer noetig
// (BytesReturned traegt die geschriebene Byte-Anzahl). Fuer READ ist die
// Doku uneindeutig ("Output buffer length: OutLength gibt die Groesse
// des Ausgabepuffers an", obwohl die eigentlichen Daten laut Data-Zeiger
// im Header selbst ankommen) - nach der Erfahrung mit
// KSPROPERTY_CONNECTION_STATE (wo die Doku ebenfalls unvollstaendig war)
// probieren WriteStreamBuffer/ReadStreamBuffer daher automatisch je zwei
// Pufferformen durch und melden per ALog, welche funktioniert hat.
// -----------------------------------------------------------------------

// schreibt EINEN Puffer Rohdaten (PCM, wie mit BuildWaveConnectBuffer
// verbunden) an einen Render-Pin im Zustand KSSTATE_RUN.
function WriteStreamBuffer(APinHandle: THandle; AData: Pointer; ADataBytes: DWORD;
  out ABytesWritten: DWORD; ALog: TStrings): Boolean;

// liest EINEN Puffer Rohdaten von einem Capture-Pin im Zustand
// KSSTATE_RUN. ABufferCapacity ist die Groesse des von AData referenzierten
// (vom Aufrufer allozierten) Zielpuffers; ABytesRead nennt danach die
// tatsaechlich vom Treiber gelieferte Byte-Anzahl.
function ReadStreamBuffer(APinHandle: THandle; AData: Pointer; ABufferCapacity: DWORD;
  out ABytesRead: DWORD; ALog: TStrings): Boolean;

// -----------------------------------------------------------------------
// SetupAPI - Geräte-Erkennung (identisches Vorgehen wie WinUsbEngine.pas,
// hier auf KS-Kategorien statt einer festen Device-Interface-GUID
// angewendet und so erweitert, dass ALLE passenden Pfade gesammelt werden,
// nicht nur der erste - ein Filter kann mehrere Interfaces registrieren).
// -----------------------------------------------------------------------
type
  HDEVINFO = THandle;

  PSP_DEVICE_INTERFACE_DATA = ^SP_DEVICE_INTERFACE_DATA;
  SP_DEVICE_INTERFACE_DATA = record
    cbSize: DWORD;
    InterfaceClassGuid: TGUID;
    Flags: DWORD;
    Reserved: NativeUInt;
  end;

  PSP_DEVICE_INTERFACE_DETAIL_DATA_W = ^SP_DEVICE_INTERFACE_DETAIL_DATA_W;
  SP_DEVICE_INTERFACE_DETAIL_DATA_W = record
    cbSize: DWORD;
    DevicePath: array[0..0] of WideChar;
  end;

const
  DIGCF_PRESENT         = $00000002;
  DIGCF_DEVICEINTERFACE = $00000010;

  {$IFDEF WIN64}
  SP_DEVICE_INTERFACE_DETAIL_DATA_SIZE = 8;
  {$ELSE}
  SP_DEVICE_INTERFACE_DETAIL_DATA_SIZE = 6;
  {$ENDIF}

function SetupDiGetClassDevsW(ClassGuid: PGUID; Enumerator: PWideChar;
  hwndParent: HWND; Flags: DWORD): HDEVINFO; stdcall;
  external 'setupapi.dll' name 'SetupDiGetClassDevsW';

function SetupDiEnumDeviceInterfaces(DeviceInfoSet: HDEVINFO;
  DeviceInfoData: Pointer; const InterfaceClassGuid: TGUID;
  MemberIndex: DWORD; var DeviceInterfaceData: SP_DEVICE_INTERFACE_DATA): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiEnumDeviceInterfaces';

function SetupDiGetDeviceInterfaceDetailW(DeviceInfoSet: HDEVINFO;
  DeviceInterfaceData: PSP_DEVICE_INTERFACE_DATA;
  DeviceInterfaceDetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W;
  DeviceInterfaceDetailDataSize: DWORD; var RequiredSize: DWORD;
  DeviceInfoData: Pointer): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiGetDeviceInterfaceDetailW';

function SetupDiDestroyDeviceInfoList(DeviceInfoSet: HDEVINFO): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiDestroyDeviceInfoList';

// Findet alle Geräte-Pfade, die unter ACategoryGuid registriert sind UND
// deren Pfad die USB-VID/PID der ISLA S2400 enthält. Liefert die Anzahl
// gefundener Pfade; AList wird vorher geleert.
function FindKsDevicePaths(const ACategoryGuid: TGUID; AVendorID, AProductID: Word;
  AList: TStrings): Integer;

// -----------------------------------------------------------------------
// KS-Property-Abfragen
// -----------------------------------------------------------------------

// öffnet einen KS-Filter (synchron, ohne FILE_FLAG_OVERLAPPED - für reine
// Property-Abfragen ausreichend; das spätere Streaming braucht einen
// eigenen, mit FILE_FLAG_OVERLAPPED geöffneten Pin-Handle).
function OpenKsFilter(const ADevicePath: string): THandle;

function GetPinCount(AFilter: THandle; out ACount: ULONG): Boolean;
function GetPinDataFlow(AFilter: THandle; APinId: ULONG; out ADataFlow: ULONG): Boolean;

// liefert den kompletten KSMULTIPLE_ITEM+KSDATARANGE[]-Puffer roh zurück;
// ABytesReturned nennt die tatsächliche Länge. Fester 16-KB-Puffer -
// f��r die überschaubare Anzahl an Formatbereichen eines Audio-Pins mehr
// als ausreichend (bei Bedarf leicht erweiterbar).
function GetPinDataRanges(AFilter: THandle; APinId: ULONG;
  out ABuffer: TBytes; out ABytesReturned: DWORD): Boolean;

// generische Abfrage fuer KSPROPERTY_PIN_INTERFACES/_MEDIUMS - beide liefern
// KSMULTIPLE_ITEM gefolgt von einer Liste fester 24-Byte-KSIDENTIFIER-
// Eintraegen (GUID Set; ULONG Id; ULONG Flags).
function GetPinIdentifierList(AFilter: THandle; APinId: ULONG; APropertyId: ULONG;
  out ABuffer: TBytes; out ABytesReturned: DWORD): Boolean;

implementation

function CTL_CODE(ADeviceType, AFunction, AMethod, AAccess: DWORD): DWORD; inline;
begin
  Result := (ADeviceType shl 16) or (AAccess shl 14) or (AFunction shl 2) or AMethod;
end;

function IoctlKsProperty: DWORD; inline;
begin
  Result := CTL_CODE(FILE_DEVICE_KS, 0, METHOD_NEITHER, FILE_ANY_ACCESS);
end;

const
  // Access-Werte fuer CTL_CODE (devioctl.h) - nicht zu verwechseln mit den
  // vollen FILE_READ_DATA/FILE_WRITE_DATA-Zugriffsmasken.
  FILE_READ_ACCESS_  = DWORD($0001);
  FILE_WRITE_ACCESS_ = DWORD($0002);

function IoctlKsWriteStream: DWORD; inline;
begin
  // CTL_CODE(FILE_DEVICE_KS, 0x004, METHOD_NEITHER, FILE_WRITE_ACCESS) -
  // verifiziert gegen winsdk-10 ks.h (17.09.2026, siehe PROJEKT_STAND.md).
  Result := CTL_CODE(FILE_DEVICE_KS, 4, METHOD_NEITHER, FILE_WRITE_ACCESS_);
end;

function IoctlKsReadStream: DWORD; inline;
begin
  // CTL_CODE(FILE_DEVICE_KS, 0x005, METHOD_NEITHER, FILE_READ_ACCESS)
  Result := CTL_CODE(FILE_DEVICE_KS, 5, METHOD_NEITHER, FILE_READ_ACCESS_);
end;

function FindKsDevicePaths(const ACategoryGuid: TGUID; AVendorID, AProductID: Word;
  AList: TStrings): Integer;
var
  DevInfo: HDEVINFO;
  IfData: SP_DEVICE_INTERFACE_DATA;
  DetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W;
  RequiredSize: DWORD;
  MemberIndex: DWORD;
  CandidatePath: string;
  VidPidFilter: string;
begin
  AList.Clear;
  VidPidFilter := UpperCase(Format('VID_%.4X&PID_%.4X', [AVendorID, AProductID]));

  DevInfo := SetupDiGetClassDevsW(@ACategoryGuid, nil, 0,
    DIGCF_PRESENT or DIGCF_DEVICEINTERFACE);
  if DevInfo = INVALID_HANDLE_VALUE then
    Exit(0);

  try
    MemberIndex := 0;
    FillChar(IfData, SizeOf(IfData), 0);
    IfData.cbSize := SizeOf(IfData);

    while SetupDiEnumDeviceInterfaces(DevInfo, nil, ACategoryGuid, MemberIndex, IfData) do
    begin
      RequiredSize := 0;
      SetupDiGetDeviceInterfaceDetailW(DevInfo, @IfData, nil, 0, RequiredSize, nil);

      if RequiredSize > 0 then
      begin
        GetMem(DetailData, RequiredSize);
        try
          DetailData^.cbSize := SP_DEVICE_INTERFACE_DETAIL_DATA_SIZE;
          if SetupDiGetDeviceInterfaceDetailW(DevInfo, @IfData, DetailData,
            RequiredSize, RequiredSize, nil) then
          begin
            CandidatePath := PWideChar(@DetailData^.DevicePath[0]);
            if Pos(VidPidFilter, UpperCase(CandidatePath)) > 0 then
              AList.Add(CandidatePath);
          end;
        finally
          FreeMem(DetailData);
        end;
      end;

      Inc(MemberIndex);
    end;
  finally
    SetupDiDestroyDeviceInfoList(DevInfo);
  end;

  Result := AList.Count;
end;

function OpenKsFilter(const ADevicePath: string): THandle;
begin
  Result := CreateFileW(PWideChar(ADevicePath), GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
end;

function KsPropertyGetRaw(AHandle: THandle; const AGuid: TGUID; AId: ULONG;
  APinId: ULONG; AUsePinId: Boolean; AOutBuf: Pointer; AOutSize: ULONG;
  out ABytesReturned: DWORD): Boolean;
var
  PinProp: TKSPPin;
  InPtr: Pointer;
  InSize: ULONG;
begin
  FillChar(PinProp, SizeOf(PinProp), 0);
  PinProp.Prop.&Set := AGuid;
  PinProp.Prop.Id := AId;
  PinProp.Prop.Flags := KSPROPERTY_TYPE_GET;
  PinProp.PinId := APinId;

  if AUsePinId then
  begin
    InPtr := @PinProp;
    InSize := SizeOf(PinProp);
  end
  else
  begin
    InPtr := @PinProp.Prop;
    InSize := SizeOf(TKSProperty);
  end;

  ABytesReturned := 0;
  Result := DeviceIoControl(AHandle, IoctlKsProperty, InPtr, InSize,
    AOutBuf, AOutSize, ABytesReturned, nil);
end;

function GetPinCount(AFilter: THandle; out ACount: ULONG): Boolean;
var
  BytesReturned: DWORD;
begin
  ACount := 0;
  Result := KsPropertyGetRaw(AFilter, KSPROPSETID_Pin, KSPROPERTY_PIN_CTYPES,
    0, False, @ACount, SizeOf(ACount), BytesReturned);
end;

function GetPinDataFlow(AFilter: THandle; APinId: ULONG; out ADataFlow: ULONG): Boolean;
var
  BytesReturned: DWORD;
begin
  ADataFlow := 0;
  Result := KsPropertyGetRaw(AFilter, KSPROPSETID_Pin, KSPROPERTY_PIN_DATAFLOW,
    APinId, True, @ADataFlow, SizeOf(ADataFlow), BytesReturned);
end;

function GetPinDataRanges(AFilter: THandle; APinId: ULONG;
  out ABuffer: TBytes; out ABytesReturned: DWORD): Boolean;
const
  BUF_SIZE = 16384;
begin
  SetLength(ABuffer, BUF_SIZE);
  Result := KsPropertyGetRaw(AFilter, KSPROPSETID_Pin, KSPROPERTY_PIN_DATARANGES,
    APinId, True, @ABuffer[0], BUF_SIZE, ABytesReturned);
  if Result then
    SetLength(ABuffer, ABytesReturned)
  else
    SetLength(ABuffer, 0);
end;

function GetPinIdentifierList(AFilter: THandle; APinId: ULONG; APropertyId: ULONG;
  out ABuffer: TBytes; out ABytesReturned: DWORD): Boolean;
const
  BUF_SIZE = 4096;
begin
  SetLength(ABuffer, BUF_SIZE);
  Result := KsPropertyGetRaw(AFilter, KSPROPSETID_Pin, APropertyId,
    APinId, True, @ABuffer[0], BUF_SIZE, ABytesReturned);
  if Result then
    SetLength(ABuffer, ABytesReturned)
  else
    SetLength(ABuffer, 0);
end;

// AInterfaceGuid/AInterfaceId und AMediumGuid/AMediumId MUESSEN vom Pin
// selbst per KSPROPERTY_PIN_INTERFACES/_MEDIUMS abgefragt werden (siehe
// OpenWavePin) statt angenommen zu werden - am 08.09.2026 empirisch
// festgestellt, dass der "msft_wave"-Filter der ISLA S2400 ausschliesslich
// KSINTERFACE_STANDARD_LOOPED_STREAMING (Id=1) akzeptiert, NICHT das
// naheliegendere KSINTERFACE_STANDARD_STREAMING (Id=0) - eine allgemeine
// Web-Recherche legte STREAMING nahe, die Hardware selbst sagt etwas
// anderes und hat immer recht.
function BuildWaveConnectBuffer(APinId: ULONG; AChannels: Word;
  ABitsPerSample: Word; ASampleRate: DWORD; const AInterfaceGuid: TGUID;
  AInterfaceId: ULONG; const AMediumGuid: TGUID; AMediumId: ULONG): TBytes;
var
  Connect: PKSPinConnect;
  DataRangeHdr: PKSDataRange;
  Wfx: PWaveFormatEx;
  BlockAlign: Word;
begin
  // Speicherlayout (siehe KsCreatePin-Doku + PortAudio pa_win_wdmks.c):
  // KSPIN_CONNECT direkt gefolgt von KSDATAFORMAT_WAVEFORMATEX
  // (= KSDATARANGE-Kopf gefolgt von WAVEFORMATEX), alles in EINEM
  // zusammenhaengenden Speicherblock.
  SetLength(Result, SizeOf(TKSPinConnect) + SizeOf(TKSDataRange) + SizeOf(TWaveFormatEx));
  FillChar(Result[0], Length(Result), 0);

  Connect := @Result[0];
  Connect^.Interface_.&Set := AInterfaceGuid;
  Connect^.Interface_.Id := AInterfaceId;
  Connect^.Interface_.Flags := 0;
  Connect^.Medium.&Set := AMediumGuid;
  Connect^.Medium.Id := AMediumId;
  Connect^.Medium.Flags := 0;
  Connect^.PinId := APinId;
  Connect^.PinToHandle := 0;
  Connect^.Priority.PriorityClass := $40000000;    // KSPRIORITY_NORMAL (verifiziert)
  Connect^.Priority.PrioritySubClass := 1;         // Subklasse laut Doku "typisch 1"

  BlockAlign := (ABitsPerSample div 8) * AChannels;

  DataRangeHdr := PKSDataRange(NativeUInt(Connect) + SizeOf(TKSPinConnect));
  DataRangeHdr^.FormatSize := SizeOf(TKSDataRange) + SizeOf(TWaveFormatEx);
  DataRangeHdr^.Flags := 0;
  DataRangeHdr^.SampleSize := BlockAlign;
  DataRangeHdr^.Reserved := 0;
  DataRangeHdr^.MajorFormat := KSDATAFORMAT_TYPE_AUDIO;
  DataRangeHdr^.SubFormat := KSDATAFORMAT_SUBTYPE_PCM_;
  DataRangeHdr^.Specifier := KSDATAFORMAT_SPECIFIER_WAVEFORMATEX;

  Wfx := PWaveFormatEx(NativeUInt(DataRangeHdr) + SizeOf(TKSDataRange));
  Wfx^.wFormatTag := WAVE_FORMAT_PCM_;
  Wfx^.nChannels := AChannels;
  Wfx^.nSamplesPerSec := ASampleRate;
  Wfx^.wBitsPerSample := ABitsPerSample;
  Wfx^.nBlockAlign := BlockAlign;
  Wfx^.nAvgBytesPerSec := ASampleRate * BlockAlign;
  Wfx^.cbSize := 0;
end;

// liefert den ERSTEN von einem Pin gemeldeten Interface- bzw. Medium-
// Eintrag (Set-GUID + Id) - fuer unsere "Wave"-Pins bislang immer genau
// einer; falls ein Pin mehrere anbietet, waere hier ggf. eine Auswahl
// noetig, aber das ist fuer die ISLA S2400 nicht der Fall.
function GetFirstPinIdentifier(AFilter: THandle; APinId: ULONG; APropertyId: ULONG;
  out AGuid: TGUID; AId: PULONG): Boolean;
var
  Buf: TBytes;
  BytesReturned: DWORD;
  Multi: PKSMultipleItem;
  First: PKSProperty;
begin
  Result := False;
  FillChar(AGuid, SizeOf(AGuid), 0);
  AId^ := 0;
  if not GetPinIdentifierList(AFilter, APinId, APropertyId, Buf, BytesReturned) then
    Exit;
  if DWORD(Length(Buf)) < SizeOf(TKSMultipleItem) + SizeOf(TKSProperty) then
    Exit;
  Multi := @Buf[0];
  if Multi^.Count = 0 then
    Exit;
  First := PKSProperty(NativeUInt(@Buf[0]) + SizeOf(TKSMultipleItem));
  AGuid := First^.&Set;
  AId^ := First^.Id;
  Result := True;
end;

function OpenWavePin(AFilterHandle: THandle; APinId: ULONG; AChannels: Word;
  ABitsPerSample: Word; ASampleRate: DWORD; ADesiredAccess: DWORD;
  out APinHandle: THandle; out ARawStatus: LongInt): Boolean;
var
  ConnectBuf: TBytes;
  IfGuid, MedGuid: TGUID;
  IfId, MedId: ULONG;
begin
  APinHandle := 0;
  ARawStatus := 0;

  if not GetFirstPinIdentifier(AFilterHandle, APinId, KSPROPERTY_PIN_INTERFACES, IfGuid, @IfId) then
  begin
    // Fallback auf den bisher angenommenen Standardwert, falls die Abfrage
    // selbst fehlschlaegt (sollte nach der Diagnose oben nicht vorkommen)
    IfGuid := KSINTERFACESETID_Standard;
    IfId := KSINTERFACE_STANDARD_STREAMING;
  end;
  if not GetFirstPinIdentifier(AFilterHandle, APinId, KSPROPERTY_PIN_MEDIUMS, MedGuid, @MedId) then
  begin
    MedGuid := KSMEDIUMSETID_Standard;
    MedId := KSMEDIUM_STANDARD_DEVIO;
  end;

  ConnectBuf := BuildWaveConnectBuffer(APinId, AChannels, ABitsPerSample, ASampleRate,
    IfGuid, IfId, MedGuid, MedId);

  // NTSTATUS=$1F (ERROR_GEN_FAILURE) trat am 17.09.2026 auf, solange andere
  // Programme (Sonarworks, VB-Audio Matrix) das Geraet belegten - die
  // Wiederholversuche halfen dabei NICHT, erst das Schliessen dieser
  // Programme. Die 3 Versuche bleiben als harmlose Absicherung drin.
  ARawStatus := KsCreatePin(AFilterHandle, PKSPinConnect(@ConnectBuf[0]),
    ADesiredAccess, APinHandle);
  if ARawStatus <> 0 then
  begin
    Sleep(200);
    ARawStatus := KsCreatePin(AFilterHandle, PKSPinConnect(@ConnectBuf[0]),
      ADesiredAccess, APinHandle);
  end;
  if ARawStatus <> 0 then
  begin
    Sleep(500);
    ARawStatus := KsCreatePin(AFilterHandle, PKSPinConnect(@ConnectBuf[0]),
      ADesiredAccess, APinHandle);
  end;

  // ARawStatus unveraendert an den Aufrufer durchreichen (roher NTSTATUS-
  // Rueckgabewert von KsCreatePin) - GetLastError() wird bewusst NICHT
  // ueberschrieben, damit ein evtl. vom System selbst gesetzter Wert beim
  // Aufrufer noch auswertbar bleibt.
  Result := ARawStatus = 0; // STATUS_SUCCESS
end;

// fuehrt DeviceIoControl mit einem ECHTEN OVERLAPPED-Structure aus und
// wartet ggf. auf den Abschluss - manche KS-Pin-Handles (im Gegensatz zu
// Filter-Handles) sind fuer asynchrone Streaming-E/A ausgelegt und
// verhalten sich bei rein synchronen Aufrufen (lpOverlapped=nil) evtl.
// nicht wie erwartet.
function DeviceIoControlOverlapped(AHandle: THandle; AIoControlCode: DWORD;
  AInBuf: Pointer; AInSize: DWORD; AOutBuf: Pointer; AOutSize: DWORD;
  out ABytesReturned: DWORD): Boolean;
var
  Ov: TOverlapped;
  Ev: THandle;
begin
  FillChar(Ov, SizeOf(Ov), 0);
  Ev := CreateEventW(nil, True, False, nil);
  Ov.hEvent := Ev;
  try
    Result := DeviceIoControl(AHandle, AIoControlCode, AInBuf, AInSize,
      AOutBuf, AOutSize, ABytesReturned, @Ov);
    if not Result and (GetLastError = ERROR_IO_PENDING) then
      Result := GetOverlappedResult(AHandle, Ov, ABytesReturned, True);
  finally
    CloseHandle(Ev);
  end;
end;

// KS-Konvention fuer KSPROPERTY_TYPE_SET (Microsoft Learn, IOCTL_KS_PROPERTY:
// "the property data is passed as the output buffer to the IOCTL"; ebenso
// PortAudio pa_win_wdmks.c, PinSetState): Eingabepuffer = NUR der
// KSPROPERTY-Kopf, Ausgabepuffer = der zu setzende Zustandswert.
//
// KORREKTUR 12.10.2026: Die Fassung vom 09.09.2026 haengte den Zustand an
// den Eingabepuffer (vom Treiber ignoriert) und uebergab als Ausgabepuffer
// eine mit 0 belegte Variable - damit wurde bei JEDEM Aufruf KSSTATE_STOP
// (=0) gesetzt. Der Pin hat STOP nie verlassen; "RUN erreicht" war ein
// Trugschluss. Die korrekte Form scheiterte damals mit Fehler 22
// (vermutlich STATUS_INVALID_DEVICE_STATE), weil zu dem Zeitpunkt noch kein
// WaveRT-Puffer angefordert war - der muss VOR dem Verlassen von STOP
// existieren (Reihenfolge wie PortAudio: erst Puffer, dann Zustaende).
function SetPinState(APinHandle: THandle; AState: ULONG; ALog: TStrings): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
  StateValue: ULONG;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_Connection;
  Prop.Id := KSPROPERTY_CONNECTION_STATE;
  Prop.Flags := KSPROPERTY_TYPE_SET;

  StateValue := AState;
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @StateValue, SizeOf(StateValue), BytesReturned, nil);

  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    -> SET Zustand %d: Treiber meldet OK.', [AState]))
    else
      ALog.Add(Format('    -> SET Zustand %d fehlgeschlagen, GetLastError=%d', [AState, GetLastError]));
  end;
end;

function GetPinState(APinHandle: THandle; out AState: ULONG): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_Connection;
  Prop.Id := KSPROPERTY_CONNECTION_STATE;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  AState := $FFFFFFFF; // bewusst ungueltig vorbelegt - faellt sofort auf
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @AState, SizeOf(AState), BytesReturned, nil);
end;

// fuehrt einen einzelnen Uebergang aus und bestaetigt ihn per GetPinState
function SetAndVerifyPinState(APinHandle: THandle; AState: ULONG; ALog: TStrings): Boolean;
var
  ActualState: ULONG;
  Err: DWORD;
begin
  if Assigned(ALog) then
    ALog.Add(Format('    Uebergang zu Zustand %d:', [AState]));
  if not SetPinState(APinHandle, AState, ALog) then
    Exit(False);

  if not GetPinState(APinHandle, ActualState) then
  begin
    Err := GetLastError;
    if Assigned(ALog) then
      ALog.Add(Format('    -> GET Zustand fehlgeschlagen, GetLastError=%d (Uebergang NICHT bestaetigt)', [Err]));
    SetLastError(Err);
    Exit(False);
  end;

  Result := ActualState = AState;
  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    -> GET bestaetigt: Pin ist jetzt in Zustand %d.', [ActualState]))
    else
      ALog.Add(Format('    -> GET WIDERSPRUCH: Pin meldet Zustand %d statt %d!', [ActualState, AState]));
  end;
  if not Result then
    SetLastError(5023); // ERROR_INVALID_STATE (winerror.h)
end;

function SetPinStateSequential(APinHandle: THandle; AFromState, AToState: ULONG;
  ALog: TStrings): Boolean;
var
  S: Integer;
begin
  Result := True;
  if AToState >= AFromState then
  begin
    for S := Integer(AFromState) + 1 to Integer(AToState) do
      if not SetAndVerifyPinState(APinHandle, ULONG(S), ALog) then
        Exit(False);
  end
  else
  begin
    for S := Integer(AFromState) - 1 downto Integer(AToState) do
      if not SetAndVerifyPinState(APinHandle, ULONG(S), ALog) then
        Exit(False);
  end;
end;

function GetRtAudioBuffer(APinHandle: THandle; ARequestedBufferSize: ULONG;
  out ABuffer: TKSRtAudioBuffer): Boolean;
var
  InProp: TKSRtAudioBufferProperty;
  BytesReturned: DWORD;
begin
  FillChar(InProp, SizeOf(InProp), 0);
  InProp.Prop.&Set := KSPROPSETID_RtAudio;
  InProp.Prop.Id := KSPROPERTY_RTAUDIO_BUFFER;
  InProp.Prop.Flags := KSPROPERTY_TYPE_GET;
  InProp.BaseAddress := nil; // laut Doku zwingend NULL, falls keine
                              // bestimmte Basisadresse gewuenscht ist
  InProp.RequestedBufferSize := ARequestedBufferSize;

  FillChar(ABuffer, SizeOf(ABuffer), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @InProp, SizeOf(InProp),
    @ABuffer, SizeOf(ABuffer), BytesReturned, nil);
end;

function GetRtAudioBufferWithNotification(APinHandle: THandle;
  ARequestedBufferSize, ANotificationCount: ULONG;
  out ABuffer: TKSRtAudioBuffer): Boolean;
var
  InProp: TKSRtAudioBufferPropertyWithNotification;
  BytesReturned: DWORD;
begin
  FillChar(InProp, SizeOf(InProp), 0);
  InProp.Prop.&Set := KSPROPSETID_RtAudio;
  InProp.Prop.Id := KSPROPERTY_RTAUDIO_BUFFER_WITH_NOTIFICATION;
  InProp.Prop.Flags := KSPROPERTY_TYPE_GET;
  InProp.BaseAddress := nil;
  InProp.RequestedBufferSize := ARequestedBufferSize;
  InProp.NotificationCount := ANotificationCount;

  FillChar(ABuffer, SizeOf(ABuffer), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @InProp, SizeOf(InProp),
    @ABuffer, SizeOf(ABuffer), BytesReturned, nil);
end;

function QueryNotificationSupport(APinHandle: THandle; out ASupported: LongBool): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_QUERY_NOTIFICATION_SUPPORT;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  ASupported := False;
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @ASupported, SizeOf(ASupported), BytesReturned, nil);
end;

function NotificationEventRequest(APinHandle: THandle; AEvent: THandle;
  APropertyId: ULONG): Boolean;
var
  InProp: TKSRtAudioNotificationEventProperty;
  BytesReturned: DWORD;
begin
  FillChar(InProp, SizeOf(InProp), 0);
  InProp.Prop.&Set := KSPROPSETID_RtAudio;
  InProp.Prop.Id := APropertyId;
  InProp.Prop.Flags := KSPROPERTY_TYPE_GET; // laut Doku Get UND Set erlaubt
  InProp.NotificationEvent := AEvent;

  // Property-Wert laut Doku NULL -> kein Ausgabepuffer
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @InProp, SizeOf(InProp),
    nil, 0, BytesReturned, nil);
end;

function RegisterNotificationEvent(APinHandle: THandle; AEvent: THandle): Boolean;
begin
  Result := NotificationEventRequest(APinHandle, AEvent,
    KSPROPERTY_RTAUDIO_REGISTER_NOTIFICATION_EVENT);
end;

function UnregisterNotificationEvent(APinHandle: THandle; AEvent: THandle): Boolean;
begin
  Result := NotificationEventRequest(APinHandle, AEvent,
    KSPROPERTY_RTAUDIO_UNREGISTER_NOTIFICATION_EVENT);
end;

function GetRtAudioReadPacket(APinHandle: THandle;
  out AInfo: TKSRtAudioGetReadPacketInfo): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_GETREADPACKET;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  FillChar(AInfo, SizeOf(AInfo), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @AInfo, SizeOf(AInfo), BytesReturned, nil);
end;

function GetRtAudioPacketCount(APinHandle: THandle; out ACount: ULONG): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_PACKETCOUNT;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  ACount := 0;
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @ACount, SizeOf(ACount), BytesReturned, nil);
end;

function SetRtAudioWritePacket(APinHandle: THandle; APacketNumber: ULONG): Boolean;
var
  Prop: TKSProperty;
  Info: TKSRtAudioSetWritePacketInfo;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_SETWRITEPACKET;
  Prop.Flags := KSPROPERTY_TYPE_SET;

  FillChar(Info, SizeOf(Info), 0);
  Info.PacketNumber := APacketNumber;

  // KS-SET-Konvention (siehe SetPinState): Wert im AUSGABEpuffer
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @Info, SizeOf(Info), BytesReturned, nil);
end;

function GetRtAudioHwLatency(APinHandle: THandle; out ALatency: TKSRtAudioHwLatency): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_HWLATENCY;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  FillChar(ALatency, SizeOf(ALatency), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @ALatency, SizeOf(ALatency), BytesReturned, nil);
end;

function GetRtAudioPositionRegister(APinHandle: THandle;
  out AReg: TKSRtAudioHwRegister): Boolean;
var
  InProp: TKSRtAudioHwRegisterProperty;
  BytesReturned: DWORD;
begin
  FillChar(InProp, SizeOf(InProp), 0);
  InProp.Prop.&Set := KSPROPSETID_RtAudio;
  InProp.Prop.Id := KSPROPERTY_RTAUDIO_POSITIONREGISTER;
  InProp.Prop.Flags := KSPROPERTY_TYPE_GET;
  InProp.BaseAddress := nil;

  FillChar(AReg, SizeOf(AReg), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @InProp, SizeOf(InProp),
    @AReg, SizeOf(AReg), BytesReturned, nil);
end;

function GetAudioPosition(APinHandle: THandle; out APos: TKSAudioPosition): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_Audio;
  Prop.Id := KSPROPERTY_AUDIO_POSITION;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  FillChar(APos, SizeOf(APos), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @APos, SizeOf(APos), BytesReturned, nil);
end;

function GetRtAudioPresentationPosition(APinHandle: THandle;
  out APos: TKSAudioPresentationPosition): Boolean;
var
  Prop: TKSProperty;
  BytesReturned: DWORD;
begin
  FillChar(Prop, SizeOf(Prop), 0);
  Prop.&Set := KSPROPSETID_RtAudio;
  Prop.Id := KSPROPERTY_RTAUDIO_PRESENTATION_POSITION;
  Prop.Flags := KSPROPERTY_TYPE_GET;

  FillChar(APos, SizeOf(APos), 0);
  Result := DeviceIoControl(APinHandle, IoctlKsProperty, @Prop, SizeOf(Prop),
    @APos, SizeOf(APos), BytesReturned, nil);
end;

function WriteStreamBuffer(APinHandle: THandle; AData: Pointer; ADataBytes: DWORD;
  out ABytesWritten: DWORD; ALog: TStrings): Boolean;
var
  Header: TKSStreamHeader;
begin
  FillChar(Header, SizeOf(Header), 0);
  Header.Size := SizeOf(Header);
  Header.Data := AData;
  Header.FrameExtent := ADataBytes;
  Header.DataUsed := ADataBytes;

  // Variante 1: laut Doku ausreichend - kein Ausgabepuffer.
  ABytesWritten := 0;
  Result := DeviceIoControl(APinHandle, IoctlKsWriteStream, @Header, SizeOf(Header),
    nil, 0, ABytesWritten, nil);
  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    WriteStream Variante 1 (kein Ausgabepuffer) -> OK, %d Bytes geschrieben',
        [ABytesWritten]))
    else
      ALog.Add(Format('    WriteStream Variante 1 (kein Ausgabepuffer) -> Fehler %d', [GetLastError]));
  end;
  if Result then Exit;

  // Variante 2: derselbe Header zusaetzlich als Ausgabepuffer (Muster wie
  // bei KSPROPERTY_CONNECTION_STATE, das ebenfalls einen zusaetzlichen
  // Ausgabepuffer verlangte, obwohl die Doku das fuer SET nicht erwaehnte).
  FillChar(Header, SizeOf(Header), 0);
  Header.Size := SizeOf(Header);
  Header.Data := AData;
  Header.FrameExtent := ADataBytes;
  Header.DataUsed := ADataBytes;
  Result := DeviceIoControl(APinHandle, IoctlKsWriteStream, @Header, SizeOf(Header),
    @Header, SizeOf(Header), ABytesWritten, nil);
  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    WriteStream Variante 2 (Header auch als Ausgabepuffer) -> OK, %d Bytes geschrieben',
        [ABytesWritten]))
    else
      ALog.Add(Format('    WriteStream Variante 2 (Header auch als Ausgabepuffer) -> Fehler %d', [GetLastError]));
  end;
end;

function ReadStreamBuffer(APinHandle: THandle; AData: Pointer; ABufferCapacity: DWORD;
  out ABytesRead: DWORD; ALog: TStrings): Boolean;
var
  Header: TKSStreamHeader;
begin
  // Variante 1: Header nur als Eingabe, Zielpuffer separat als Ausgabepuffer
  // (AData direkt, nicht der Header) - naheliegende Lesart von "Output
  // buffer: Stream data is returned in the buffers pointed to by the
  // stream headers", falls der DeviceIoControl-Ausgabeparameter direkt auf
  // den Zieldatenpuffer zeigen soll statt auf den Header.
  FillChar(Header, SizeOf(Header), 0);
  Header.Size := SizeOf(Header);
  Header.Data := AData;
  Header.FrameExtent := ABufferCapacity;
  Header.DataUsed := 0;
  ABytesRead := 0;
  Result := DeviceIoControl(APinHandle, IoctlKsReadStream, @Header, SizeOf(Header),
    AData, ABufferCapacity, ABytesRead, nil);
  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    ReadStream Variante 1 (Zielpuffer als Ausgabe) -> OK, %d Bytes gelesen (DataUsed=%d)',
        [ABytesRead, Header.DataUsed]))
    else
      ALog.Add(Format('    ReadStream Variante 1 (Zielpuffer als Ausgabe) -> Fehler %d', [GetLastError]));
  end;
  if Result then Exit;

  // Variante 2: derselbe Header sowohl als Eingabe- als auch als
  // Ausgabepuffer (Muster wie bei KSPROPERTY_CONNECTION_STATE) - der
  // eigentliche Audio-Zielpuffer bleibt ueber Header.Data referenziert.
  FillChar(Header, SizeOf(Header), 0);
  Header.Size := SizeOf(Header);
  Header.Data := AData;
  Header.FrameExtent := ABufferCapacity;
  Header.DataUsed := 0;
  Result := DeviceIoControl(APinHandle, IoctlKsReadStream, @Header, SizeOf(Header),
    @Header, SizeOf(Header), ABytesRead, nil);
  if Assigned(ALog) then
  begin
    if Result then
      ALog.Add(Format('    ReadStream Variante 2 (Header auch als Ausgabepuffer) -> OK, %d Bytes gelesen (DataUsed=%d)',
        [ABytesRead, Header.DataUsed]))
    else
      ALog.Add(Format('    ReadStream Variante 2 (Header auch als Ausgabepuffer) -> Fehler %d', [GetLastError]));
  end;
end;

end.
