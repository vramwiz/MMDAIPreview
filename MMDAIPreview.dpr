program MMDAIPreview;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  MmdAiPreviewHost in 'Source\MmdAiPreviewHost.pas';

begin
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  try
    RunMmdAiPreviewHost;
  except
    on E: Exception do
    begin
      Writeln(ErrOutput, E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
