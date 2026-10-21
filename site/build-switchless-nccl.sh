#!/usr/bin/env bash
# Build NCCL 2.30.7 with RiNGSiDE's switchless dual-PF patches (four IPv4 GIDs a listener, routes that keep the
# local PCIe function's root) in the site image's toolchain, and install it on every Spark at NCCL_LIB_DIR
# (default ~/.local/share/glm53-switchless-nccl). TensorFold loads it through TF_NCCL_LIB (start.sh, NCCL_LIB_DIR),
# so the ring exchange's links can use a port's PCIe twin with this site's addressing (both functions of a port in one
# /24). Source: NVIDIA/nccl 73cf112295c33aee2b895f329f592f2a9b4b0f97 (v2.30.7-1) with
# GLM-5.3-Flash-NVFP4-2x-4x-DGX-Sparks-RiNGSiDE patches/nccl 0001 and 0002 (tree 9edccf0677e3...). The measured
# library: sha256 a196b2d8daa0c9cf004f0c60b8a5066b0669f401b5aa046d47eb04e6f1788064 (rebuilds are not bit-identical).
set -euo pipefail
ringside=${RINGSIDE:-$HOME/ai/GLM-5.3-Flash-NVFP4-2x-4x-DGX-Sparks-RiNGSiDE}
image=${IMAGE:-tensorfold-glm53:v0.6.0-tp4-stock64k-94cce4bf6ee4}
dest=${NCCL_LIB_DIR:-$HOME/.local/share/glm53-switchless-nccl}
work=${WORK:-$HOME/.cache/glm53-switchless-nccl-build}
mkdir -p "$work"
cd "$work"
if [[ ! -d nccl/.git ]]; then
  git init -q nccl
  git -C nccl fetch -q --depth 1 https://github.com/NVIDIA/nccl.git 73cf112295c33aee2b895f329f592f2a9b4b0f97
  git -C nccl checkout -q FETCH_HEAD
  git -C nccl apply --index "$ringside/patches/nccl/0001-switchless-ring-setup-and-listener-hardening.patch"
  git -C nccl apply --index "$ringside/patches/nccl/0002-dual-pf-four-gid-routing.patch"
fi
[[ "$(git -C nccl write-tree)" == 9edccf0677e35c9b451eb2f5e037dfb9e6677a93 ]] || { echo "unexpected NCCL tree" >&2; exit 1; }
docker run --rm -v "$work/nccl:/nccl" -w /nccl --entrypoint bash "$image" -c \
  "make -j18 src.build CUDA_HOME=/usr/local/cuda NVCC_GENCODE='-gencode=arch=compute_121,code=sm_121' >/nccl/build.log 2>&1 && chown -R $(id -u):$(id -g) /nccl/build"
for host in localhost ${WORKERS:-192.168.0.180 192.168.0.244 192.168.0.25}; do
  if [[ $host == localhost ]]; then
    mkdir -p "$dest" && cp nccl/build/lib/libnccl.so.2.30.7 "$dest/" && ln -sf libnccl.so.2.30.7 "$dest/libnccl.so.2"
  else
    ssh -o BatchMode=yes "spark@$host" "mkdir -p '$dest'"
    scp -q nccl/build/lib/libnccl.so.2.30.7 "spark@$host:$dest/"
    ssh -o BatchMode=yes "spark@$host" "ln -sf libnccl.so.2.30.7 '$dest/libnccl.so.2'"
  fi
done
sha256sum nccl/build/lib/libnccl.so.2.30.7
