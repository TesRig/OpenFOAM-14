[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,
    [string]$BuildRoot = 'C:\OFBuild',
    [ValidateRange(1, 256)]
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$Gpu,
    [switch]$SkipBuild,
    [switch]$SkipPackage,
    [string]$MsysRoot = 'C:\msys64'
)

$ErrorActionPreference = 'Stop'
$portCommit = 'f57ca4c8aea92c170cb2e397f88f0dd6cfd4b81f'
$thirdPartyCommit = '8fee8283fa502f4835a94dc2291581fc2b053d4d'
$openFoamDir = Join-Path $BuildRoot 'OpenFOAM-13-Windows'
$thirdPartyDir = Join-Path $BuildRoot 'ThirdParty-13-Windows'
$bash = Join-Path $MsysRoot 'usr\bin\bash.exe'

# bash.exe does not select an MSYS2 subsystem by itself.  The native port
# requires the UCRT64 environment so gcc, dlltool and runtime DLLs all use the
# same Windows CRT ABI.
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$env:MSYS2_PATH_TYPE = 'inherit'

if (-not (Test-Path -LiteralPath $bash)) {
    throw "MSYS2 was not found at $MsysRoot. Run tools/build/windows/bootstrap.ps1."
}

New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null

function Sync-PinnedRepository {
    param([string]$Url, [string]$Path, [string]$Commit)
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) {
        git clone $Url $Path
        if ($LASTEXITCODE -ne 0) { throw "Clone failed: $Url" }
    }
    git -C $Path fetch origin $Commit --depth=1
    if ($LASTEXITCODE -ne 0) { throw "Fetch failed: $Url@$Commit" }
    git -C $Path checkout --detach $Commit
    if ($LASTEXITCODE -ne 0) { throw "Checkout failed: $Url@$Commit" }
}

Sync-PinnedRepository -Url 'https://github.com/fralarco/OpenFOAM-13-Windows.git' -Path $openFoamDir -Commit $portCommit
Sync-PinnedRepository -Url 'https://github.com/fralarco/ThirdParty-13-Windows.git' -Path $thirdPartyDir -Commit $thirdPartyCommit

# The upstream port defaults to native NTFS symlinks, which require Developer
# Mode or an elevated token.  Select MSYS2's deep-copy mode so installer builds
# also work on locked-down build hosts.  Keep this as a small, auditable patch
# over the pinned port instead of modifying the downloaded source implicitly.
$linkPatch = Join-Path $ProjectRoot 'tools\build\windows\patches\non-admin-links.patch'
$environmentScript = Join-Path $openFoamDir 'scripts\windows\env.sh'
$environmentText = Get-Content -LiteralPath $environmentScript -Raw
if ($environmentText.Contains('export MSYS=winsymlinks:nativestrict')) {
    git -C $openFoamDir apply $linkPatch
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply the non-admin lnInclude patch.' }
}
elseif (-not $environmentText.Contains('OPENFOAM_WINDOWS_MSYS_LINKS')) {
    throw 'The pinned port has an unexpected MSYS link-mode configuration.'
}

$extensionRoot = Join-Path $openFoamDir 'extensions'
New-Item -ItemType Directory -Force -Path $extensionRoot | Out-Null
$stagedAmgxFoam = Join-Path $extensionRoot 'amgxFoam'
if (Test-Path -LiteralPath $stagedAmgxFoam) {
    # This is a generated clone-side staging directory. Replacing it prevents
    # PowerShell from nesting amgxFoam/amgxFoam on incremental builds.
    Remove-Item -LiteralPath $stagedAmgxFoam -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'extensions\amgxFoam') `
    -Destination $stagedAmgxFoam -Recurse -Force

$toMsys = {
    param([string]$Path)
    (& $bash -lc 'cygpath -u "$1"' _ $Path).Trim()
}
$buildRootMsys = & $toMsys $BuildRoot
$openFoamMsys = & $toMsys $openFoamDir
$projectRootMsys = & $toMsys $ProjectRoot

if (-not $SkipBuild) {
    $serialBuild = @"
set -euo pipefail
export OF13_ROOT='$buildRootMsys'
export OF13_CLONE='$openFoamMsys'
export OF13_THIRDPARTY='$buildRootMsys/ThirdParty-13-Windows'
export WM_NCOMPPROCS='$Jobs'
export WM_MPLIB=Dummy FOAM_MPI=dummy
export OPENFOAM_WINDOWS_MSYS_LINKS=winsymlinks:deepcopy
source '$openFoamMsys/scripts/windows/env.sh'
cd \"`$WM_PROJECT_DIR\"
if [ ! -f .portable-deepcopy-links ]; then
    wcleanLnIncludeAll
    touch .portable-deepcopy-links
fi
./Allwmake -j '$Jobs'
bash scripts/windows/setup_msmpi.sh
bash scripts/windows/build_pstream_mpi.sh
"@
    & $bash -lc $serialBuild
    if ($LASTEXITCODE -ne 0) { throw 'Native Windows OpenFOAM build failed.' }
}

if ($Gpu) {
    & (Join-Path $ProjectRoot 'tools\build\windows\build-amgx.ps1') `
        -ProjectRoot $ProjectRoot -OpenFoamDir $openFoamDir -BuildRoot $BuildRoot `
        -MsysRoot $MsysRoot -Jobs $Jobs
}

if (-not $SkipPackage) {
    & (Join-Path $ProjectRoot 'tools\build\windows\package.ps1') `
        -ProjectRoot $ProjectRoot -OpenFoamDir $openFoamDir -OutputDir (Join-Path $ProjectRoot 'dist') `
        -MsysRoot $MsysRoot -Gpu:$Gpu
}

