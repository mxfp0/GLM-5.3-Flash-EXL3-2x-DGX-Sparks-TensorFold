# Sparks TP4 site

Upstream branch `tp4`, base `d22003070575c2774de0f010062aa57bae06f3c7`.

Use llama-swap at `http://192.168.0.112:8080/v1`, model `GLM-5.3-Flash-EXL3`.
Backend: `127.0.0.1:8898`. Start on demand through the router. Do not run a
second direct launcher while a managed model is active.

Site settings: `site/sparks.env`, loaded by `scripts/local.sh`.
Managed entry: `~/.local/libexec/llama-swap/glm-5.3-flash-exl3`.
The entry executes `site/managed-launcher.sh`, which owns the existing shared
DeepSeek launcher lock. Both launchers wait at most 180 seconds for that lock.
Both start paths stop and verify the other model's inference containers first.
DeepSeek's existing image, weights, NFS, local Engram, network and limits remain.
The retired GLM NVFP4 stop hook now calls EXL3; the router API unload and separate
DeepSeek stop hook remain, with the existing 300-second service stop budget.

## Runtime

Rank order: spark1, spark2, spark3, spark4. Master `10.100.227.2:29551`.
Gloo and NCCL sockets use `enp1s0f0np0`; all runtime traffic uses QSFP.
SSH uses the explicit Wi-Fi management addresses. Existing routes, MTU 9000,
stock 64 KiB kernel and NVIDIA driver remain unchanged.

This profile uses the primary PCI domain of each physical cable:
`rocep1s0f0,rocep1s0f1`, IPv4 GID 3. The inventory filter excludes secondary
PCI-domain interfaces because the current addresses share the primary /24.
No paired-domain throughput is claimed. Upstream per-rank NCCL ring/link graphs
and the RoCE neighbour relay handle opposite ranks. Small gathers use RoCE;
large gathers and split prompt exchanges use NCCL. No DeepSeek NCCL library
is injected into this image.

Configured: context 1,048,576, eight requests, 32 GiB shared KV pool budget per
rank, FP8 KV, q4 dense, DFlash2 plus copy drafts, vision, no disk spill or
display-memory reservation. The default output budget is 32,768 tokens.
The engine reports the actual shared pool capacity after loading. These settings
do not mean eight independent full-context histories fit simultaneously.
TP4 switchless is experimental upstream. Basic deployment checks do not qualify
near-1M context, sustained eight-stream load, full output length or broad quality.

## Pinned artifacts

Base image tag `tensorfold-glm53:v0.6.0`, registry digest
`sha256:eb17e092fa56ea23ca385c3aba0a4250d0cb46c705b9455f2e4c29d1ca4847e8`,
image ID `sha256:7f8f1b38bcf1770e527bdc9ceacdc663063d2871e464f7693a8602e0efbd4a95`,
base patch hash `7a37454d3238`.

Active site image: `tensorfold-glm53:v0.6.0-tp4-stock64k-94cce4bf6ee4`,
ID `sha256:cea648e5a3aba7e479568be0ee53ea8dd95c2b98d51f670d2ad3364f07ef766e`,
patch hash `94cce4bf6ee4`, identical on all four Sparks. Build recipe:
`site/Dockerfile.stock64k`. It retains all base layers and adds the exact two-line
upstream [PR107](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/107)
fix as `0110-glm-mmap-uploads.patch`. DFlash2 and vision tensors are cloned out
of their safetensors mappings before GPU upload. This is required with the
existing 64 KiB kernel: the base image stalls in `cuMemcpyHtoDAsync`.

PR108 and the other gaps in `SITE-GAPS.md` are deferred at the user's request.
An offline-tested candidate is retained in private setup state; it is not active.

All nodes use their local Hugging Face cache at `~/.cache/huggingface/hub`:

- Target `Mia-AiLab/GLM-5.3-Flash-EXL3-4bpw-TensorFold`, revision
  `078455ffe6472f9a52fbc1139f58b9db2881b25c`, all 97 files verified.
- Drafter `incoai/GLM-5.3-Flash-DFlash2`, revision
  `bf582e4eacc1810f76656d1811693ff6c6737d2a`, all five files verified.

The head authenticated Hub metadata with `HF_TOKEN` from `~/.bashrc`.
Containers run offline and receive no token environment variable. Workers received image and drafter
bytes over the existing QSFP routes. Temporary HTTP service and transfer bundles
were removed after verification. `PREPARE=0` prevents upstream preparation from
copying large artifacts over SSH.

## Operations and evidence

Unload asynchronously:

```sh
curl -fsS -X POST http://127.0.0.1:8080/api/models/unload/GLM-5.3-Flash-EXL3
```

An API response acknowledges the request. Verify all four exact container names
`glm53-flash-tf` are absent and the shared lock is released before declaring stop
complete. The independent managed `--stop` verifies all four nodes and returns
failure if any node is unreachable or any matching container remains.

Deployment evidence: `~/.local/state/glm53-exl3-setup/`. Original router,
service drop-in and launcher backups are in its `backups-before/` directory.
Per-rank stopped logs: `~/.cache/tensorfold-glm53/logs/` on each node.
The new model's writable JIT cache is node-local under
`~/.cache/tensorfold-glm53/94cce4bf6ee4`.

## Verified deployment

All four active image IDs and the installed drafter/vision source hashes match.
The upstream mmap loader check and a real FC tensor GPU roundtrip pass on all
workers; the head passes both checks too. Actual target, drafter and vision
loading reach serving readiness. The engine reports a shared pool of 5,834,752
tokens, with a maximum of 1,048,576 per request.

Router requests pass text, streaming, reasoning, typed tool calls and tool-result
continuation, image reading, eight short simultaneous requests, and retrieval
from a 14,187-token synthetic inventory. Its continuation reports 14,144 cached
prompt tokens. The initial fake private-access-marker fixture caused a model
refusal; the benign public inventory test passes. This is a fixture correction,
not a change to the model or its safety settings.

All ranks remain running, with zero container OOM events/restarts and no CUDA
allocation failures in their logs. DeepSeek inference is absent. Its router
model definition is unchanged; the spark3 NFS container ID, PID, start time,
image and mounts match the pre-setup snapshot. The shared launcher lock is held.
Startup cancellation removed all four containers during the earlier base-image
attempt and released that lock. No additional model switch or restart is needed.

Canonical evidence: `~/.local/state/glm53-exl3-setup/readiness.json`, API replies
in `api/`, installed-source manifests and per-rank live logs. This deployment
uses basic functional checks. Near-1M inference, sustained C8 load, full output
length and performance remain unqualified. See `SITE-GAPS.md` for unresolved
upstream reports; no nonblocking gap fixes are active.

## llama-swap Prefill/Decode metrics

The router now reads TensorFold's native `tensorfold.prefill_s` and `decode_s`
from normal responses and final SSE chunks. Prefill is uncached prompt tokens
per reported prefill second. Decode excludes the first output token, which
TensorFold samples during prefill. These are engine timing rates, including
scheduling/interleaving and cached-state overhead, not client throughput.
Missing/invalid timing data stays unknown. Historical rows are unchanged.

The deployed router is `v263+tensorfold-metrics`, based on the exact previously
installed commit `e33e97bb36e1efb4572d135e3f9811744d1ac592`. Its frontend source
and lockfile are unchanged. The newer main working tree and its staged edits
are preserved. Reproducible source delta:
`site/llama-swap-v263-tensorfold-metrics.patch`. Build worktree:
`~/.local/state/glm53-exl3-setup/router-metrics-src`. Original binary:
`~/.local/state/glm53-exl3-setup/backups-before/llama-swap-v263`.

Twenty-four TensorFold monitor cases and the existing parser/server tests pass.
The required `make test-dev` runs fail in the unchanged GPU-monitor test
`TestStart_GpuRestartWaitResetsAfterStats`; the failure also reproduces in the
unmodified perf package, while the isolated test passes. No GPU-monitor code
was changed to bypass it.

Actual normal, streamed (`include_usage:false`), cache-prime and cached
continuation requests create numeric dashboard rates in rows31471-31474. The
stored rates match the response timings and token counts. Evidence:
`~/.local/state/glm53-exl3-setup/metrics-api/passed.json`. The managed router
restart removed the earlier EXL containers; all four ranks reloaded successfully,
with unchanged image/source hashes and zero OOM/restarts. NFS is preserved.

## Prefill configuration (2026-10-21)

The router's model now runs a faster prompt path; everything else above still holds. Details, every measurement and
the experiments that did not help: `EXPERIMENTS.md`, "Prefill toward 5,000 tok/s".

- Image `tensorfold-glm53:v0.6.0-tp4-stock64k-prefill-9ae7c2842917` on all four Sparks: the site image above plus
  `patches/0111-glm-prompt-fp8-y16.patch` (`site/Dockerfile.stock64k-prefill`). 0111 adds three opt-in prompt
  switches: `TF_GLM_PROMPT_FP8` (e4m3 prompt matmuls on the 4-bit weights), `TF_GLM_PROMPT_W8` (e4m3 copies of the
  BF16 dense matrices for prompt matmuls through cuBLASLt, ~1.7 GiB a rank; used here) and `TF_GLM_PROMPT_Y16`
  (bf16 routed-expert rows). Its kernel cache is `~/.cache/tensorfold-glm53/9ae7c2842917`.
- NCCL: TensorFold loads `~/.local/share/glm53-switchless-nccl/libnccl.so.2` (NCCL 2.30.7 with RiNGSiDE's
  switchless dual-PF patches, built in the image's toolchain by `site/build-switchless-nccl.sh`, sha256
  `a196b2d8...`) through `NCCL_LIB_DIR` in `start.sh`. With `RING_TWINS=1` (`scripts/nodes.sh`) and all four netdevs
  in `FABRIC_NETDEVS`, the ring exchange's links alternate each port's two PCIe functions (each function carries half:
  checked with the RDMA port counters); TensorFold's RoCE all-gathers and the ring communicator stay on the primary
  functions. No host network setting changed.
- Switches in `site/sparks.env`: `TF_GLM_PROMPT_PARTIALS=bf16`, `TF_GLM_PROMPT_W8=1`, `TF_GLM_MSA=1`,
  `TF_GLM_PROMPT_Y16=1`, `TF_GLM_PREFILL_ROWS=8192`, `NCCL_CHANNELS=2`, and `KV_POOL_GIB=28` (was 32): the larger
  prompt buffers take ~6 GiB a rank, and the pool is now 5,201,920 tokens; MemAvailable after start 18.0 GB on the head,
  20.4 GB on the workers. All four prompt switches change the prompt's bits (not its decode path).
- Measured through the router: 3,220 / 3,389 / 3,388 tok/s prefill at 8K / 32K / 64K (before: 2,303 / 2,359 / 2,371
  with the same bench); needles at 32K and 100K found; long-prompt GSM8K 96 % (before 97 %, 99 of 100 answers
  equal). Unqualified: sustained multi-stream serving, near-1M prompts, decode per-round time.
- Rollback: `cp ~/prefill-lab/sparks.env.before-prefill site/sparks.env`, then unload and reload through the router
  (the old image and its kernel cache are kept). Lab material (scripts, raw results, lab images `tensorfold-glm53:lab-*`,
  Nsight reports in the kernel cache directories): `~/prefill-lab/`.

## Prefill round 2 (2026-10-21)

Two more exact prompt switches (no reply changes: five solo greedy prompts of 5K-13K tokens give the same replies).
Details and the eleven changes measured and dropped: `EXPERIMENTS.md`, "Round 2".

- Image `tensorfold-glm53:v0.6.0-tp4-stock64k-prefill-404488aedd91` on all four Sparks: `site/Dockerfile.stock64k-prefill`
  now applies `patches/0111-glm-prompt-fp8-y16.patch` and `patches/0112-glm-prompt-draft-skip-partial16.patch` to the
  site image. Kernel cache `~/.cache/tensorfold-glm53/404488aedd91`.
- `site/sparks.env` adds `TF_GLM_DRAFT_SKIP=1` (DFlash2 takes a prompt's taps only within its 2,176-row ring's reach of
  the prompt's end and its kept points) and `TF_GLM_PARTIAL16=1` (the attention and MoE partials are written straight
  into the bf16 exchange buffers, without the fp32 staging and its conversions).
- Measured through the router (client tok/s, prompt / time to first content): 3,387 / 3,590 / 3,596 at 8K / 32K / 64K,
  against 3,191 / 3,367 / 3,367 before (+6 / +7 / +7 %). MemAvailable after start: 23.1 GB on the head, 25.5-26.0 GB
  on the workers.
- Rollback: `cp ~/prefill-lab/sparks.env.before-0112 site/sparks.env`, then unload and reload through the router (the
  `9ae7c2842917` image and its kernel cache are kept).

## Prefill round 3 (2026-10-21)

Five more exact prompt switches (the same replies as round 2's: five solo greedy prompts of 5K-13K tokens, cold and
resumed). Details and the changes measured and dropped: `EXPERIMENTS.md`, "Round 3".

- Image `tensorfold-glm53:v0.6.0-tp4-stock64k-prefill-404a07a20e25` on all four Sparks:
  `site/Dockerfile.stock64k-prefill` now applies 0111, 0112 and `patches/0113-glm-prompt-ring-exchange.patch` to the
  site image. Kernel cache `~/.cache/tensorfold-glm53/404a07a20e25`.
- `site/sparks.env` adds `TF_GLM_PROMPT_HANDOFF8=1` (the KDA layers' input rows cross the ring as e4m3) and
  `TF_GLM_PRX=1 TF_GLM_PRX_SHARE=1 TF_GLM_PRX_RINGAG=1 TF_GLM_PRX_ZC=1`: the row split's exchanges run on the NICs
  alone (the copy engines stage rows in pinned memory, a proxy thread RDMA-writes them to the neighbours over both PCIe
  functions, the GPU waits with stream memory operations; no NCCL kernel), with a second channel for the DSA shares, a
  ring-aware all-gather and zero-copy partials.
- Costs: the two proxy threads poll, a CPU core each on every Spark; ~770 MiB of pinned host memory a Spark. A failed
  RDMA write or a dead peer leaves the GPU waiting with no timeout: the host side raises `TF_GLM_PRX failed` at its
  next exchange, and the server has to be restarted (unload and reload through the router).
- Measured through the router (client tok/s): 4,028 / 4,340 / 4,335 at 8K / 32K / 64K, and 3,971 / 4,221 / 4,266 in a
  second run, against 3,387 / 3,590 / 3,596 before (+17 to +21 %). RigMark's prefill 4,077 / 4,342 / 4,289 / 4,252 /
  4,058 tok/s at 8K / 32K / 64K / 128K / 256K (before: 3,485 / 3,687 / 3,683 / 3,601 / 3,463). GSM8K 97 %, both
  needles found, decode unchanged. KV pool 5,201,920 tokens as before; MemAvailable after start 22.5 GB on the head,
  25.7-26.4 GB on the workers.
- `vm.min_free_kbytes` is 45,166 kB on every Spark. A transparent huge page test raised it to 6,471,424 kB, which cost
  ~19 GiB of memory at start (the KV pool fell to ~4.2M tokens) until it was set back; if THP is ever enabled again,
  check it afterwards.
- Rollback: `cp ~/prefill-lab/sparks.env.before-0113 site/sparks.env`, then unload and reload through the router (the
  `404488aedd91` image and its kernel cache are kept). The lab images' kernels were moved out of the stock image's cache
  to `~/.cache/tensorfold-glm53/lab-94cce4bf6ee4/`.
