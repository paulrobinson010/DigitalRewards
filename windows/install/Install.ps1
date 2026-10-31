<#
.SYNOPSIS
  Builds (optionally) and installs the DigitalRewards Windows enforcer as a service.

.DESCRIPTION
  Run from an elevated PowerShell on the PC to protect. Publishes the service and tray agent
  self-contained for win-x64 (needs the .NET 8 SDK unless -SourceDir points at a published folder),
  copies them to Program Files, writes appsettings.json, registers the "DigitalRewards" service
  (LocalSystem, automatic start, restart on failure) and starts it.

  The GitHub Actions build ships a package whose appsettings.json already holds the API token
  and environment; Install.cmd in that package runs this script with -SourceDir and no token.

.EXAMPLE
  .\Install.ps1 -ApiToken 0123abcd... -Environment production
.EXAMPLE
  .\Install.ps1 -SourceDir C:\Downloads\DigitalRewards -ApiToken 0123abcd...
#>
[CmdletBinding()]
param(
    # These override appsettings.json; leave them out to keep what the package was built with.
    [string]$ApiToken,
    [ValidateSet('development', 'production')][string]$Environment,
    [string]$ContainerId,
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'DigitalRewards'),
    [string]$SourceDir
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'DigitalRewards'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

if (-not $SourceDir) {
    $repo = Split-Path -Parent $PSScriptRoot
    $SourceDir = Join-Path ([IO.Path]::GetTempPath()) ('DigitalRewards-publish-' + [guid]::NewGuid().ToString('N'))
    Write-Host "Publishing to $SourceDir ..."
    foreach ($project in 'DigitalRewards.Service', 'DigitalRewards.Tray') {
        & dotnet publish (Join-Path $repo "src\$project\$project.csproj") -c Release -r win-x64 --self-contained true -o $SourceDir
        if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for $project" }
    }
}

# Files extracted from a downloaded zip carry the "from the internet" mark; clear it.
Get-ChildItem -Path $SourceDir -Recurse -File | Unblock-File

foreach ($exe in 'DigitalRewards.Service.exe', 'DigitalRewards.Tray.exe') {
    if (-not (Test-Path (Join-Path $SourceDir $exe))) { throw "$exe not found in $SourceDir" }
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host 'Stopping the existing service ...'
    if ($existing.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
    Get-Process -Name 'DigitalRewards.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force
}

Write-Host "Installing to $InstallDir ..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $SourceDir '*') -Destination $InstallDir -Recurse -Force

$settingsPath = Join-Path $InstallDir 'appsettings.json'
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
if ($ApiToken) { $settings.CloudKit.ApiToken = $ApiToken }
if ($Environment) { $settings.CloudKit.Environment = $Environment }
if ($ContainerId) { $settings.CloudKit.ContainerId = $ContainerId }
if (-not $settings.CloudKit.ApiToken -or $settings.CloudKit.ApiToken -like 'REPLACE_WITH*') {
    throw 'No CloudKit API token: pass -ApiToken, or use a package built by GitHub Actions.'
}
$settings | ConvertTo-Json -Depth 10 | Set-Content -Path $settingsPath -Encoding UTF8

# appsettings.json holds the API token: only SYSTEM and Administrators may read it.
& icacls.exe $settingsPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null

if (-not [Diagnostics.EventLog]::SourceExists($ServiceName)) {
    New-EventLog -LogName Application -Source $ServiceName
}

$binPath = '"' + (Join-Path $InstallDir 'DigitalRewards.Service.exe') + '"'
if (-not $existing) {
    Write-Host 'Registering the service ...'
    & sc.exe create $ServiceName binPath= $binPath start= auto obj= LocalSystem DisplayName= 'Go AFK' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'sc.exe create failed' }
} else {
    & sc.exe config $ServiceName binPath= $binPath start= auto obj= LocalSystem DisplayName= 'Go AFK' | Out-Null
}
& sc.exe description $ServiceName 'Go AFK: earn gaming time with exercise. Counts play time and closes apps when time runs out.' | Out-Null
# Restart after 5 s on every failure; reset the failure count daily. Also restart on non-crash failures.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
& sc.exe failureflag $ServiceName 1 | Out-Null

Start-Service -Name $ServiceName
Write-Host ''
Write-Host 'Go AFK is installed and running.'
Write-Host 'Next: each child logs in to their own STANDARD (non-admin) Windows account,'
Write-Host 'right-clicks the Go AFK tray icon and chooses "Sign in to iCloud...".'
