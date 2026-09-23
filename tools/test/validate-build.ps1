[CmdletBinding()]
param(
    [string]$Dist = (Join-Path $PSScriptRoot '..\..\dist'),
    [switch]$RequireGpu
)

$ErrorActionPreference = 'Stop'
$distPath = (Resolve-Path -LiteralPath $Dist).Path
$validated = 0

function Assert-ArchiveEntry {
    param(
        [string[]]$Entries,
        [string]$Pattern,
        [string]$Archive
    )
    if (-not ($Entries | Where-Object { $_ -like $Pattern } | Select-Object -First 1)) {
        throw "$Archive is missing required entry: $Pattern"
    }
}

function Assert-ArchiveHash {
    param([string]$Archive)
    $sidecar = "$Archive.sha256"
    if (-not (Test-Path -LiteralPath $sidecar)) {
        throw "$Archive is missing its SHA-256 sidecar."
    }
    $expected = ((Get-Content -LiteralPath $sidecar -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    if ($actual -ine $expected) { throw "SHA-256 validation failed for $Archive" }
}

$linuxArchive = Join-Path $distPath 'openfoam-14-linux-x86_64.tar.xz'
if (Test-Path -LiteralPath $linuxArchive) {
    Assert-ArchiveHash $linuxArchive
    $entries = @(& tar -tf $linuxArchive)
    if ($LASTEXITCODE -ne 0) { throw "Cannot read $linuxArchive" }
    Assert-ArchiveEntry $entries 'openfoam-14-linux-x86_64/openfoam-run' $linuxArchive
    Assert-ArchiveEntry $entries '*/runtime/manifest.json' $linuxArchive
    Assert-ArchiveEntry $entries '*/platforms/*/bin/foamRun' $linuxArchive
    Assert-ArchiveEntry $entries '*/platforms/*/lib/libOpenFOAM.so' $linuxArchive
    if ($RequireGpu) {
        Assert-ArchiveEntry $entries '*/platforms/*/lib/libamgxFoam.so' $linuxArchive
        Assert-ArchiveEntry $entries '*/runtime/lib/libamgxsh.so*' $linuxArchive
    }
    $manifestText = (& tar -xOf $linuxArchive 'openfoam-14-linux-x86_64/runtime/manifest.json') -join "`n"
    $manifest = $manifestText | ConvertFrom-Json
    if (-not $manifest.cpuParallel.supported) { throw 'Linux manifest does not enable CPU MPI.' }
    if ($RequireGpu -and -not $manifest.gpu.supported) { throw 'Linux manifest does not enable GPU solving.' }
    Write-Host "Validated $linuxArchive"
    $validated++
}

$windowsArchive = Join-Path $distPath 'openfoam-13-windows-x86_64.zip'
if (Test-Path -LiteralPath $windowsArchive) {
    Assert-ArchiveHash $windowsArchive
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($windowsArchive)
    try {
        $entries = @($zip.Entries | ForEach-Object FullName)
        Assert-ArchiveEntry $entries 'openfoam-13-windows-x86_64/openfoam-run.cmd' $windowsArchive
        Assert-ArchiveEntry $entries '*/runtime/manifest.json' $windowsArchive
        Assert-ArchiveEntry $entries '*/platforms/*/bin/foamRun.exe' $windowsArchive
        Assert-ArchiveEntry $entries '*/platforms/*/lib/libOpenFOAM.dll' $windowsArchive
        if ($RequireGpu) {
            Assert-ArchiveEntry $entries '*/platforms/*/lib/libamgxFoam.dll' $windowsArchive
            Assert-ArchiveEntry $entries '*/runtime/amgxsh.dll' $windowsArchive
        }
        $manifestEntry = $zip.Entries | Where-Object FullName -like '*/runtime/manifest.json' | Select-Object -First 1
        $reader = [IO.StreamReader]::new($manifestEntry.Open())
        try { $manifest = ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose() }
        if (-not $manifest.cpuParallel.supported) { throw 'Windows manifest does not enable CPU MPI.' }
        if ($RequireGpu -and -not $manifest.gpu.supported) { throw 'Windows manifest does not enable GPU solving.' }
    }
    finally {
        $zip.Dispose()
    }
    Write-Host "Validated $windowsArchive"
    $validated++
}

if ($validated -eq 0) {
    throw "No OpenFOAM portable archives were found in $distPath"
}

Write-Host "Validation complete: $validated archive(s)."

