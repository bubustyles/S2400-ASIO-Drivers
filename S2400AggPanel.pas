unit S2400AggPanel;

// =============================================================================
// S2400AggPanel.pas - Einstellungsfenster des Verbund-Treibers "S2400 Aggregate"
//
// Etappe D (30.10.2026): eigenes, dunkles Design nach dem abgestimmten
// Entwurf - komplett selbst gezeichnet (S2400UiKit), dunkle Titelleiste,
// keine Windows-Standardgrafik. Umlaute als #$00xx-Escapes.
// Etappe C (30.10.2026): Bereich "Windows-Ausgang" (z.B. Realtek), dafuer
// zweispaltig, damit das Fenster nicht zu hoch wird.
// Isla-Monitoring (05./06.11.2026): dritte Spalte - Zustand und Knopf
// "Mixer & Matrix" (Fenster in S2400AggMixer.pas, Aenderungen gelten sofort).
//
// Aufbau:
//   Kopf      Wellen-Symbol, Name, Geraete, Statuspille (live)
//   Status    Kacheln Samplerate / Puffer / Latenz Ein / Isla-Takt (live)
//             Fuellstandsbalken Eingang / Ausgang / Windows (live)
//   links     Master-Geraet, Windows-Ausgang
//   Mitte     ISLA S2400, Laufzeitausgleich
//   rechts    Isla-Monitoring
//   Fuss      Abbrechen / Uebernehmen
//
// Die Live-Werte holt ein Timer (250 ms) ueber AStatus vom Treiber - der
// Treiber liefert dabei nur zwischengespeicherte Werte und ruft NICHT in den
// fremden Master-Treiber hinein.
// =============================================================================

interface

uses
  Winapi.Windows,
  Winapi.DwmApi,
  System.SysUtils,
  System.Classes,
  System.UITypes,
  System.Math,
  Vcl.Graphics,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  S2400UiKit,
  S2400Lang,
  S2400AsioLogo,
  S2400WasapiOut,    // TS2400WinDevice
  S2400ControlPanel; // C_S2400_BUFFER_OPTIONS, NearestAllowedBufferSize, C_MAX_EXTRA_LATENCY

type
  TS2400AggPanelResult = (aprCancel, aprOk, aprMasterPanel);

  // Einstellungen, die das Fenster aendern kann
  TS2400AggSettings = record
    Master: string;
    IslaEnabled: Boolean;
    IslaPacket: Cardinal;
    ReserveHigh: Boolean;
    AlignInputs: Boolean;
    IslaExtraIn: Integer;
    WinEnabled: Boolean;
    WinDeviceId: string;
    WinExclusive: Boolean;
  end;

  // Momentaufnahme fuer die Live-Anzeige
  TS2400AggStatus = record
    Running: Boolean;
    MasterName: string;      // Name wie in der Liste (Registry)
    SampleRate: Double;
    BufferFrames: Integer;
    InLatency: Integer;      // gemeldete Eingangslatenz (Frames)
    MasterIn, MasterOut: Integer;
    IslaPresent: Boolean;    // Isla geoeffnet
    IslaSync: Boolean;       // Takt-Angleichung laeuft
    CapPpm, RenPpm: Double;
    CapLevel, CapTarget: Double;
    RenLevel, RenTarget: Double;
    CapUnderruns, RenUnderruns: Int64;
    WinPresent: Boolean;     // Windows-Ausgang eingebunden
    WinSync: Boolean;        // Windows-Ausgang laeuft
    WinName: string;
    WinFormat: string;       // z.B. "exklusiv, 48000 Hz, 24/24 Bit"
    WinPpm: Double;
    WinLevel, WinTarget: Double;
    WinUnderruns: Int64;
    MonEnabled: Boolean;     // Isla-Monitoring eingeschaltet
    MonActive: Boolean;      // Monitoring laeuft gerade
    MonLatencyMs: Double;    // Isla-Ton bis zum Ausgang des Masters (0 = unbekannt)
  end;
  TS2400AggStatusFunc = reference to function: TS2400AggStatus;
  // oeffnet den Isla-Mixer (vom Treiber, modal ueber AOwner)
  TS2400OpenMixerProc = reference to procedure(AOwner: HWND);

// Zeigt das Fenster modal. ASettings ist Vorbelegung und enthaelt danach
// die (ggf. geaenderten) Werte - auch bei aprMasterPanel (dann soll der
// Aufrufer die Werte uebernehmen UND das Fenster des Master-Geraets oeffnen).
// AOpenMixer: oeffnet den Isla-Mixer (Knopf "Mixer & Matrix").
function ShowS2400AggPanel(AOwnerWnd: HWND; const AStatus: TS2400AggStatusFunc;
  const AMasterNames: TArray<string>; const AWinDevices: TArray<TS2400WinDevice>;
  const AOpenMixer: TS2400OpenMixerProc; var ASettings: TS2400AggSettings): TS2400AggPanelResult;

implementation

const
  // dunkle Titelleiste (Windows 10 20H1+ / Windows 11), Farbe der Titelleiste (Windows 11)
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  DWMWA_CAPTION_COLOR = 35;
  DWMWA_TEXT_COLOR = 36;

type
  TS2400Line = record
    X1, Y1, X2, Y2: Integer;
  end;

  TS2400AggPanelForm = class(TForm)
  private
    FStatus: TS2400AggStatusFunc;
    FMasterNames: TArray<string>;
    FWinDevices: TArray<TS2400WinDevice>;
    FOpenMixer: TS2400OpenMixerProc;
    FLines: TArray<TS2400Line>;
    FTimer: TTimer;
    FLastCapUnder, FLastRenUnder, FLastWinUnder: Int64;
    FHaveUnder: Boolean;
    FErrorUntil: UInt64;

    procedure AddLine(AX1, AY1, AX2, AY2: Integer);
    function AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
      AColor: TColor; ASemibold: Boolean = False): TLabel;
    procedure FormPaint(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure TimerTick(Sender: TObject);
    procedure MasterButtonClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure MixerButtonClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
  public
    WaveIcon: TS2400WaveIcon;
    LabelTitle, LabelSub: TLabel;
    Pill: TS2400Pill;
    TileRate, TileBuffer, TileLatency, TilePpm: TS2400StatTile;
    BarIn, BarOut, BarWin: TS2400LevelBar;
    MasterList: TS2400DeviceList;
    ButtonMaster: TS2400Button;
    ToggleWin: TS2400Toggle;
    WinList: TS2400DeviceList;
    ToggleExclusive: TS2400Toggle;
    LabelWinState: TLabel;
    ToggleIsla: TS2400Toggle;
    SegPacket: TS2400Segment;
    SegReserve: TS2400Segment;
    ToggleAlign: TS2400Toggle;
    StepExtra: TS2400Stepper;
    LabelHint: TLabel;
    ButtonMixer: TS2400Button;
    LabelMonState: TLabel;
    ButtonCancel, ButtonOk: TS2400Button;
    constructor CreatePanel(AOwner: TComponent; const AStatus: TS2400AggStatusFunc;
      const AMasterNames: TArray<string>; const AWinDevices: TArray<TS2400WinDevice>;
      const AOpenMixer: TS2400OpenMixerProc);
    destructor Destroy; override;
    procedure IslaToggleChange(Sender: TObject);
    procedure AlignToggleChange(Sender: TObject);
    procedure WinToggleChange(Sender: TObject);
    procedure UpdateStatus;
  end;

// ---------------------------------------------------------------------------
// Aufbau
// ---------------------------------------------------------------------------

constructor TS2400AggPanelForm.CreatePanel(AOwner: TComponent; const AStatus: TS2400AggStatusFunc;
  const AMasterNames: TArray<string>; const AWinDevices: TArray<TS2400WinDevice>;
  const AOpenMixer: TS2400OpenMixerProc);
var
  Y, YTop, YL, YR, Y3, X, W, M, CW, XL, XR, X3, TileW, I, Gap: Integer;
  Items: TArray<string>;
begin
  inherited CreateNew(AOwner);
  FStatus := AStatus;
  FMasterNames := Copy(AMasterNames);
  FWinDevices := Copy(AWinDevices);
  FOpenMixer := AOpenMixer;

  Scaled := False; // alle Masse rechnet Sc() selbst um
  BorderStyle := bsDialog;
  BorderIcons := [biSystemMenu];
  Position := poScreenCenter;
  Caption := 'S2400 Aggregate';
  Color := C_UI_BG;
  DoubleBuffered := True;
  KeyPreview := True;
  UiSetFont(Font, 9, C_UI_TEXT);
  OnPaint := FormPaint;
  OnKeyDown := FormKeyDown;

  M := Sc(18);                 // Seitenrand
  Gap := Sc(28);               // Abstand der Spalten
  ClientWidth := Sc(1200);
  W := ClientWidth - 2 * M;    // Inhaltsbreite
  CW := (W - 2 * Gap) div 3;   // Spaltenbreite
  XL := M;
  XR := M + CW + Gap;          // mittlere Spalte (Isla)
  X3 := M + 2 * (CW + Gap);    // rechte Spalte (Monitoring)

  // --- Kopf ---
  WaveIcon := TS2400WaveIcon.Create(Self);
  WaveIcon.Parent := Self;
  WaveIcon.SetBounds(M, Sc(16), Sc(28), Sc(28));
  LabelTitle := AddLabel(M + Sc(40), Sc(12), Sc(400), Sc(22), 'S2400 Aggregate', 12, C_UI_TEXT, True);
  LabelSub := AddLabel(M + Sc(40), Sc(34), Sc(560), Sc(18), '', 8, C_UI_MUTED);
  Pill := TS2400Pill.Create(Self);
  Pill.Parent := Self;
  Pill.SetStatus(usOff, Tr('Gestoppt', 'Stopped'));
  Pill.SetBounds(ClientWidth - M - Sc(130), Sc(17), Sc(130), Sc(26));
  Y := Sc(60);
  AddLine(0, Y, ClientWidth, Y);
  Inc(Y, Sc(12));

  // --- Status: Kacheln ---
  TileW := (W - 3 * Sc(8)) div 4;
  TileRate := TS2400StatTile.Create(Self);
  TileBuffer := TS2400StatTile.Create(Self);
  TileLatency := TS2400StatTile.Create(Self);
  TilePpm := TS2400StatTile.Create(Self);
  TileRate.Caption := Tr('Samplerate', 'Sample rate');
  TileBuffer.Caption := Tr('Puffer', 'Buffer');
  TileLatency.Caption := Tr('Latenz Ein', 'Input latency');
  TilePpm.Caption := Tr('Isla-Takt', 'Isla clock');
  X := M;
  for I := 0 to 3 do
  begin
    case I of
      0: TileRate.SetBounds(X, Y, TileW, Sc(52));
      1: TileBuffer.SetBounds(X, Y, TileW, Sc(52));
      2: TileLatency.SetBounds(X, Y, TileW, Sc(52));
      3: TilePpm.SetBounds(X, Y, W - 3 * (TileW + Sc(8)), Sc(52));
    end;
    Inc(X, TileW + Sc(8));
  end;
  TileRate.Parent := Self;
  TileBuffer.Parent := Self;
  TileLatency.Parent := Self;
  TilePpm.Parent := Self;
  Inc(Y, Sc(52) + Sc(12));

  // --- Status: Fuellstandsbalken ---
  BarIn := TS2400LevelBar.Create(Self);
  BarIn.Parent := Self;
  BarIn.Caption := Tr('Eingang', 'Input');
  BarIn.SetBounds(M, Y, W, Sc(22));
  Inc(Y, Sc(26));
  BarOut := TS2400LevelBar.Create(Self);
  BarOut.Parent := Self;
  BarOut.Caption := Tr('Ausgang', 'Output');
  BarOut.SetBounds(M, Y, W, Sc(22));
  Inc(Y, Sc(26));
  BarWin := TS2400LevelBar.Create(Self);
  BarWin.Parent := Self;
  BarWin.Caption := 'Windows';
  BarWin.SetBounds(M, Y, W, Sc(22));
  Inc(Y, Sc(22) + Sc(8));
  AddLine(0, Y, ClientWidth, Y);
  Inc(Y, Sc(12));

  YTop := Y;
  YL := Y;
  YR := Y;
  Y3 := Y;

  // ===== linke Spalte =====
  // --- Master ---
  AddLabel(XL, YL + Sc(3), CW, Sc(18), Tr('Master-Ger'#$00E4't (Taktgeber)', 'Master device (clock source)'), 8, C_UI_MUTED);
  Inc(YL, Sc(26));
  MasterList := TS2400DeviceList.Create(Self);
  MasterList.Parent := Self;
  MasterList.MaxVisible := 5;
  MasterList.SetData(FMasterNames, nil);
  MasterList.SetBounds(XL, YL, CW, MasterList.PreferredHeight);
  Inc(YL, MasterList.Height + Sc(8));
  ButtonMaster := TS2400Button.Create(Self);
  ButtonMaster.Parent := Self;
  ButtonMaster.Caption := Tr('Einstellungen des Master-Ger'#$00E4'ts', 'Master device settings');
  ButtonMaster.Glyph := #$E713; // Zahnrad (Segoe MDL2 Assets)
  ButtonMaster.SetBounds(XL, YL, ButtonMaster.PreferredWidth, Sc(30));
  ButtonMaster.OnClick := MasterButtonClick;
  Inc(YL, Sc(30) + Sc(10));
  AddLine(XL, YL, XL + CW, YL);
  Inc(YL, Sc(12));

  // --- Windows-Ausgang ---
  AddLabel(XL, YL + Sc(3), Sc(220), Sc(18), Tr('Windows-Ausgang (optional)', 'Windows output (optional)'), 8, C_UI_MUTED);
  ToggleWin := TS2400Toggle.Create(Self);
  ToggleWin.Parent := Self;
  ToggleWin.Caption := Tr('Einbinden', 'Include');
  ToggleWin.SetBounds(XL + CW - Sc(150), YL, Sc(150), Sc(24));
  ToggleWin.OnChange := WinToggleChange;
  Inc(YL, Sc(32));
  WinList := TS2400DeviceList.Create(Self);
  WinList.Parent := Self;
  WinList.MaxVisible := 3;
  SetLength(Items, Length(FWinDevices));
  for I := 0 to High(FWinDevices) do
    Items[I] := FWinDevices[I].Name;
  WinList.SetData(Items, nil);
  WinList.SetBounds(XL, YL, CW, WinList.PreferredHeight);
  Inc(YL, WinList.Height + Sc(8));
  ToggleExclusive := TS2400Toggle.Create(Self);
  ToggleExclusive.Parent := Self;
  ToggleExclusive.Caption := Tr('Exklusiv-Modus (geringere Latenz)', 'Exclusive mode (lower latency)');
  ToggleExclusive.SetBounds(XL, YL, CW, Sc(24));
  Inc(YL, Sc(28));
  LabelWinState := AddLabel(XL, YL, CW, Sc(18), '', 8, C_UI_MUTED);
  Inc(YL, Sc(22));

  // ===== rechte Spalte =====
  // --- Isla ---
  AddLabel(XR, YR + Sc(3), Sc(200), Sc(18), 'ISLA S2400', 8, C_UI_MUTED);
  ToggleIsla := TS2400Toggle.Create(Self);
  ToggleIsla.Parent := Self;
  ToggleIsla.Caption := Tr('Einbinden', 'Include');
  ToggleIsla.SetBounds(XR + CW - Sc(150), YR, Sc(150), Sc(24));
  ToggleIsla.OnChange := IslaToggleChange;
  Inc(YR, Sc(32));
  AddLabel(XR, YR, CW, Sc(18), Tr('Paketgr'#$00F6#$00DF'e (Samples)', 'Packet size (samples)'), 9, C_UI_TEXT2);
  Inc(YR, Sc(22));
  SegPacket := TS2400Segment.Create(Self);
  SegPacket.Parent := Self;
  SetLength(Items, Length(C_S2400_BUFFER_OPTIONS));
  for I := 0 to High(C_S2400_BUFFER_OPTIONS) do
    Items[I] := IntToStr(C_S2400_BUFFER_OPTIONS[I]);
  SegPacket.Items := Items;
  SegPacket.SetBounds(XR, YR, CW, Sc(28));
  Inc(YR, Sc(36));
  with AddLabel(XR, YR, Sc(120), Sc(28), Tr('Reserve', 'Safety margin'), 9, C_UI_TEXT2) do
    Layout := tlCenter;
  SegReserve := TS2400Segment.Create(Self);
  SegReserve.Parent := Self;
  SegReserve.Items := [Tr('Normal 2 ms', 'Normal 2 ms'), Tr('Hoch 5 ms', 'High 5 ms')];
  SegReserve.Width := SegReserve.PreferredWidth + Sc(16);
  SegReserve.SetBounds(XR + CW - SegReserve.Width, YR, SegReserve.Width, Sc(28));
  Inc(YR, Sc(28) + Sc(12));
  AddLine(XR, YR, XR + CW, YR);
  Inc(YR, Sc(12));

  // --- Laufzeitausgleich ---
  AddLabel(XR, YR + Sc(3), Sc(200), Sc(18), Tr('Laufzeitausgleich', 'Latency alignment'), 8, C_UI_MUTED);
  ToggleAlign := TS2400Toggle.Create(Self);
  ToggleAlign.Parent := Self;
  ToggleAlign.Caption := Tr('Eing'#$00E4'nge angleichen', 'Align inputs');
  ToggleAlign.SetBounds(XR + CW - Sc(220), YR, Sc(220), Sc(24));
  ToggleAlign.OnChange := AlignToggleChange;
  Inc(YR, Sc(32));
  with AddLabel(XR, YR, Sc(200), Sc(28), Tr('Korrektur Isla-Eingang', 'Isla input correction'), 9, C_UI_TEXT2) do
    Layout := tlCenter;
  StepExtra := TS2400Stepper.Create(Self);
  StepExtra.Parent := Self;
  StepExtra.MinValue := -C_MAX_EXTRA_LATENCY;
  StepExtra.MaxValue := C_MAX_EXTRA_LATENCY;
  StepExtra.Suffix := ' Smp';
  StepExtra.SetBounds(XR + CW - Sc(140), YR, Sc(140), Sc(28));
  Inc(YR, Sc(36));
  LabelHint := AddLabel(XR, YR, CW, Sc(52),
    Tr('Wandler-/USB-Zeit der Isla laut Messung (positiv = Isla sp'#$00E4'ter). ' +
    'Umschalt = 10er-Schritte, Strg = 100er-Schritte, Mausrad geht auch. ' +
    'Der Windows-Ausgang wird bewusst nicht angeglichen.',
    'Converter/USB time of the Isla as measured (positive = Isla later). ' +
    'Shift = steps of 10, Ctrl = steps of 100, mouse wheel works too. ' +
    'The Windows output is intentionally not aligned.'), 8, C_UI_MUTED);
  LabelHint.WordWrap := True;
  Inc(YR, Sc(56));

  // ===== rechte Spalte: Isla-Monitoring =====
  AddLabel(X3, Y3 + Sc(3), Sc(200), Sc(18), Tr('Isla-Monitoring', 'Isla monitoring'), 8, C_UI_MUTED);
  Inc(Y3, Sc(32));
  ButtonMixer := TS2400Button.Create(Self);
  ButtonMixer.Parent := Self;
  ButtonMixer.Caption := Tr('Mixer & Matrix '#$00F6'ffnen', 'Open mixer & matrix');
  ButtonMixer.Glyph := #$E9E9; // Regler (Segoe MDL2 Assets)
  ButtonMixer.SetBounds(X3, Y3, Max(ButtonMixer.PreferredWidth, Sc(200)), Sc(30));
  ButtonMixer.OnClick := MixerButtonClick;
  ButtonMixer.Enabled := Assigned(FOpenMixer);
  Inc(Y3, Sc(30) + Sc(12));
  LabelMonState := AddLabel(X3, Y3, CW, Sc(70), '', 8, C_UI_MUTED);
  LabelMonState.WordWrap := True;
  Inc(Y3, Sc(74));
  with AddLabel(X3, Y3, CW, Sc(70),
    Tr('Im Mixer: je Isla-Kanal Pegel, Panorama und Ein/Aus, darunter die Matrix: ' +
    'welcher Kanal auf welches Ausgangspaar des Master-Ger'#$00E4'ts geht. Mehrere Ziele gleichzeitig m'#$00F6'glich.',
    'In the mixer: level, pan and on/off per Isla channel, below that the matrix: ' +
    'which channel goes to which output pair of the master device. Several destinations at once are possible.'),
    8, C_UI_MUTED) do
    WordWrap := True;
  Inc(Y3, Sc(74));

  // senkrechte Trennlinien zwischen den Spalten, dann waagerecht ueber dem Fuss
  Y := Max(Max(YL, YR), Y3);
  AddLine(M + CW + Gap div 2, YTop, M + CW + Gap div 2, Y);
  AddLine(M + 2 * CW + Gap + Gap div 2, YTop, M + 2 * CW + Gap + Gap div 2, Y);
  AddLine(0, Y, ClientWidth, Y);
  Inc(Y, Sc(12));

  // --- Fuss ---
  ButtonOk := TS2400Button.Create(Self);
  ButtonOk.Parent := Self;
  ButtonOk.Caption := Tr(#$00DC'bernehmen', 'Apply');
  ButtonOk.Primary := True;
  ButtonOk.Width := Max(Sc(110), ButtonOk.PreferredWidth);
  ButtonOk.SetBounds(ClientWidth - M - ButtonOk.Width, Y, ButtonOk.Width, Sc(30));
  ButtonOk.OnClick := OkClick;
  ButtonCancel := TS2400Button.Create(Self);
  ButtonCancel.Parent := Self;
  ButtonCancel.Caption := Tr('Abbrechen', 'Cancel');
  ButtonCancel.Width := Max(Sc(100), ButtonCancel.PreferredWidth);
  ButtonCancel.SetBounds(ButtonOk.Left - Sc(8) - ButtonCancel.Width, Y, ButtonCancel.Width, Sc(30));
  ButtonCancel.OnClick := CancelClick;
  // ASIO-Compatible-Logo mit Markenhinweis (Steinberg ASIO Usage Guidelines)
  AddAsioLogo(Self, M, Y + Sc(15));
  Inc(Y, Sc(30) + Sc(14));

  ClientHeight := Y;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 250;
  FTimer.OnTimer := TimerTick;
  FTimer.Enabled := Assigned(FStatus);
end;

destructor TS2400AggPanelForm.Destroy;
begin
  if FTimer <> nil then
    FTimer.Enabled := False;
  inherited Destroy;
end;

procedure TS2400AggPanelForm.CreateWnd;
var
  Dark: BOOL;
  Col: COLORREF;
begin
  inherited CreateWnd;
  // dunkle Titelleiste; Fehler (aeltere Windows-Versionen) bewusst ignorieren
  Dark := True;
  if DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, @Dark, SizeOf(Dark)) <> S_OK then
    DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, @Dark, SizeOf(Dark));
  Col := ColorToRGB(C_UI_BG);
  DwmSetWindowAttribute(Handle, DWMWA_CAPTION_COLOR, @Col, SizeOf(Col));
  Col := ColorToRGB(C_UI_TEXT);
  DwmSetWindowAttribute(Handle, DWMWA_TEXT_COLOR, @Col, SizeOf(Col));
end;

procedure TS2400AggPanelForm.AddLine(AX1, AY1, AX2, AY2: Integer);
var
  L: TS2400Line;
begin
  L.X1 := AX1;
  L.Y1 := AY1;
  L.X2 := AX2;
  L.Y2 := AY2;
  FLines := FLines + [L];
end;

function TS2400AggPanelForm.AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
  AColor: TColor; ASemibold: Boolean): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent := Self;
  Result.AutoSize := False;
  Result.Transparent := True;
  Result.ShowAccelChar := False;
  Result.SetBounds(AX, AY, AW, AH);
  UiSetFont(Result.Font, ASize, AColor, ASemibold);
  Result.Caption := AText;
end;

procedure TS2400AggPanelForm.FormPaint(Sender: TObject);
var
  L: TS2400Line;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_UI_BG;
  Canvas.FillRect(ClientRect);
  Canvas.Pen.Color := C_UI_LINE;
  Canvas.Pen.Width := 1;
  for L in FLines do
  begin
    Canvas.MoveTo(L.X1, L.Y1);
    Canvas.LineTo(L.X2, L.Y2);
  end;
end;

procedure TS2400AggPanelForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_ESCAPE then
  begin
    ModalResult := mrCancel;
    Key := 0;
  end
  else if Key = VK_RETURN then
  begin
    ModalResult := mrOk;
    Key := 0;
  end;
end;

procedure TS2400AggPanelForm.IslaToggleChange(Sender: TObject);
begin
  SegPacket.Enabled := ToggleIsla.Checked;
  SegReserve.Enabled := ToggleIsla.Checked;
end;

procedure TS2400AggPanelForm.AlignToggleChange(Sender: TObject);
begin
  StepExtra.Enabled := ToggleAlign.Checked;
end;

procedure TS2400AggPanelForm.WinToggleChange(Sender: TObject);
begin
  WinList.Enabled := ToggleWin.Checked;
  ToggleExclusive.Enabled := ToggleWin.Checked;
end;

// Isla-Mixer modal ueber diesem Fenster; Aenderungen dort gelten sofort
// (unabhaengig von Uebernehmen/Abbrechen hier)
procedure TS2400AggPanelForm.MixerButtonClick(Sender: TObject);
begin
  if not Assigned(FOpenMixer) then
    Exit;
  FTimer.Enabled := False;
  try
    FOpenMixer(Handle);
  finally
    FTimer.Enabled := Assigned(FStatus);
  end;
  UpdateStatus;
end;

procedure TS2400AggPanelForm.MasterButtonClick(Sender: TObject);
begin
  ModalResult := mrRetry;
end;

procedure TS2400AggPanelForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TS2400AggPanelForm.OkClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TS2400AggPanelForm.TimerTick(Sender: TObject);
begin
  try
    UpdateStatus;
  except
    FTimer.Enabled := False; // Anzeige ist nie wichtiger als der Host
  end;
end;

// ---------------------------------------------------------------------------
// Live-Anzeige
// ---------------------------------------------------------------------------

procedure TS2400AggPanelForm.UpdateStatus;
var
  S: TS2400AggStatus;
  Details: TArray<string>;
  I: Integer;
  Fresh, Settling: Boolean;

  function RateText(ARate: Double): string;
  begin
    if ARate <= 0 then
      Result := #$2013
    else if Abs(ARate - Round(ARate / 1000) * 1000) < 1 then
      Result := Format('%d kHz', [Round(ARate / 1000)])
    else
      Result := Format('%.1f kHz', [ARate / 1000]);
  end;

  function BarColor(ALevel, ATarget: Double; AError: Boolean): TColor;
  begin
    if AError then
      Result := C_UI_ERR
    else if (ATarget > 0) and (Abs(ALevel - ATarget) > 0.4 * ATarget) then
      Result := C_UI_ACCENT
    else
      Result := C_UI_LEVEL;
  end;

  function LevelFraction(ALevel, ATarget: Double): Double;
  begin
    if ATarget <= 0 then
      Result := 0
    else
      Result := ALevel / (2 * ATarget);
  end;

  function OffTarget(ALevel, ATarget: Double): Boolean;
  begin
    Result := (ALevel <= 0) or ((ATarget > 0) and (Abs(ALevel - ATarget) > 0.4 * ATarget));
  end;

begin
  if not Assigned(FStatus) then
    Exit;
  S := FStatus();

  // Kopf
  LabelSub.Caption := S.MasterName;
  if S.IslaPresent then
    LabelSub.Caption := LabelSub.Caption + ' + ISLA S2400';
  if S.WinPresent then
    LabelSub.Caption := LabelSub.Caption + ' + ' + S.WinName;

  // Aussetzer seit dem letzten Blick -> 3 s lang rot anzeigen
  if FHaveUnder and ((S.CapUnderruns > FLastCapUnder) or (S.RenUnderruns > FLastRenUnder) or
    (S.WinUnderruns > FLastWinUnder)) then
    FErrorUntil := GetTickCount64 + 3000;
  FLastCapUnder := S.CapUnderruns;
  FLastRenUnder := S.RenUnderruns;
  FLastWinUnder := S.WinUnderruns;
  FHaveUnder := True;
  Fresh := GetTickCount64 < FErrorUntil;

  // Kacheln
  TileRate.ValueText := RateText(S.SampleRate);
  if S.BufferFrames > 0 then
    TileBuffer.ValueText := IntToStr(S.BufferFrames)
  else
    TileBuffer.ValueText := #$2013;
  if (S.SampleRate > 0) and (S.InLatency > 0) then
    TileLatency.ValueText := Format('%.1f ms', [S.InLatency * 1000 / S.SampleRate])
  else
    TileLatency.ValueText := #$2013;
  if S.Running and S.IslaSync and (S.CapLevel > 0) then
    TilePpm.ValueText := Format('%.0f ppm', [S.CapPpm])
  else
    TilePpm.ValueText := #$2013;

  // Balken
  if S.Running and S.IslaSync then
  begin
    BarIn.SetState(LevelFraction(S.CapLevel, S.CapTarget), BarColor(S.CapLevel, S.CapTarget, Fresh),
      Format(Tr('%d Aussetzer', '%d dropouts'), [S.CapUnderruns]));
    BarOut.SetState(LevelFraction(S.RenLevel, S.RenTarget), BarColor(S.RenLevel, S.RenTarget, Fresh),
      Format(Tr('%d Aussetzer', '%d dropouts'), [S.RenUnderruns]));
  end
  else
  begin
    BarIn.SetState(0, C_UI_LEVEL, #$2013);
    BarOut.SetState(0, C_UI_LEVEL, #$2013);
  end;
  if S.Running and S.WinSync then
    BarWin.SetState(LevelFraction(S.WinLevel, S.WinTarget), BarColor(S.WinLevel, S.WinTarget, Fresh),
      Format(Tr('%d Aussetzer', '%d dropouts'), [S.WinUnderruns]))
  else
    BarWin.SetState(0, C_UI_LEVEL, #$2013);

  // Statuspille
  Settling := (S.IslaSync and (OffTarget(S.CapLevel, S.CapTarget) or OffTarget(S.RenLevel, S.RenTarget))) or
    (S.WinSync and OffTarget(S.WinLevel, S.WinTarget));
  if not S.Running then
    Pill.SetStatus(usOff, Tr('Gestoppt', 'Stopped'))
  else if not S.IslaPresent and not S.WinPresent then
    Pill.SetStatus(usOff, Tr('Nur Master', 'Master only'))
  else if S.IslaPresent and not S.IslaSync then
    Pill.SetStatus(usBusy, Tr('Isla still', 'Isla silent'))
  else if Fresh then
    Pill.SetStatus(usError, Tr('Aussetzer', 'Dropout'))
  else if Settling then
    Pill.SetStatus(usBusy, Tr('Gleicht an', 'Settling'))
  else
    Pill.SetStatus(usOk, Tr('Synchron', 'In sync'));
  Pill.SetBounds(ClientWidth - Sc(18) - Pill.PreferredWidth, Pill.Top, Pill.PreferredWidth, Pill.Height);

  // Zustand des Windows-Ausgangs
  if not S.WinPresent then
    LabelWinState.Caption := Tr('Nicht eingebunden', 'Not included')
  else if S.WinSync then
    LabelWinState.Caption := Tr('Aktiv: ', 'Active: ') + S.WinFormat
  else if S.Running then
    LabelWinState.Caption := Tr('Ger'#$00E4't nicht ge'#$00F6'ffnet (belegt oder nicht verf'#$00FC'gbar)', 'Device not opened (busy or unavailable)')
  else
    LabelWinState.Caption := Tr('Bereit (startet mit der Audio-Engine)', 'Ready (starts with the audio engine)');

  // Zustand des Isla-Monitorings
  if not S.MonEnabled then
    LabelMonState.Caption := Tr('Aus (im Mixer einschalten). Die Isla ist nur '#$00FC'ber die Audio-Software zu h'#$00F6'ren.',
      'Off (switch on in the mixer). The Isla can only be heard through your audio software.')
  else if S.MonActive and (S.MonLatencyMs > 0) then
    LabelMonState.Caption := Format(Tr('Aktiv, Latenz ca. %.1f ms. In der Audio-Software das Monitoring der Isla-Spuren ' +
      'auf "Aus" stellen, sonst ist die Isla doppelt zu h'#$00F6'ren.',
      'Active, latency approx. %.1f ms. In your audio software set monitoring of the Isla tracks to "Off", ' +
      'otherwise the Isla is heard twice.'), [S.MonLatencyMs])
  else if S.Running then
    LabelMonState.Caption := Tr('Wartet auf die Isla.', 'Waiting for the Isla.')
  else
    LabelMonState.Caption := Tr('Bereit (startet mit der Audio-Engine).', 'Ready (starts with the audio engine).');

  // Kanalzahl beim aktiven Master
  SetLength(Details, Length(FMasterNames));
  for I := 0 to High(FMasterNames) do
    if SameText(FMasterNames[I], S.MasterName) and (S.MasterIn + S.MasterOut > 0) then
      Details[I] := Format(Tr('%d ein '#$00B7' %d aus', '%d in '#$00B7' %d out'), [S.MasterIn, S.MasterOut]);
  MasterList.SetDetails(Details);
end;

// ---------------------------------------------------------------------------
// Aufruf
// ---------------------------------------------------------------------------

// Eigene Modal-Schleife statt ShowModal (12.11.2026): ShowModal bricht sofort
// mit mrCancel ab, sobald Application.Terminated gesetzt ist. In einem fremden
// Prozess (z.B. S2400 Monitor) genuegt dafuer ein einziges WM_QUIT, das die
// Schleife dieses Treibers einmal gesehen hat - das Fenster blitzte dann nur
// kurz auf. Ausserdem kommt das Fenster hier sicher nach vorn.
function RunPanelModal(AForm: TForm): Integer;
var
  TaskWins: TTaskWindowList;
  PrevActive: HWND;
begin
  AForm.ModalResult := mrNone;
  AForm.HandleNeeded;
  PrevActive := GetActiveWindow;
  TaskWins := DisableTaskWindows(AForm.Handle);
  try
    AForm.Show;
    SetForegroundWindow(AForm.Handle);
    while (AForm.ModalResult = mrNone) and AForm.Visible do
    begin
      Application.ProcessMessages;
      if (AForm.ModalResult = mrNone) and AForm.Visible then
        WaitMessage;
    end;
    Result := AForm.ModalResult;
    if Result = mrNone then
      Result := mrCancel; // ueber das X geschlossen
  finally
    EnableTaskWindows(TaskWins);
    if PrevActive <> 0 then
      SetActiveWindow(PrevActive);
    AForm.Hide;
  end;
end;

function ShowS2400AggPanel(AOwnerWnd: HWND; const AStatus: TS2400AggStatusFunc;
  const AMasterNames: TArray<string>; const AWinDevices: TArray<TS2400WinDevice>;
  const AOpenMixer: TS2400OpenMixerProc; var ASettings: TS2400AggSettings): TS2400AggPanelResult;
var
  Form: TS2400AggPanelForm;
  PrevAppHandle: HWND;
  I, MR: Integer;
begin
  Result := aprCancel;
  GUiScale := Screen.PixelsPerInch / 96;
  UiGdiplusStart;
  try
    Form := TS2400AggPanelForm.CreatePanel(nil, AStatus, AMasterNames, AWinDevices, AOpenMixer);
    try
      for I := 0 to High(AMasterNames) do
        if SameText(AMasterNames[I], ASettings.Master) then
          Form.MasterList.ItemIndex := I;
      Form.ToggleIsla.Checked := ASettings.IslaEnabled;
      ASettings.IslaPacket := NearestAllowedBufferSize(ASettings.IslaPacket);
      for I := 0 to High(C_S2400_BUFFER_OPTIONS) do
        if C_S2400_BUFFER_OPTIONS[I] = ASettings.IslaPacket then
          Form.SegPacket.ItemIndex := I;
      if ASettings.ReserveHigh then
        Form.SegReserve.ItemIndex := 1
      else
        Form.SegReserve.ItemIndex := 0;
      Form.ToggleAlign.Checked := ASettings.AlignInputs;
      Form.StepExtra.Value := ASettings.IslaExtraIn;
      Form.ToggleWin.Checked := ASettings.WinEnabled;
      for I := 0 to High(AWinDevices) do
        if AWinDevices[I].Id = ASettings.WinDeviceId then
          Form.WinList.ItemIndex := I;
      Form.ToggleExclusive.Checked := ASettings.WinExclusive;
      // Sperren passend zu den Schaltern (OnChange feuert nur bei Aenderung)
      Form.IslaToggleChange(nil);
      Form.AlignToggleChange(nil);
      Form.WinToggleChange(nil);
      Form.UpdateStatus;

      PrevAppHandle := Application.Handle;
      if AOwnerWnd <> 0 then
        Application.Handle := AOwnerWnd;
      try
        MR := RunPanelModal(Form);
      finally
        Application.Handle := PrevAppHandle;
      end;

      if (MR = mrOk) or (MR = mrRetry) then
      begin
        if Form.MasterList.ItemIndex >= 0 then
          ASettings.Master := AMasterNames[Form.MasterList.ItemIndex];
        ASettings.IslaEnabled := Form.ToggleIsla.Checked;
        if Form.SegPacket.ItemIndex >= 0 then
          ASettings.IslaPacket := C_S2400_BUFFER_OPTIONS[Form.SegPacket.ItemIndex];
        ASettings.ReserveHigh := Form.SegReserve.ItemIndex = 1;
        ASettings.AlignInputs := Form.ToggleAlign.Checked;
        ASettings.IslaExtraIn := Form.StepExtra.Value;
        ASettings.WinEnabled := Form.ToggleWin.Checked;
        if Form.WinList.ItemIndex >= 0 then
          ASettings.WinDeviceId := AWinDevices[Form.WinList.ItemIndex].Id;
        ASettings.WinExclusive := Form.ToggleExclusive.Checked;
        if MR = mrOk then
          Result := aprOk
        else
          Result := aprMasterPanel;
      end;
    finally
      Form.Free; // alle GDI+-Zeichnungen sind damit beendet
    end;
  finally
    UiGdiplusStop;
  end;
end;

end.
