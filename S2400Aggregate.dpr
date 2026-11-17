library S2400Aggregate;

// Verbund-Treiber "S2400 Aggregate" (eigene CLSID, siehe S2400AggCore.pas):
// Master-ASIO-Geraet (z.B. UAD Apollo) + ISLA S2400 per Kernel Streaming,
// Isla laufend an den Master-Takt angeglichen. Der Isla-Treiber
// S2400AsioDriver.dll bleibt davon unberuehrt.
//
// Registrieren (als Administrator):  regsvr32 S2400Aggregate.dll

uses
  System.SysUtils,
  System.Classes,
  Winapi.ActiveX,
  Vcl.Forms,
  AsioInterface in 'AsioInterface.pas',
  S2400KsInterop in 'S2400KsInterop.pas',
  S2400KsEngine in 'S2400KsEngine.pas',
  S2400Resampler in 'S2400Resampler.pas',
  S2400DriftControl in 'S2400DriftControl.pas',
  S2400AsioHost in 'S2400AsioHost.pas',
  S2400WasapiOut in 'S2400WasapiOut.pas',
  S2400ControlPanel in 'S2400ControlPanel.pas',
  S2400UiKit in 'S2400UiKit.pas',
  S2400AsioLogo in 'S2400AsioLogo.pas',
  S2400Lang in 'S2400Lang.pas',
  S2400MonitorLink in 'S2400MonitorLink.pas',
  S2400AggPanel in 'S2400AggPanel.pas',
  S2400AggMixer in 'S2400AggMixer.pas',
  S2400AggCore in 'S2400AggCore.pas';

{$R *.res}

exports
  DllGetClassObject,
  DllCanUnloadNow,
  DllRegisterServer,
  DllUnregisterServer;

begin
end.
