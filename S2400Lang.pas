unit S2400Lang;

// =============================================================================
// S2400Lang.pas - Sprache der sichtbaren Texte beider Treiber (30.10.2026)
//
// Deutsch, wenn die Windows-Anzeigesprache Deutsch ist, sonst Englisch.
// Gilt fuer alles, was der Nutzer sieht (Einstellungsfenster, Infotexte,
// Fehlermeldungen an den Host). Die Logdateien bleiben deutsch - sie dienen
// nur der Fehlersuche.
//
// Verwendung: Tr('Deutscher Text', 'English text'); Umlaute im deutschen
// Text weiter als #$00xx-Escapes.
// =============================================================================

interface

// True = deutsche Texte
function S2400IsGerman: Boolean;
function Tr(const AGerman, AEnglish: string): string;

implementation

uses
  Winapi.Windows;

const
  LANG_GERMAN_PRIMARY = $07;

var
  GChecked: Boolean = False;
  GGerman: Boolean = False;

function S2400IsGerman: Boolean;
begin
  if not GChecked then
  begin
    // primaere Sprachkennung = untere 10 Bit der LANGID
    GGerman := (GetUserDefaultUILanguage and $3FF) = LANG_GERMAN_PRIMARY;
    GChecked := True;
  end;
  Result := GGerman;
end;

function Tr(const AGerman, AEnglish: string): string;
begin
  if S2400IsGerman then
    Result := AGerman
  else
    Result := AEnglish;
end;

end.
