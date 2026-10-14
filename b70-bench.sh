#!/usr/bin/env bash
# b70-bench: one standard llama.cpp benchmark for Intel Arc Pro B70 / Battlemage owners, with the environment attached,
# so results from different machines, drivers and backends can be compared in one table.
#
#   curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- --sycl ~/llama.cpp/build-sycl/bin/llama-bench
#   bash b70-bench.sh --vulkan /path/to/llama-bench --sycl /path/to/llama-bench --tier standard
#
# It downloads the standard models (asks first), runs llama-bench, writes results to ~/b70-bench-results/<time>/,
# and shows how to submit them. It never posts anything without asking.
# https://github.com/riceharvest/b70-bench  (MIT)
set -uo pipefail
VERSION=0.1.0
REPO=riceharvest/b70-bench
DOCTOR_URL=https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh

usage() {
  cat <<'EOF'
usage: b70-bench.sh [options]
  --sycl PATH        llama-bench from a SYCL build        (repeatable as --bin for any backend)
  --vulkan PATH      llama-bench from a Vulkan build
  --bin PATH         llama-bench of any backend (label is read from its output)
  --tier T           quick   = Llama-2-7B Q4_0 (3.6 GB, comparable with the llama.cpp Vulkan scoreboard)
                     standard= quick + Qwen3.8-27B UD-Q4_K_M (15.3 GB)                       [default]
                     full    = standard + Qwen3.6-35B-A3B UD-Q4_K_M (20.6 GB) + 65K-depth decode
                     none    = only the --model files
  --model FILE       also bench this local .gguf (repeatable; reported as "custom", not in the main table)
  --models-dir DIR   where standard models are stored (default ~/.cache/b70-bench/models)
  --out DIR          results directory (default ~/b70-bench-results/<time>)
  --reps N           llama-bench repetitions (default 3)
  --dev DEV          pass -dev DEV to llama-bench (pick a GPU, e.g. SYCL0 or Vulkan0)
  --yes              don't ask before downloading
  --no-submit        don't offer to post the result
EOF
}

BINS=(); LABELS=(); CUSTOM=(); TIER=standard; MODELS_DIR=${B70B_MODELS_DIR:-$HOME/.cache/b70-bench/models}
OUT=""; REPS=3; DEV=""; YES=0; SUBMIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sycl) BINS+=("${2:?}"); LABELS+=(SYCL); shift 2 ;;
    --vulkan) BINS+=("${2:?}"); LABELS+=(Vulkan); shift 2 ;;
    --bin) BINS+=("${2:?}"); LABELS+=(""); shift 2 ;;
    --tier) TIER=${2:?}; shift 2 ;;
    --model) CUSTOM+=("${2:?}"); shift 2 ;;
    --models-dir) MODELS_DIR=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --reps) REPS=${2:?}; shift 2 ;;
    --dev) DEV=${2:?}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --no-submit) SUBMIT=0; shift ;;
    --version) echo "b70-bench $VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$TIER" in none|quick|standard|full) ;; *) echo "--tier must be none, quick, standard or full" >&2; exit 2 ;; esac
command -v python3 >/dev/null || { echo "b70-bench needs python3" >&2; exit 2; }

say() { printf '%s\n' "$*"; }
ask() { # ask "question" -> 0 for yes. Reads the terminal even when the script itself comes from a pipe.
  [ "$YES" = 1 ] && return 0
  local a=""
  if [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
    printf '%s [y/N] ' "$1" > /dev/tty; read -r a <&3; exec 3<&-
  else
    say "$1 -> no terminal to ask on; re-run with --yes to allow it"; return 1
  fi
  case "$a" in y|Y|yes|YES) return 0 ;; esac; return 1
}

if [ "${#BINS[@]}" = 0 ]; then
  if command -v llama-bench >/dev/null; then BINS=("$(command -v llama-bench)"); LABELS=("")
  else
    cat >&2 <<'EOF'
No llama-bench given. Build llama.cpp for one or both backends, then pass the binaries:
  git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
  # Vulkan (needs vulkan headers + glslc):
  cmake -B build-vulkan -DGGML_VULKAN=ON && cmake --build build-vulkan --target llama-bench -j8
  # SYCL (needs oneAPI; source /opt/intel/oneapi/setvars.sh first):
  cmake -B build-sycl -DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx -DGGML_SYCL_F16=ON
  cmake --build build-sycl --target llama-bench -j8
  bash b70-bench.sh --vulkan build-vulkan/bin/llama-bench --sycl build-sycl/bin/llama-bench
EOF
    exit 2
  fi
fi
for b in "${BINS[@]}"; do [ -x "$b" ] || { echo "not executable: $b" >&2; exit 2; }; done

# id|repo|revision|file|bytes|sha256|depths|extra flash-attn sweep
STD_MODELS=(
  "llama2-7b-q4_0|TheBloke/Llama-2-7B-GGUF|b4e04e128f421c93a5f1e34ac4d7ca9b0af47b80|llama-2-7b.Q4_0.gguf|3825807040|78b8f9777dd620ad29cd2cffb6653b17fa8a5b1fddc1b8821180d60eedd24d48|0|0,1"
  "qwen3.8-27b-ud-q4_k_m|unsloth/Qwen3.8-27B-GGUF|4ca720788d1e01f1bff70c033e0d0028fd02e502|Qwen3.8-27B-UD-Q4_K_M.gguf|16464440224|322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482|0,8192,32768|1"
  "qwen3.6-35b-a3b-ud-q4_k_m|unsloth/Qwen3.6-35B-A3B-GGUF|a483e9e6cbd595906af30beda3187c2663a1118c|Qwen3.6-35B-A3B-UD-Q4_K_M.gguf|22134528992|ac0e2c1189e055faa36eff361580e79c5bd6f8e76bffb4ce547f167d53e31a61|0,8192,32768|1"
)
case "$TIER" in none) N_STD=0 ;; quick) N_STD=1 ;; standard) N_STD=2 ;; full) N_STD=3 ;; esac
[ "$TIER" = full ] && STD_MODELS[1]=${STD_MODELS[1]/|0,8192,32768|/|0,8192,32768,65536|}

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=${OUT:-$HOME/b70-bench-results/$STAMP}
mkdir -p "$OUT" "$MODELS_DIR" || exit 2
say "b70-bench $VERSION -> results in $OUT"

# --- environment (b70-doctor --json) -------------------------------------------------
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
DOCTOR=""
for c in "${B70B_DOCTOR:-}" "$HERE/b70-doctor.sh" "$(command -v b70-doctor.sh 2>/dev/null)"; do
  [ -n "$c" ] && [ -f "$c" ] && { DOCTOR=$c; break; }
done
if [ -z "$DOCTOR" ] && command -v curl >/dev/null; then
  DOCTOR="$OUT/b70-doctor.sh"; curl -fsSL "$DOCTOR_URL" -o "$DOCTOR" 2>/dev/null || DOCTOR=""
fi
if [ -n "$DOCTOR" ] && bash "$DOCTOR" --json > "$OUT/env.json" 2>/dev/null && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT/env.json" 2>/dev/null; then
  say "environment: $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); g=(d.get("gpus") or [{}])[0]; print(g.get("name","?"), "| kernel", d.get("kernel","?"), "| GuC", g.get("guc","?"))' "$OUT/env.json")"
else
  echo '{}' > "$OUT/env.json"; say "environment: b70-doctor unavailable, submitting without it"
fi
VRAM=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(max([g.get("bar_bytes",0) for g in d.get("gpus",[])] or [0]))' "$OUT/env.json" 2>/dev/null || echo 0)

# --- models ------------------------------------------------------------------------------
fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }
RUN_MODELS=()   # id|path|depths|fa
need=0; todo=()
for ((i = 0; i < N_STD; i++)); do
  IFS='|' read -r id repo rev file bytes sha depths fa <<< "${STD_MODELS[$i]}"
  p="$MODELS_DIR/$file"
  if [ "$VRAM" -gt 0 ] && [ $((bytes * 100 / VRAM)) -gt 85 ]; then
    say "skip $id: $(( bytes / 1073741824 )) GiB does not fit this card's $(( VRAM / 1073741824 )) GiB with context"; continue
  fi
  if [ "$(fsize "$p")" != "$bytes" ] && [ "${B70B_SKIP_VERIFY:-0}" != 1 ]; then need=$((need + bytes - $(fsize "$p"))); todo+=("$i"); fi
  RUN_MODELS+=("$id|$p|$depths|$fa")
done
if [ "${#todo[@]}" -gt 0 ]; then
  command -v curl >/dev/null || { echo "need curl to download models" >&2; exit 2; }
  if ! ask "Download $(( need / 1073741824 )) GiB of models to $MODELS_DIR?"; then echo "nothing downloaded; stopping" >&2; exit 1; fi
  for i in "${todo[@]}"; do
    IFS='|' read -r id repo rev file bytes sha depths fa <<< "${STD_MODELS[$i]}"
    say "downloading $file ($(( bytes / 1048576 )) MiB)"
    curl -fL -C - --retry 5 -o "$MODELS_DIR/$file.part" "https://huggingface.co/$repo/resolve/$rev/$file" || { echo "download failed: $file" >&2; exit 1; }
    [ "$(fsize "$MODELS_DIR/$file.part")" = "$bytes" ] || { echo "size mismatch for $file; delete $MODELS_DIR/$file.part and retry" >&2; exit 1; }
    say "checking sha256 of $file"
    got=$(sha256sum "$MODELS_DIR/$file.part" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { echo "sha256 mismatch for $file (got $got); delete it and retry" >&2; exit 1; }
    mv "$MODELS_DIR/$file.part" "$MODELS_DIR/$file"
  done
fi
for c in "${CUSTOM[@]}"; do
  [ -f "$c" ] || { echo "no such model: $c" >&2; exit 2; }
  RUN_MODELS+=("custom:$(basename "$c" .gguf | tr -c 'A-Za-z0-9._\n-' '-' | cut -c1-70)|$c|0|1")
done

# --- run -----------------------------------------------------------------------------------
TO=${B70B_TIMEOUT:-2400}
n=0
for bi in "${!BINS[@]}"; do
  b=${BINS[$bi]}
  for m in "${RUN_MODELS[@]}"; do
    IFS='|' read -r id path depths fa <<< "$m"
    n=$((n+1)); tag=$(printf '%02d' "$n")
    args=(-m "$path" -ngl 99 -p 512 -n 128 -d "$depths" -fa "$fa" -r "$REPS" -o json)
    [ -n "$DEV" ] && args+=(-dev "$DEV")
    say "[$tag] ${LABELS[$bi]:-llama-bench} $id (depths $depths)"
    printf '%s\n' "$b ${args[*]}" > "$OUT/run$tag.cmd"
    printf '{"model_id":"%s","label":"%s"}\n' "$id" "${LABELS[$bi]}" > "$OUT/run$tag.meta"
    if command -v timeout >/dev/null; then T=(timeout "$TO"); else T=(); fi
    "${T[@]}" "$b" "${args[@]}" > "$OUT/run$tag.json" 2> "$OUT/run$tag.log"
    rc=$?
    if [ "$rc" != 0 ]; then
      say "    failed (exit $rc): $(grep -v '^\s*$' "$OUT/run$tag.log" | tail -n1 | cut -c1-160)"
      [ "$rc" = 124 ] && say "    timed out after ${TO}s: check 'sudo dmesg | grep xe' for a GPU hang"
    fi
  done
done

# --- aggregate + submission ------------------------------------------------------------------
python3 - "$OUT" "$VERSION" "$TIER" "$REPO" <<'PY'
import glob, json, os, sys, datetime
out, version, tier, repo = sys.argv[1:5]
env = json.load(open(os.path.join(out, "env.json")))
runs, failures = [], []
for cmd in sorted(glob.glob(os.path.join(out, "run*.cmd"))):
    base = cmd[:-4]; meta = json.load(open(base + ".meta"))
    try:
        rows = json.load(open(base + ".json"))
    except Exception:
        log = open(base + ".log", errors="replace").read().strip().splitlines()
        failures.append({"model_id": meta["model_id"], "backend": meta["label"] or "?",
                         "error": (log[-1] if log else "no output")[:200]})
        continue
    for r in rows:
        test = f"pp{r['n_prompt']}" if r.get("n_prompt") else f"tg{r['n_gen']}"
        runs.append({
            "model_id": meta["model_id"], "backend": meta["label"] or r.get("backends", "?"),
            "backends": r.get("backends", ""), "gpu_info": r.get("gpu_info", ""),
            "build_commit": r.get("build_commit", ""), "build_number": r.get("build_number", 0),
            "model_type": r.get("model_type", ""), "test": test, "depth": r.get("n_depth", 0),
            "flash_attn": r.get("flash_attn"), "avg_ts": round(float(r["avg_ts"]), 2),
            "stddev_ts": round(float(r.get("stddev_ts", 0)), 2), "n_threads": r.get("n_threads"),
            "type_k": r.get("type_k", ""), "type_v": r.get("type_v", "")})
doc = {"schema": 1, "tool": "b70-bench", "version": version, "tier": tier,
       "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
       "env": env, "runs": runs, "failures": failures}
json.dump(doc, open(os.path.join(out, "results.json"), "w"), indent=1)

g = (env.get("gpus") or [{}])[0]
backends = sorted({r["backend"] for r in runs} | {f["backend"] for f in failures})
lines = ["| model | test | " + " | ".join(backends) + " |", "|---|---|" + "---|" * len(backends)]
keys = []
for r in runs:
    k = (r["model_id"], r["test"], r["depth"], r["flash_attn"])
    if k not in keys: keys.append(k)
for k in keys:
    cells = []
    for b in backends:
        hit = [r for r in runs if (r["model_id"], r["test"], r["depth"], r["flash_attn"]) == k and r["backend"] == b]
        cells.append(f"{hit[0]['avg_ts']:.1f} ± {hit[0]['stddev_ts']:.1f}" if hit else "")
    name = k[1] + (f" @ d{k[2]}" if k[2] else "") + ("" if k[3] in (1, None) else " (fa off)")
    lines.append(f"| {k[0]} | {name} | " + " | ".join(cells) + " |")
table = "\n".join(lines)
pk = env.get("packages", {})
drv = ", ".join(f"{k} {v}" for k, v in pk.items() if k in ("intel-compute-runtime", "libze-intel-gpu1", "intel-opencl-icd", "mesa-vulkan-drivers", "vulkan-intel"))
builds = ", ".join(sorted({f"{r['backend']} b{r['build_number']} ({r['build_commit']})" for r in runs}))
summary = (f"GPU: {g.get('name', '?')} | kernel {env.get('kernel', '?')} | GuC {g.get('guc', '?')} | {drv or 'driver versions unknown'}\n"
           f"llama.cpp: {builds or '-'}\n\ntokens/s (llama-bench, -ngl 99, Q4 weights, f16 KV):\n\n{table}\n")
if failures:
    summary += "\nfailed runs:\n" + "\n".join(f"- {f['backend']} {f['model_id']}: {f['error']}" for f in failures) + "\n"
open(os.path.join(out, "summary.md"), "w").write(summary)
title = f"[result] {g.get('name', 'GPU')} | {' + '.join(backends) or 'no runs'} | {doc['date']}"
body = (f"<!-- b70-bench-result v1 -->\n{summary}\n<details><summary>raw results (parsed by the bot)</summary>\n\n"
        f"```json\n{json.dumps(doc, separators=(',', ':'))}\n```\n</details>\n")
open(os.path.join(out, "issue-title.txt"), "w").write(title + "\n")
open(os.path.join(out, "issue-body.md"), "w").write(body)
print("\n" + summary)
PY

[ -s "$OUT/results.json" ] || { echo "no results written" >&2; exit 1; }
nruns=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["runs"]))' "$OUT/results.json")
[ "$nruns" -gt 0 ] || { say "No successful runs, so there's nothing to submit. Logs: $OUT/run*.log"; exit 1; }
if [ "$SUBMIT" = 1 ]; then
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1 && ask "Post this result as a public issue on github.com/$REPO (adds it to the results table)?"; then
    gh issue create -R "$REPO" --title "$(cat "$OUT/issue-title.txt")" --body-file "$OUT/issue-body.md"
  else
    say "To add it to the table: open https://github.com/$REPO/issues/new , use this title and paste $OUT/issue-body.md as the body:"
    say "  $(cat "$OUT/issue-title.txt")"
  fi
fi
