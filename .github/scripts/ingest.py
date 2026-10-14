"""Turn a b70-bench result issue into results/<issue>.json and regenerate RESULTS.md.

usage: ingest.py EVENT_JSON COMMENT_OUT        (run by .github/workflows/ingest.yml)
       ingest.py --rebuild                      (regenerate RESULTS.md from results/*.json)

Issue bodies are untrusted: nothing from them reaches a shell. Every field is type-checked, strings are
reduced to a safe character set, and the bot only writes files under results/ plus RESULTS.md.
"""
import datetime
import glob
import json
import os
import re
import sys

ROOT = os.environ.get("B70B_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULTS = os.path.join(ROOT, "results")
MARKER = "<!-- b70-bench-result v1 -->"
REPO = re.sub(r"[^A-Za-z0-9._/-]", "", os.environ.get("GITHUB_REPOSITORY", "riceharvest/b70-bench"))
STD_MODELS = [
    ("llama2-7b-q4_0", "Llama-2-7B Q4_0 (same model as the llama.cpp Vulkan scoreboard)"),
    ("qwen3.8-27b-ud-q4_k_m", "Qwen3.8-27B UD-Q4_K_M (dense, 15.3 GB)"),
    ("qwen3.6-35b-a3b-ud-q4_k_m", "Qwen3.6-35B-A3B UD-Q4_K_M (MoE, 20.6 GB)"),
]
GPU_OK = re.compile(r"(arc|battlemage|bmg|b70|b65|b60|b50|b580|b570|intel)", re.I)


class Invalid(Exception):
    pass


def clean(v, n=80):
    """Untrusted value -> short string of safe characters (no markdown/HTML/pipes)."""
    s = re.sub(r"[^A-Za-z0-9 .:+()/,-]", "", str(v if v is not None else ""))
    return s.strip()[:n]


def num(v, lo, hi, what):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not (lo <= v <= hi):
        raise Invalid(f"{what} must be a number in [{lo}, {hi}], got {clean(v, 20)!r}")
    return v


def parse(body):
    if MARKER not in body:
        raise Invalid("not a b70-bench result (marker missing)")
    m = re.search(r"```json\s*\n(.*?)\n\s*```", body[body.index(MARKER):], re.S)
    if not m:
        raise Invalid("no ```json block found")
    if len(m.group(1)) > 400_000:
        raise Invalid("json block too large")
    try:
        doc = json.loads(m.group(1))
    except ValueError as e:
        raise Invalid(f"json does not parse: {clean(e, 120)}")
    if not isinstance(doc, dict) or doc.get("schema") != 1 or doc.get("tool") != "b70-bench":
        raise Invalid("expected schema 1 from tool b70-bench")
    env = doc.get("env") if isinstance(doc.get("env"), dict) else {}
    gpus = env.get("gpus") if isinstance(env.get("gpus"), list) else []
    g = gpus[0] if gpus and isinstance(gpus[0], dict) else {}
    pk = env.get("packages") if isinstance(env.get("packages"), dict) else {}
    runs_in = doc.get("runs")
    if not isinstance(runs_in, list) or not runs_in or len(runs_in) > 400:
        raise Invalid("runs must be a non-empty list (at most 400)")
    runs = []
    for r in runs_in:
        if not isinstance(r, dict):
            raise Invalid("each run must be an object")
        model, test = str(r.get("model_id")), str(r.get("test"))
        if not re.fullmatch(r"(custom:)?[A-Za-z0-9._-]{1,80}", model) or not re.fullmatch(r"(pp|tg)\d{1,6}", test):
            raise Invalid(f"bad model_id/test: {clean(model, 40)!r} {clean(test, 12)!r}")
        if str(r.get("split_mode", "none")) not in ("none", ""):
            raise Invalid("runs must use one GPU (split_mode none); multi-GPU results don't belong in the single-card table")
        fa = r.get("flash_attn")
        if fa not in (0, 1, True, False, None):
            raise Invalid("flash_attn must be 0/1")
        runs.append({
            "model_id": model, "test": test,
            "depth": int(num(r.get("depth", 0), 0, 1_048_576, "depth")),
            "flash_attn": None if fa is None else int(fa),
            "backend": clean(r.get("backend"), 40) or "?",
            "build_commit": clean(r.get("build_commit"), 12),
            "build_number": int(num(r.get("build_number", 0), 0, 10_000_000, "build_number")),
            "avg_ts": round(float(num(r.get("avg_ts"), 0.0001, 100_000, "avg_ts")), 2),
            "stddev_ts": round(float(num(r.get("stddev_ts", 0), 0, 100_000, "stddev_ts")), 2),
            "type_k": clean(r.get("type_k"), 10), "type_v": clean(r.get("type_v"), 10),
        })
    gpu = clean(g.get("name"), 40)
    if not GPU_OK.search(gpu + " " + " ".join(clean(r.get("gpu_info"), 80) for r in runs_in if isinstance(r, dict))):
        raise Invalid("GPU is not an Intel Arc / Battlemage card")
    date = clean(doc.get("date"), 10)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise Invalid("date must be YYYY-MM-DD")
    return {
        "date": date, "version": clean(doc.get("version"), 12), "tier": clean(doc.get("tier"), 10),
        "gpu": gpu or "?", "kernel": clean(env.get("kernel"), 40), "os": clean(env.get("os"), 60),
        "guc": clean(g.get("guc"), 20), "link": f"{clean(g.get('link'), 16)} x{clean(g.get('link_width'), 3)}".strip(),
        "packages": {clean(k, 40): clean(v, 40) for k, v in list(pk.items())[:20]},
        "runs": runs,
    }


def driver_for(rec, backend):
    pk = rec["packages"]
    if "vulkan" in backend.lower():
        v = pk.get("mesa-vulkan-drivers") or pk.get("vulkan-intel")
        return f"Mesa {v}" if v else ""
    v = pk.get("intel-compute-runtime") or pk.get("libze-intel-gpu1") or pk.get("intel-opencl-icd")
    return f"CR {v}" if v else ""


def col_name(test, depth, fa):
    d = "" if not depth else f" @{depth // 1024}K" if depth % 1024 == 0 else f" @{depth}"
    return f"{test}{d}" + (" fa off" if fa == 0 else "")


def render(records):
    out = ["# b70-bench results", "",
           "Tokens/s from `llama-bench` (`-ngl 99 -p 512 -n 128`, f16 KV), submitted by owners with "
           "[b70-bench.sh](b70-bench.sh). Each row is one issue; click the number for the full environment. "
           "`@8K` = after 8,192 tokens of context. CR = Intel compute-runtime. Generated, do not edit.", ""]
    for mid, title in STD_MODELS:
        rows = []
        for n, rec in records:
            by_backend = {}
            for r in rec["runs"]:
                if r["model_id"] == mid:
                    by_backend.setdefault((r["backend"], r["build_number"], r["build_commit"]), []).append(r)
            for (backend, bn, bc), rs in by_backend.items():
                rows.append((n, rec, backend, bn, bc, {(r["test"], r["depth"], r["flash_attn"]): r for r in rs}))
        if not rows:
            continue
        cols = sorted({k for *_, cells in rows for k in cells},
                      key=lambda k: (k[1], 0 if k[2] in (1, None) else 1, k[0][:2] != "pp", k[0]))
        out += [f"## {title}", "",
                "| GPU | backend | llama.cpp | " + " | ".join(col_name(*k) for k in cols) + " | driver | kernel | date | # |",
                "|---|---|---|" + "---:|" * len(cols) + "---|---|---|---|"]
        rows.sort(key=lambda x: (x[2], -max((c["avg_ts"] for k, c in x[5].items() if k[0].startswith("tg")), default=0)))
        for n, rec, backend, bn, bc, cells in rows:
            vals = [f"{cells[k]['avg_ts']:.1f}" if k in cells else "" for k in cols]
            out.append(f"| {rec['gpu']} | {backend} | b{bn} {bc} | " + " | ".join(vals) +
                       f" | {driver_for(rec, backend)} | {rec['kernel'].split('-')[0]} | {rec['date']} | [{n}](https://github.com/{REPO}/issues/{n}) |")
        out.append("")
    if len(out) == 4:
        out.append("No results yet.")
    return "\n".join(out) + "\n"


def load_all():
    recs = []
    for f in sorted(glob.glob(os.path.join(RESULTS, "*.json"))):
        n = int(os.path.basename(f)[:-5])
        recs.append((n, json.load(open(f))))
    return recs


def rebuild():
    open(os.path.join(ROOT, "RESULTS.md"), "w").write(render(load_all()))


def main(event_path, comment_path):
    ev = json.load(open(event_path))
    issue, action = ev["issue"], ev.get("action")
    n = int(issue["number"]); path = os.path.join(RESULTS, f"{n}.json")
    os.makedirs(RESULTS, exist_ok=True)
    msg = ""
    if action == "closed" and issue.get("state_reason") == "not_planned":
        if os.path.exists(path):
            os.remove(path)
    elif MARKER not in (issue.get("body") or ""):
        if os.path.exists(path):  # marker edited away: drop the row quietly
            os.remove(path)
    elif action in ("opened", "edited", "reopened"):
        try:
            rec = parse(issue.get("body") or "")
            rec["issue"] = {"number": n, "author": clean(issue["user"]["login"], 40),
                            "created": clean(issue.get("created_at"), 20)}
            json.dump(rec, open(path, "w"), indent=1)
            std = sorted({r["model_id"] for r in rec["runs"] if not r["model_id"].startswith("custom:")})
            msg = (f"Thanks! Parsed {len(rec['runs'])} measurements for {rec['gpu']} "
                   f"({', '.join(sorted({r['backend'] for r in rec['runs']}))}); "
                   + (f"added to [RESULTS.md](https://github.com/{REPO}/blob/main/RESULTS.md) under {', '.join(std)}." if std
                      else "only custom models, so it's stored but not shown in the tables."))
        except Invalid as e:
            if os.path.exists(path):
                os.remove(path)
            msg = f"Couldn't read this result: {e}. Edit the issue to fix it, or re-run b70-bench.sh and paste its issue-body.md."
    rebuild()
    # comment on new results, and on edits only when something is wrong
    if msg and (action != "edited" or msg.startswith("Couldn't")):
        open(comment_path, "w").write(msg + "\n")


if __name__ == "__main__":
    if sys.argv[1:] == ["--rebuild"]:
        rebuild()
    else:
        main(sys.argv[1], sys.argv[2])
