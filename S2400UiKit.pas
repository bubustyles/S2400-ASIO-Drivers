unit S2400UiKit;

// =============================================================================
// S2400UiKit.pas - eigene, selbst gezeichnete Bedienelemente im dunklen
// Design (Etappe D, 30.10.2026) fuer die Einstellungsfenster der S2400-
// Treiber. Keine Windows-Standardgrafik: Flaechen, Schalter, Segmenttasten,
// Listen und Anzeigen werden mit GDI+ kantengeglaettet gezeichnet, Text mit
// GDI (ClearType).
//
// GDI+ in einer DLL: Winapi.GDIPOBJ startet GDI+ in einer DLL bewusst NICHT
// (GdiplusStartup darf laut Microsoft nicht aus DllMain kommen, dort laufen
// die Unit-Initialisierungen). Wer diese Elemente benutzt, ruft vorher
// UiGdiplusStart und nach dem Freigeben aller Elemente UiGdiplusStop auf -
// im Bedienthread, z.B. beim Oeffnen/Schliessen des Fensters.
//
// Alle Elemente sind TCustomControl (eigenes Fenster, Ursprung 0,0, doppelt
// gepuffert) - GDI+ auf dem DC eines TGraphicControl beachtet den von der
// VCL verschobenen Ursprung nicht verlaesslich.
//
// Masse in 96-dpi-Pixeln, umgerechnet ueber Sc() mit GUiScale.
// =============================================================================

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.Math,
  Vcl.Graphics,
  Vcl.Controls,
  Winapi.GDIPAPI,
  Winapi.GDIPOBJ;

const
  // Farben (TColor = $00BBGGRR), abgestimmt im Entwurf vom 30.10.2026
  C_UI_BG           = TColor($00201D1C); // #1C1D20 Fenster
  C_UI_CARD         = TColor($002A2624); // #24262A Kacheln
  C_UI_CTRL         = TColor($002C2826); // #26282C Bedienflaechen
  C_UI_CTRL_HOVER   = TColor($0036322F); // #2F3236
  C_UI_TRACK        = TColor($00302C2A); // #2A2C30 Balken-Hintergrund
  C_UI_OFF          = TColor($00413C3A); // #3A3C41 Schalter aus
  C_UI_LINE         = TColor($0034302E); // #2E3034 Trennlinien
  C_UI_BORDER       = TColor($00514C4A); // #4A4C51 Rahmen
  C_UI_TEXT         = TColor($00E1E6E8); // #E8E6E1 Text
  C_UI_TEXT2        = TColor($00A1A7A9); // #A9A7A1 Text, zweitrangig
  C_UI_MUTED        = TColor($00858B8D); // #8D8B85 Beschriftungen
  C_UI_DISABLED     = TColor($00595D60); // #605D59 gesperrt
  C_UI_ACCENT       = TColor($00279FEF); // #EF9F27 Akzent (Bernstein)
  C_UI_ACCENT_HOVER = TColor($0040B0F5); // #F5B040
  C_UI_ON_ACCENT    = TColor($00022441); // #412402 Text auf Akzent
  C_UI_SEL_BG       = TColor($0018242B); // #2B2418 ausgewaehlte Zeile
  C_UI_SEL_BORDER   = TColor($000B4F85); // #854F0B
  C_UI_SEL_TEXT     = TColor($0075C7FA); // #FAC775
  C_UI_SEL_DETAIL   = TColor($001775BA); // #BA7517
  C_UI_OK           = TColor($0059C497); // #97C459 gruen
  C_UI_OK_BG        = TColor($001A2A1F); // #1F2A1A
  C_UI_OK_BORDER    = TColor($00116D3B); // #3B6D11
  C_UI_WARN_BG      = TColor($00141F2B); // #2B1F14
  C_UI_ERR          = TColor($004A4BE2); // #E24B4A rot
  C_UI_ERR_BG       = TColor($001C1C34); // #341C1C
  C_UI_ERR_BORDER   = TColor($002D2DA3); // #A32D2D
  C_UI_LEVEL        = TColor($00A5CA5D); // #5DCAA5 Fuellstand ok (tuerkis)

  C_UI_FONT          = 'Segoe UI';
  C_UI_FONT_SEMIBOLD = 'Segoe UI Semibold';

var
  GUiScale: Single = 1.0;

// 96-dpi-Mass -> Bildschirmpixel
function Sc(AValue: Integer): Integer;
// GDI+ fuer die Bedienelemente starten/beenden (nicht aus DllMain!)
procedure UiGdiplusStart;
procedure UiGdiplusStop;
procedure UiSetFont(AFont: TFont; ASize: Integer; AColor: TColor; ASemibold: Boolean = False);

// Zeichenhelfer, auch fuer eigene Elemente in anderen Units (Isla-Mixer, 06.11.2026)
function GpBegin(DC: HDC): TGPGraphics;
function GpColor(AColor: TColor): ARGB;
function RoundPath(X, Y, W, H, R: Single): TGPGraphicsPath;
procedure GpFillRound(G: TGPGraphics; X, Y, W, H, R: Single; AColor: TColor);
procedure GpFillCircle(G: TGPGraphics; CX, CY, R: Single; AColor: TColor);
procedure UiText(ACanvas: TCanvas; const S: string; R: TRect; AFlags: Cardinal);

type
  TS2400UiState = (usOff, usOk, usBusy, usError);

  // gemeinsame Basis: dunkler Hintergrund, doppelt gepuffert, Schrift
  TS2400UiControl = class(TCustomControl)
  protected
    FHot: Boolean;
    procedure CMMouseEnter(var Msg: TMessage); message CM_MOUSEENTER;
    procedure CMMouseLeave(var Msg: TMessage); message CM_MOUSELEAVE;
    procedure CMEnabledChanged(var Msg: TMessage); message CM_ENABLEDCHANGED;
    procedure CMTextChanged(var Msg: TMessage); message CM_TEXTCHANGED;
    procedure WMEraseBkgnd(var Msg: TWMEraseBkgnd); message WM_ERASEBKGND;
    procedure PaintBackground;
    procedure HotChanged; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    property Caption;
    property Color;
    property Font;
    property OnClick;
  end;

  // Ein/Aus-Schalter mit Beschriftung links davon
  TS2400Toggle = class(TS2400UiControl)
  private
    FChecked: Boolean;
    FOnChange: TNotifyEvent;
    procedure SetChecked(AValue: Boolean);
  protected
    procedure Paint; override;
    procedure Click; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    property Checked: Boolean read FChecked write SetChecked;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // Segmenttasten (eine Auswahl aus mehreren)
  TS2400Segment = class(TS2400UiControl)
  private
    FItems: TArray<string>;
    FItemIndex: Integer;
    FHoverIndex: Integer;
    FRects: TArray<TRect>;
    FOnChange: TNotifyEvent;
    procedure SetItems(const AValue: TArray<string>);
    procedure SetItemIndex(AValue: Integer);
    procedure CalcRects;
    function ItemAt(X, Y: Integer): Integer;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure HotChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    // passende Breite fuer die Beschriftungen
    function PreferredWidth: Integer;
    property Items: TArray<string> read FItems write SetItems;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // Zahlenfeld mit - und + (Umschalt = x10, Strg = x100, Mausrad, Pfeiltasten)
  TS2400Stepper = class(TS2400UiControl)
  private
    FValue, FMinValue, FMaxValue: Integer;
    FSuffix: string;
    FHoverPart: Integer; // -1 minus, 1 plus, 0 Mitte
    FOnChange: TNotifyEvent;
    procedure SetValue(AValue: Integer);
    procedure StepBy(ADelta: Integer; Shift: TShiftState);
    function PartAt(X: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure HotChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    property Value: Integer read FValue write SetValue;
    property MinValue: Integer read FMinValue write FMinValue;
    property MaxValue: Integer read FMaxValue write FMaxValue;
    property Suffix: string read FSuffix write FSuffix;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // Geraeteliste mit Auswahlpunkt, rechts optional eine Zusatzangabe
  TS2400DeviceList = class(TS2400UiControl)
  private
    FItems: TArray<string>;
    FDetails: TArray<string>;
    FItemIndex: Integer;
    FHoverIndex: Integer;
    FTopIndex: Integer;
    FMaxVisible: Integer;
    FOnChange: TNotifyEvent;
    procedure SetItemIndex(AValue: Integer);
    function RowHeight: Integer;
    function RowAt(Y: Integer): Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure HotChanged; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetData(const AItems, ADetails: TArray<string>);
    // nur die Zusatzangaben erneuern (Auswahl und Scrollstand bleiben)
    procedure SetDetails(const ADetails: TArray<string>);
    // Hoehe fuer alle (hoechstens MaxVisible) Zeilen
    function PreferredHeight: Integer;
    property ItemIndex: Integer read FItemIndex write SetItemIndex;
    property MaxVisible: Integer read FMaxVisible write FMaxVisible;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

  // flache Schaltflaeche; Primary = Akzentfarbe; Glyph = Zeichen aus
  // "Segoe MDL2 Assets" (z.B. #$E713 Zahnrad), leer = ohne Symbol
  TS2400Button = class(TS2400UiControl)
  private
    FPrimary: Boolean;
    FPressed: Boolean;
    FGlyph: string;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    function PreferredWidth: Integer;
    property Primary: Boolean read FPrimary write FPrimary;
    property Glyph: string read FGlyph write FGlyph;
  end;

  // Kachel: kleine Beschriftung, darunter ein Wert
  TS2400StatTile = class(TS2400UiControl)
  private
    FValueText: string;
    procedure SetValueText(const AValue: string);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    property ValueText: string read FValueText write SetValueText;
  end;

  // Fuellstandsbalken: Beschriftung links, Balken, Markierung (Sollwert),
  // Text rechts
  TS2400LevelBar = class(TS2400UiControl)
  private
    FFraction: Double;
    FMarker: Double;
    FBarColor: TColor;
    FRightText: string;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetState(AFraction: Double; ABarColor: TColor; const ARightText: string);
    property Marker: Double read FMarker write FMarker;
  end;

  // Statusanzeige als Pille mit Punkt
  TS2400Pill = class(TS2400UiControl)
  private
    FState: TS2400UiState;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetStatus(AState: TS2400UiState; const AText: string);
    function PreferredWidth: Integer;
  end;

  // Kachel mit mehrzeiligem Text (Caption, Zeilenumbrueche erlaubt)
  TS2400InfoCard = class(TS2400UiControl)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

  // kleines Wellen-Symbol fuer die Kopfzeile
  TS2400WaveIcon = class(TS2400UiControl)
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

var
  GGdipToken: ULONG_PTR = 0;
  GGdipCount: Integer = 0;
  GMeasure: TBitmap = nil;

function Sc(AValue: Integer): Integer;
begin
  Result := Round(AValue * GUiScale);
end;

procedure UiGdiplusStart;
var
  Input: TGdiplusStartupInput;
begin
  if GGdipCount = 0 then
  begin
    FillChar(Input, SizeOf(Input), 0);
    Input.GdiplusVersion := 1;
    if GdiplusStartup(GGdipToken, @Input, nil) <> Ok then
      GGdipToken := 0;
  end;
  Inc(GGdipCount);
end;

procedure UiGdiplusStop;
begin
  if GGdipCount = 0 then
    Exit;
  Dec(GGdipCount);
  if (GGdipCount = 0) and (GGdipToken <> 0) then
  begin
    GdiplusShutdown(GGdipToken);
    GGdipToken := 0;
  end;
end;

procedure UiSetFont(AFont: TFont; ASize: Integer; AColor: TColor; ASemibold: Boolean);
begin
  if ASemibold then
    AFont.Name := C_UI_FONT_SEMIBOLD
  else
    AFont.Name := C_UI_FONT;
  AFont.Size := ASize;
  AFont.Color := AColor;
  AFont.Style := [];
  AFont.Quality := fqClearType;
end;

function TextWidthOf(AFont: TFont; const S: string): Integer;
begin
  if GMeasure = nil then
    GMeasure := TBitmap.Create;
  GMeasure.Canvas.Font.Assign(AFont);
  Result := GMeasure.Canvas.TextWidth(S);
end;

// ---------------------------------------------------------------------------
// GDI+-Helfer
// ---------------------------------------------------------------------------

function GpColor(AColor: TColor): ARGB;
var
  C: Cardinal;
begin
  C := ColorToRGB(AColor);
  Result := MakeColor(255, GetRValue(C), GetGValue(C), GetBValue(C));
end;

function GpBegin(DC: HDC): TGPGraphics;
begin
  Result := TGPGraphics.Create(DC);
  Result.SetSmoothingMode(SmoothingModeAntiAlias);
  Result.SetPixelOffsetMode(PixelOffsetModeHalf);
end;

function RoundPath(X, Y, W, H, R: Single): TGPGraphicsPath;
var
  D: Single;
begin
  if R > H / 2 then
    R := H / 2;
  if R > W / 2 then
    R := W / 2;
  if R < 0.5 then
    R := 0.5;
  D := 2 * R;
  Result := TGPGraphicsPath.Create;
  Result.AddArc(X, Y, D, D, 180, 90);
  Result.AddArc(X + W - D, Y, D, D, 270, 90);
  Result.AddArc(X + W - D, Y + H - D, D, D, 0, 90);
  Result.AddArc(X, Y + H - D, D, D, 90, 90);
  Result.CloseFigure;
end;

procedure GpFillRound(G: TGPGraphics; X, Y, W, H, R: Single; AColor: TColor);
var
  P: TGPGraphicsPath;
  B: TGPSolidBrush;
begin
  P := RoundPath(X, Y, W, H, R);
  B := TGPSolidBrush.Create(GpColor(AColor));
  try
    G.FillPath(B, P);
  finally
    B.Free;
    P.Free;
  end;
end;

procedure GpStrokeRound(G: TGPGraphics; X, Y, W, H, R: Single; AColor: TColor; AWidth: Single = 1);
var
  P: TGPGraphicsPath;
  Pen: TGPPen;
begin
  P := RoundPath(X + AWidth / 2, Y + AWidth / 2, W - AWidth, H - AWidth, R);
  Pen := TGPPen.Create(GpColor(AColor), AWidth);
  try
    G.DrawPath(Pen, P);
  finally
    Pen.Free;
    P.Free;
  end;
end;

procedure GpFillCircle(G: TGPGraphics; CX, CY, R: Single; AColor: TColor);
var
  B: TGPSolidBrush;
begin
  B := TGPSolidBrush.Create(GpColor(AColor));
  try
    G.FillEllipse(B, CX - R, CY - R, 2 * R, 2 * R);
  finally
    B.Free;
  end;
end;

procedure GpStrokeCircle(G: TGPGraphics; CX, CY, R: Single; AColor: TColor; AWidth: Single);
var
  Pen: TGPPen;
begin
  Pen := TGPPen.Create(GpColor(AColor), AWidth);
  try
    G.DrawEllipse(Pen, CX - R, CY - R, 2 * R, 2 * R);
  finally
    Pen.Free;
  end;
end;

// kleiner Pfeil (Chevron) nach oben (AUp) oder unten, Mitte CX/CY
procedure GpChevron(G: TGPGraphics; CX, CY, Size: Single; AUp: Boolean; AColor: TColor; AWidth: Single);
var
  Pen: TGPPen;
  Dy: Single;
begin
  Pen := TGPPen.Create(GpColor(AColor), AWidth);
  try
    Pen.SetStartCap(LineCapRound);
    Pen.SetEndCap(LineCapRound);
    if AUp then Dy := -Size / 2 else Dy := Size / 2;
    G.DrawLine(Pen, CX - Size, CY - Dy, CX, CY + Dy);
    G.DrawLine(Pen, CX, CY + Dy, CX + Size, CY - Dy);
  finally
    Pen.Free;
  end;
end;

// Text in ein Rechteck (GDI, ClearType), ohne &-Kuerzel
procedure UiText(ACanvas: TCanvas; const S: string; R: TRect; AFlags: Cardinal);
begin
  ACanvas.Brush.Style := bsClear;
  Winapi.Windows.DrawText(ACanvas.Handle, PChar(S), Length(S), R,
    AFlags or DT_NOPREFIX or DT_SINGLELINE or DT_VCENTER);
end;

// ---------------------------------------------------------------------------
// TS2400UiControl
// ---------------------------------------------------------------------------

constructor TS2400UiControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque] - [csSetCaption];
  DoubleBuffered := True;
  ParentColor := False;
  Color := C_UI_BG;
  ParentFont := False;
  UiSetFont(Font, 9, C_UI_TEXT2);
end;

procedure TS2400UiControl.CMMouseEnter(var Msg: TMessage);
begin
  inherited;
  FHot := True;
  HotChanged;
end;

procedure TS2400UiControl.CMMouseLeave(var Msg: TMessage);
begin
  inherited;
  FHot := False;
  HotChanged;
end;

procedure TS2400UiControl.CMEnabledChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TS2400UiControl.CMTextChanged(var Msg: TMessage);
begin
  inherited;
  Invalidate;
end;

procedure TS2400UiControl.WMEraseBkgnd(var Msg: TWMEraseBkgnd);
begin
  Msg.Result := 1; // alles in Paint (doppelt gepuffert, kein Flackern)
end;

procedure TS2400UiControl.HotChanged;
begin
  Invalidate;
end;

procedure TS2400UiControl.PaintBackground;
begin
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);
end;

// ---------------------------------------------------------------------------
// TS2400Toggle
// ---------------------------------------------------------------------------

constructor TS2400Toggle.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crHandPoint;
  Width := Sc(200);
  Height := Sc(24);
end;

procedure TS2400Toggle.SetChecked(AValue: Boolean);
begin
  if FChecked = AValue then
    Exit;
  FChecked := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400Toggle.Click;
begin
  if Enabled then
    Checked := not Checked;
  inherited Click;
end;

procedure TS2400Toggle.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key = VK_SPACE then
  begin
    Checked := not Checked;
    Key := 0;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TS2400Toggle.Paint;
var
  G: TGPGraphics;
  TW, TH, TX, TY: Integer;
  Track, Knob: TColor;
  R: TRect;
begin
  PaintBackground;
  TW := Sc(34);
  TH := Sc(18);
  TX := Width - TW;
  TY := (Height - TH) div 2;

  // Beschriftung rechtsbuendig links vom Schalter
  if Enabled then
    Canvas.Font.Color := C_UI_TEXT2
  else
    Canvas.Font.Color := C_UI_DISABLED;
  Canvas.Font.Name := Font.Name;
  Canvas.Font.Size := Font.Size;
  R := Rect(0, 0, TX - Sc(8), Height);
  UiText(Canvas, Caption, R, DT_RIGHT);

  if not Enabled then
  begin
    Track := C_UI_OFF;
    Knob := C_UI_DISABLED;
  end
  else if FChecked then
  begin
    if FHot then Track := C_UI_ACCENT_HOVER else Track := C_UI_ACCENT;
    Knob := C_UI_ON_ACCENT;
  end
  else
  begin
    if FHot then Track := C_UI_BORDER else Track := C_UI_OFF;
    Knob := C_UI_TEXT2;
  end;

  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, TX, TY, TW, TH, TH / 2, Track);
    if FChecked then
      GpFillCircle(G, TX + TW - TH / 2, TY + TH / 2, TH / 2 - Sc(2), Knob)
    else
      GpFillCircle(G, TX + TH / 2, TY + TH / 2, TH / 2 - Sc(2), Knob);
  finally
    G.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Segment
// ---------------------------------------------------------------------------

constructor TS2400Segment.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crHandPoint;
  FItemIndex := -1;
  FHoverIndex := -1;
  Height := Sc(28);
  Width := Sc(200);
end;

procedure TS2400Segment.SetItems(const AValue: TArray<string>);
begin
  FItems := Copy(AValue);
  CalcRects;
  Invalidate;
end;

procedure TS2400Segment.SetItemIndex(AValue: Integer);
begin
  if (AValue < -1) or (AValue > High(FItems)) then
    AValue := -1;
  if FItemIndex = AValue then
    Exit;
  FItemIndex := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TS2400Segment.PreferredWidth: Integer;
var
  I: Integer;
begin
  Result := Sc(4);
  for I := 0 to High(FItems) do
    Inc(Result, TextWidthOf(Font, FItems[I]) + Sc(18) + Sc(2));
end;

// Breiten nach Textlaenge, Rest gleichmaessig verteilt
procedure TS2400Segment.CalcRects;
var
  I, X, Extra, Each, W: Integer;
begin
  SetLength(FRects, Length(FItems));
  if Length(FItems) = 0 then
    Exit;
  Extra := Width - PreferredWidth;
  if Extra < 0 then
    Extra := 0;
  Each := Extra div Length(FItems);
  X := Sc(2);
  for I := 0 to High(FItems) do
  begin
    W := TextWidthOf(Font, FItems[I]) + Sc(18) + Each;
    if I = High(FItems) then
      W := Width - Sc(2) - X;
    FRects[I] := Rect(X, Sc(2), X + W, Height - Sc(2));
    X := X + W + Sc(2);
  end;
end;

procedure TS2400Segment.Resize;
begin
  inherited Resize;
  CalcRects;
end;

function TS2400Segment.ItemAt(X, Y: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FRects) do
    if PtInRect(FRects[I], Point(X, Y)) then
      Exit(I);
  Result := -1;
end;

procedure TS2400Segment.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  I := ItemAt(X, Y);
  if I >= 0 then
    ItemIndex := I;
end;

procedure TS2400Segment.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  I := ItemAt(X, Y);
  if I <> FHoverIndex then
  begin
    FHoverIndex := I;
    Invalidate;
  end;
end;

procedure TS2400Segment.HotChanged;
begin
  if not FHot then
    FHoverIndex := -1;
  Invalidate;
end;

procedure TS2400Segment.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_LEFT) and (FItemIndex > 0) then
  begin
    ItemIndex := FItemIndex - 1;
    Key := 0;
  end
  else if (Key = VK_RIGHT) and (FItemIndex < High(FItems)) then
  begin
    ItemIndex := FItemIndex + 1;
    Key := 0;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TS2400Segment.Paint;
var
  G: TGPGraphics;
  I: Integer;
  R: TRect;
  TextColor: TColor;
begin
  PaintBackground;
  if Length(FRects) <> Length(FItems) then
    CalcRects;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 0, Width, Height, Sc(6), C_UI_CTRL);
    for I := 0 to High(FItems) do
    begin
      R := FRects[I];
      if I = FItemIndex then
      begin
        if Enabled then
          GpFillRound(G, R.Left, R.Top, R.Width, R.Height, Sc(5), C_UI_ACCENT)
        else
          GpFillRound(G, R.Left, R.Top, R.Width, R.Height, Sc(5), C_UI_OFF);
      end
      else if (I = FHoverIndex) and Enabled then
        GpFillRound(G, R.Left, R.Top, R.Width, R.Height, Sc(5), C_UI_CTRL_HOVER);
    end;
  finally
    G.Free;
  end;

  Canvas.Font.Name := Font.Name;
  Canvas.Font.Size := Font.Size;
  for I := 0 to High(FItems) do
  begin
    if not Enabled then
      TextColor := C_UI_DISABLED
    else if I = FItemIndex then
      TextColor := C_UI_ON_ACCENT
    else if I = FHoverIndex then
      TextColor := C_UI_TEXT
    else
      TextColor := C_UI_TEXT2;
    Canvas.Font.Color := TextColor;
    UiText(Canvas, FItems[I], FRects[I], DT_CENTER);
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Stepper
// ---------------------------------------------------------------------------

constructor TS2400Stepper.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  FMinValue := -100000;
  FMaxValue := 100000;
  Width := Sc(140);
  Height := Sc(28);
end;

procedure TS2400Stepper.SetValue(AValue: Integer);
begin
  AValue := EnsureRange(AValue, FMinValue, FMaxValue);
  if FValue = AValue then
    Exit;
  FValue := AValue;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TS2400Stepper.StepBy(ADelta: Integer; Shift: TShiftState);
begin
  if ssCtrl in Shift then
    ADelta := ADelta * 100
  else if ssShift in Shift then
    ADelta := ADelta * 10;
  Value := FValue + ADelta;
end;

function TS2400Stepper.PartAt(X: Integer): Integer;
begin
  if X < Sc(30) then
    Result := -1
  else if X >= Width - Sc(30) then
    Result := 1
  else
    Result := 0;
end;

procedure TS2400Stepper.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  P := PartAt(X);
  if P <> 0 then
    StepBy(P, Shift);
end;

procedure TS2400Stepper.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  P: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  P := PartAt(X);
  if P <> FHoverPart then
  begin
    FHoverPart := P;
    Invalidate;
  end;
end;

procedure TS2400Stepper.HotChanged;
begin
  if not FHot then
    FHoverPart := 0;
  Invalidate;
end;

function TS2400Stepper.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if not Enabled then
    Exit;
  if WheelDelta > 0 then
    StepBy(1, Shift)
  else if WheelDelta < 0 then
    StepBy(-1, Shift);
end;

procedure TS2400Stepper.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key in [VK_UP, VK_RIGHT] then
  begin
    StepBy(1, Shift);
    Key := 0;
  end
  else if Key in [VK_DOWN, VK_LEFT] then
  begin
    StepBy(-1, Shift);
    Key := 0;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TS2400Stepper.Paint;
var
  G: TGPGraphics;
  BW: Integer;

  function PartColor(APart: Integer): TColor;
  begin
    if not Enabled then
      Result := C_UI_DISABLED
    else if FHoverPart = APart then
      Result := C_UI_ACCENT
    else
      Result := C_UI_TEXT2;
  end;

begin
  PaintBackground;
  BW := Sc(30);
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 0, Width, Height, Sc(6), C_UI_CTRL);
  finally
    G.Free;
  end;
  Canvas.Font.Name := C_UI_FONT;
  Canvas.Font.Size := 11;
  Canvas.Font.Color := PartColor(-1);
  UiText(Canvas, #$2212, Rect(0, 0, BW, Height - Sc(1)), DT_CENTER);
  Canvas.Font.Color := PartColor(1);
  UiText(Canvas, '+', Rect(Width - BW, 0, Width, Height - Sc(1)), DT_CENTER);

  Canvas.Font.Size := Font.Size;
  if Enabled then
    Canvas.Font.Color := C_UI_TEXT
  else
    Canvas.Font.Color := C_UI_DISABLED;
  UiText(Canvas, IntToStr(FValue) + FSuffix, Rect(BW, 0, Width - BW, Height), DT_CENTER);
end;

// ---------------------------------------------------------------------------
// TS2400DeviceList
// ---------------------------------------------------------------------------

constructor TS2400DeviceList.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crHandPoint;
  FItemIndex := -1;
  FHoverIndex := -1;
  FMaxVisible := 6;
  Width := Sc(300);
  Height := Sc(100);
end;

procedure TS2400DeviceList.SetData(const AItems, ADetails: TArray<string>);
begin
  FItems := Copy(AItems);
  FDetails := Copy(ADetails);
  SetLength(FDetails, Length(FItems));
  FTopIndex := 0;
  Invalidate;
end;

procedure TS2400DeviceList.SetDetails(const ADetails: TArray<string>);
var
  I: Integer;
  Changed: Boolean;
begin
  Changed := False;
  for I := 0 to High(FDetails) do
    if (I <= High(ADetails)) and (FDetails[I] <> ADetails[I]) then
    begin
      FDetails[I] := ADetails[I];
      Changed := True;
    end;
  if Changed then
    Invalidate;
end;

function TS2400DeviceList.RowHeight: Integer;
begin
  Result := Sc(34);
end;

function TS2400DeviceList.PreferredHeight: Integer;
var
  N: Integer;
begin
  N := Length(FItems);
  if N > FMaxVisible then
    N := FMaxVisible;
  if N < 1 then
    N := 1;
  Result := N * (RowHeight + Sc(2));
end;

procedure TS2400DeviceList.SetItemIndex(AValue: Integer);
begin
  if (AValue < -1) or (AValue > High(FItems)) then
    AValue := -1;
  if FItemIndex = AValue then
    Exit;
  FItemIndex := AValue;
  // Auswahl sichtbar halten
  if FItemIndex >= 0 then
  begin
    if FItemIndex < FTopIndex then
      FTopIndex := FItemIndex
    else if FItemIndex >= FTopIndex + FMaxVisible then
      FTopIndex := FItemIndex - FMaxVisible + 1;
  end;
  Invalidate;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TS2400DeviceList.RowAt(Y: Integer): Integer;
begin
  Result := FTopIndex + Y div (RowHeight + Sc(2));
  if (Y < 0) or (Result > High(FItems)) then
    Result := -1;
end;

procedure TS2400DeviceList.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if not Enabled or (Button <> mbLeft) then
    Exit;
  if CanFocus then
    SetFocus;
  // Klick auf die Pfeilspalte blaettert
  if (Length(FItems) > FMaxVisible) and (X >= Width - Sc(22)) then
  begin
    if Y < Height div 2 then
      FTopIndex := Max(0, FTopIndex - 1)
    else
      FTopIndex := Min(Length(FItems) - FMaxVisible, FTopIndex + 1);
    Invalidate;
    Exit;
  end;
  I := RowAt(Y);
  if I >= 0 then
    ItemIndex := I;
end;

procedure TS2400DeviceList.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  I := RowAt(Y);
  if I <> FHoverIndex then
  begin
    FHoverIndex := I;
    Invalidate;
  end;
end;

procedure TS2400DeviceList.HotChanged;
begin
  if not FHot then
    FHoverIndex := -1;
  Invalidate;
end;

function TS2400DeviceList.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if Length(FItems) <= FMaxVisible then
    Exit;
  if WheelDelta > 0 then
    FTopIndex := Max(0, FTopIndex - 1)
  else if WheelDelta < 0 then
    FTopIndex := Min(Length(FItems) - FMaxVisible, FTopIndex + 1);
  Invalidate;
end;

procedure TS2400DeviceList.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_UP) and (FItemIndex > 0) then
  begin
    ItemIndex := FItemIndex - 1;
    Key := 0;
  end
  else if (Key = VK_DOWN) and (FItemIndex < High(FItems)) then
  begin
    ItemIndex := FItemIndex + 1;
    Key := 0;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TS2400DeviceList.Paint;
var
  G: TGPGraphics;
  I, Y, RH, RW, CX, CY, DetailW: Integer;
  Sel, Scrolls: Boolean;
  R: TRect;
  GX: Single;
begin
  PaintBackground;
  RH := RowHeight;
  // laesst sich die Liste scrollen, bekommt sie rechts eine eigene schmale
  // Spalte mit Pfeilen - die Zeilen werden entsprechend schmaler
  Scrolls := Length(FItems) > FMaxVisible;
  if Scrolls then
    RW := Width - Sc(22)
  else
    RW := Width;

  // Flaechen, Auswahlpunkte und Pfeile (GDI+)
  G := GpBegin(Canvas.Handle);
  try
    for I := FTopIndex to Min(High(FItems), FTopIndex + FMaxVisible - 1) do
    begin
      Y := (I - FTopIndex) * (RH + Sc(2));
      Sel := I = FItemIndex;
      if Sel then
      begin
        GpFillRound(G, 0, Y, RW, RH, Sc(6), C_UI_SEL_BG);
        GpStrokeRound(G, 0, Y, RW, RH, Sc(6), C_UI_SEL_BORDER, 1);
      end
      else if (I = FHoverIndex) and Enabled then
        GpFillRound(G, 0, Y, RW, RH, Sc(6), C_UI_CTRL);
      CX := Sc(18);
      CY := Y + RH div 2;
      if Sel then
      begin
        GpStrokeCircle(G, CX, CY, Sc(6), C_UI_ACCENT, Sc(2) * 0.75);
        GpFillCircle(G, CX, CY, Sc(3), C_UI_ACCENT);
      end
      else
        GpStrokeCircle(G, CX, CY, Sc(6), C_UI_MUTED, Sc(2) * 0.6);
    end;
    if Scrolls then
    begin
      GX := Width - Sc(9);
      GpFillRound(G, Width - Sc(16), 0, Sc(14), Height - Sc(2), Sc(7), C_UI_CARD);
      if FTopIndex > 0 then
        GpChevron(G, GX, Sc(14), Sc(4), True, C_UI_TEXT2, Sc(2) * 0.8)
      else
        GpChevron(G, GX, Sc(14), Sc(4), True, C_UI_OFF, Sc(2) * 0.8);
      if FTopIndex + FMaxVisible < Length(FItems) then
        GpChevron(G, GX, Height - Sc(16), Sc(4), False, C_UI_TEXT2, Sc(2) * 0.8)
      else
        GpChevron(G, GX, Height - Sc(16), Sc(4), False, C_UI_OFF, Sc(2) * 0.8);
    end;
  finally
    G.Free;
  end;

  // Text (GDI)
  Canvas.Font.Name := Font.Name;
  Canvas.Font.Size := Font.Size;
  for I := FTopIndex to Min(High(FItems), FTopIndex + FMaxVisible - 1) do
  begin
    Y := (I - FTopIndex) * (RH + Sc(2));
    Sel := I = FItemIndex;
    DetailW := 0;
    if FDetails[I] <> '' then
    begin
      Canvas.Font.Size := Font.Size - 1;
      DetailW := Canvas.TextWidth(FDetails[I]) + Sc(14);
      if Sel then Canvas.Font.Color := C_UI_SEL_DETAIL else Canvas.Font.Color := C_UI_MUTED;
      R := Rect(RW - DetailW, Y, RW - Sc(12), Y + RH);
      UiText(Canvas, FDetails[I], R, DT_RIGHT);
      Canvas.Font.Size := Font.Size;
    end;
    if not Enabled then
      Canvas.Font.Color := C_UI_DISABLED
    else if Sel then
      Canvas.Font.Color := C_UI_SEL_TEXT
    else
      Canvas.Font.Color := C_UI_TEXT2;
    R := Rect(Sc(34), Y, RW - DetailW - Sc(8), Y + RH);
    UiText(Canvas, FItems[I], R, DT_LEFT or DT_END_ELLIPSIS);
  end;
end;

// ---------------------------------------------------------------------------
// TS2400Button
// ---------------------------------------------------------------------------

constructor TS2400Button.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  TabStop := True;
  Cursor := crHandPoint;
  Height := Sc(30);
  Width := Sc(110);
end;

function TS2400Button.PreferredWidth: Integer;
begin
  Result := TextWidthOf(Font, Caption) + Sc(30);
  if FGlyph <> '' then
    Inc(Result, Sc(22));
end;

procedure TS2400Button.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    FPressed := True;
    Invalidate;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TS2400Button.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if FPressed then
  begin
    FPressed := False;
    Invalidate;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TS2400Button.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if Key in [VK_SPACE, VK_RETURN] then
  begin
    Key := 0;
    Click;
  end;
  inherited KeyDown(Key, Shift);
end;

procedure TS2400Button.Paint;
var
  G: TGPGraphics;
  Fill, Border, TextColor: TColor;
  R: TRect;
  X0: Integer;
begin
  PaintBackground;
  if FPrimary then
  begin
    if FHot then Fill := C_UI_ACCENT_HOVER else Fill := C_UI_ACCENT;
    Border := Fill;
    TextColor := C_UI_ON_ACCENT;
  end
  else
  begin
    if FHot then Fill := C_UI_CTRL_HOVER else Fill := Color;
    Border := C_UI_BORDER;
    TextColor := C_UI_TEXT;
  end;
  if not Enabled then
    TextColor := C_UI_DISABLED;

  G := GpBegin(Canvas.Handle);
  try
    if FPressed then
      GpFillRound(G, Sc(1), Sc(1), Width - Sc(2), Height - Sc(2), Sc(6), Fill)
    else
      GpFillRound(G, 0, 0, Width, Height, Sc(6), Fill);
    if not FPrimary then
      GpStrokeRound(G, 0, 0, Width, Height, Sc(6), Border, 1);
  finally
    G.Free;
  end;

  Canvas.Font.Color := TextColor;
  if FGlyph <> '' then
  begin
    X0 := (Width - PreferredWidth) div 2 + Sc(15);
    Canvas.Font.Name := 'Segoe MDL2 Assets';
    Canvas.Font.Size := Font.Size;
    R := Rect(X0, 0, X0 + Sc(16), Height);
    UiText(Canvas, FGlyph, R, DT_LEFT);
    Canvas.Font.Name := Font.Name;
    R := Rect(X0 + Sc(22), 0, Width, Height);
    UiText(Canvas, Caption, R, DT_LEFT);
  end
  else
  begin
    Canvas.Font.Name := Font.Name;
    Canvas.Font.Size := Font.Size;
    UiText(Canvas, Caption, ClientRect, DT_CENTER);
  end;
end;

// ---------------------------------------------------------------------------
// TS2400StatTile
// ---------------------------------------------------------------------------

constructor TS2400StatTile.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := Sc(130);
  Height := Sc(52);
end;

procedure TS2400StatTile.SetValueText(const AValue: string);
begin
  if FValueText = AValue then
    Exit;
  FValueText := AValue;
  Invalidate;
end;

procedure TS2400StatTile.Paint;
var
  G: TGPGraphics;
begin
  PaintBackground;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 0, Width, Height, Sc(8), C_UI_CARD);
  finally
    G.Free;
  end;
  UiSetFont(Canvas.Font, 8, C_UI_MUTED);
  UiText(Canvas, Caption, Rect(Sc(10), Sc(4), Width - Sc(6), Sc(22)), DT_LEFT);
  UiSetFont(Canvas.Font, 12, C_UI_TEXT, True);
  UiText(Canvas, FValueText, Rect(Sc(10), Sc(20), Width - Sc(6), Height - Sc(4)), DT_LEFT or DT_END_ELLIPSIS);
end;

// ---------------------------------------------------------------------------
// TS2400LevelBar
// ---------------------------------------------------------------------------

constructor TS2400LevelBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FMarker := 0.5;
  FBarColor := C_UI_LEVEL;
  Width := Sc(400);
  Height := Sc(22);
end;

procedure TS2400LevelBar.SetState(AFraction: Double; ABarColor: TColor; const ARightText: string);
begin
  AFraction := EnsureRange(AFraction, 0.0, 1.0);
  if (Abs(AFraction - FFraction) < 0.002) and (ABarColor = FBarColor) and (ARightText = FRightText) then
    Exit;
  FFraction := AFraction;
  FBarColor := ABarColor;
  FRightText := ARightText;
  Invalidate;
end;

procedure TS2400LevelBar.Paint;
var
  G: TGPGraphics;
  LW, RW, BX, BW, BH, BY: Integer;
  Pen: TGPPen;
  MX: Single;
begin
  PaintBackground;
  LW := Sc(76);
  RW := Sc(92);
  BX := LW;
  BW := Width - LW - RW;
  BH := Sc(6);
  BY := (Height - BH) div 2;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, BX, BY, BW, BH, BH / 2, C_UI_TRACK);
    if FFraction > 0.005 then
      GpFillRound(G, BX, BY, Max(BH, Round(BW * FFraction)), BH, BH / 2, FBarColor);
    MX := BX + BW * FMarker;
    Pen := TGPPen.Create(GpColor(C_UI_MUTED), Sc(2));
    try
      G.DrawLine(Pen, MX, BY - Sc(3), MX, BY + BH + Sc(3));
    finally
      Pen.Free;
    end;
  finally
    G.Free;
  end;
  UiSetFont(Canvas.Font, 9, C_UI_TEXT2);
  UiText(Canvas, Caption, Rect(0, 0, LW - Sc(8), Height), DT_LEFT);
  UiText(Canvas, FRightText, Rect(Width - RW + Sc(8), 0, Width, Height), DT_RIGHT);
end;

// ---------------------------------------------------------------------------
// TS2400Pill
// ---------------------------------------------------------------------------

constructor TS2400Pill.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Height := Sc(26);
  Width := Sc(110);
end;

function TS2400Pill.PreferredWidth: Integer;
begin
  Result := TextWidthOf(Font, Caption) + Sc(36);
end;

procedure TS2400Pill.SetStatus(AState: TS2400UiState; const AText: string);
begin
  if (AState = FState) and (AText = Caption) then
    Exit;
  FState := AState;
  Caption := AText; // loest Neuzeichnen aus
  Invalidate;
end;

procedure TS2400Pill.Paint;
var
  G: TGPGraphics;
  Bg, Border, Fg: TColor;
begin
  PaintBackground;
  case FState of
    usOk:
      begin Bg := C_UI_OK_BG; Border := C_UI_OK_BORDER; Fg := C_UI_OK; end;
    usBusy:
      begin Bg := C_UI_WARN_BG; Border := C_UI_SEL_BORDER; Fg := C_UI_ACCENT; end;
    usError:
      begin Bg := C_UI_ERR_BG; Border := C_UI_ERR_BORDER; Fg := C_UI_ERR; end;
  else
    begin Bg := C_UI_CARD; Border := C_UI_BORDER; Fg := C_UI_MUTED; end;
  end;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 0, Width, Height, Height / 2, Bg);
    GpStrokeRound(G, 0, 0, Width, Height, Height / 2, Border, 1);
    GpFillCircle(G, Sc(14), Height / 2, Sc(4), Fg);
  finally
    G.Free;
  end;
  Canvas.Font.Name := Font.Name;
  Canvas.Font.Size := Font.Size;
  Canvas.Font.Color := Fg;
  UiText(Canvas, Caption, Rect(Sc(24), 0, Width - Sc(8), Height), DT_LEFT);
end;

// ---------------------------------------------------------------------------
// TS2400InfoCard
// ---------------------------------------------------------------------------

constructor TS2400InfoCard.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := Sc(300);
  Height := Sc(80);
end;

procedure TS2400InfoCard.Paint;
var
  G: TGPGraphics;
  R: TRect;
  S: string;
begin
  PaintBackground;
  G := GpBegin(Canvas.Handle);
  try
    GpFillRound(G, 0, 0, Width, Height, Sc(8), C_UI_CARD);
  finally
    G.Free;
  end;
  UiSetFont(Canvas.Font, 9, C_UI_TEXT2);
  Canvas.Brush.Style := bsClear;
  R := Rect(Sc(12), Sc(9), Width - Sc(12), Height - Sc(8));
  S := Caption;
  Winapi.Windows.DrawText(Canvas.Handle, PChar(S), Length(S), R, DT_LEFT or DT_WORDBREAK or DT_NOPREFIX);
end;

// ---------------------------------------------------------------------------
// TS2400WaveIcon
// ---------------------------------------------------------------------------

constructor TS2400WaveIcon.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := Sc(28);
  Height := Sc(28);
end;

procedure TS2400WaveIcon.Paint;
const
  N = 40;
var
  G: TGPGraphics;
  Pen: TGPPen;
  I: Integer;
  X0, Y0, X1, Y1, Amp, Mid: Single;
begin
  PaintBackground;
  G := GpBegin(Canvas.Handle);
  Pen := TGPPen.Create(GpColor(C_UI_ACCENT), Sc(2) * 1.0);
  try
    Mid := Height / 2;
    Amp := Height * 0.3;
    X0 := Sc(2);
    Y0 := Mid;
    for I := 1 to N do
    begin
      X1 := Sc(2) + (Width - Sc(4)) * I / N;
      Y1 := Mid - Amp * Sin(2 * Pi * 1.5 * I / N);
      G.DrawLine(Pen, X0, Y0, X1, Y1);
      X0 := X1;
      Y0 := Y1;
    end;
  finally
    Pen.Free;
    G.Free;
  end;
end;

initialization

finalization
  FreeAndNil(GMeasure);

end.
