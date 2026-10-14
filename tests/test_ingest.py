"""Ingest bot tests (stdlib only). usage: test_ingest.py ISSUE_BODY_FROM_B70_BENCH"""
import json, os, sys, tempfile, importlib.util
tmp = tempfile.mkdtemp(); os.environ["B70B_ROOT"] = tmp
spec = importlib.util.spec_from_file_location(
    "ingest", os.path.join(os.path.dirname(__file__), "..", ".github", "scripts", "ingest.py"))
ing = importlib.util.module_from_spec(spec); spec.loader.exec_module(ing)
body = open(sys.argv[1]).read()
fails = 0
def check(name, cond):
    global fails
    print(("OK   " if cond else "FAIL ") + name); fails += (not cond)
def event(action, n, body, reason=None):
    p = os.path.join(tmp, f"ev{n}{action}.json")
    json.dump({"action": action, "issue": {"number": n, "body": body, "user": {"login": "someone"},
               "created_at": "2026-10-15T00:00:00Z", "state_reason": reason}}, open(p, "w"))
    c = os.path.join(tmp, f"c{n}{action}.md")
    if os.path.exists(c): os.remove(c)
    ing.main(p, c)
    return open(c).read() if os.path.exists(c) else ""
def doc_of(b):
    import re
    return json.loads(re.search(r"```json\n(.*?)\n```", b, re.S).group(1))
def body_of(doc):
    return f"{ing.MARKER}\n```json\n{json.dumps(doc)}\n```\n"

# real b70-bench output parses and lands in RESULTS.md
c = event("opened", 7, body)
res = open(os.path.join(tmp, "RESULTS.md")).read()
check("comment confirms", "Parsed 20 measurements for Arc Pro B70 (SYCL, Vulkan)" in c and "qwen3.8-27b-ud-q4_k_m" in c)
check("results file", os.path.exists(os.path.join(tmp, "results", "7.json")))
check("27B table", "## Qwen3.8-27B UD-Q4_K_M" in res and "| pp512 | tg128 | pp512 @8K | tg128 @8K | pp512 @32K | tg128 @32K |" in res)
check("7B fa columns", "| pp512 | tg128 | pp512 fa off | tg128 fa off |" in res)
check("row content", "| Arc Pro B70 | SYCL | b7001 097cf33d9 | 1100.0 | 55.0 |" in res and "CR 26.27.39122.11-0 | 7.0.0 |" in res)
check("vulkan driver col", "| Arc Pro B70 | Vulkan |" in res and "Mesa 26.1.2-1ubuntu1" in res)
check("issue link", "[7](https://github.com/riceharvest/b70-bench/issues/7)" in res)
check("no MoE table without data", "35B-A3B" not in res)

# edits: valid edit -> no comment; broken edit -> comment + row removed
check("valid edit silent", event("edited", 7, body) == "")
c = event("edited", 7, body.replace('"schema":1', '"schema":2'))
check("broken edit explains", c.startswith("Couldn't read this result: expected schema 1"))
check("broken edit removes row", not os.path.exists(os.path.join(tmp, "results", "7.json")))
event("edited", 7, body)

# hostile / invalid input
d = doc_of(body)
evil = json.loads(json.dumps(d)); evil["env"]["gpus"][0]["name"] = "Arc B70 | <script>x</script> @admin `rm -rf`"
evil["runs"][0]["backend"] = "SYCL|![x](http://e/x.png)"
event("opened", 8, body_of(evil))
r8 = json.load(open(os.path.join(tmp, "results", "8.json")))
check("strings sanitized", all(ch not in r8["gpu"] + r8["runs"][0]["backend"] for ch in "|<>`@![]"))
for name, mut in [
    ("negative t/s", lambda x: x["runs"][0].__setitem__("avg_ts", -5)),
    ("bool as number", lambda x: x["runs"][0].__setitem__("avg_ts", True)),
    ("bad test name", lambda x: x["runs"][0].__setitem__("test", "pp512; rm")),
    ("bad model id", lambda x: x["runs"][0].__setitem__("model_id", "../../etc/passwd")),
    ("non-intel gpu", lambda x: (x["env"]["gpus"][0].__setitem__("name", "RTX 5090"),
                                 [r.__setitem__("gpu_info", "NVIDIA") for r in x["runs"]])),
    ("too many runs", lambda x: x.__setitem__("runs", x["runs"] * 30)),
    ("multi-gpu split", lambda x: x["runs"][0].__setitem__("split_mode", "layer")),
]:
    x = json.loads(json.dumps(d)); mut(x)
    c = event("opened", 9, body_of(x))
    check(f"rejects {name}", c.startswith("Couldn't read") and not os.path.exists(os.path.join(tmp, "results", "9.json")))
check("no marker -> ignored", event("opened", 10, "hello") == "" and not os.path.exists(os.path.join(tmp, "results", "10.json")))

# closing as not planned removes the row; completed keeps it
event("closed", 8, body_of(evil), "not_planned")
check("not_planned removes", not os.path.exists(os.path.join(tmp, "results", "8.json")))
event("closed", 7, body, "completed")
check("completed keeps", os.path.exists(os.path.join(tmp, "results", "7.json")))
sys.exit(1 if fails else 0)
