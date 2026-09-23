[CmdletBinding()]
param(
    [string]$Case = (Get-Location).Path,
    [ValidateRange(1, 4096)][int]$Ranks = 1,
    [switch]$Gpu,
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(ValueFromRemainingArguments)][string[]]$SolverArguments
)

$ErrorActionPreference = 'Stop'
$packageRoot = $PSScriptRoot
$foamRoot = Join-Path $packageRoot 'OpenFOAM-13-Windows'
$platform = Get-ChildItem -LiteralPath (Join-Path $foamRoot 'platforms') -Directory | Select-Object -First 1
$bin = Join-Path $platform.FullName 'bin'
$lib = Join-Path $platform.FullName 'lib'
$runtime = Join-Path $packageRoot 'runtime'
$mpiBin = if ($env:MSMPI_BIN) { $env:MSMPI_BIN.TrimEnd('\') } else { 'C:\Program Files\Microsoft MPI\Bin' }

if ($Gpu -and $Ranks -gt 1) {
    throw 'The AmgX plugin currently supports one process/GPU only. Use -Ranks 1.'
}

$env:WM_PROJECT_DIR = $foamRoot
$env:WM_PROJECT = 'OpenFOAM'
$env:WM_PROJECT_VERSION = '13'
$env:WM_OPTIONS = $platform.Name
$env:FOAM_APPBIN = $bin
$env:FOAM_LIBBIN = $lib
$env:FOAM_MPI = 'msmpi'
$env:MPI_BUFFER_SIZE = '20000000'
$env:Path = "$bin;$lib;$(Join-Path $lib 'msmpi');$runtime;$mpiBin;$($env:Path)"
if ($Gpu) { $env:FOAM_GPU_BACKEND = 'amgx' }

$program = Join-Path $bin ([IO.Path]::GetFileNameWithoutExtension($Executable) + '.exe')
if (-not (Test-Path -LiteralPath $program)) {
    throw "OpenFOAM executable not found: $program"
}
if (-not (Test-Path -LiteralPath $Case)) {
    throw "Case directory not found: $Case"
}

Push-Location -LiteralPath $Case
try {
    if ($Ranks -gt 1) {
        $mpiexec = Join-Path $mpiBin 'mpiexec.exe'
        if (-not (Test-Path -LiteralPath $mpiexec)) {
            throw 'Microsoft MPI runtime is not installed.'
        }
        & $mpiexec -n $Ranks $program @SolverArguments -parallel
    }
    else {
        & $program @SolverArguments
    }
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}

