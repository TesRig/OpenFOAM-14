#!/usr/bin/env bash
set -euo pipefail

project_dir=""
jobs="$(nproc)"
while (($#)); do
    case "$1" in
        --project) project_dir="$2"; shift 2 ;;
        --jobs) jobs="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v nvcc >/dev/null 2>&1 || {
    echo "CUDA compiler not found. Run tools/build/linux/bootstrap.sh --gpu." >&2
    exit 3
}

: "${FOAM_LIBBIN:?Source the OpenFOAM environment before building AmgX support}"
amgx_base="${OPENFOAM_AMGX_BUILD_ROOT:-$HOME/.cache/openfoam-portable/amgx}"
amgx_source="$amgx_base/source"
amgx_build="$amgx_base/build"
amgx_install="$amgx_base/install"

if [[ ! -d "$amgx_source/.git" ]]; then
    git clone --branch v2.4.0 --depth 1 --recursive \
        https://github.com/NVIDIA/AMGX.git "$amgx_source"
fi
git -C "$amgx_source" submodule update --init --recursive

cuda_architectures="${OPENFOAM_CUDA_ARCHITECTURES:-75}"

cmake -S "$amgx_source" -B "$amgx_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$amgx_install" \
    -DCUDA_ARCH="$cuda_architectures" \
    -DCMAKE_NO_MPI=ON \
    -DAMGX_NO_RPATH=ON
cmake --build "$amgx_build" --parallel "$jobs"
cmake --install "$amgx_build"
cp "$amgx_source/LICENSE" "$amgx_install/LICENSE.AMGX"

export AMGX_ROOT="$amgx_install"
wmake libso "$project_dir/extensions/amgxFoam"

mkdir -p "$FOAM_LIBBIN/amgx-runtime"
find "$amgx_install" -type f \( -name 'libamgxsh.so*' -o -name 'libamgx.so*' \) \
    -exec cp -aL {} "$FOAM_LIBBIN/amgx-runtime/" \;
cp "$amgx_install/LICENSE.AMGX" "$FOAM_LIBBIN/amgx-runtime/"

echo "AmgX solver plugin built at $FOAM_LIBBIN/libamgxFoam.so"

