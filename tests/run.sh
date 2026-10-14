#!/usr/bin/env bash
# CPU-only tests: b70-bench.sh against a fake llama-bench + fake doctor, then the ingest bot on its output.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PASS=0; FAILN=0
ok()   { PASS=$((PASS+1)); }
bad()  { FAILN=$((FAILN+1)); echo "FAIL [$1]: $2"; }
has()  { grep -qE -- "$3" "$2" && ok || { bad "$1" "expected /$3/ in $(basename "$2")"; sed 's/^/    | /' "$2" | head -40; }; }

FB="$HERE/fixtures/fake-llama-bench"
export B70B_DOCTOR="$HERE/fixtures/fake-doctor.sh" B70B_SKIP_VERIFY=1
MD="$TMP/models"; mkdir -p "$MD"
for f in llama-2-7b.Q4_0.gguf Qwen3.8-27B-UD-Q4_K_M.gguf Qwen3.6-35B-A3B-UD-Q4_K_M.gguf; do : > "$MD/$f"; done
: > "$TMP/my model+v2.gguf"

# 1. standard tier, two backends
O="$TMP/std"
FAKE_BACKEND=SYCL bash "$ROOT/b70-bench.sh" --sycl "$FB" --vulkan "$FB" --models-dir "$MD" --out "$O" --no-submit > "$TMP/std.out" 2>&1
[ $? = 0 ] && ok || { bad std "exit != 0"; cat "$TMP/std.out"; }
has std "$TMP/std.out" '\[01\] SYCL llama2-7b-q4_0 \(depths 0\)'
has std "$TMP/std.out" '\[04\] Vulkan qwen3.8-27b-ud-q4_k_m \(depths 0,8192,32768\)'
has std "$O/summary.md" '\| model \| test \| SYCL \| Vulkan \|'
has std "$O/summary.md" '\| llama2-7b-q4_0 \| pp512 \(fa off\) \|'
has std "$O/summary.md" '\| qwen3.8-27b-ud-q4_k_m \| tg128 @ d32768 \| '
has std "$O/summary.md" 'GPU: Arc Pro B70 \| kernel 7.0.0-38-generic \| GuC 70.65.0 \| libze-intel-gpu1 26.27'
has std "$O/issue-title.txt" '^\[result\] Arc Pro B70 \| SYCL \+ Vulkan \| 20[0-9-]+$'
grep -q 'qwen3.6-35b' "$TMP/std.out" && bad std "MoE model ran in standard tier" || ok
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["schema"]==1 and len(d["runs"])==2*(4+6), len(d["runs"])' "$O/results.json" && ok || bad std "results.json run count"

# 2. full tier adds MoE + 65K depth; small card skips models that don't fit
O="$TMP/full"
bash "$ROOT/b70-bench.sh" --bin "$FB" --tier full --models-dir "$MD" --out "$O" --no-submit > "$TMP/full.out" 2>&1
has full "$TMP/full.out" 'qwen3.6-35b-a3b-ud-q4_k_m'
has full "$TMP/full.out" 'depths 0,8192,32768,65536'
O="$TMP/small"
FAKE_VRAM=17179869184 bash "$ROOT/b70-bench.sh" --bin "$FB" --tier full --models-dir "$MD" --out "$O" --no-submit > "$TMP/small.out" 2>&1
has small "$TMP/small.out" 'skip qwen3.8-27b-ud-q4_k_m: 15 GiB does not fit this card.s 16 GiB'
has small "$TMP/small.out" 'skip qwen3.6-35b'
has small "$TMP/small.out" '\[01\] llama-bench llama2-7b-q4_0'

# 3. a failing backend is recorded, the other still reported
O="$TMP/fail"
cat > "$TMP/dead-bench" <<EOF
#!/usr/bin/env bash
FAKE_FAIL=1 exec "$FB" "\$@"
EOF
chmod +x "$TMP/dead-bench"
bash "$ROOT/b70-bench.sh" --vulkan "$FB" --sycl "$TMP/dead-bench" --tier quick --models-dir "$MD" --out "$O" --no-submit > "$TMP/fail.out" 2>&1
has fail "$TMP/fail.out" 'failed \(exit 134\): ggml_sycl: UR_RESULT_ERROR_DEVICE_LOST'
has fail "$O/summary.md" '- SYCL llama2-7b-q4_0: ggml_sycl: UR_RESULT_ERROR_DEVICE_LOST'
has fail "$O/summary.md" '\| model \| test \| SYCL \| Vulkan \|'
has fail "$O/summary.md" '\| llama2-7b-q4_0 \| tg128 \|  \| [0-9.]+ ± [0-9.]+ \|$'

# 4. custom model only; odd filename is sanitized
O="$TMP/custom"
bash "$ROOT/b70-bench.sh" --bin "$FB" --tier none --model "$TMP/my model+v2.gguf" --out "$O" --no-submit > "$TMP/custom.out" 2>&1
has custom "$O/summary.md" 'custom:my-model-v2'

# 5. no model download without consent (no tty, no --yes) and nothing given
O="$TMP/nodl"; rm -f "$TMP/empty"; mkdir -p "$TMP/empty"
B70B_SKIP_VERIFY=0 setsid -w bash "$ROOT/b70-bench.sh" --bin "$FB" --tier quick --models-dir "$TMP/empty" --out "$O" --no-submit < /dev/null > "$TMP/nodl.out" 2>&1 < /dev/null
rc=$?
[ "$rc" = 1 ] && ok || bad nodl "exit $rc, want 1"
[ -z "$(ls -A "$TMP/empty")" ] && ok || bad nodl "something was downloaded"

# 6. bench output -> ingest bot -> RESULTS.md (end to end), plus validation cases
python3 "$HERE/test_ingest.py" "$TMP/std/issue-body.md" > "$TMP/ingest.out" 2>&1 && ok || { bad ingest "test_ingest.py failed"; cat "$TMP/ingest.out"; }
grep -E '^(OK|FAIL)' "$TMP/ingest.out" | grep -c FAIL | grep -qx 0 && ok || bad ingest "subtests failed"

echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
