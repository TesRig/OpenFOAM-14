#!/usr/bin/env bash
set -euo pipefail

project_dir=""
output_dir=""
with_gpu=0
while (($#)); do
    case "$1" in
        --project) project_dir="$2"; shift 2 ;;
        --output) output_dir="$2"; shift 2 ;;
        --gpu) with_gpu="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

: "${WM_OPTIONS:?Source the OpenFOAM environment before packaging}"
package_name="openfoam-14-linux-x86_64"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
payload="$stage/$package_name"
foam_dst="$payload/OpenFOAM/OpenFOAM-14"

mkdir -p "$foam_dst" "$payload/runtime/lib" "$output_dir"
rsync -a \
    --include='/bin/***' --include='/etc/***' \
    --include='/platforms/' --include="/platforms/$WM_OPTIONS/" \
    --include="/platforms/$WM_OPTIONS/bin/***" \
    --include="/platforms/$WM_OPTIONS/lib/***" \
    --include='/COPYING' --include='/README.org' --exclude='*' \
    "$project_dir/" "$foam_dst/"
install -m 0755 "$project_dir/tools/runtime/linux/openfoam-run" "$payload/openfoam-run"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$payload/THIRD_PARTY_NOTICES.md"

# Bundle non-glibc dependencies so the artifact is portable across compatible
# x86-64 distributions. The kernel, glibc and GPU driver remain host contracts.
while IFS= read -r binary; do
    ldd "$binary" 2>/dev/null | awk '/=> \// {print $3} /^\// {print $1}' || true
done < <(find "$foam_dst/platforms/$WM_OPTIONS" -type f -perm -u+x) |
    sort -u |
    grep -Ev '/(ld-linux|libc\.so|libm\.so|libpthread\.so|librt\.so|libdl\.so|libutil\.so|libresolv\.so|libcuda\.so|libnvidia[^/]*\.so)' |
    while IFS= read -r library; do
        [[ -f "$library" ]] && cp -aL "$library" "$payload/runtime/lib/"
    done

if (( with_gpu )); then
    cp -aL "$foam_dst/platforms/$WM_OPTIONS/lib/amgx-runtime/"* "$payload/runtime/lib/"
fi

cat > "$payload/runtime/manifest.json" <<EOF
{
  "schema": 1,
  "product": "OpenFOAM-14",
  "platform": "linux-x86_64",
  "abi": "$WM_OPTIONS",
  "entrypoint": "openfoam-run",
  "cpuParallel": { "provider": "Open MPI", "supported": true },
  "gpu": { "provider": "NVIDIA AmgX", "supported": $([[ "$with_gpu" == 1 ]] && echo true || echo false), "parallel": false },
  "hostRequirements": ["x86-64 Linux kernel", "glibc >= 2.35", "Open MPI 4 process launcher for multi-rank runs", "NVIDIA driver when GPU solving is used"],
  "source": {
    "repository": "https://github.com/TesRig/OpenFOAM-14",
    "commit": "e103ea86fc7726097999e0840ad149344aee978b"
  }
}
EOF

archive="$output_dir/$package_name.tar.xz"
tar -C "$stage" -cJf "$archive" "$package_name"
(
    cd "$output_dir"
    sha256sum "$package_name.tar.xz" > "$package_name.tar.xz.sha256"
)
echo "Created $archive"

