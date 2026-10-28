<#
.SYNOPSIS
  Removes the DigitalRewards service and files. -RemoveData also deletes saved sign-ins and cached data.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:ProgramFiles 'DigitalRewards'),
    [switch]$RemoveData
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'DigitalRewards'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
    & sc.exe delete $ServiceName | Out-Null
}
Get-Process -Name 'DigitalRewards.Tray' -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $InstallDir) { Remove-Item -Path $InstallDir -Recurse -Force }

if ($RemoveData) {
    $data = Join-Path $env:ProgramData 'DigitalRewards'
    if (Test-Path $data) { Remove-Item -Path $data -Recurse -Force }
}

Write-Host 'DigitalRewards has been removed.'
