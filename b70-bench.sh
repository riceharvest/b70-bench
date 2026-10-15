#!/usr/bin/env bash
# b70-bench: one standard llama.cpp benchmark for Intel Arc Pro B70 / Battlemage owners, with the environment attached,
# so results from different machines, drivers and backends can be compared in one table.
#
#   curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- --prebuilt --tier quick
#   curl -fsSL https://raw.githubusercontent.com/riceharvest/b70-bench/main/b70-bench.sh | bash -s -- --sycl ~/llama.cpp/build-sycl/bin/llama-bench
#   bash b70-bench.sh --vulkan /path/to/llama-bench --sycl /path/to/llama-bench --tier standard
#
# It downloads the standard models (asks first), runs llama-bench, writes results to ~/b70-bench-results/<time>/,
# and shows how to submit them. It never posts anything without asking.
# https://github.com/riceharvest/b70-bench  (MIT)
set -uo pipefail
VERSION=0.2.1
REPO=riceharvest/b70-bench
DOCTOR_URL=https://raw.githubusercontent.com/riceharvest/b70-doctor/main/b70-doctor.sh
BUILDS_URL=${B70B_BUILDS_URL:-https://github.com/riceharvest/b70-llama-builds/releases}

usage() {
  cat <<'EOF'
usage: b70-bench.sh [options]
  --sycl PATH        llama-bench from a SYCL build        (repeatable as --bin for any backend)
  --vulkan PATH      llama-bench from a Vulkan build
  --bin PATH         llama-bench of any backend (label is read from its output)
  --prebuilt [B]     download the prebuilt B70 llama.cpp from github.com/riceharvest/b70-llama-builds (latest
                     release, sha256-checked, cached in ~/.cache/b70-bench/builds). B = sycl, vulkan or
                     sycl,vulkan [default]. Needs glibc 2.39+ (Ubuntu 24.04+, Fedora 40+, Debian 13+).
  --tier T           quick   = Llama-2-7B Q4_0 (3.6 GB, comparable with the llama.cpp Vulkan scoreboard)
                     standard= quick + Qwen3.8-27B UD-Q4_K_M (15.3 GB)                       [default]
                     full    = standard + Qwen3.6-35B-A3B UD-Q4_K_M (20.6 GB) + 65K-depth decode
                     none    = only the --model files
  --model FILE       also bench this local .gguf (repeatable; reported as "custom", not in the main table)
  --models-dir DIR   where standard models are stored (default ~/.cache/b70-bench/models)
  --out DIR          results directory (default ~/b70-bench-results/<time>)
  --reps N           llama-bench repetitions (default 3)
  --dev DEV          pass -dev DEV to llama-bench (pick a GPU, e.g. SYCL0 or Vulkan0). Without --dev/--mg, when a
                     binary sees more than one GPU, the Battlemage one (else the largest) is picked for it.
  --mg N             pass -mg N (main GPU index). Runs always use one GPU (-sm none).
  --yes              don't ask before downloading
  --no-submit        don't offer to post the result
EOF
}

BINS=(); LABELS=(); CUSTOM=(); PREBUILT=""; TIER=standard; MODELS_DIR=${B70B_MODELS_DIR:-$HOME/.cache/b70-bench/models}
OUT=""; REPS=3; DEV=""; MG=""; YES=0; SUBMIT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sycl) BINS+=("${2:?}"); LABELS+=(SYCL); shift 2 ;;
    --vulkan) BINS+=("${2:?}"); LABELS+=(Vulkan); shift 2 ;;
    --bin) BINS+=("${2:?}"); LABELS+=(""); shift 2 ;;
    --prebuilt)
      case "${2:-}" in sycl|vulkan|sycl,vulkan|vulkan,sycl) PREBUILT=$2; shift 2 ;; *) PREBUILT=sycl,vulkan; shift ;; esac ;;
    --tier) TIER=${2:?}; shift 2 ;;
    --model) CUSTOM+=("${2:?}"); shift 2 ;;
    --models-dir) MODELS_DIR=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --reps) REPS=${2:?}; shift 2 ;;
    --dev) DEV=${2:?}; shift 2 ;;
    --mg) MG=${2:?}; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --no-submit) SUBMIT=0; shift ;;
    --version) echo "b70-bench $VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$TIER" in none|quick|standard|full) ;; *) echo "--tier must be none, quick, standard or full" >&2; exit 2 ;; esac
[ "$TIER" = none ] && [ "${#CUSTOM[@]}" = 0 ] && { echo "--tier none needs at least one --model FILE" >&2; exit 2; }
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

# --- prebuilt llama.cpp (b70-llama-builds) ---------------------------------------------------
if [ -n "$PREBUILT" ]; then
  command -v curl >/dev/null || { echo "need curl for --prebuilt" >&2; exit 2; }
  CACHE=${B70B_BUILDS_DIR:-$HOME/.cache/b70-bench/builds}
  # The latest release redirects to .../tag/<tag>; download from that tag so tarballs and SHA256SUMS match.
  TAG=${B70B_BUILDS_TAG:-$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$BUILDS_URL/latest" 2>/dev/null | sed -n 's#.*/tag/##p')}
  [ -n "$TAG" ] || { echo "could not find the latest release at $BUILDS_URL (offline?)" >&2; exit 2; }
  case "$TAG" in *[!A-Za-z0-9._-]*) echo "unexpected release tag: $TAG" >&2; exit 2 ;; esac
  BDIR="$CACHE/$TAG"; mkdir -p "$BDIR" || exit 2
  want=(); for b in ${PREBUILT//,/ }; do want+=("$b"); done
  get=(); for b in "${want[@]}"; do [ -x "$BDIR/llama-b70-$b-ubuntu24-x64/llama-bench" ] || get+=("$b"); done
  if [ "${#get[@]}" -gt 0 ]; then
    if ! ask "Download prebuilt llama.cpp (${get[*]}, release $TAG; SYCL ~250 MB, Vulkan ~30 MB) from ${BUILDS_URL%/releases}?"; then
      echo "nothing downloaded; stopping" >&2; exit 1
    fi
    curl -fsSL --retry 3 -o "$BDIR/SHA256SUMS" "$BUILDS_URL/download/$TAG/SHA256SUMS" || { echo "download failed: SHA256SUMS" >&2; exit 1; }
    for b in "${get[@]}"; do
      f=llama-b70-$b-ubuntu24-x64.tar.gz
      say "downloading $f"
      curl -fL --retry 3 -o "$BDIR/$f" "$BUILDS_URL/download/$TAG/$f" || { echo "download failed: $f" >&2; exit 1; }
      want_sha=$(awk -v f="$f" '$2 == f || $2 == "*" f {print $1}' "$BDIR/SHA256SUMS")
      got=$(sha256sum "$BDIR/$f" | cut -d' ' -f1)
      [ -n "$want_sha" ] && [ "$got" = "$want_sha" ] || { rm -f "$BDIR/$f"; echo "sha256 mismatch for $f (got $got, want ${want_sha:-none}); deleted it" >&2; exit 1; }
      rm -rf "$BDIR/llama-b70-$b-ubuntu24-x64"
      tar -xzf "$BDIR/$f" -C "$BDIR" --no-same-owner || { echo "could not unpack $f" >&2; exit 1; }
      rm -f "$BDIR/$f"
      [ -x "$BDIR/llama-b70-$b-ubuntu24-x64/llama-bench" ] || { echo "$f has no llama-bench" >&2; exit 1; }
    done
  fi
  for b in "${want[@]}"; do
    BINS+=("$BDIR/llama-b70-$b-ubuntu24-x64/llama-bench")
    case "$b" in sycl) LABELS+=(SYCL) ;; vulkan) LABELS+=(Vulkan) ;; esac
  done
  say "prebuilt llama.cpp: release $TAG in $BDIR"
fi

if [ "${#BINS[@]}" = 0 ]; then
  if command -v llama-bench >/dev/null; then BINS=("$(command -v llama-bench)"); LABELS=("")
  else
    cat >&2 <<'EOF'
No llama-bench given. Either use the prebuilt B70 builds (Linux x86-64, glibc 2.39+):
  bash b70-bench.sh --prebuilt
or build llama.cpp for one or both backends, then pass the binaries:
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
if [ "$VRAM" -gt 0 ] && [ "$VRAM" -lt 1073741824 ]; then
  say "note: the VRAM BAR is only $(( VRAM / 1048576 )) MiB (Resizable BAR off?), so VRAM size is unknown; running all models. b70-doctor explains the BIOS fix."
  VRAM=0
fi

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
[ "${#RUN_MODELS[@]}" -gt 0 ] || { echo "no model fits this card's VRAM; nothing to run" >&2; exit 2; }

# --- run -----------------------------------------------------------------------------------
# One llama-bench call per depth with jsonl output: a slow or hung deep-context run can't take the others with it,
# and the lines finished before a timeout are kept.
TO=${B70B_TIMEOUT:-2400}
if command -v timeout >/dev/null; then T=(timeout "$TO"); else T=(); fi
# Pick the GPU per binary unless the user did: with an iGPU present, SYCL's device 0 can be the iGPU.
pick_dev() { # pick_dev BIN -> prints "NAME|DESCRIPTION|N_DEVICES" or nothing
  "${T0[@]}" "$1" --list-devices 2>/dev/null | python3 -c '
import re, sys
devs = [m.groups() for m in (re.match(r"\s+(\S+): (.*) \((\d+) MiB, \d+ MiB free\)\s*$", l) for l in sys.stdin) if m]
bmg = re.compile(r"Arc\(TM\) (Pro )?B\d+|Battlemage|\bBMG\b|\bB70\b", re.I)
if len(devs) > 1:
    best = max(devs, key=lambda d: (bool(bmg.search(d[1])), int(d[2])))
    print(f"{best[0]}|{best[1]}|{len(devs)}")'
}
if command -v timeout >/dev/null; then T0=(timeout 120); else T0=(); fi
BDEV=()
for bi in "${!BINS[@]}"; do
  BDEV[$bi]=$DEV
  if [ -z "$DEV" ] && [ -z "$MG" ]; then
    pick=$(pick_dev "${BINS[$bi]}")
    if [ -n "$pick" ]; then
      IFS='|' read -r pname pdesc pn <<< "$pick"
      BDEV[$bi]=$pname
      say "${LABELS[$bi]:-llama-bench}: $pn GPUs visible, using $pname ($pdesc); pass --dev to choose another"
    fi
  fi
done

n=0
for bi in "${!BINS[@]}"; do
  b=${BINS[$bi]}
  for m in "${RUN_MODELS[@]}"; do
    IFS='|' read -r id path depths fa <<< "$m"
    IFS=',' read -r -a dlist <<< "$depths"
    for d in "${dlist[@]}"; do
      n=$((n+1)); tag=$(printf '%02d' "$n")
      args=(-m "$path" -ngl 99 -sm none -p 512 -n 128 -d "$d" -fa "$fa" -r "$REPS" -o jsonl)
      [ -n "${BDEV[$bi]}" ] && args+=(-dev "${BDEV[$bi]}")
      [ -n "$MG" ] && args+=(-mg "$MG")
      say "[$tag] ${LABELS[$bi]:-llama-bench} $id depth $d"
      printf '%s\n' "$b ${args[*]}" > "$OUT/run$tag.cmd"
      printf '{"model_id":"%s","label":"%s","depth":%d}\n' "$id" "${LABELS[$bi]}" "$d" > "$OUT/run$tag.meta"
      "${T[@]}" "$b" "${args[@]}" > "$OUT/run$tag.jsonl" 2> "$OUT/run$tag.log"
      rc=$?
      if [ "$rc" = 124 ]; then
        say "    stopped after ${TO}s (kept the finished tests). Slow is as likely as hung: deep context on Vulkan/Xe2 can"
        say "    take very long. If dmesg shows 'xe ... Timedout job' or 'Engine reset', it was a GPU hang."
        echo "timeout after ${TO}s" >> "$OUT/run$tag.log"
      elif [ "$rc" != 0 ]; then
        say "    failed (exit $rc): $(grep -v '^\s*$' "$OUT/run$tag.log" | tail -n1 | sed "s#$HOME#~#g" | cut -c1-160)"
      fi
      printf '%s\n' "$rc" > "$OUT/run$tag.rc"
    done
  done
done

# --- aggregate + submission ------------------------------------------------------------------
python3 - "$OUT" "$VERSION" "$TIER" "$REPO" <<'PY'
import glob, json, os, sys, datetime
out, version, tier, repo = sys.argv[1:5]
env = json.load(open(os.path.join(out, "env.json")))
home = os.path.expanduser("~")
runs, failures = [], []
for cmd in sorted(glob.glob(os.path.join(out, "run*.cmd"))):
    base = cmd[:-4]; meta = json.load(open(base + ".meta"))
    rows = []
    for line in open(base + ".jsonl", errors="replace") if os.path.exists(base + ".jsonl") else []:
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass  # a line cut off by a timeout
    rc = open(base + ".rc").read().strip() if os.path.exists(base + ".rc") else "0"
    if rc != "0" or not rows:
        log = [l for l in open(base + ".log", errors="replace").read().splitlines() if l.strip()]
        failures.append({"model_id": meta["model_id"], "depth": meta.get("depth", 0),
                         "backend": meta["label"] or (rows[0].get("backends") if rows else "") or "?",
                         "kept_tests": len(rows),
                         "error": (log[-1] if log else f"exit {rc}, no output").replace(home, "~")[:200]})
    for r in rows:
        test = f"pp{r['n_prompt']}" if r.get("n_prompt") else f"tg{r['n_gen']}"
        runs.append({
            "model_id": meta["model_id"], "backend": meta["label"] or r.get("backends", "?"),
            "backends": r.get("backends", ""), "gpu_info": r.get("gpu_info", ""),
            "split_mode": r.get("split_mode", ""), "devices": r.get("devices", ""),
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
           f"llama.cpp: {builds or '-'}\n\ntokens/s (llama-bench, one GPU (-sm none), -ngl 99, f16 KV):\n\n{table}\n")
if failures:
    summary += "\nfailed or cut-short runs:\n" + "\n".join(
        f"- {f['backend']} {f['model_id']} depth {f['depth']}: {f['error']}" + (f" (kept {f['kept_tests']} finished tests)" if f['kept_tests'] else "")
        for f in failures) + "\n"
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
