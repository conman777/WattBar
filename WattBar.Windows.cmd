@echo off
setlocal
set "ROOT=%~dp0"
set "APP=%ROOT%WattBar.Windows.exe"

if not exist "%APP%" (
    echo Building Watt Bar for Windows...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%BuildWattBar.Windows.ps1"
    if errorlevel 1 (
        echo.
        echo Watt Bar could not be built.
        pause
        exit /b 1
    )
)

start "" "%APP%"
