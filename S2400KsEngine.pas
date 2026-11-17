unit S2400KsEngine;

// =============================================================================
// S2400KsEngine.pas
//
// Kernel-Streaming-Engine des ISLA-S2400-ASIO-Treibers (ersetzt
// S2400WasapiEngine.pas, das nur noch als Referenz im Ordner liegt).
//
// Spricht per Kernel Streaming direkt mit dem "msft_wave"-Filter des
// Windows-USB-Audiotreibers (usbaudio2.sys) - ohne Windows-Audiodienst,
// Mixer oder Abtastratenwandlung dazwischen. Alle hier verwendeten Ablaeufe
// wurden vorher mit S2400KsDiag.exe an der echten Hardware verifiziert
// (siehe PROJEKT_STAND.md, 12.10.2026):
//
//   - Capture-Pin: bis 10 Kanaele, Render-Pin: bis 2 Kanaele, jeweils
//     16 Bit PCM / 48 kHz (laut KSPROPERTY_PIN_DATARANGES - die Pins werden
//     hier zur Laufzeit anhand ihrer Datenbereiche gesucht, nicht fest
//     verdrahtet)
//   - Reihenfolge: Pin oeffnen -> Ringpuffer MIT Notification anfordern
//     (noch in STOP) -> Event registrieren -> STOP/ACQUIRE/PAUSE/RUN
//   - Ringpuffer = 2 Pakete; der Treiber signalisiert pro Paket ein Event
//   - Capture: KSPROPERTY_RTAUDIO_GETREADPACKET liefert die Nummer des
//     fertigen Pakets, Lage im Puffer = (Nummer mod 2) * Paketgroesse
//   - Render: KSPROPERTY_RTAUDIO_PACKETCOUNT = N heisst laut Doku "Paket N
//     laeuft gerade", geschrieben wird Paket N+1 (Lage = (N+1) mod 2)
//
// Eine ASIO-Puffergroesse entspricht genau EINEM Paket. Getaktet wird der
// Streaming-Thread vom Capture-Event (Render und Capture haengen an
// derselben Geraete-Clock).
// =============================================================================

interface

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  S2400KsInterop;

const
  // Obergrenzen fuer die Kanal-Arrays im Treiberkern; die tatsaechlichen
  // Kanalzahlen liefert der Treiber per KSPROPERTY_PIN_DATARANGES
  // (ISLA S2400 am 12.10.2026: Capture 10, Render 2).
  C_ISLA_MAX_INPUT_CHANNELS  = 10;
  C_ISLA_MAX_OUTPUT_CHANNELS = 2;

  C_ISLA_SAMPLE_RATE      = 48000; // einzige vom Geraet gemeldete Rate
  C_ISLA_BITS_PER_SAMPLE  = 16;    // einzige vom Geraet gemeldete Bittiefe
  C_ISLA_BYTES_PER_SAMPLE = 2;

  C_ISLA_DEFAULT_BUFFER_SAMPLES = 144; // 128 ist laut Messung defekt (siehe S2400ControlPanel)

  // Pakete pro Ringpuffer (= NotificationCount, laut Doku nur 1 oder 2)
  C_KS_PACKETS_PER_BUFFER = 2;

// Schreibt eine Zeile in %TEMP%\<S2400LogFileName>. Fehler beim Loggen
// werden verschluckt, damit das Logging nie selbst zum Problem wird.
procedure S2400Log(const AMsg: string);

var
  // Dateiname des Logs im TEMP-Ordner - der Verbund-Treiber setzt beim
  // Laden "S2400Aggregate.log", damit sich die Logs nicht mischen
  S2400LogFileName: string = 'S2400AsioDriver.log';

type
  // Zustand EINER Richtung (Capture oder Render)
  TS2400KsStream = record
    PinId: ULONG;
    Channels: Integer;
    Handle: THandle;
    Event: THandle;
    EventRegistered: Boolean;
    Buffer: PByte;
    BufferBytes: ULONG;
    PacketBytes: ULONG;
    PacketFrames: Cardinal;
    BytesPerFrame: Integer;
    CallMemoryBarrier: Boolean;
    HwLatencyFrames: Integer;
  end;

  // Momentaufnahme eines der ersten Zyklen (Phasenlage Capture/Render) -
  // wird im Echtzeit-Thread nur gespeichert und erst beim Stoppen geloggt
  TS2400CycleInfo = record
    CapturePacket: Int64;
    HaveRenderCount: Boolean;
    RenderTargetPacket: ULONG;
  end;

  TS2400KsEngine = class
  private
    FFilter: THandle;
    FCapture: TS2400KsStream;
    FRender: TS2400KsStream;
    FAbortEvent: THandle;
    FIsOpen: Boolean;
    FIsStarted: Boolean;
    FLastError: string;
    FDesiredBufferFrames: Cardinal;
    FBufferSizeFrames: Cardinal;

    // Capture-Zustand (nur vom Streaming-Thread benutzt). WICHTIG: im
    // Echtzeit-Thread wird NICHT geloggt (eine Logzeile kostet ~6 ms, ein
    // Paket bei 128 Samples nur 2,7 ms - das Logging selbst hat am
    // 13.10.2026 Pakete verloren). Stattdessen Zaehler, Bilanz beim Stoppen.
    FCaptureMoreData: Boolean;
    FLastCapturePacket: Int64;
    FLastCaptureQpc: UInt64;
    FCaptureCycles: Int64;
    FDroppedCapturePackets: Int64;
    FDroppedAtStartup: Int64;
    FMoreDataCount: Int64;
    FCaptureReadErrors: Int64;
    FCaptureFirstError: DWORD;

    // Render-Zustand (nur vom Streaming-Thread benutzt)
    FRenderUsePacketCount: Boolean;
    FRenderUseSetWritePacket: Boolean;
    FRenderSetWriteUnsupportedError: DWORD;
    FRenderCycle: ULONG;
    FRenderTargetPacket: ULONG;
    FRenderLateWrites: Int64;
    FRenderLateAtStartup: Int64;
    FRenderFirstError: DWORD;

    FCycleInfo: array[0..7] of TS2400CycleInfo;
    FCycleInfoCount: Integer;
    FStartTick: UInt64;

    // Zeitstempel-Analyse der Capture-Pakete (15.10.2026): Lauf ueber 2,6 h
    // bei 128 Samples lieferte 4,8 % WENIGER Pakete als 48 kHz verlangen,
    // obwohl die Paketnummern lueckenlos waren. Die QPC-Zeitstempel des
    // Treibers (Aufnahmezeitpunkt je Paket) zeigen, ob dabei Audio fehlt.
    FQpcFreq: Int64;
    FExpectedPacketQpc: Int64;   // Soll-Abstand zweier Pakete in QPC-Ticks
    FFirstPacketNumber: Int64;
    FFirstPacketQpc: UInt64;
    FPrevPacketQpc: UInt64;
    FMinPacketDelta: Int64;
    FMaxPacketDelta: Int64;
    FQpcGaps: Int64;             // Abstand > 1,5 x Soll -> versteckte Luecke
    FQpcGapExcess: Int64;        // Summe der Ueberlaenge dieser Luecken (QPC)
    FFirstReadQpc: Int64;        // eigene Uhr: erstes erfolgreiches Lesen
    FLastReadQpc: Int64;

    procedure LogStreamingSummary;

    procedure Fail(const AMsg: string);
    function FindFilterPath: string;
    function FindStreamPins: Boolean;
    function OpenStream(var AStream: TS2400KsStream; const AName: string): Boolean;
    procedure StopStream(var AStream: TS2400KsStream);
    procedure CloseStream(var AStream: TS2400KsStream);
  public
    constructor Create;
    destructor Destroy; override;

    function Open: Boolean;
    procedure Close;

    function StartStreaming: Boolean;
    procedure StopStreaming;
    // laesst ein blockierendes WaitForCaptureReady sofort zurueckkehren
    procedure AbortStreaming;

    // vom Streaming-Thread genutzt
    function WaitForCaptureReady(ATimeoutMs: Cardinal): Boolean;
    function ReadCaptureBuffer(out AData: PByte; out AFrames: Cardinal): Boolean;
    function WriteRenderBuffer(out AData: PByte; AFrames: Cardinal): Boolean;
    procedure ReleaseRenderBuffer;

    property IsOpen: Boolean read FIsOpen;
    property IsStarted: Boolean read FIsStarted;
    property LastError: string read FLastError;

    // gewuenschte Paketgroesse in Frames - wirkt erst beim naechsten Open()
    property DesiredBufferSizeFrames: Cardinal read FDesiredBufferFrames write FDesiredBufferFrames;
    // tatsaechliche Paketgroesse nach Open() (= ASIO-Puffergroesse)
    property BufferSizeFrames: Cardinal read FBufferSizeFrames;

    property InputChannels: Integer read FCapture.Channels;
    property OutputChannels: Integer read FRender.Channels;
    property BytesPerFrameCapture: Integer read FCapture.BytesPerFrame;
    property BytesPerFrameRender: Integer read FRender.BytesPerFrame;

    // vom Treiber per KSPROPERTY_RTAUDIO_HWLATENCY gemeldeter Anteil
    property InputHwLatencyFrames: Integer read FCapture.HwLatencyFrames;
    property OutputHwLatencyFrames: Integer read FRender.HwLatencyFrames;

    // True = der Treiber hat bereits ein weiteres fertiges Capture-Paket
    // (Streaming-Thread lag zurueck und holt ohne Warten auf)
    property CaptureMoreData: Boolean read FCaptureMoreData;
    // QPC-Zeitpunkt des ersten Samples im zuletzt gelesenen Capture-Paket
    // (vom Treiber per GETREADPACKET geliefert), 0 = unbekannt
    property LastCaptureQpc: UInt64 read FLastCaptureQpc;
    property DroppedCapturePackets: Int64 read FDroppedCapturePackets;
  end;

implementation

const
  // Win32-Fehlercodes, die "Property nicht unterstuetzt" bedeuten
  ERR_INVALID_FUNCTION = 1;
  ERR_NOT_SUPPORTED    = 50;
  ERR_NOT_FOUND        = 1168;
  ERR_SET_NOT_FOUND    = 1170;

  // Zyklen, die als "Startphase" gelten (Pakete/Fehler darin werden in der
  // Bilanz getrennt ausgewiesen, damit Anlaufeffekte den Dauerbetrieb
  // nicht verfaelschen). 50 Zyklen = 133 ms bei 128 Samples.
  C_STARTUP_CYCLES = 50;

var
  GBarrierDummy: Integer;
  // serialisiert S2400Log - Host-Thread und Streaming-Thread schreiben
  // sonst gleichzeitig in dieselbe Datei und Zeilen gehen verloren
  GLogLock: TCriticalSection;

// vollstaendiger Speicher-Fence (LOCK-praefigierter Interlocked-Zugriff) -
// nur noetig, falls der Treiber CallMemoryBarrier verlangt
procedure FullMemoryBarrier; inline;
begin
  TInterlocked.Exchange(GBarrierDummy, 0);
end;

function IsUnsupportedError(AErr: DWORD): Boolean;
begin
  Result := (AErr = ERR_INVALID_FUNCTION) or (AErr = ERR_NOT_SUPPORTED) or
    (AErr = ERR_NOT_FOUND) or (AErr = ERR_SET_NOT_FOUND);
end;

procedure S2400Log(const AMsg: string);
var
  LogDir, LogPath: string;
  F: TextFile;
  TempBuf: array[0..MAX_PATH] of WideChar;
begin
  try
    // GetTempPath statt Umgebungsvariable TEMP: liefert auch dann einen
    // gueltigen Ordner, wenn ein Host-Prozess ohne TEMP gestartet wurde
    if GetTempPathW(MAX_PATH, TempBuf) = 0 then
      Exit;
    LogDir := PWideChar(@TempBuf[0]);
    LogPath := IncludeTrailingPathDelimiter(LogDir) + S2400LogFileName;

    if GLogLock <> nil then
      GLogLock.Enter;
    try
      AssignFile(F, LogPath);
      if FileExists(LogPath) then
        Append(F)
      else
        Rewrite(F);
      try
        WriteLn(F, FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + '  ' + AMsg);
      finally
        CloseFile(F);
      end;
    finally
      if GLogLock <> nil then
        GLogLock.Leave;
    end;
  except
    // Logging darf selbst nie zum Fehler fuehren - bewusst verschluckt.
  end;
end;

procedure ResetStream(var AStream: TS2400KsStream);
begin
  FillChar(AStream, SizeOf(AStream), 0);
  AStream.PinId := $FFFFFFFF;
end;

// -----------------------------------------------------------------------
// TS2400KsEngine
// -----------------------------------------------------------------------

constructor TS2400KsEngine.Create;
begin
  inherited Create;
  FFilter := INVALID_HANDLE_VALUE;
  ResetStream(FCapture);
  ResetStream(FRender);
  FDesiredBufferFrames := C_ISLA_DEFAULT_BUFFER_SAMPLES;
  FBufferSizeFrames := C_ISLA_DEFAULT_BUFFER_SAMPLES;
  FAbortEvent := CreateEventW(nil, True, False, nil); // manuelles Reset
end;

destructor TS2400KsEngine.Destroy;
begin
  Close;
  if FAbortEvent <> 0 then
    CloseHandle(FAbortEvent);
  inherited Destroy;
end;

procedure TS2400KsEngine.Fail(const AMsg: string);
begin
  FLastError := AMsg;
  S2400Log('FEHLER: ' + AMsg);
end;

// sucht den "msft_wave"-Filter (mi_00) der ISLA S2400 - mi_03 ("global")
// ist die MIDI-Schnittstelle und fuer Audio irrelevant
function TS2400KsEngine.FindFilterPath: string;
var
  Paths: TStringList;
  I: Integer;
begin
  Result := '';
  Paths := TStringList.Create;
  try
    FindKsDevicePaths(KSCATEGORY_CAPTURE, VID_ISLA_S2400, PID_ISLA_S2400, Paths);
    for I := 0 to Paths.Count - 1 do
      S2400Log('KS-Filter gefunden: ' + Paths[I]);

    for I := 0 to Paths.Count - 1 do
      if Pos('MSFT_WAVE', UpperCase(Paths[I])) > 0 then
        Exit(Paths[I]);
    for I := 0 to Paths.Count - 1 do
      if Pos('MI_00', UpperCase(Paths[I])) > 0 then
        Exit(Paths[I]);
  finally
    Paths.Free;
  end;
end;

// findet Capture- und Render-Pin anhand ihrer Datenbereiche: Audio, PCM,
// 16 Bit und 48 kHz muessen im gemeldeten Bereich liegen
function TS2400KsEngine.FindStreamPins: Boolean;
var
  PinCount, PinId, Flow: ULONG;
  Buf: TBytes;
  BytesRet: DWORD;
  Multi: PKSMultipleItem;
  P: PByte;
  BufEnd: NativeUInt;
  J: Integer;
  DR: PKSDataRange;
  DRA: PKSDataRangeAudio;
  MaxCh: ULONG;
begin
  Result := False;
  ResetStream(FCapture);
  ResetStream(FRender);

  if not GetPinCount(FFilter, PinCount) then
  begin
    Fail(Format('KSPROPERTY_PIN_CTYPES fehlgeschlagen, GetLastError=%d', [GetLastError]));
    Exit;
  end;
  if PinCount = 0 then
  begin
    Fail('KS-Filter meldet keine Pins.');
    Exit;
  end;

  for PinId := 0 to PinCount - 1 do
  begin
    if not GetPinDataFlow(FFilter, PinId, Flow) then
      Continue;
    if not GetPinDataRanges(FFilter, PinId, Buf, BytesRet) then
      Continue;
    if Length(Buf) < SizeOf(TKSMultipleItem) then
      Continue;

    Multi := @Buf[0];
    P := PByte(Multi) + SizeOf(TKSMultipleItem);
    BufEnd := NativeUInt(@Buf[0]) + NativeUInt(Length(Buf));
    MaxCh := 0;

    for J := 0 to Integer(Multi^.Count) - 1 do
    begin
      if NativeUInt(P) + SizeOf(TKSDataRange) > BufEnd then
        Break;
      DR := PKSDataRange(P);
      if (DR^.FormatSize = 0) or (NativeUInt(P) + DR^.FormatSize > BufEnd) then
        Break;

      if IsEqualGUID(DR^.MajorFormat, KSDATAFORMAT_TYPE_AUDIO) and
         IsEqualGUID(DR^.SubFormat, KSDATAFORMAT_SUBTYPE_PCM_) and
         (DR^.FormatSize >= SizeOf(TKSDataRangeAudio)) then
      begin
        DRA := PKSDataRangeAudio(P);
        if (DRA^.MinimumBitsPerSample <= C_ISLA_BITS_PER_SAMPLE) and
           (DRA^.MaximumBitsPerSample >= C_ISLA_BITS_PER_SAMPLE) and
           (DRA^.MinimumSampleFrequency <= C_ISLA_SAMPLE_RATE) and
           (DRA^.MaximumSampleFrequency >= C_ISLA_SAMPLE_RATE) and
           (DRA^.MaximumChannels > MaxCh) then
          MaxCh := DRA^.MaximumChannels;
      end;

      // Eintraege in einer KSMULTIPLE_ITEM-Liste sind 8-Byte-ausgerichtet
      Inc(P, (DR^.FormatSize + 7) and not ULONG(7));
    end;

    if MaxCh = 0 then
      Continue;

    if (Flow = KSPIN_DATAFLOW_OUT) and (FCapture.PinId = $FFFFFFFF) then
    begin
      FCapture.PinId := PinId;
      FCapture.Channels := MaxCh;
      if FCapture.Channels > C_ISLA_MAX_INPUT_CHANNELS then
        FCapture.Channels := C_ISLA_MAX_INPUT_CHANNELS;
      S2400Log(Format('Capture-Pin: %d (bis %d Kanaele, verwendet %d)', [PinId, MaxCh, FCapture.Channels]));
    end
    else if (Flow = KSPIN_DATAFLOW_IN) and (FRender.PinId = $FFFFFFFF) then
    begin
      FRender.PinId := PinId;
      FRender.Channels := MaxCh;
      if FRender.Channels > C_ISLA_MAX_OUTPUT_CHANNELS then
        FRender.Channels := C_ISLA_MAX_OUTPUT_CHANNELS;
      S2400Log(Format('Render-Pin: %d (bis %d Kanaele, verwendet %d)', [PinId, MaxCh, FRender.Channels]));
    end;
  end;

  if FCapture.PinId = $FFFFFFFF then
    Fail('Kein Capture-Pin mit 16 Bit / 48 kHz PCM gefunden.')
  else if FRender.PinId = $FFFFFFFF then
    Fail('Kein Render-Pin mit 16 Bit / 48 kHz PCM gefunden.')
  else
    Result := True;
end;

function TS2400KsEngine.OpenStream(var AStream: TS2400KsStream; const AName: string): Boolean;
var
  RawStatus: LongInt;
  State: ULONG;
  NotifySupported: LongBool;
  RtBuf: TKSRtAudioBuffer;
  Requested: ULONG;
  HwLat: TKSRtAudioHwLatency;
  Err: DWORD;
begin
  Result := False;
  AStream.BytesPerFrame := C_ISLA_BYTES_PER_SAMPLE * AStream.Channels;

  if not OpenWavePin(FFilter, AStream.PinId, AStream.Channels, C_ISLA_BITS_PER_SAMPLE,
    C_ISLA_SAMPLE_RATE, GENERIC_READ or GENERIC_WRITE, AStream.Handle, RawStatus) then
  begin
    AStream.Handle := 0;
    Fail(Format('%s: KsCreatePin (Pin %d, %d Kanaele) fehlgeschlagen, NTSTATUS=$%.8x. ' +
      'Belegt ein anderes Programm das Geraet?',
      [AName, AStream.PinId, AStream.Channels, Cardinal(RawStatus)]));
    Exit;
  end;

  if GetPinState(AStream.Handle, State) then
    S2400Log(Format('%s: Pin geoeffnet, Zustand %d', [AName, State]));
  if QueryNotificationSupport(AStream.Handle, NotifySupported) then
    S2400Log(Format('%s: Notification-Unterstuetzung = %s', [AName, BoolToStr(NotifySupported, True)]));

  // Ringpuffer = 2 Pakete a FDesiredBufferFrames - noch im Zustand STOP
  Requested := FDesiredBufferFrames * C_KS_PACKETS_PER_BUFFER * ULONG(AStream.BytesPerFrame);
  if not GetRtAudioBufferWithNotification(AStream.Handle, Requested, C_KS_PACKETS_PER_BUFFER, RtBuf) then
  begin
    Err := GetLastError;
    Fail(Format('%s: Ringpuffer mit Notification (%d Bytes) nicht erhalten, GetLastError=%d',
      [AName, Requested, Err]));
    Exit;
  end;

  AStream.Buffer := RtBuf.BufferAddress;
  AStream.BufferBytes := RtBuf.ActualBufferSize;
  AStream.CallMemoryBarrier := RtBuf.CallMemoryBarrier;
  AStream.PacketBytes := AStream.BufferBytes div C_KS_PACKETS_PER_BUFFER;
  if (AStream.Buffer = nil) or (AStream.PacketBytes = 0) or
     (AStream.PacketBytes mod ULONG(AStream.BytesPerFrame) <> 0) then
  begin
    Fail(Format('%s: unbrauchbarer Ringpuffer (Adresse %p, %d Bytes)',
      [AName, AStream.Buffer, AStream.BufferBytes]));
    Exit;
  end;
  AStream.PacketFrames := AStream.PacketBytes div ULONG(AStream.BytesPerFrame);
  S2400Log(Format('%s: Ringpuffer %d Bytes (angefragt %d), Paket = %d Frames, CallMemoryBarrier=%s',
    [AName, AStream.BufferBytes, Requested, AStream.PacketFrames, BoolToStr(AStream.CallMemoryBarrier, True)]));

  AStream.Event := CreateEventW(nil, False, False, nil); // Auto-Reset
  if AStream.Event = 0 then
  begin
    Fail(Format('%s: CreateEvent fehlgeschlagen, GetLastError=%d', [AName, GetLastError]));
    Exit;
  end;
  if not RegisterNotificationEvent(AStream.Handle, AStream.Event) then
  begin
    Fail(Format('%s: RegisterNotificationEvent fehlgeschlagen, GetLastError=%d', [AName, GetLastError]));
    Exit;
  end;
  AStream.EventRegistered := True;

  // vom Treiber gemeldete Hardware-Latenz (FIFO + Chipsatz + Codec)
  AStream.HwLatencyFrames := 0;
  if GetRtAudioHwLatency(AStream.Handle, HwLat) then
  begin
    AStream.HwLatencyFrames := Integer(HwLat.FifoSize div ULONG(AStream.BytesPerFrame)) +
      Round((Int64(HwLat.ChipsetDelay) + Int64(HwLat.CodecDelay)) * C_ISLA_SAMPLE_RATE / 10000000);
    S2400Log(Format('%s: HWLATENCY FifoSize=%d Bytes, ChipsetDelay=%d, CodecDelay=%d (x100ns) -> %d Frames',
      [AName, HwLat.FifoSize, HwLat.ChipsetDelay, HwLat.CodecDelay, AStream.HwLatencyFrames]));
  end
  else
    S2400Log(Format('%s: HWLATENCY nicht verfuegbar (GetLastError=%d) - nur Puffer-Latenz wird gemeldet',
      [AName, GetLastError]));

  Result := True;
end;

// faehrt einen Pin vom TATSAECHLICHEN Zustand aus auf STOP herunter
procedure TS2400KsEngine.StopStream(var AStream: TS2400KsStream);
var
  State: ULONG;
begin
  if AStream.Handle = 0 then
    Exit;
  if GetPinState(AStream.Handle, State) and (State > KSSTATE_STOP) and (State <= KSSTATE_RUN) then
    SetPinStateSequential(AStream.Handle, State, KSSTATE_STOP, nil);
end;

procedure TS2400KsEngine.CloseStream(var AStream: TS2400KsStream);
var
  PinId: ULONG;
  Channels: Integer;
begin
  StopStream(AStream);
  if (AStream.Handle <> 0) and AStream.EventRegistered then
    UnregisterNotificationEvent(AStream.Handle, AStream.Event);
  if AStream.Handle <> 0 then
    CloseHandle(AStream.Handle); // gibt laut Doku auch den Ringpuffer frei
  if AStream.Event <> 0 then
    CloseHandle(AStream.Event);

  PinId := AStream.PinId;
  Channels := AStream.Channels;
  ResetStream(AStream);
  AStream.PinId := PinId;
  AStream.Channels := Channels;
end;

function TS2400KsEngine.Open: Boolean;
var
  Path: string;
  Count: ULONG;
begin
  Result := False;
  if FIsOpen then
    Exit(True);

  S2400Log(Format('KS-Engine Open: gewuenschte Puffergroesse %d Frames', [FDesiredBufferFrames]));

  Path := FindFilterPath;
  if Path = '' then
  begin
    Fail('ISLA S2400 nicht gefunden (kein KS-Audiofilter mit VID_0483&PID_A21D). ' +
      'Ist das Geraet angeschlossen und eingeschaltet?');
    Exit;
  end;

  FFilter := OpenKsFilter(Path);
  if FFilter = INVALID_HANDLE_VALUE then
  begin
    Fail(Format('KS-Filter konnte nicht geoeffnet werden, GetLastError=%d', [GetLastError]));
    Exit;
  end;

  if not FindStreamPins or
     not OpenStream(FCapture, 'Capture') or
     not OpenStream(FRender, 'Render') then
  begin
    Close;
    Exit;
  end;

  if FCapture.PacketFrames <> FRender.PacketFrames then
  begin
    Fail(Format('Paketgroessen passen nicht zusammen: Capture %d, Render %d Frames',
      [FCapture.PacketFrames, FRender.PacketFrames]));
    Close;
    Exit;
  end;
  FBufferSizeFrames := FCapture.PacketFrames;

  // Render-Paketzaehler testen (im Zustand STOP laut Doku 0)
  FRenderUsePacketCount := GetRtAudioPacketCount(FRender.Handle, Count);
  if FRenderUsePacketCount then
    S2400Log(Format('Render: PACKETCOUNT unterstuetzt (aktuell %d)', [Count]))
  else
    S2400Log(Format('Render: PACKETCOUNT NICHT unterstuetzt (GetLastError=%d) - ' +
      'Render-Paket wird ueber den eigenen Zykluszaehler bestimmt', [GetLastError]));
  FRenderUseSetWritePacket := True; // wird beim ersten "nicht unterstuetzt" abgeschaltet

  FIsOpen := True;
  Result := True;
  S2400Log(Format('KS-Engine Open: OK - %d Eingaenge, %d Ausgaenge, Puffer %d Frames, HW-Latenz Ein %d / Aus %d Frames',
    [FCapture.Channels, FRender.Channels, FBufferSizeFrames, FCapture.HwLatencyFrames, FRender.HwLatencyFrames]));
end;

procedure TS2400KsEngine.Close;
begin
  StopStreaming;
  CloseStream(FRender);
  CloseStream(FCapture);
  if FFilter <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FFilter);
    FFilter := INVALID_HANDLE_VALUE;
  end;
  FIsOpen := False;
end;

function TS2400KsEngine.StartStreaming: Boolean;
var
  Err: DWORD;
begin
  Result := False;
  if not FIsOpen then
  begin
    Fail('StartStreaming: Engine ist nicht geoeffnet.');
    Exit;
  end;
  if FIsStarted then
    Exit(True);

  ResetEvent(FAbortEvent);
  FillChar(FRender.Buffer^, FRender.BufferBytes, 0); // mit Stille starten

  FCaptureMoreData := False;
  FLastCapturePacket := -1;
  FLastCaptureQpc := 0;
  FCaptureCycles := 0;
  FDroppedCapturePackets := 0;
  FDroppedAtStartup := 0;
  FMoreDataCount := 0;
  FCaptureReadErrors := 0;
  FCaptureFirstError := 0;
  FRenderCycle := 0;
  FRenderTargetPacket := 0;
  FRenderLateWrites := 0;
  FRenderLateAtStartup := 0;
  FRenderFirstError := 0;
  FRenderSetWriteUnsupportedError := 0;
  FCycleInfoCount := 0;
  FStartTick := GetTickCount64;

  if not QueryPerformanceFrequency(FQpcFreq) then
    FQpcFreq := 0;
  FExpectedPacketQpc := (FQpcFreq * Int64(FCapture.PacketFrames)) div C_ISLA_SAMPLE_RATE;
  FFirstPacketNumber := -1;
  FFirstPacketQpc := 0;
  FPrevPacketQpc := 0;
  FMinPacketDelta := High(Int64);
  FMaxPacketDelta := 0;
  FQpcGaps := 0;
  FQpcGapExcess := 0;
  FFirstReadQpc := 0;
  FLastReadQpc := 0;

  // Beide Pins bis PAUSE vorbereiten, dann Render und UNMITTELBAR danach
  // Capture auf RUN: Render laeuft damit minimal voraus. Weil der Thread
  // vom Capture-Event getaktet wird, bleibt so fuer das naechste Render-
  // Paket fast eine volle Paketlaenge Zeit (siehe WriteRenderBuffer).
  if not SetPinStateSequential(FRender.Handle, KSSTATE_STOP, KSSTATE_PAUSE, nil) or
     not SetPinStateSequential(FCapture.Handle, KSSTATE_STOP, KSSTATE_PAUSE, nil) or
     not SetPinStateSequential(FRender.Handle, KSSTATE_PAUSE, KSSTATE_RUN, nil) or
     not SetPinStateSequential(FCapture.Handle, KSSTATE_PAUSE, KSSTATE_RUN, nil) then
  begin
    Err := GetLastError;
    Fail(Format('StartStreaming: Zustandswechsel fehlgeschlagen, GetLastError=%d', [Err]));
    StopStream(FCapture);
    StopStream(FRender);
    Exit;
  end;

  FIsStarted := True;
  Result := True;
  S2400Log('KS-Engine: Streaming gestartet (beide Pins in RUN, per GET bestaetigt).');
end;

procedure TS2400KsEngine.StopStreaming;
begin
  if not FIsStarted then
    Exit;
  StopStream(FCapture);
  StopStream(FRender);
  FIsStarted := False;
  LogStreamingSummary;
end;

// Bilanz eines Streaming-Laufs - wird ausserhalb des Echtzeit-Threads
// geschrieben (StopStreaming laeuft im Host-Thread, nachdem der
// Streaming-Thread beendet ist)
procedure TS2400KsEngine.LogStreamingSummary;
var
  I: Integer;
  Seconds: Double;
begin
  for I := 0 to FCycleInfoCount - 1 do
    S2400Log(Format('Zyklus %d: Capture-Paket %d, Render-Zaehler %s -> Render-Paket %d',
      [I + 1, FCycleInfo[I].CapturePacket, BoolToStr(FCycleInfo[I].HaveRenderCount, True),
       FCycleInfo[I].RenderTargetPacket]));

  Seconds := (GetTickCount64 - FStartTick) / 1000;
  S2400Log(Format('KS-Engine: Streaming gestoppt nach %.1f s, %d Zyklen a %d Frames',
    [Seconds, FCaptureCycles, FBufferSizeFrames]));
  S2400Log(Format('  Capture: verlorene Pakete %d (davon Startphase %d, Dauerbetrieb %d), ' +
    'Aufholzyklen (MoreData) %d, GetReadPacket-Fehler %d (erster Code %d)',
    [FDroppedCapturePackets, FDroppedAtStartup, FDroppedCapturePackets - FDroppedAtStartup,
     FMoreDataCount, FCaptureReadErrors, FCaptureFirstError]));
  // Abtastrate auf zwei unabhaengigen Wegen:
  //  - laut Treiber-Zeitstempeln: Paketnummern-Differenz / Zeitstempel-Differenz
  //  - laut eigener Uhr: tatsaechlich gelesene Pakete / eigene Lesezeit
  // Weichen beide von 48000 ab bzw. voneinander ab, fehlt Audio, das die
  // Paketnummern nicht zeigen.
  if (FQpcFreq > 0) and (FFirstPacketNumber >= 0) and (FPrevPacketQpc > FFirstPacketQpc) then
    S2400Log(Format('  Abtastrate laut Treiber-Zeitstempeln: %.1f Hz (%d Pakete in %.3f s)',
      [(FLastCapturePacket - FFirstPacketNumber) * Int64(FCapture.PacketFrames) /
        ((FPrevPacketQpc - FFirstPacketQpc) / FQpcFreq),
       FLastCapturePacket - FFirstPacketNumber, (FPrevPacketQpc - FFirstPacketQpc) / FQpcFreq]));
  if (FQpcFreq > 0) and (FLastReadQpc > FFirstReadQpc) and (FCaptureCycles > 1) then
    S2400Log(Format('  Abtastrate laut eigener Uhr (gelesene Pakete): %.1f Hz (%d Pakete in %.3f s)',
      [(FCaptureCycles - 1) * Int64(FCapture.PacketFrames) / ((FLastReadQpc - FFirstReadQpc) / FQpcFreq),
       FCaptureCycles - 1, (FLastReadQpc - FFirstReadQpc) / FQpcFreq]));
  if (FQpcFreq > 0) and (FMaxPacketDelta > 0) then
    S2400Log(Format('  Paketabstand laut Zeitstempeln: Soll %.3f ms, min %.3f ms, max %.3f ms; ' +
      'versteckte Luecken (> 1,5 x Soll): %d, fehlendes Audio darin %.1f ms',
      [FExpectedPacketQpc * 1000 / FQpcFreq, FMinPacketDelta * 1000 / FQpcFreq,
       FMaxPacketDelta * 1000 / FQpcFreq, FQpcGaps, FQpcGapExcess * 1000 / FQpcFreq]));

  if FRenderSetWriteUnsupportedError <> 0 then
    S2400Log(Format('  Render: SETWRITEPACKET nicht unterstuetzt (Code %d), daher keine Spaet-Erkennung',
      [FRenderSetWriteUnsupportedError]))
  else
    S2400Log(Format('  Render: zu spaet geschriebene Pakete %d (davon Startphase %d, Dauerbetrieb %d), erster Code %d',
      [FRenderLateWrites, FRenderLateAtStartup, FRenderLateWrites - FRenderLateAtStartup, FRenderFirstError]));
end;

procedure TS2400KsEngine.AbortStreaming;
begin
  if FAbortEvent <> 0 then
    SetEvent(FAbortEvent);
end;

function TS2400KsEngine.WaitForCaptureReady(ATimeoutMs: Cardinal): Boolean;
var
  Handles: array[0..1] of THandle;
begin
  if not FIsStarted then
    Exit(False);
  Handles[0] := FCapture.Event;
  Handles[1] := FAbortEvent;
  Result := WaitForMultipleObjects(2, @Handles[0], False, ATimeoutMs) = WAIT_OBJECT_0;
end;

function TS2400KsEngine.ReadCaptureBuffer(out AData: PByte; out AFrames: Cardinal): Boolean;
var
  Info: TKSRtAudioGetReadPacketInfo;
  Err: DWORD;
  ReadQpc, Delta: Int64;
begin
  AData := nil;
  AFrames := 0;
  FCaptureMoreData := False;

  if not GetRtAudioReadPacket(FCapture.Handle, Info) then
  begin
    Err := GetLastError;
    // ERROR_NOT_READY = laut Doku "noch kein neues Paket" - kein echter Fehler
    if Err <> ERROR_NOT_READY then
    begin
      Inc(FCaptureReadErrors);
      if FCaptureFirstError = 0 then
        FCaptureFirstError := Err;
    end;
    Exit(False);
  end;

  Inc(FCaptureCycles);
  if (FLastCapturePacket >= 0) and (Int64(Info.PacketNumber) > FLastCapturePacket + 1) then
  begin
    Inc(FDroppedCapturePackets, Int64(Info.PacketNumber) - FLastCapturePacket - 1);
    if FCaptureCycles <= C_STARTUP_CYCLES then
      Inc(FDroppedAtStartup, Int64(Info.PacketNumber) - FLastCapturePacket - 1);
  end;
  FLastCapturePacket := Info.PacketNumber;
  FLastCaptureQpc := Info.PerformanceCounterValue;
  FCaptureMoreData := Info.MoreData;
  if Info.MoreData then
    Inc(FMoreDataCount);

  // Zeitstempel-Analyse (nur Zaehler, kein Logging im Echtzeit-Thread)
  QueryPerformanceCounter(ReadQpc);
  if FFirstReadQpc = 0 then
    FFirstReadQpc := ReadQpc;
  FLastReadQpc := ReadQpc;
  if Info.PerformanceCounterValue <> 0 then
  begin
    if FFirstPacketNumber < 0 then
    begin
      FFirstPacketNumber := Info.PacketNumber;
      FFirstPacketQpc := Info.PerformanceCounterValue;
    end
    else if (FPrevPacketQpc <> 0) and (FCaptureCycles > C_STARTUP_CYCLES) then
    begin
      Delta := Int64(Info.PerformanceCounterValue) - Int64(FPrevPacketQpc);
      if Delta < FMinPacketDelta then
        FMinPacketDelta := Delta;
      if Delta > FMaxPacketDelta then
        FMaxPacketDelta := Delta;
      if (FExpectedPacketQpc > 0) and (Delta > (FExpectedPacketQpc * 3) div 2) then
      begin
        Inc(FQpcGaps);
        Inc(FQpcGapExcess, Delta - FExpectedPacketQpc);
      end;
    end;
    FPrevPacketQpc := Info.PerformanceCounterValue;
  end;

  if FCapture.CallMemoryBarrier then
    FullMemoryBarrier;

  AData := FCapture.Buffer + (Info.PacketNumber mod C_KS_PACKETS_PER_BUFFER) * FCapture.PacketBytes;
  AFrames := FCapture.PacketFrames;
  Result := True;
end;

function TS2400KsEngine.WriteRenderBuffer(out AData: PByte; AFrames: Cardinal): Boolean;
var
  Count: ULONG;
  HaveCount: Boolean;
begin
  Inc(FRenderCycle);

  // Laut Doku zu KSPROPERTY_RTAUDIO_PACKETCOUNT: Zaehler N = Pakete 0..N-1
  // fertig, Paket N laeuft gerade -> Paket N+1 schreiben. Faellt die
  // Abfrage aus, ersetzt der eigene Zykluszaehler sie (Zyklus k ~ Zaehler k).
  HaveCount := FRenderUsePacketCount and GetRtAudioPacketCount(FRender.Handle, Count);
  if HaveCount then
    FRenderTargetPacket := Count + 1
  else
    FRenderTargetPacket := FRenderCycle + 1;

  // die ersten Zyklen merken (Phasenlage Capture/Render) - geloggt wird
  // erst beim Stoppen, nicht hier im Echtzeit-Thread
  if FCycleInfoCount <= High(FCycleInfo) then
  begin
    FCycleInfo[FCycleInfoCount].CapturePacket := FLastCapturePacket;
    FCycleInfo[FCycleInfoCount].HaveRenderCount := HaveCount;
    FCycleInfo[FCycleInfoCount].RenderTargetPacket := FRenderTargetPacket;
    Inc(FCycleInfoCount);
  end;

  AData := FRender.Buffer + (FRenderTargetPacket mod C_KS_PACKETS_PER_BUFFER) * FRender.PacketBytes;
  Result := True;
end;

procedure TS2400KsEngine.ReleaseRenderBuffer;
var
  Err: DWORD;
begin
  if not FRenderUseSetWritePacket then
    Exit;
  if SetRtAudioWritePacket(FRender.Handle, FRenderTargetPacket) then
    Exit;

  Err := GetLastError;
  if IsUnsupportedError(Err) then
  begin
    // laut Doku optional - der Treiber streamt auch ohne
    FRenderUseSetWritePacket := False;
    FRenderSetWriteUnsupportedError := Err;
  end
  else
  begin
    // vermutlich STATUS_DATA_LATE_ERROR/STATUS_DATA_OVERRUN -> Win32 1117
    // (laut Doku zu PACKETCOUNT die Datenfluss-Fehler von SetWritePacket)
    Inc(FRenderLateWrites);
    if FRenderCycle <= C_STARTUP_CYCLES then
      Inc(FRenderLateAtStartup);
    if FRenderFirstError = 0 then
      FRenderFirstError := Err;
  end;
end;

initialization
  GLogLock := TCriticalSection.Create;

finalization
  FreeAndNil(GLogLock);

end.
