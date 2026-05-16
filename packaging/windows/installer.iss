[Setup]
AppName=Object Data Browser
AppVersion=2.0.16
DefaultDirName={autopf}\Object Data Browser
DefaultGroupName=Object Data Browser
OutputBaseFilename=object-data-browser-installer

[Files]
Source: "..\..\apps\flutter_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs
