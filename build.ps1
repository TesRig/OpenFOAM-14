[CmdletBinding()]
param(
    [ValidateSet('Linux', 'Windows', 'All')]
    [string]$Target = 'All',
    [ValidateRange(1, 256)]
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$Gpu,
    [string]$WslDistribution = 'Ubuntu',
    [string]$WindowsBuildRoot = 'C:\OFBuild',
    [switch]$SkipBuild,
    [switch]$SkipPackage
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot

function Invoke-LinuxBuild {
    $wslPath = (& wsl.exe -d $WslDistribution -- wslpath -a ($projectRoot -replace '\\', '/')).Trim()
    if (-not $wslPath) {
        throw "Could not translate the project path for WSL distribution '$WslDistribution'."
    }

    $gpuValue = if ($Gpu) { '1' } else { '0' }
    $skipBuildValue = if ($SkipBuild) { '1' } else { '0' }
    $skipPackageValue = if ($SkipPackage) { '1' } else { '0' }
    $command = @(
        'bash', "$wslPath/tools/build/linux/build.sh",
        '--source', $wslPath,
        '--jobs', $Jobs,
        '--gpu', $gpuValue,
        '--skip-build', $skipBuildValue,
        '--skip-package', $skipPackageValue
    )

    # Windows PowerShell 5 wraps normal native stderr (for example Git clone
    # progress) as ErrorRecord objects. Do not let that terminate this wrapper;
    # the WSL process exit code is the authoritative build result.
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & wsl.exe -d $WslDistribution -- @command
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($exitCode -ne 0) {
        throw "Linux build failed with exit code $exitCode."
    }
}

function Invoke-WindowsBuild {
    & "$projectRoot\tools\build\windows\build.ps1" `
        -ProjectRoot $projectRoot `
        -BuildRoot $WindowsBuildRoot `
        -Jobs $Jobs `
        -Gpu:$Gpu `
        -SkipBuild:$SkipBuild `
        -SkipPackage:$SkipPackage
}

switch ($Target) {
    'Linux' { Invoke-LinuxBuild }
    'Windows' { Invoke-WindowsBuild }
    'All' {
        Invoke-LinuxBuild
        Invoke-WindowsBuild
    }
}

