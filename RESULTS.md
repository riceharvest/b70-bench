# b70-bench results

Tokens/s from `llama-bench` (`-ngl 99 -p 512 -n 128`, f16 KV), submitted by owners with [b70-bench.sh](b70-bench.sh). Each row is one issue; click the number for the full environment. `@8K` = after 8,192 tokens of context. CR = Intel compute-runtime. Generated, do not edit.

## Llama-2-7B Q4_0 (same model as the llama.cpp Vulkan scoreboard)

| GPU | backend | llama.cpp | pp512 | tg128 | pp512 fa off | tg128 fa off | driver | kernel | date | # |
|---|---|---|---:|---:|---:|---:|---|---|---|---|
| Arc Pro B70 | Vulkan | b907 097cf33d9 | 2580.5 | 83.4 | 2643.7 | 81.0 | Mesa 25.3.6 | 7.1.8 | 2026-10-15 | [2](https://github.com/riceharvest/b70-bench/issues/2) |

