#!/usr/bin/env bash
set -euo pipefail

with_gpu=0
if [[ "${1:-}" == "--gpu" ]]; then
    with_gpu=1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "This bootstrap script supports Debian/Ubuntu systems only." >&2
    exit 2
fi

sudo apt-get update
sudo apt-get install -y \
    build-essential bison flex cmake ninja-build git rsync patchelf zip zstd \
    libopenmpi-dev openmpi-bin libscotch-dev libscotchparmetis-dev \
    libboost-system-dev libboost-thread-dev libcgal-dev libfftw3-dev \
    libreadline-dev libncurses-dev libxt-dev zlib1g-dev libmetis-dev

if (( with_gpu )); then
    sudo apt-get install -y nvidia-cuda-toolkit
fi

echo "Linux/WSL build dependencies are installed."

