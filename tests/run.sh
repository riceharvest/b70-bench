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
has std "$TMP/std.out" '\[01\] SYCL llama2-7b-q4_0 depth 0'
has std "$TMP/std.out" '\[08\] Vulkan qwen3.8-27b-ud-q4_k_m depth 32768'
has std "$O/run02.cmd" ' -ngl 99 -sm none -p 512 -n 128 -d 0 -fa 1 -r 3 -o jsonl$'
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
has full "$TMP/full.out" 'qwen3.8-27b-ud-q4_k_m depth 65536'
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
has fail "$O/summary.md" '- SYCL llama2-7b-q4_0 depth 0: ggml_sycl: UR_RESULT_ERROR_DEVICE_LOST while loading ~/models/x.gguf'
grep -q "$HOME" "$O/summary.md" "$O/issue-body.md" "$TMP/fail.out" && bad fail "home path leaked" || ok
has fail "$O/summary.md" '\| model \| test \| SYCL \| Vulkan \|'
has fail "$O/summary.md" '\| llama2-7b-q4_0 \| tg128 \|  \| [0-9.]+ ± [0-9.]+ \|$'

# 3b. a stalled deep-context run is cut by the timeout; finished tests of it and other depths are kept
O="$TMP/slow"
FAKE_SLOW_DEPTH=32768 B70B_TIMEOUT=3 bash "$ROOT/b70-bench.sh" --bin "$FB" --models-dir "$MD" --out "$O" --no-submit > "$TMP/slow.out" 2>&1
has slow "$TMP/slow.out" 'stopped after 3s \(kept the finished tests\)'
has slow "$O/summary.md" 'qwen3.8-27b-ud-q4_k_m \| pp512 @ d32768 \| [0-9.]+'
has slow "$O/summary.md" 'qwen3.8-27b-ud-q4_k_m \| tg128 @ d8192 \| [0-9.]+'
has slow "$O/summary.md" 'depth 32768: timeout after 3s \(kept 1 finished tests\)'

# 3c. Resizable BAR off: VRAM unknown, nothing skipped
O="$TMP/rebar"
FAKE_VRAM=268435456 bash "$ROOT/b70-bench.sh" --bin "$FB" --tier quick --models-dir "$MD" --out "$O" --no-submit > "$TMP/rebar.out" 2>&1
has rebar "$TMP/rebar.out" 'VRAM BAR is only 256 MiB \(Resizable BAR off\?\)'
has rebar "$TMP/rebar.out" '\[01\] llama-bench llama2-7b-q4_0 depth 0'

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

# 5b. --prebuilt: release tarballs from a local fake release; sha256 checked, cached, labels set
REL="$TMP/rel/download/b70-test-1"; mkdir -p "$REL"
for b in sycl vulkan; do
  N=llama-b70-$b-ubuntu24-x64; mkdir -p "$TMP/pkg/$N"; cp "$FB" "$TMP/pkg/$N/llama-bench"
  tar -czf "$REL/$N.tar.gz" -C "$TMP/pkg" "$N"
done
(cd "$REL" && sha256sum *.tar.gz > SHA256SUMS)
export B70B_BUILDS_URL="file://$TMP/rel" B70B_BUILDS_TAG=b70-test-1 B70B_BUILDS_DIR="$TMP/builds"
O="$TMP/pre"
bash "$ROOT/b70-bench.sh" --prebuilt --tier quick --models-dir "$MD" --out "$O" --no-submit --yes > "$TMP/pre.out" 2>&1
[ $? = 0 ] && ok || { bad pre "exit != 0"; cat "$TMP/pre.out"; }
has pre "$TMP/pre.out" 'prebuilt llama.cpp: release b70-test-1'
has pre "$TMP/pre.out" '\[01\] SYCL llama2-7b-q4_0'
has pre "$TMP/pre.out" '\[02\] Vulkan llama2-7b-q4_0'
has pre "$O/summary.md" '\| model \| test \| SYCL \| Vulkan \|'
[ ! -e "$TMP/builds/b70-test-1/llama-b70-sycl-ubuntu24-x64.tar.gz" ] && ok || bad pre "tarball not removed after unpack"
# cached: second run with only vulkan needs no download and no consent
rm -rf "$TMP/rel"
O="$TMP/pre2"
setsid -w bash "$ROOT/b70-bench.sh" --prebuilt vulkan --tier quick --models-dir "$MD" --out "$O" --no-submit < /dev/null > "$TMP/pre2.out" 2>&1
[ $? = 0 ] && ok || { bad pre2 "cached run failed"; cat "$TMP/pre2.out"; }
grep -q 'downloading' "$TMP/pre2.out" && bad pre2 "downloaded again" || ok
grep -q ' SYCL ' "$TMP/pre2.out" && bad pre2 "ran sycl though only vulkan was asked" || ok
# a tampered tarball is rejected and deleted
mkdir -p "$REL"; N=llama-b70-sycl-ubuntu24-x64; tar -czf "$REL/$N.tar.gz" -C "$TMP/pkg" "$N"
echo "0000000000000000000000000000000000000000000000000000000000000000  $N.tar.gz" > "$REL/SHA256SUMS"
O="$TMP/pre3"
B70B_BUILDS_DIR="$TMP/builds3" bash "$ROOT/b70-bench.sh" --prebuilt sycl --tier quick --models-dir "$MD" --out "$O" --no-submit --yes > "$TMP/pre3.out" 2>&1
[ $? = 1 ] && ok || bad pre3 "tampered tarball did not fail with exit 1"
has pre3 "$TMP/pre3.out" 'sha256 mismatch for llama-b70-sycl-ubuntu24-x64.tar.gz'
[ ! -e "$TMP/builds3/b70-test-1/$N" ] && [ ! -e "$TMP/builds3/b70-test-1/$N.tar.gz" ] && ok || bad pre3 "tampered build left behind"
# no consent without a terminal
O="$TMP/pre4"
B70B_BUILDS_DIR="$TMP/builds4" setsid -w bash "$ROOT/b70-bench.sh" --prebuilt --tier quick --models-dir "$MD" --out "$O" --no-submit < /dev/null > "$TMP/pre4.out" 2>&1
[ $? = 1 ] && ok || bad pre4 "downloaded without consent"
[ -z "$(ls -A "$TMP/builds4/b70-test-1" 2>/dev/null)" ] && ok || bad pre4 "files written without consent"
unset B70B_BUILDS_URL B70B_BUILDS_TAG B70B_BUILDS_DIR

# 5c. nothing to run is an early, clear error
bash "$ROOT/b70-bench.sh" --bin "$FB" --tier none --out "$TMP/none" --no-submit > "$TMP/none.out" 2>&1
[ $? = 2 ] && ok || bad none "exit != 2"
has none "$TMP/none.out" '--tier none needs at least one --model FILE'
[ ! -e "$TMP/none" ] && ok || bad none "results dir created"

# 5d. GPU pick: B70 over a bigger-memory iGPU; single GPU adds no -dev; --dev wins
O="$TMP/pick"
FAKE_DEVICES="SYCL0=Intel(R) Arc(TM) Graphics=47000;SYCL1=Intel(R) Arc(TM) Pro B70 Graphics=31000" \
  bash "$ROOT/b70-bench.sh" --sycl "$FB" --tier quick --models-dir "$MD" --out "$O" --no-submit > "$TMP/pick.out" 2>&1
has pick "$TMP/pick.out" 'SYCL: 2 GPUs visible, using SYCL1 \(Intel\(R\) Arc\(TM\) Pro B70 Graphics\)'
has pick "$O/run01.cmd" ' -o jsonl -dev SYCL1$'
FAKE_DEVICES="Vulkan0=Intel(R) Graphics (BMG G31)=31000;Vulkan1=AMD Radeon RX 7600=8000" \
  bash "$ROOT/b70-bench.sh" --vulkan "$FB" --tier quick --models-dir "$MD" --out "$TMP/pick2" --no-submit > "$TMP/pick2.out" 2>&1
has pick2 "$TMP/pick2/run01.cmd" ' -dev Vulkan0$'
grep -q -- '-dev' "$TMP/std/run01.cmd" && bad pick "single GPU got -dev" || ok
FAKE_DEVICES="SYCL0=Intel(R) Arc(TM) Graphics=47000;SYCL1=Intel(R) Arc(TM) Pro B70 Graphics=31000" \
  bash "$ROOT/b70-bench.sh" --sycl "$FB" --dev SYCL0 --tier quick --models-dir "$MD" --out "$TMP/pick3" --no-submit > "$TMP/pick3.out" 2>&1
has pick3 "$TMP/pick3/run01.cmd" ' -dev SYCL0$'
grep -q 'GPUs visible' "$TMP/pick3.out" && bad pick3 "picked despite --dev" || ok

# 6. bench output -> ingest bot -> RESULTS.md (end to end), plus validation cases
python3 "$HERE/test_ingest.py" "$TMP/std/issue-body.md" > "$TMP/ingest.out" 2>&1 && ok || { bad ingest "test_ingest.py failed"; cat "$TMP/ingest.out"; }
grep -E '^(OK|FAIL)' "$TMP/ingest.out" | grep -c FAIL | grep -qx 0 && ok || bad ingest "subtests failed"

echo "passed $PASS, failed $FAILN"
[ "$FAILN" = 0 ]
