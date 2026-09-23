[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$OpenFoamDir,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$MsysRoot = 'C:\msys64',
    [ValidateRange(1, 256)][int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = 'Stop'
$amgxSource = Join-Path $BuildRoot 'AMGX'
$amgxBuild = Join-Path $BuildRoot 'AMGX-build'
$amgxInstall = Join-Path $BuildRoot 'AMGX-install'
$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'

$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$env:MSYS2_PATH_TYPE = 'inherit'

if (-not (Test-Path -LiteralPath (Join-Path $amgxSource '.git'))) {
    git clone --branch v2.4.0 --depth 1 --recursive https://github.com/NVIDIA/AMGX.git $amgxSource
    if ($LASTEXITCODE -ne 0) { throw 'Failed to clone NVIDIA AMGX.' }
}
git -C $amgxSource submodule update --init --recursive
if ($LASTEXITCODE -ne 0) { throw 'Failed to initialise NVIDIA AMGX submodules.' }

$cudaArchitectures = if ($env:OPENFOAM_CUDA_ARCHITECTURES) { $env:OPENFOAM_CUDA_ARCHITECTURES } else { '75' }
cmake -S $amgxSource -B $amgxBuild -G 'Visual Studio 17 2022' -A x64 `
    -DCMAKE_INSTALL_PREFIX=$amgxInstall `
    -DCUDA_ARCH=$cudaArchitectures `
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded `
    -DCMAKE_NO_MPI=ON `
    -DAMGX_NO_RPATH=ON
if ($LASTEXITCODE -ne 0) { throw 'AMGX configuration failed.' }
cmake --build $amgxBuild --config Release --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'AMGX build failed.' }
cmake --install $amgxBuild --config Release
if ($LASTEXITCODE -ne 0) { throw 'AMGX installation failed.' }

Copy-Item -LiteralPath (Join-Path $amgxSource 'LICENSE') `
    -Destination (Join-Path $amgxInstall 'LICENSE.AMGX') -Force

$amgxDll = Get-ChildItem -LiteralPath $amgxInstall -Recurse -Filter amgxsh.dll | Select-Object -First 1
if (-not $amgxDll) { throw 'AMGX build did not produce amgxsh.dll.' }

$toMsys = {
    param([string]$Path)
    (& $bash -lc 'cygpath -u "$1"' _ $Path).Trim()
}
$openFoamMsys = & $toMsys $OpenFoamDir
$buildRootMsys = & $toMsys $BuildRoot
$amgxInstallMsys = & $toMsys $amgxInstall
$amgxDllMsys = & $toMsys $amgxDll.FullName

$gpuBuild = @"
set -euo pipefail
export OF13_ROOT='$buildRootMsys'
export OF13_CLONE='$openFoamMsys'
export OF13_THIRDPARTY='$buildRootMsys/ThirdParty-13-Windows'
export WM_MPLIB=MSMPI FOAM_MPI=msmpi
export OPENFOAM_WINDOWS_MSYS_LINKS=winsymlinks:deepcopy
source '$openFoamMsys/scripts/windows/env.sh'
export AMGX_ROOT='$amgxInstallMsys'
mkdir -p \"`$AMGX_ROOT/lib\" \"`$FOAM_LIBBIN/amgx-runtime\"
gendef '$amgxDllMsys'
dlltool -d amgxsh.def -D amgxsh.dll -l \"`$AMGX_ROOT/lib/libamgxsh.a\"
cp '$amgxDllMsys' \"`$FOAM_LIBBIN/amgx-runtime/amgxsh.dll\"
cp \"`$AMGX_ROOT/LICENSE.AMGX\" \"`$FOAM_LIBBIN/amgx-runtime/LICENSE.AMGX\"
wmake libso '$openFoamMsys/extensions/amgxFoam'
"@
& $bash -lc $gpuBuild
if ($LASTEXITCODE -ne 0) { throw 'OpenFOAM AmgX plugin build failed.' }

