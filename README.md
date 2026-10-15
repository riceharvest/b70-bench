# b70-bench

One standard llama.cpp benchmark for Intel Arc Pro B70 owners (B60/B50/B580 work too). It runs `llama-bench` on a
fixed set of models with fixed settings, attaches your driver/firmware/kernel versions, and lets you add the result to
a shared table with one issue. Then "which backend, which driver, which kernel is fastest on this card" has an answer
backed by more than one machine.

Made by [@imdariotoo](https://x.com/imdariotoo). I post my B70 and local-model releases on X, so follow there for the next ones.

**[→ Results table](RESULTS.md)**

## Why another benchmark

llama.cpp has two scoreboards: [Vulkan](https://github.com/ggml-org/llama.cpp/discussions/10879) and Intel's
[SYCL one](https://github.com/ggml-org/llama.cpp/discussions/23313). Both are great for comparing GPUs. But both test one
7B model at short context, each on a single backend, and the SYCL one asks for no cross-backend tables. What B70
owners actually need to know is different:

- **SYCL vs Vulkan on the same machine.** Both are run if you pass both binaries.
- **Models that use the 32 GB:** a 27B dense model and a 35B MoE, not only 7B.
- **Deep context.** Decode speed after 8K and 32K tokens of context. This is where Vulkan on Xe2 collapses
  ([llama.cpp#28721](https://github.com/ggml-org/llama.cpp/issues/28721)).
- **The environment next to every number:** kernel, GuC firmware, compute-runtime, Mesa, PCIe link, all from
  [b70-doctor](https://github.com/riceharvest/b70-doctor). Regressions and driver wins become visible.

The 7B run uses the scoreboards' exact model and `-fa 0,1`, so those numbers stay comparable with them.

## Run it

No build needed: `--prebuilt` downloads the SYCL and Vulkan llama.cpp builds from
[b70-llama-builds](https://github.com/riceharvest/b70-llama-builds) (latest release, sha256-checked, cached in
`~/.cache/b70-bench/builds`; Linux x86-64 with glibc 2.39+) and benches both:

```bash
curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- --prebuilt --tier quick
```

`--prebuilt sycl` or `--prebuilt vulkan` picks one backend. On an older distro (glibc < 2.39), or to get Mesa 26 without
updating the system, `--docker` runs the same builds from the
[b70-llama image](https://github.com/riceharvest/b70-llama-builds#docker-image) instead. Vulkan then uses the image's Mesa 26 and
SYCL its compute-runtime, and the result lists those versions, not the host's:

```bash
curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- --docker --tier quick
```
 To bench your own builds instead (the script prints the build
commands if you run it without a binary):

```bash
curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- \
  --sycl ~/llama.cpp/build-sycl/bin/llama-bench --vulkan ~/llama.cpp/build-vulkan/bin/llama-bench
```

It asks before downloading builds or models, and again before posting anything. At the end it prints a summary table and offers
to open the result issue. That uses `gh` if you're logged in; otherwise it tells you which file to paste.

| tier | models (pinned Hugging Face revisions, sha256-checked) | download |
|---|---|---|
| `quick` | Llama-2-7B Q4_0: pp512 / tg128, flash attention on and off | 3.6 GB |
| `standard` (default) | + Qwen3.8-27B UD-Q4_K_M: pp512 / tg128 at depth 0, 8K, 32K | + 15.3 GB |
| `full` | + Qwen3.6-35B-A3B UD-Q4_K_M (MoE) at depth 0/8K/32K, and the 27B also at 64K | + 20.6 GB |

Every run is `llama-bench -ngl 99 -sm none -p 512 -n 128 -d <depth> -fa <fa> -r 3 -o jsonl`, one call per depth. It
always uses one GPU (`-sm none`); pick it with `--dev` / `--mg` on multi-GPU boxes. Raw output, logs and the exact
commands are kept in `~/b70-bench-results/<time>/`. Models that don't fit your card's VRAM are skipped.

Deep context on Vulkan can be very slow on Xe2, because flash attention falls back to a scalar path
([#30503](https://github.com/ggml-org/llama.cpp/issues/30503), [#27638](https://github.com/ggml-org/llama.cpp/issues/27638),
which also reports device loss). Each call has a 40-minute cap (`B70B_TIMEOUT`, in seconds). If a call hits the cap,
the tests it already finished are kept and the submission marks the call as cut short.

Other options: `--model my.gguf` adds your own model (stored as "custom", kept out of the main tables), `--dev SYCL0`
picks a GPU, `--reps N`, `--tier none` runs only `--model` files, and `--yes` skips the download question.

## What gets submitted

The issue contains your results plus the b70-doctor environment: OS name, kernel, RAM size, GPU model and PCI
address, PCIe link, BAR size, firmware versions, and Intel/Mesa package versions. There's no hostname, username, IP or CPU
serial, and home-directory paths in error lines are shortened to `~`. You can read and edit `issue-body.md` before posting.

A GitHub Action validates the issue (strict types, safe characters only) and adds it to [RESULTS.md](RESULTS.md).
Edit the issue to fix it; close it as "not planned" to remove it.

## Tests

`bash tests/run.sh` runs on any Linux box without a GPU. It covers the script against a fake `llama-bench` that
emits real-format JSON (captured from llama.cpp b907), and the ingest bot against real output and hostile input.

## Related

- [Awesome Arc Pro B70](https://github.com/riceharvest/awesome-b70): everything for B70 owners in one place, including known driver bugs with workarounds
- [b70-doctor](https://github.com/riceharvest/b70-doctor): checks your B70 setup and prints fixes
- [b70-qwen38-cookbook](https://github.com/riceharvest/b70-qwen38-cookbook): Qwen3.8-27B with 262K context on one B70 (vLLM)

MIT license.
