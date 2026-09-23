# Portable Linux, Windows, MPI, and GPU builds

The repository now produces installer-ready archives in `dist/`:

| Artifact | OpenFOAM source | CPU parallel | GPU linear solver |
| --- | --- | --- | --- |
| `openfoam-14-linux-x86_64.tar.xz` | Pinned TesRig/OpenFOAM-14 commit `e103ea86f` | Open MPI | NVIDIA AmgX |
| `openfoam-13-windows-x86_64.zip` | Pinned Foundation 13 Windows port | Microsoft MPI | NVIDIA AmgX |

Each archive has a neighboring `.sha256` file for installer integrity checks.
The Windows artifact is explicitly named as OpenFOAM 13: it is an installer-ready
native compatibility runtime, not a mislabeled OpenFOAM 14 binary.

The Windows artifact is a native PE/COFF MinGW-w64 build - no WSL or Cygwin
runtime. It uses the maintained Windows port at commit
`f57ca4c8aea92c170cb2e397f88f0dd6cfd4b81f`. The unmodified OpenFOAM 14 tree cannot be compiled
for Windows by swapping compilers alone: it needs the port's case-collision
renames, Win32 OS layer, PE link closure, and MS-MPI Pstream implementation.

## Quick start

Run PowerShell from the repository root.

```powershell
# Install Linux/WSL build dependencies. This prompts for the WSL sudo password.
wsl -d Ubuntu -- bash tools/build/linux/bootstrap.sh --gpu

# Install MSYS2/UCRT64 dependencies. Install the MS-MPI runtime + SDK too.
.\tools\build\windows\bootstrap.ps1

# Build and package both platforms with CPU MPI and NVIDIA GPU support.
.\build.ps1 -Target All -Gpu -Jobs 12
```

Build only one platform with `-Target Linux` or `-Target Windows`. The Linux
build is staged on WSL's ext4 filesystem under
`~/.cache/openfoam-portable`; compiling a large C++ tree directly under
`/mnt/c` or `/mnt/e` is substantially slower. The Windows build defaults to
`C:\OFBuild` because the MinGW linker is sensitive to long paths; override it
with `-WindowsBuildRoot`.

The Linux script seeds that ext4 build tree from the pinned TesRig/OpenFOAM-14
commit `e103ea86fc7726097999e0840ad149344aee978b`, then overlays this working tree.
This is required because the source contains filenames that differ only by
case; an NTFS checkout silently loses one member of each pair.
Set `OPENFOAM_OVERLAY_FULL_SOURCE=1` inside WSL only when intentionally modifying
core OpenFOAM files in a case-sensitive checkout. The default fast path overlays
only this project's tools, extension, and packaging metadata. Do not enable it
from a normal NTFS checkout: OpenFOAM 14 contains paths that differ only by case,
and Git on NTFS makes those paths appear as a large set of modified files.

`-SkipBuild` repackages an existing build. `-SkipPackage` compiles without
creating an archive.

## Installer integration contract

Extract each archive without changing its internal layout, then launch only
through its root entrypoint. The launcher establishes all runtime paths and
returns the solver's exit code.

Linux:

```bash
./openfoam-run --case /data/case --ranks 8 -- foamRun
```

Windows:

```powershell
.\openfoam-run.cmd -Case C:\data\case -Ranks 8 -Executable foamRun
```

Each package contains `runtime/manifest.json`. The consuming installer should
read it to check the ABI and prerequisites. Do not add the package globally to
`PATH`; invoke the entrypoint by absolute path. Case data should live outside
the installation directory.

Windows CPU parallel runs require the Microsoft MPI v10 runtime on the target
machine. The application installer should chain Microsoft's redistributable.
The Microsoft runtime is not copied into this package.

Linux CPU parallel runs require an Open MPI 4-compatible `mpirun` on the target
machine. The solver-side shared libraries are bundled, but the process launcher
is treated as an installer prerequisite.

## GPU solving

GPU builds add the runtime-selectable `AmgX` linear solver. The host needs an
NVIDIA GPU and a driver compatible with the packaged CUDA/AmgX build. Add this
to `system/controlDict`:

```foam
libs ("libamgxFoam.so");
```

Then select it in `system/fvSolution`, for example:

```foam
solvers
{
    p
    {
        solver      AmgX;
        tolerance   1e-7;
        relTol      0.05;
        maxIter     200;
    }
}
```

Launch with `--gpu` on Linux or `-Gpu` on Windows. The current adapter supports
one GPU process and uncoupled matrix interfaces. It rejects MPI and coupled
interfaces instead of returning a mathematically invalid partition-local
solution. CPU MPI and GPU solve modes are therefore separate in this version.

## Validation

After building, run:

```powershell
.\tools\test\validate-build.ps1 -Dist .\dist
```

For CPU MPI validation, copy the `pitzDaily` tutorial to a writable case
directory, decompose it, and run two ranks. GPU validation should use a case
without cyclic/processor interfaces and compare final residuals against an
OpenFOAM CPU solver before performance testing.

## Reproducibility and licensing

The Windows OpenFOAM and ThirdParty repositories and NVIDIA AmgX are pinned in
the scripts. Portable artifacts contain GPL and third-party notices. If the
installer redistributes additional CUDA runtime DLLs or shared objects, review
NVIDIA's current redistribution terms before shipping them.

