param(
    [Parameter(Mandatory = $true)]
    [double]$Watts
)

$ErrorActionPreference = "Stop"
if ([double]::IsNaN($Watts) -or [double]::IsInfinity($Watts) -or
    $Watts -lt 0 -or $Watts -gt 100000) {
    throw "Watts must be a number from 0 through 100000."
}

$directory = Join-Path $env:LOCALAPPDATA "WattBar"
$path = Join-Path $directory "external-power-watts.txt"
$temporaryPath = Join-Path $directory "external-power-watts.tmp"
[IO.Directory]::CreateDirectory($directory) | Out-Null

$invariant = [Globalization.CultureInfo]::InvariantCulture
$text = $Watts.ToString("R", $invariant) + [Environment]::NewLine
$encoding = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($temporaryPath, $text, $encoding)

if ([IO.File]::Exists($path)) {
    [IO.File]::Replace($temporaryPath, $path, $null, $true)
} else {
    [IO.File]::Move($temporaryPath, $path)
}

Write-Host "Updated Watt Bar external whole-device power: $Watts W"
