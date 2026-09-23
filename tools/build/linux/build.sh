#!/usr/bin/env bash
set -euo pipefail

source_dir=""
jobs="$(nproc)"
with_gpu=0
skip_build=0
skip_package=0

while (($#)); do
    case "$1" in
        --source) source_dir="$2"; shift 2 ;;
        --jobs) jobs="$2"; shift 2 ;;
        --gpu) with_gpu="$2"; shift 2 ;;
        --skip-build) skip_build="$2"; shift 2 ;;
        --skip-package) skip_package="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$source_dir" && -f "$source_dir/Allwmake" ]] || {
    echo "--source must identify this OpenFOAM source tree" >&2
    exit 2
}

for tool in gcc g++ make flex bison mpicc mpirun rsync; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing '$tool'. Run tools/build/linux/bootstrap.sh first." >&2
        exit 3
    }
done

build_base="${OPENFOAM_LINUX_BUILD_ROOT:-$HOME/.cache/openfoam-portable}"
install_root="$build_base/OpenFOAM"
project_dir="$install_root/OpenFOAM-14"
upstream_dir="$build_base/upstream/TesRig-OpenFOAM-14"
upstream_url="${OPENFOAM_UPSTREAM_URL:-https://github.com/TesRig/OpenFOAM-14.git}"
# Pinned TesRig OpenFOAM 14 revision.  The
# checkout must live on WSL's case-sensitive filesystem; an NTFS checkout loses
# headers such as PointHit.H/pointHit.H and cannot be compiled on Linux.
upstream_commit="${OPENFOAM_UPSTREAM_COMMIT:-e103ea86fc7726097999e0840ad149344aee978b}"

if [[ ! -d "$upstream_dir/.git" ]]; then
    mkdir -p "$(dirname "$upstream_dir")"
    git clone --filter=blob:none --no-checkout "$upstream_url" "$upstream_dir"
fi

if ! git -C "$upstream_dir" cat-file -e "$upstream_commit^{commit}" 2>/dev/null; then
    git -C "$upstream_dir" fetch --depth 1 origin "$upstream_commit"
fi

if [[ "$(git -C "$upstream_dir" rev-parse HEAD 2>/dev/null || true)" != "$upstream_commit" \
   || ! -f "$upstream_dir/Allwmake" ]]; then
    # --no-checkout clones still have HEAD at the requested commit. Also test
    # the work tree so an interrupted initial clone is repaired on the retry.
    git -C "$upstream_dir" checkout --detach --force "$upstream_commit"
fi

mkdir -p "$project_dir"
# Seed all official files first, including names which differ only by case.
rsync -a --exclude '/.git/' "$upstream_dir/" "$project_dir/"
# Overlay this project's build/runtime additions.  The upstream commit is the
# exact source snapshot, so copying the entire NTFS tree on every incremental
# build only changes timestamps and can take several minutes.  Developers who
# intentionally edit OpenFOAM core files can opt into the full overlay.
if [[ "${OPENFOAM_OVERLAY_FULL_SOURCE:-0}" == 1 ]]; then
    rsync -a \
        --exclude '/.build/' --exclude '/dist/' --exclude '/platforms/' \
        --exclude '/.git/' \
        "$source_dir/" "$project_dir/"
else
    rsync -a "$source_dir/tools/" "$project_dir/tools/"
    rsync -a "$source_dir/extensions/" "$project_dir/extensions/"
    cp -f "$source_dir/BUILD_PORTABLE.md" "$project_dir/BUILD_PORTABLE.md"
    cp -f "$source_dir/THIRD_PARTY_NOTICES.md" "$project_dir/THIRD_PARTY_NOTICES.md"
fi

cd "$project_dir"
# shellcheck disable=SC1091
set +u
source etc/bashrc \
    WM_MPLIB=SYSTEMOPENMPI \
    SCOTCH_TYPE=system \
    ZOLTAN_TYPE=none \
    METIS_TYPE=system \
    PARMETIS_TYPE=none \
    ParaView_TYPE=none
set -u

if (( ! skip_build )); then
    # Refresh generated header links after overlaying the local snapshot.  This
    # also repairs a build directory first created from a case-insensitive copy.
    wmakeLnIncludeAll -update -j "$jobs"
    ./Allwmake -j "$jobs"
fi

if (( with_gpu )); then
    "$project_dir/tools/build/linux/build-amgx.sh" \
        --project "$project_dir" --jobs "$jobs"
fi

if (( ! skip_package )); then
    "$project_dir/tools/build/linux/package.sh" \
        --project "$project_dir" \
        --output "$source_dir/dist" \
        --gpu "$with_gpu"
fi

