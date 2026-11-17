library S2400AsioDriver;

{ Wichtiger Hinweis zur DLL-Speicherverwaltung: ShareMem muss die erste
  Unit in der USES-Klausel Ihrer Bibliothek UND in der USES-Klausel Ihres Projekts
  sein (w�hlen Sie "Projekt, Quelltext anzeigen"), wenn Ihre DLL Prozeduren oder Funktionen
  exportiert, die Strings als Parameter oder Funktionsergebnisse �bergeben. Dies
  gilt f�r alle Strings, die an oder von Ihrer DLL �bergeben werden, auch f�r solche,
  die in Records und Klassen verschachtelt sind. ShareMem ist die Interface-Unit f�r
  den gemeinsamen BORLNDMM.DLL-Speichermanager, der zusammen mit Ihrer DLL
  weitergegeben werden muss. �bergeben Sie String-Informationen mit PChar- oder ShortString-
  Parametern, um die Verwendung von BORLNDMM.DLL zu vermeiden.

  Wichtiger Hinweis zur Verwendung der VCL: Wenn diese DLL implizit geladen wird
  und die in einem Unit-Initialisierungsabschnitt erstellte TWicImage/TImageCollection-Komponente
  verwendet, dann muss Vcl.WicImageInit in die USES-Klausel
  der Bibliothek aufgenommen werden. }

uses
  System.SysUtils,
  System.Classes,
  Winapi.ActiveX,
  Vcl.Forms,
  AsioInterface in 'AsioInterface.pas',
  S2400KsInterop in 'S2400KsInterop.pas',
  S2400KsEngine in 'S2400KsEngine.pas',
  S2400Resampler in 'S2400Resampler.pas',
  S2400ControlPanel in 'S2400ControlPanel.pas',
  S2400UiKit in 'S2400UiKit.pas',
  S2400AsioLogo in 'S2400AsioLogo.pas',
  S2400Lang in 'S2400Lang.pas',
  S2400MonitorLink in 'S2400MonitorLink.pas',
  S2400DriverCore in 'S2400DriverCore.pas';
  // Seit 12.10.2026 Kernel-Streaming-Engine (S2400KsEngine.pas).
  // S2400WasapiEngine.pas und WinUsbEngine.pas sind nicht mehr Teil des
  // Builds und liegen nur noch als Referenz im Projektordner.

{$R *.res}

exports
  DllGetClassObject,
  DllCanUnloadNow,
  DllRegisterServer,
  DllUnregisterServer;

begin
end.
