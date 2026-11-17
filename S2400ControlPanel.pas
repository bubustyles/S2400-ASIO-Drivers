unit S2400ControlPanel;

// =============================================================================
// S2400ControlPanel.pas
//
// Einstellungsfenster (Control Panel) des ISLA-S2400-ASIO-Treibers. Wird von
// TS2400AsioDriver.controlPanel() (S2400DriverCore.pas) modal geoeffnet.
//
// Seit 30.10.2026 im selben dunklen Design wie der Verbund-Treiber
// (S2400UiKit, selbst gezeichnet, dunkle Titelleiste). Die Schnittstelle
// (ShowS2400ControlPanel) ist unveraendert geblieben.
//
// Kennt bewusst weder die Engine noch den Treiberkern - nur einfache Werte,
// damit keine zirkulaere Unit-Abhaengigkeit entsteht.
//
// Einstellbar:
//   - Samplerate 44,1 / 48 kHz (44,1 rechnet der Treiber um)
//   - Paketgroesse (= Puffergroesse des KS-Ringpuffers), nur gemessen
//     saubere Groessen
//   - Latenz-Korrektur Eingang/Ausgang in Samples: wird zur gemeldeten
//     Latenz addiert, damit Aufnahmen im Sync exakt im Raster liegen
//
// Hinweis: Umlaute in Strings bewusst als #$00xx-Escapes, damit die
// Anzeige nicht von der Kodierung der Quelldatei abhaengt.
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
  S2400UiKit,
  S2400Lang,
  S2400AsioLogo;

const
  C_MAX_EXTRA_LATENCY = 4800; // +/- 100 ms bei 48 kHz - grosszuegige Grenze

  // Zulaessige Paketgroessen in Frames bei 48 kHz - am 15.10.2026 mit dem
  // Puffergroessen-Durchlauf von S2400KsDiag an der Isla GEMESSEN:
  //   32/48/64: lehnt usbaudio2 ab (GetLastError 87), Minimum ist 96
  //   128: Capture liefert reproduzierbar nur ~45.715 Hz statt 48.000 Hz
  //        (Pakete alle 2,80 statt 2,67 ms) -> Brizzeln. NICHT verwenden.
  //   96, 144, 160, 192, 240, 256, 288, 384, 512: exakt 48 kHz
  C_S2400_BUFFER_OPTIONS: array[0..7] of Cardinal = (96, 144, 160, 192, 240, 256, 384, 512);

// liefert die kleinste zulaessige Groesse >= AValue (sonst die groesste) -
// z.B. fuer alte, gespeicherte Einstellungen wie 128
function NearestAllowedBufferSize(AValue: Cardinal): Cardinal;

// Zeigt das Control Panel modal an. ASampleRate/ABufferSizeSamples/AExtra*
// werden als Vorbelegung uebergeben und enthalten nach OK (Result = True)
// die neuen Werte. AInfoText: mehrzeiliger Statustext (Geraet, Latenzen).
function ShowS2400ControlPanel(AOwnerWnd: HWND; const AInfoText: string;
  var ASampleRate: Double; var ABufferSizeSamples: Cardinal;
  var AExtraInputLatency, AExtraOutputLatency: Integer): Boolean;

implementation

const
  DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
  DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
  DWMWA_CAPTION_COLOR = 35;
  DWMWA_TEXT_COLOR = 36;

type
  TS2400ControlPanelForm = class(TForm)
  private
    FLinesY: TArray<Integer>;
    procedure Separator(var Y: Integer);
    function AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
      AColor: TColor; ASemibold: Boolean = False): TLabel;
    procedure FormPaint(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure CancelClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
  protected
    procedure CreateWnd; override;
  public
    WaveIcon: TS2400WaveIcon;
    Info: TS2400InfoCard;
    SegRate: TS2400Segment;
    SegPacket: TS2400Segment;
    StepIn, StepOut: TS2400Stepper;
    ButtonCancel, ButtonOk: TS2400Button;
    constructor CreatePanel(AOwner: TComponent);
  end;

function NearestAllowedBufferSize(AValue: Cardinal): Cardinal;
var
  I: Integer;
begin
  for I := 0 to High(C_S2400_BUFFER_OPTIONS) do
    if C_S2400_BUFFER_OPTIONS[I] >= AValue then
      Exit(C_S2400_BUFFER_OPTIONS[I]);
  Result := C_S2400_BUFFER_OPTIONS[High(C_S2400_BUFFER_OPTIONS)];
end;

// ---------------------------------------------------------------------------
// Aufbau
// ---------------------------------------------------------------------------

constructor TS2400ControlPanelForm.CreatePanel(AOwner: TComponent);
var
  Y, M, W, I: Integer;
  Items: TArray<string>;
begin
  // CreateNew statt Create: es gibt keine .dfm-Ressource fuer diese Klasse
  inherited CreateNew(AOwner);
  Scaled := False; // alle Masse rechnet Sc() selbst um
  BorderStyle := bsDialog;
  BorderIcons := [biSystemMenu];
  Position := poScreenCenter;
  Caption := 'S2400 ASIO Driver';
  Color := C_UI_BG;
  DoubleBuffered := True;
  KeyPreview := True;
  UiSetFont(Font, 9, C_UI_TEXT);
  OnPaint := FormPaint;
  OnKeyDown := FormKeyDown;

  M := Sc(18);
  ClientWidth := Sc(560);
  W := ClientWidth - 2 * M;

  // --- Kopf ---
  WaveIcon := TS2400WaveIcon.Create(Self);
  WaveIcon.Parent := Self;
  WaveIcon.SetBounds(M, Sc(16), Sc(28), Sc(28));
  AddLabel(M + Sc(40), Sc(12), Sc(400), Sc(22), 'S2400 ASIO Driver', 12, C_UI_TEXT, True);
  AddLabel(M + Sc(40), Sc(34), Sc(400), Sc(18), 'ISLA S2400 '#$00B7' Kernel Streaming', 8, C_UI_MUTED);
  Y := Sc(60);
  Separator(Y);

  // --- Status (Text vom Treiber) ---
  Info := TS2400InfoCard.Create(Self);
  Info.Parent := Self;
  Info.SetBounds(M, Y, W, Sc(88));
  Inc(Y, Sc(88) + Sc(12));
  Separator(Y);

  // --- Samplerate ---
  with AddLabel(M, Y, Sc(200), Sc(28), Tr('Samplerate', 'Sample rate'), 9, C_UI_TEXT2) do
    Layout := tlCenter;
  SegRate := TS2400Segment.Create(Self);
  SegRate.Parent := Self;
  SegRate.Items := [Tr('44,1 kHz', '44.1 kHz'), '48 kHz'];
  SegRate.Width := SegRate.PreferredWidth + Sc(24);
  SegRate.SetBounds(ClientWidth - M - SegRate.Width, Y, SegRate.Width, Sc(28));
  Inc(Y, Sc(32));
  with AddLabel(M, Y, W, Sc(34), Tr('Die Isla l'#$00E4'uft '#$00FC'ber USB immer mit 48 kHz - ' +
    '44,1 kHz rechnet der Treiber in Studioqualit'#$00E4't um.',
    'The Isla always runs at 48 kHz over USB - the driver converts to 44.1 kHz ' +
    'in studio quality.'), 8, C_UI_MUTED) do
    WordWrap := True;
  Inc(Y, Sc(38));

  // --- Paketgroesse ---
  AddLabel(M, Y, W, Sc(18), Tr('Paketgr'#$00F6#$00DF'e (Samples bei 48 kHz)', 'Packet size (samples at 48 kHz)'), 9, C_UI_TEXT2);
  Inc(Y, Sc(22));
  SegPacket := TS2400Segment.Create(Self);
  SegPacket.Parent := Self;
  SetLength(Items, Length(C_S2400_BUFFER_OPTIONS));
  for I := 0 to High(C_S2400_BUFFER_OPTIONS) do
    Items[I] := IntToStr(C_S2400_BUFFER_OPTIONS[I]);
  SegPacket.Items := Items;
  SegPacket.SetBounds(M, Y, W, Sc(28));
  Inc(Y, Sc(32));
  with AddLabel(M, Y, W, Sc(34), Tr('128 fehlt mit Absicht: bei dieser Gr'#$00F6#$00DF'e liefert die Isla ' +
    'zu wenige Samples (Messung 15.10.2026).',
    '128 is left out on purpose: at this size the Isla delivers too few ' +
    'samples (measured 15 Oct 2026).'), 8, C_UI_MUTED) do
    WordWrap := True;
  Inc(Y, Sc(38));
  Separator(Y);

  // --- Latenzkorrektur ---
  AddLabel(M, Y + Sc(3), W, Sc(18), Tr('Latenzkorrektur', 'Latency correction'), 8, C_UI_MUTED);
  Inc(Y, Sc(28));
  with AddLabel(M, Y, Sc(200), Sc(28), Tr('Eingang', 'Input'), 9, C_UI_TEXT2) do
    Layout := tlCenter;
  StepIn := TS2400Stepper.Create(Self);
  StepIn.Parent := Self;
  StepIn.MinValue := -C_MAX_EXTRA_LATENCY;
  StepIn.MaxValue := C_MAX_EXTRA_LATENCY;
  StepIn.Suffix := ' Smp';
  StepIn.SetBounds(ClientWidth - M - Sc(140), Y, Sc(140), Sc(28));
  Inc(Y, Sc(36));
  with AddLabel(M, Y, Sc(200), Sc(28), Tr('Ausgang', 'Output'), 9, C_UI_TEXT2) do
    Layout := tlCenter;
  StepOut := TS2400Stepper.Create(Self);
  StepOut.Parent := Self;
  StepOut.MinValue := -C_MAX_EXTRA_LATENCY;
  StepOut.MaxValue := C_MAX_EXTRA_LATENCY;
  StepOut.Suffix := ' Smp';
  StepOut.SetBounds(ClientWidth - M - Sc(140), Y, Sc(140), Sc(28));
  Inc(Y, Sc(34));
  with AddLabel(M, Y, W, Sc(34), Tr('Wird zur gemeldeten Latenz addiert, damit Aufnahmen exakt im ' +
    'Raster liegen. Umschalt = 10er-Schritte, Strg = 100er-Schritte, Mausrad geht auch.',
    'Added to the reported latency so recordings land exactly on the grid. ' +
    'Shift = steps of 10, Ctrl = steps of 100, mouse wheel works too.'), 8, C_UI_MUTED) do
    WordWrap := True;
  Inc(Y, Sc(38));
  Separator(Y);

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
end;

procedure TS2400ControlPanelForm.CreateWnd;
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

procedure TS2400ControlPanelForm.Separator(var Y: Integer);
begin
  FLinesY := FLinesY + [Y];
  Inc(Y, Sc(12));
end;

function TS2400ControlPanelForm.AddLabel(AX, AY, AW, AH: Integer; const AText: string; ASize: Integer;
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

procedure TS2400ControlPanelForm.FormPaint(Sender: TObject);
var
  Y: Integer;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := C_UI_BG;
  Canvas.FillRect(ClientRect);
  Canvas.Pen.Color := C_UI_LINE;
  Canvas.Pen.Width := 1;
  for Y in FLinesY do
  begin
    Canvas.MoveTo(0, Y);
    Canvas.LineTo(ClientWidth, Y);
  end;
end;

procedure TS2400ControlPanelForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
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

procedure TS2400ControlPanelForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TS2400ControlPanelForm.OkClick(Sender: TObject);
begin
  ModalResult := mrOk;
end;

// ---------------------------------------------------------------------------
// Aufruf
// ---------------------------------------------------------------------------

function ShowS2400ControlPanel(AOwnerWnd: HWND; const AInfoText: string;
  var ASampleRate: Double; var ABufferSizeSamples: Cardinal;
  var AExtraInputLatency, AExtraOutputLatency: Integer): Boolean;
var
  Form: TS2400ControlPanelForm;
  PrevAppHandle: HWND;
  I: Integer;
  Buffer: Cardinal;
begin
  Result := False;
  GUiScale := Screen.PixelsPerInch / 96;
  UiGdiplusStart;
  try
    Form := TS2400ControlPanelForm.CreatePanel(nil);
    try
      Form.Info.Caption := AInfoText;
      if Abs(ASampleRate - 44100) < 0.5 then
        Form.SegRate.ItemIndex := 0
      else
        Form.SegRate.ItemIndex := 1;
      Buffer := NearestAllowedBufferSize(ABufferSizeSamples);
      for I := 0 to High(C_S2400_BUFFER_OPTIONS) do
        if C_S2400_BUFFER_OPTIONS[I] = Buffer then
          Form.SegPacket.ItemIndex := I;
      Form.StepIn.Value := AExtraInputLatency;
      Form.StepOut.Value := AExtraOutputLatency;

      // Dialog dem Host-Fenster zuordnen (Z-Order/Deaktivierung korrekt)
      PrevAppHandle := Application.Handle;
      if AOwnerWnd <> 0 then
        Application.Handle := AOwnerWnd;
      try
        if Form.ShowModal = mrOk then
        begin
          if Form.SegRate.ItemIndex = 0 then
            ASampleRate := 44100
          else
            ASampleRate := 48000;
          if Form.SegPacket.ItemIndex >= 0 then
            ABufferSizeSamples := C_S2400_BUFFER_OPTIONS[Form.SegPacket.ItemIndex];
          AExtraInputLatency := Form.StepIn.Value;
          AExtraOutputLatency := Form.StepOut.Value;
          Result := True;
        end;
      finally
        Application.Handle := PrevAppHandle;
      end;
    finally
      Form.Free; // alle GDI+-Zeichnungen sind damit beendet
    end;
  finally
    UiGdiplusStop;
  end;
end;

end.
