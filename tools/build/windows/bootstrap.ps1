[CmdletBinding()]
param(
    [string]$MsysRoot = 'C:\msys64'
)

$ErrorActionPreference = 'Stop'
$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'

if (-not (Test-Path -LiteralPath $bash)) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'MSYS2 is missing and winget is unavailable. Install MSYS2 from https://www.msys2.org/.'
    }
    & $winget.Source install --id MSYS2.MSYS2 --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bash)) {
        throw 'MSYS2 installation failed.'
    }
}

$packages = @(
    'git', 'make', 'flex', 'bison', 'diffutils', 'patch', 'rsync', 'zip',
    'mingw-w64-ucrt-x86_64-gcc',
    'mingw-w64-ucrt-x86_64-tools'
) -join ' '

& $bash -lc "pacman -Sy --needed --noconfirm $packages"
if ($LASTEXITCODE -ne 0) {
    throw 'MSYS2 dependency installation failed.'
}

$mpiHeader = 'C:\Program Files (x86)\Microsoft SDKs\MPI\Include\mpi.h'
$mpiRuntime = 'C:\Windows\System32\msmpi.dll'
if (-not (Test-Path -LiteralPath $mpiHeader) -or -not (Test-Path -LiteralPath $mpiRuntime)) {
    Write-Warning 'Install both the Microsoft MPI v10 runtime and SDK before building CPU-parallel support.'
    Write-Host 'https://learn.microsoft.com/message-passing-interface/microsoft-mpi'
}

Write-Host 'Windows build dependencies are ready.'

