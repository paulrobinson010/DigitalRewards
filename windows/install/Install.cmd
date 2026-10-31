@echo off
rem Double-click to install Go AFK. Asks for administrator rights.
net session >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -SourceDir "%~dp0app"
pause
