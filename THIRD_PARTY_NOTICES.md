# Third-party notices for portable builds

The portable artifacts are assembled from separately licensed components.

- OpenFOAM is distributed under GPL-3.0. The complete license is in `COPYING`.
- The native Windows compatibility runtime is based on the unofficial
  `fralarco/OpenFOAM-13-Windows` and `ThirdParty-13-Windows` ports. Their
  upstream OpenFOAM and third-party notices remain in those source trees.
- NVIDIA AmgX is distributed under the BSD 3-Clause license. GPU-enabled
  packages include its license as `LICENSE.AMGX` beside the AmgX runtime.
- Open MPI, Scotch, GCC runtime libraries and other packaged shared libraries
  retain their respective upstream licenses.

Microsoft MPI and the NVIDIA display driver are host prerequisites and are not
redistributed by these package scripts. CUDA user-mode runtime libraries required
by AmgX are bundled when the GPU build is selected.

