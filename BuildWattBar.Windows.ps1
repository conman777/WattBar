param(
    [switch]$Test
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root "Sources\WattBar.Windows\WattBar.Windows.cs"
$dashboardSource = Join-Path $root "Sources\WattBar.Windows\DashboardForm.cs"
$output = Join-Path $root "WattBar.Windows.exe"

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compiler = $compilerCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $compiler) {
    throw "The .NET Framework C# compiler was not found. Install .NET Framework 4.8 Developer Pack."
}

& $compiler `
    /nologo `
    /target:winexe `
    /optimize+ `
    /platform:anycpu `
    /codepage:65001 `
    /reference:System.dll `
    /reference:System.Drawing.dll `
    /reference:System.Runtime.Serialization.dll `
    /reference:System.Windows.Forms.dll `
    "/out:$output" `
    $source `
    $dashboardSource

if ($LASTEXITCODE -ne 0) {
    throw "Watt Bar Windows build failed with exit code $LASTEXITCODE."
}

Write-Host "Built $output"

if ($Test) {
    $process = Start-Process -FilePath $output -ArgumentList "--self-test" -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Watt Bar Windows self-tests failed with exit code $($process.ExitCode)."
    }
    Write-Host "Windows tracking and formatting self-tests passed."
}
