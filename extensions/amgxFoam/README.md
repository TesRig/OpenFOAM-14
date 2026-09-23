# AmgX OpenFOAM solver plugin

This runtime-selectable `lduMatrix` solver offloads a serial OpenFOAM linear
system to NVIDIA AmgX. It supports double precision with 32-bit labels, which
matches the packaged `DPInt32` builds.

Load the plugin in `system/controlDict`:

```foam
libs ("libamgxFoam.so");
```

Select it for a field in `system/fvSolution`:

```foam
solvers
{
    p
    {
        solver          AmgX;
        tolerance       1e-7;
        relTol          0.05;
        maxIter         200;
    }
}
```

The generated default uses FGMRES with an aggregation AMG preconditioner. To
use a custom AmgX JSON configuration, add `amgxConfigFile` to the solver
dictionary.

Current limitations are explicit: one process, NVIDIA CUDA, and no coupled
matrix interfaces. Native OpenFOAM solvers remain available for MPI CPU runs.

