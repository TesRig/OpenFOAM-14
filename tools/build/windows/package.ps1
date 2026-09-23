[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$OpenFoamDir,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$MsysRoot = 'C:\msys64',
    [switch]$Gpu
)

$ErrorActionPreference = 'Stop'
$packageName = 'openfoam-13-windows-x86_64'
$stage = Join-Path ([IO.Path]::GetTempPath()) ("openfoam-package-" + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $stage $packageName
$foamDestination = Join-Path $payload 'OpenFOAM-13-Windows'
$runtime = Join-Path $payload 'runtime'

try {
    New-Item -ItemType Directory -Force -Path $foamDestination, $runtime, $OutputDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $OpenFoamDir 'bin') -Destination $foamDestination -Recurse
    Copy-Item -LiteralPath (Join-Path $OpenFoamDir 'etc') -Destination $foamDestination -Recurse
    $sourcePlatform = Get-ChildItem -LiteralPath (Join-Path $OpenFoamDir 'platforms') -Directory | Select-Object -First 1
    $platformDestination = Join-Path $foamDestination "platforms\$($sourcePlatform.Name)"
    New-Item -ItemType Directory -Force -Path $platformDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $sourcePlatform.FullName 'bin') -Destination $platformDestination -Recurse
    Copy-Item -LiteralPath (Join-Path $sourcePlatform.FullName 'lib') -Destination $platformDestination -Recurse
    Copy-Item -LiteralPath (Join-Path $OpenFoamDir 'COPYING') -Destination $foamDestination
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'THIRD_PARTY_NOTICES.md') -Destination $payload
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tools\runtime\windows\openfoam-run.ps1') -Destination $payload
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tools\runtime\windows\openfoam-run.cmd') -Destination $payload

    foreach ($name in 'libgcc_s_seh-1.dll', 'libstdc++-6.dll', 'libwinpthread-1.dll', 'libgomp-1.dll') {
        $path = Join-Path $MsysRoot "ucrt64\bin\$name"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $runtime }
    }

    if ($Gpu) {
        $gpuRuntime = Get-ChildItem -LiteralPath (Join-Path $OpenFoamDir 'platforms') -Recurse -Filter amgxsh.dll | Select-Object -First 1
        if (-not $gpuRuntime) { throw 'GPU packaging requested, but amgxsh.dll is missing.' }
        Copy-Item -LiteralPath $gpuRuntime.FullName -Destination $runtime

        # Bundle the non-driver CUDA DLL closure used by AmgX. The display
        # driver (nvcuda.dll) remains a host prerequisite, but installing the
        # full CUDA Toolkit on end-user machines is not required.
        $objdump = Join-Path $MsysRoot 'ucrt64\bin\objdump.exe'
        if (-not (Test-Path -LiteralPath $objdump)) {
            throw 'objdump.exe is required to resolve AmgX runtime dependencies.'
        }
        $cudaPath = $env:CUDA_PATH
        if (-not $cudaPath) {
            $nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
            if ($nvcc) { $cudaPath = Split-Path -Parent (Split-Path -Parent $nvcc.Source) }
        }
        if (-not $cudaPath -or -not (Test-Path -LiteralPath (Join-Path $cudaPath 'bin'))) {
            throw 'CUDA_PATH does not identify a CUDA Toolkit installation.'
        }

        $searchDirectories = @(
            (Join-Path $cudaPath 'bin'),
            (Join-Path $MsysRoot 'ucrt64\bin'),
            $runtime
        )
        $systemDlls = @(
            'advapi32.dll', 'bcrypt.dll', 'cfgmgr32.dll', 'crypt32.dll',
            'gdi32.dll', 'kernel32.dll', 'msmpi.dll', 'nvcuda.dll',
            'ole32.dll', 'oleaut32.dll', 'rpcrt4.dll', 'shell32.dll',
            'user32.dll', 'version.dll', 'winmm.dll', 'ws2_32.dll'
        )
        $seen = @{}
        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue((Join-Path $runtime 'amgxsh.dll'))
        while ($queue.Count -gt 0) {
            $binary = $queue.Dequeue()
            $imports = & $objdump -p $binary 2>$null |
                ForEach-Object {
                    if ($_ -match '^\s*DLL Name:\s*(.+?)\s*$') { $Matches[1] }
                }
            foreach ($import in $imports) {
                $key = $import.ToLowerInvariant()
                if ($key.StartsWith('api-ms-win-') -or
                    $key.StartsWith('ext-ms-win-') -or
                    $systemDlls -contains $key -or
                    $seen.ContainsKey($key)) {
                    continue
                }
                $seen[$key] = $true
                $dependency = $null
                foreach ($directory in $searchDirectories) {
                    $candidate = Join-Path $directory $import
                    if (Test-Path -LiteralPath $candidate) {
                        $dependency = $candidate
                        break
                    }
                }
                if ($dependency) {
                    $destination = Join-Path $runtime $import
                    if (-not (Test-Path -LiteralPath $destination)) {
                        Copy-Item -LiteralPath $dependency -Destination $destination
                    }
                    $queue.Enqueue($destination)
                }
                elseif ($key -notmatch '^(ntdll|ucrtbase|vcruntime\d*|msvcp\d*)\.dll$') {
                    Write-Warning "Could not bundle imported DLL '$import' required by $binary"
                }
            }
        }

        $cudaEula = Join-Path $cudaPath 'doc\EULA.txt'
        if (Test-Path -LiteralPath $cudaEula) {
            Copy-Item -LiteralPath $cudaEula -Destination (Join-Path $runtime 'LICENSE.CUDA.txt')
        }
    }

    $platformDirectory = Get-ChildItem -LiteralPath (Join-Path $foamDestination 'platforms') -Directory | Select-Object -First 1
    $manifest = [ordered]@{
        schema = 1
        product = 'OpenFOAM-13-Windows'
        platform = 'windows-x86_64'
        abi = $platformDirectory.Name
        entrypoint = 'openfoam-run.cmd'
        cpuParallel = @{ provider = 'Microsoft MPI'; supported = $true }
        gpu = @{ provider = 'NVIDIA AmgX'; supported = [bool]$Gpu; parallel = $false }
        hostRequirements = @('Windows 10/11 x64', 'Microsoft MPI v10 runtime', 'NVIDIA driver compatible with the bundled CUDA runtime when GPU solving is used')
        source = @{
            repository = 'https://github.com/fralarco/OpenFOAM-13-Windows'
            commit = 'f57ca4c8aea92c170cb2e397f88f0dd6cfd4b81f'
        }
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runtime 'manifest.json') -Encoding UTF8

    $archive = Join-Path $OutputDir "$packageName.zip"
    Compress-Archive -LiteralPath $payload -DestinationPath $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $packageName.zip" | Set-Content -LiteralPath "$archive.sha256" -Encoding ascii
    Write-Host "Created $archive"
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

