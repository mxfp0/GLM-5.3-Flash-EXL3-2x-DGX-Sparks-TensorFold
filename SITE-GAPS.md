# TP4 upstream gap audit

Audited 2026-10-21. Read-only source audit; no runtime qualification implied.
Compared `tp4` base `d22003070575c2774de0f010062aa57bae06f3c7` with
`main` at `3fd60dfc836fab0f1ed0fd4f0afaf2a1d62b2aab`.
Merge base: `549fdc562c477d477244d2df0590d6c14bda4889`.
All 96 common patch files have identical Git object IDs. Main's additional
patches `0098-glm-mmap-uploads` through `0108-glm-seg-chunks-cuda` are absent
from TP4, rather than renamed. TP4 README lines 37-38 documents this omission.
Main lacks TP4's ring transport patches, so its image cannot replace TP4's image.

## Deployment and correctness

| Item | Upstream status | Site recommendation |
| --- | --- | --- |
| [PR107](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/107), mmap upload hang with 64 KiB pages | Merged | Backported locally as `0110`; verify drafter and vision loading on all ranks. |
| [PR108](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/108), long tokenization blocks other streams | Merged | Suitable standalone backport after the startup baseline; run both upstream CPU checks and concurrent tokenization checks. |
| [PR158](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/158), literal closing tool markup inside argument values can truncate arguments or leak contents into text | Open, unmerged | Separate parser regression and semantic tool qualification before adoption. |
| [PR164](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/164), quoted added-token text becomes actual control tokens | Open, unmerged | Relevant to agents reading logs/templates. Changes prompt encoding intentionally; depends on the tokenizer helper. Qualify separately. |
| [PR156](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/pull/156), repeated whole-history hashing during retained-reasoning restore | Open, unmerged | Can stall all streams on long tool histories; defer until functional readiness and focused history tests. |

[Issue166](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/issues/166)
independently identifies these omissions and the collision between main's and
TP4's patch numbers. Renumber imported patches after the ring patches.

## Exact PR108 input and review

Merged commit: `91927feead6a1b27a626f42d2efce6d304ff2399`.
Read the pinned files with `git show 91927fe:<path>`:

- [Patch](https://raw.githubusercontent.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/91927feead6a1b27a626f42d2efce6d304ff2399/patches/0099-glm-tokenize-nogil.patch): `patches/0099-glm-tokenize-nogil.patch`.
- [Server test](https://raw.githubusercontent.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/91927feead6a1b27a626f42d2efce6d304ff2399/tools/tokenize_check.py): `tools/tokenize_check.py`.
- [Vision test](https://raw.githubusercontent.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/91927feead6a1b27a626f42d2efce6d304ff2399/tools/vision_tokenize_check.py): `tools/vision_tokenize_check.py`.

Patch scope: six server tokenization sites use `App._encode_ids`; vision
preparation changes its one whole-prompt tokenization call. Each replacement
uses `encode_batch_fast([text], add_special_tokens=flag)[0].ids`. Flags stay
unchanged; token-ID prompts bypass tokenization as before. No new settings,
GPU allocations, rank communication, tokenizer mutation or worker threads in
the recipe. No dependency on main's other missing patches.

The upstream tests compare IDs for both special-token flags, Unicode, added
tokens, empty/whitespace text and large corpora; vision checks also compare
picture positions and hashes. Their counting threads check GIL release.
These are not full concurrent HTTP or error-path tests. Verify that the actual
pinned image provides `encode_batch_fast`, run simultaneous calls on its shared
tokenizer, and test malformed API input before adoption. Valid strings retain
the same IDs; do not promise identical tokenizer exception messages for invalid
Python objects. Existing API type validation is untouched.

For mechanism reference, the [tokenizers v0.22.1 Python binding](https://github.com/huggingface/tokenizers/blob/v0.22.1/bindings/python/src/tokenizer.rs)
keeps `encode` under the GIL and explicitly calls `py.allow_threads` for
`encode_batch_fast`, whose receiver is immutable `&self`. This supports the
design but does not establish the exact installed library version. No source
review blocker found; image checks remain the adoption gate.

## Deferred performance work and unresolved reports

Main's draft prelaunch, prompt selection/tile/scoring, qmm reduction, decode
indexer and `FILL_ROWS` changes are optional performance work. Several touch
TP4's own-front/microbatch paths and require rebasing and numerical checks.
Main's TP3 attention optimizations `0104`, `0106` and `0108` do not activate at
TP4's 16 heads per rank. No throughput claim transfers from their TP2/TP3 tests.

[Issue168](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/issues/168)
reports low worker available memory and NVIDIA allocation failures under
sustained TP4/parallel8/KV32 GiB traffic on driver 580.178.04. This matches the
site profile closely, but is not reproduced here and has no established fix.
Monitor actual available memory; basic readiness does not qualify sustained
eight-stream traffic. Related allocator reports in
[issue143](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold/issues/143)
are field observations, not grounds for an untested allocator change.
