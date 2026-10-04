"""LM choice experiment (M4 validation, tools-only, opt-in).

Question: repair-mode (free generation) flipped 0/4 and edge-scoring
flipped 0/N with qwen2.5 <=1.5b instruct. Both asked too much of a small
model (generation, calibration). Choice asks less: pick ONE index from the
offline top-8 (discrimination). Output space is locked to the list, so
hallucination is unrepresentable — anything unparseable abstains to top-1.

Shippability bar (stated upfront): flips > 0 on tie cases AND zero WORSE
on controls. Anything else falsifies choice for small instruct models.

Protocol mirrors decode_with_fallback semantics without touching runtime:
  1. Swift --decode produces offline top-8 (single decoder implementation).
     The Jev path also sends the raw key stream, pinned-dictionary phonetic
     evidence, and offline candidate provenance as structured state. This is
     intentionally different from the historical candidate-only run: a
     fluency judge cannot recover the user's intent from Chinese strings.
  2. The model replies with a single number (temp 0 on ollama; default
     sampling on OpenAI reasoning tiers).
  3. Accept ONLY when the reply parses to an index 1..N (0 or garbage =
     abstain -> offline top-1). No text gate needed: the pick IS a beam
     entry by construction.
  4. Report CER before/after, per-call latency, abstentions, stability.

Fixtures are synthetic session cases (no personal text). Ollama is
localhost-only; the Jev backend sends only the synthetic raw keys, derived
evidence, and candidate lists unless the caller explicitly supplies context
or a user-lexicon path. The key comes from the environment and is never
logged.

Usage:
  PYTHONPATH=src python tools/lm_choose.py            # 1.5b model
  PYTHONPATH=src python tools/lm_choose.py --model qwen2.5:0.5b --reps 1
  OPENAI_API_KEY=... PYTHONPATH=src python tools/lm_choose.py \
      --backend openai --model gpt-5.6-luna --reps 3
  PYTHONPATH=src python tools/lm_choose.py --backend jev \
      --user-context '開場問候' --user-lexicon /path/to/phrases.json
  PYTHONPATH=src python tools/lm_choose.py --backend jev-local \
      --local-url http://127.0.0.1:8000/predict   # Laya; default is jev-local
"""

import argparse
import json
import math
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
from lm_rescore import CASES as RESCORE_CASES  # noqa: E402
from lm_rescore import (cer, load_char_bases, load_toneless_bases,
                        offline_entries, parse_evidence)  # noqa: E402

OLLAMA_URL = "http://localhost:11434/api/chat"

BASELINE_CASES = RESCORE_CASES + [
    {"name": "yue-recall-absent", "model": None,
     "keys": "u,4x96u,4", "expected": "越來越"},
]

CONTEXT_CASES = [
    {
        "name": "dada-ime-context",
        "keys": "hkguvu8cjo1jcjo282jo",
        "expected": "測試一下會不會打對",
        "context": "我在測試新輸入法在長句子下的選字表現，",
    },
    {
        "name": "dada-quiz-context",
        "keys": "hkguvu8cjo1jcjo282jo",
        "expected": "測試一下會不會答對",
        "context": "這道題目難度非常高，老師想透過隨堂測驗，",
    },
    {
        "name": "bianshi-ai-context",
        "keys": "1u04g4",
        "expected": "辨識",
        "context": "我們系統導入了最新的深度學習模型來進行人臉",
    },
    {
        "name": "buda-rain-context",
        "keys": "1j28",
        "expected": "不打",
        "context": "今天下午突然下起傾盆大雨，這場戶外網球賽我們先",
    },
    {
        "name": "buda-size-control",
        "keys": "1j28",
        "expected": "不大",
        "context": "這件大衣的版型比預期合身很多，穿起來一點都",
    },
    {
        "name": "qianbao-shopping-context",
        "keys": "294fu061l ",
        "expected": "帶錢包",
        "context": "出門去超市結帳買東西時，千萬別忘了隨身要",
    },
    {
        "name": "zuoye-homework-context",
        "keys": "yji4yji4u,4",
        "expected": "做作業",
        "context": "老師叮嚀大家放學回家後，一定要專心",
    },
]

CASES = BASELINE_CASES + CONTEXT_CASES


def build_jev_state(raw_keys: str, evidence: list[dict[str, str | None]],
                    candidates: list[str],
                    metadata: list[dict[str, object]] | None = None,
                    user_context: str = "",
                    user_preferences: list[dict[str, object]] | None = None,
                    char_bases: dict[str, set[str]] | None = None,
                    rich_context: bool = False
                    ) -> str:
    """Serialize decision inputs without including the expected answer.

    Candidate rank/score are provenance rather than a hidden label, so a
    rerank result can be inspected against the offline baseline. The raw
    stream stays beside normalized readings, matching the capture-first
    contract.
    """
    rows: list[dict[str, object]] = []
    baseline = candidates[0] if candidates else ""
    for index, text in enumerate(candidates):
        row: dict[str, object] = {"index": index + 1, "text": text}
        if metadata is not None and index < len(metadata):
            for key in ("rank", "score", "repairs", "unresolved"):
                if key in metadata[index]:
                    row[key] = metadata[index][key]
        if rich_context:
            row["phonetic_alignment"] = candidate_alignment(
                text, evidence, char_bases or {})
            row["diff_from_candidate_1"] = candidate_diff(text, baseline)
        rows.append(row)
    state = {
        "phonetic_input": {
            "raw_keys": raw_keys,
            "syllables": evidence,
        },
        "candidates": rows,
        "user_context": user_context or None,
        "user_preferences": user_preferences or [],
    }
    if rich_context:
        state["decoder_contract"] = {
            "input_mode": "bopomofo_zhuyin",
            "stage": "completed_delayed_phrase",
            "tone_policy": "explicit tones are evidence; absent tones remain uncertain",
            "selection_goal": "recover user intent, not generic text frequency",
            "candidate_rank_is_offline_provenance": True,
        }
    return json.dumps(state, ensure_ascii=False, separators=(",", ":"))


def candidate_alignment(text: str, evidence: list[dict[str, str | None]],
                        char_bases: dict[str, set[str]]) -> dict[str, object]:
    """Summarize per-character compatibility without decoding new text."""
    chars = list(text)
    cells: list[dict[str, object]] = []
    for index, item in enumerate(evidence):
        char = chars[index] if index < len(chars) else None
        valid = sorted(char_bases.get(char, set())) if char else []
        base = item.get("base")
        cells.append({
            "position": index + 1,
            "char": char,
            "input_base": base,
            "input_tone": item.get("tone"),
            "known_bases": valid[:8],
            "base_match": bool(char and base in char_bases.get(char, set())),
        })
    return {
        "length_match": len(chars) == len(evidence),
        "matched_bases": sum(bool(cell["base_match"]) for cell in cells),
        "syllable_count": len(evidence),
        "characters": cells,
    }


def candidate_diff(text: str, baseline: str) -> list[dict[str, object]]:
    """Expose only changed positions relative to offline candidate 1."""
    changes: list[dict[str, object]] = []
    for index in range(max(len(text), len(baseline))):
        left = baseline[index] if index < len(baseline) else None
        right = text[index] if index < len(text) else None
        if left != right:
            changes.append({"position": index + 1, "offline": left, "candidate": right})
    return changes


PROMPT_VARIANTS = {
    "structured": (
        "先檢查候選是否符合 phonetic_input 的注音音節與聲調；再使用 "
        "user_context 和句意判斷。只在證據與上下文足以區分時選一項。"
        "若多個候選都同樣符合、或無法判斷使用者意圖，選最保守的候選，"
        "不要因為單純更常見就假裝確定。"
    ),
    "constraints": (
        "你是注音輸入法解碼器，不是一般文章流暢度評分器。依序執行："
        "一，把每個音節和明確聲調視為硬證據；二，只在符合證據的候選中"
        "使用 user_context 和 user_preferences；三，如果這些訊號仍無法區分，"
        "保留離線候選1。不要只因為字詞更常見或更像人話就改選。"
    ),
    "contrastive": (
        "逐項比較 candidates，只看候選彼此不同的字詞。對每個差異檢查"
        "phonetic_input 的音節、聲調、user_context 和 user_preferences；"
        "共同的前後文不提供區分訊號。如果差異沒有任何證據支持，保留"
        "離線候選1，不要用一般語料常見度猜測。"
    ),
    "rich-audit": (
        "先讀 decoder_contract，再逐候選檢查 phonetic_alignment 的"
        "length_match、base_match 和 diff_from_candidate_1。淘汰不符合"
        "注音證據的候選；剩下者才使用 user_context 和 user_preferences。"
        "若仍沒有區分訊號，保留離線候選1，不要用一般語料常見度猜測。"
    ),
}


def phonetic_instructions(variant: str = "structured") -> str:
    """Tell Jev what evidence is authoritative for this experiment."""
    try:
        return PROMPT_VARIANTS[variant]
    except KeyError as error:
        raise ValueError(f"unknown prompt variant: {variant}") from error


def load_user_preferences(path: str | Path | None,
                          evidence: list[dict[str, str | None]]) -> list[dict[str, object]]:
    """Load only matching learned phrases for an explicit Jev run.

    The IME's lexicon is local by default. This helper is opt-in and strips
    timestamps and unrelated readings before a caller deliberately sends the
    matching text to a remote evaluator.
    """
    if not path:
        return []
    try:
        payload = json.loads(Path(path).read_text())
    except (OSError, TypeError, ValueError):
        return []
    if not isinstance(payload, dict):
        return []
    entries = payload.get("entries")
    if not isinstance(entries, dict):
        return []
    reading_key = "".join(item.get("base") or "" for item in evidence)
    raw_entries = entries.get(reading_key, {})
    if not isinstance(raw_entries, dict):
        return []
    preferences: list[dict[str, object]] = []
    for text, record in raw_entries.items():
        if not isinstance(text, str) or not isinstance(record, dict):
            continue
        count = record.get("count", 0)
        if isinstance(count, int) and count > 0:
            preferences.append({"text": text, "count": count})
    preferences.sort(key=lambda item: (-int(item["count"]), str(item["text"])))
    return preferences


def choice_prompt(candidates: list[str]) -> str:
    numbered = "\n".join(f"{i + 1}. {c}" for i, c in enumerate(candidates))
    return (
        "你是中文輸入法選句器。下面有"
        + str(len(candidates))
        + "個候選句，請選出最通順、最自然、最像人話的一句。"
          "只輸出它的編號數字（例如 3），不要輸出句子、不要解釋。"
          "如果沒有任何一句通順，輸出 0。\n" + numbered
    )


def parse_pick(reply: str, count: int) -> int | None:
    """Strict index parse shared by backends: 1..N -> 0-based, else abstain."""
    match = re.search(r"-?\d+", reply.strip())
    if match is None:
        print(f"  [abstain] unparseable: {reply.strip()[:60]!r}")
        return None
    index = int(match.group(0)) - 1
    if index < 0:
        print("  [abstain] model voted none-natural")
        return None
    if index >= count:
        print(f"  [abstain] out-of-list index: {reply.strip()[:60]!r}")
        return None
    return index


def lm_choose(candidates: list[str], model: str,
              timeout_s: float) -> tuple[int | None, float]:
    """Return the chosen 0-based index, or None on abstain/error (ollama)."""
    body = json.dumps({"model": model, "temperature": 0, "stream": False,
                       "options": {"num_predict": 8},
                       "messages": [{"role": "user",
                                     "content": choice_prompt(candidates)}]}).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(OLLAMA_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            reply = json.loads(resp.read())["message"]["content"]
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000
    elapsed_ms = (time.perf_counter() - started) * 1000
    return parse_pick(reply, len(candidates)), elapsed_ms


def ollama_logprobs_choose(candidates: list[str], model: str,
                           timeout_s: float) -> tuple[int | None, float, float | None]:
    """Jev-shaped local choice: single constrained token + logprobs.

    Sends the same numbered choice prompt but asks for ONE token
    (num_predict=1, temp 0) with logprobs/top_logprobs. The first-token
    distribution over "1".."N" (+ "0" abstain) is the local analogue of
    Jev's Choice probabilities; max-prob is the confidence. Nothing leaves
    localhost; stdlib only. Returns (0-based index | None, ms, maxprob).
    """
    valid = {str(i + 1) for i in range(len(candidates))} | {"0"}
    body = json.dumps({
        "model": model, "stream": False,
        "options": {"num_predict": 1, "temperature": 0},
        "logprobs": True, "top_logprobs": max(10, len(candidates) + 2),
        "messages": [{"role": "user", "content": choice_prompt(candidates)}],
    }).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(OLLAMA_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = json.loads(resp.read())
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000, None
    elapsed_ms = (time.perf_counter() - started) * 1000
    try:
        entries = payload.get("logprobs") or []
        top = (entries[0].get("top_logprobs") or []) if entries else []
    except Exception as error:
        print(f"  [lm-error] bad logprobs payload: {error}")
        return None, elapsed_ms, None
    mass: dict[str, float] = {}
    for entry in top:
        token = str(entry.get("token", "")).strip()
        if token in valid and token not in mass:
            try:
                mass[token] = math.exp(float(entry.get("logprob", float("-inf"))))
            except (TypeError, ValueError):
                continue
    total = sum(mass.get(str(i + 1), 0.0) for i in range(len(candidates)))
    total += mass.get("0", 0.0)
    if total <= 0:
        print(f"  [abstain] no valid digit in top_logprobs: {top[:4]}")
        return None, elapsed_ms, None
    probs = {k: v / total for k, v in mass.items() if k in valid}
    best = max(probs, key=lambda k: probs[k])
    maxprob = probs[best]
    print(f"  [logprobs] {[(k, round(probs[k], 3)) for k in sorted(probs)]}")
    if best == "0":
        print("  [abstain] model voted none-natural")
        return None, elapsed_ms, maxprob
    return int(best) - 1, elapsed_ms, maxprob


def ollama_logprobs_trust(candidates: list[str], model: str,
                          timeout_s: float) -> tuple[float | None, float]:
    """Local trust triage: p("1"=yes) vs p("0"=no) on offline top-1.

    Same single-token logprobs trick as above. trust = p1 / (p1 + p0).
    Returns (trust | None, ms).
    """
    prompt = (
        f"候選1「{candidates[0]}」是最通順、最自然的中文嗎？"
        "只輸出一個數字：是輸出 1，否輸出 0，不要解釋。"
    )
    body = json.dumps({
        "model": model, "stream": False,
        "options": {"num_predict": 1, "temperature": 0},
        "logprobs": True, "top_logprobs": 10,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(OLLAMA_URL, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = json.loads(resp.read())
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000
    elapsed_ms = (time.perf_counter() - started) * 1000
    try:
        entries = payload.get("logprobs") or []
        top = (entries[0].get("top_logprobs") or []) if entries else []
    except Exception as error:
        print(f"  [lm-error] bad logprobs payload: {error}")
        return None, elapsed_ms
    mass: dict[str, float] = {}
    for entry in top:
        token = str(entry.get("token", "")).strip()
        if token in ("1", "0") and token not in mass:
            try:
                mass[token] = math.exp(float(entry.get("logprob", float("-inf"))))
            except (TypeError, ValueError):
                continue
    if "1" not in mass and "0" not in mass:
        print(f"  [abstain] no 1/0 in top_logprobs: {top[:4]}")
        return None, elapsed_ms
    denom = mass.get("1", 0.0) + mass.get("0", 0.0)
    trust = mass.get("1", 0.0) / denom if denom > 0 else None
    print(f"  [logprobs] p1={mass.get('1', 0.0):.3f} p0={mass.get('0', 0.0):.3f}")
    return trust, elapsed_ms


def load_dotenv(path: Path) -> dict[str, str]:
    """Minimal .env reader (KEY=value, no interpolation, no new deps)."""
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip("\"'")
        if key.strip():
            values[key.strip()] = value
    return values


def ensure_ai_sdk() -> Path:
    """Self-bootstrap the `ai` npm package outside the repo (tools-only).

    Returns the dir to put on NODE_PATH. npm output stays quiet; failure
    raises loudly so the experiment fails fast instead of half-running.
    """
    root = Path(tempfile.gettempdir()) / "misstype-jev-sdk"
    marker = root / "node_modules" / "ai" / "package.json"
    if marker.exists():
        return root
    if shutil.which("npm") is None or shutil.which("node") is None:
        raise RuntimeError("node/npm not found; cannot bootstrap ai SDK")
    root.mkdir(parents=True, exist_ok=True)
    init = subprocess.run(["npm", "init", "-y"], cwd=root, capture_output=True)
    if init.returncode != 0:
        raise RuntimeError("npm init failed")
    install = subprocess.run(["npm", "i", "ai", "--no-audit", "--no-fund"],
                             cwd=root, capture_output=True)
    if install.returncode != 0 or not marker.exists():
        raise RuntimeError("npm i ai failed")
    return root


def jev_noul(candidates: list[str], model: str, api_key: str,
             timeout_s: float, *, raw_keys: str = "",
             evidence: list[dict[str, str | None]] | None = None,
             metadata: list[dict[str, object]] | None = None,
             user_context: str = "",
             user_preferences: list[dict[str, object]] | None = None,
             prompt_variant: str = "structured",
             char_bases: dict[str, set[str]] | None = None,
             rich_context: bool = False,
             ) -> tuple[int | None, float, list[float]]:
    """Decomposed flow (docs-aligned): parallel Noul questions in ONE
    request, argmax combined in code. Returns (pick | None, ms, all nouls).

    Same information as single-Choice, different mechanism (absolute vs
    relative judgment). If this flips what Choice missed, flow design was
    the blocker; if it agrees, the tie class itself resists voting.
    """
    state = build_jev_state(raw_keys, evidence or [], candidates, metadata,
                            user_context, user_preferences, char_bases,
                            rich_context)
    questions = {
        f"c{i + 1}": {
            # Gateway accepts choice/score/boolean ("noul" is the docs'
            # playground-era name and is rejected here).
            "type": "boolean",
            "instructions": f"{phonetic_instructions(prompt_variant)} "
                            f"候選{i + 1}「{c}」最符合注音證據、上下文和使用者意圖",
        } for i, c in enumerate(candidates)
    }
    job = {"model": model, "state": state, "questions": questions}
    try:
        sdk_root = ensure_ai_sdk()
    except Exception as error:
        print(f"  [lm-error] bootstrap: {error}")
        return None, 0.0, []
    helper = ROOT / "tools" / "jev_choice.cjs"
    env = dict(os.environ)
    env["AI_GATEWAY_API_KEY"] = api_key
    env["NODE_PATH"] = str(sdk_root / "node_modules") + os.pathsep + env.get("NODE_PATH", "")
    try:
        proc = subprocess.run(["node", str(helper), json.dumps(job)],
                              capture_output=True, text=True,
                              timeout=timeout_s, env=env)
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, 0.0, []
    if proc.returncode != 0:
        print(f"  [lm-error] node: {proc.stderr.strip()[-300:]}")
        return None, 0.0, []
    try:
        payload = json.loads(proc.stdout.strip())
        answers = payload["answers"]
        usage = payload.get("usage") or {}
        print(f"  [usage] in={usage.get('inputTokens')} "
              f"out={usage.get('outputTokens')}")
    except Exception as error:
        print(f"  [lm-error] bad payload: {error}")
        return None, 0.0, []
    nouls: list[float] = []
    for i in range(len(candidates)):
        entry = answers.get(f"c{i + 1}") or {}
        # Boolean answers carry singular "probability" (docs-era "noul"
        # key also accepted if a backend ever returns it).
        value = entry.get("probability", entry.get("noul", entry.get("boolean")))
        nouls.append(float(value) if isinstance(value, (int, float)) else -1.0)
    if any(v < 0 for v in nouls):
        print(f"  [abstain] missing nouls: {nouls}")
        return None, float(payload.get("ms", 0)), nouls
    best = max(range(len(nouls)), key=lambda i: nouls[i])
    return best, float(payload.get("ms", 0)), nouls


def jev_trust(candidates: list[str], model: str, api_key: str,
              timeout_s: float, *, raw_keys: str = "",
              evidence: list[dict[str, str | None]] | None = None,
              metadata: list[dict[str, object]] | None = None,
              user_context: str = "",
              user_preferences: list[dict[str, object]] | None = None,
              prompt_variant: str = "structured",
              char_bases: dict[str, set[str]] | None = None,
              rich_context: bool = False,
              ) -> tuple[float | None, float]:
    """Interruption triage: one boolean on offline top-1. Returns
    (trust | None, ms). High trust -> panel stays out of the way; low
    trust -> surface the candidate window. One request, same state shape
    as the other modes; threshold decided post-hoc from data, never from
    a single anecdote.
    """
    state = build_jev_state(raw_keys, evidence or [], candidates, metadata,
                            user_context, user_preferences, char_bases,
                            rich_context)
    job = {"model": model, "state": state,
           "questions": {"trust": {
               "type": "boolean",
               "instructions": f"{phonetic_instructions(prompt_variant)} "
                               f"候選1「{candidates[0]}」符合注音證據、上下文和使用者意圖",
           }}}
    try:
        sdk_root = ensure_ai_sdk()
    except Exception as error:
        print(f"  [lm-error] bootstrap: {error}")
        return None, 0.0
    helper = ROOT / "tools" / "jev_choice.cjs"
    env = dict(os.environ)
    env["AI_GATEWAY_API_KEY"] = api_key
    env["NODE_PATH"] = str(sdk_root / "node_modules") + os.pathsep + env.get("NODE_PATH", "")
    try:
        proc = subprocess.run(["node", str(helper), json.dumps(job)],
                              capture_output=True, text=True,
                              timeout=timeout_s, env=env)
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, 0.0
    if proc.returncode != 0:
        print(f"  [lm-error] node: {proc.stderr.strip()[-300:]}")
        return None, 0.0
    try:
        payload = json.loads(proc.stdout.strip())
        entry = payload["answers"]["trust"]
        usage = payload.get("usage") or {}
        print(f"  [usage] in={usage.get('inputTokens')} "
              f"out={usage.get('outputTokens')}")
        value = entry.get("probability", entry.get("noul", entry.get("boolean")))
        trust = float(value) if isinstance(value, (int, float)) else None
    except Exception as error:
        print(f"  [lm-error] bad payload: {error}")
        return None, 0.0
    if trust is None:
        print("  [abstain] missing trust value")
    return trust, float(payload.get("ms", 0))


def jev_choose(candidates: list[str], evidence: list[dict[str, str | None]],
               model: str, api_key: str, timeout_s: float, *, raw_keys: str = "",
               metadata: list[dict[str, object]] | None = None,
               user_context: str = "",
               user_preferences: list[dict[str, object]] | None = None,
               prompt_variant: str = "structured",
               char_bases: dict[str, set[str]] | None = None,
               rich_context: bool = False,
               ) -> tuple[int | None, float, float | None]:
    """Choice via Jev (Vercel AI Gateway evaluate). Returns
    (0-based index | None, in-model ms, max probability | None).

    State contains raw keys, normalized phonetic evidence, optional user
    context, matching learned preferences, and candidate provenance. When
    ``rich_context`` is enabled it also includes character-level alignment,
    changed positions, and the decoder contract. The answer remains a beam
    index.
    """
    job = jev_choice_job(candidates, evidence, model, raw_keys=raw_keys,
                         metadata=metadata, user_context=user_context,
                         user_preferences=user_preferences,
                         prompt_variant=prompt_variant, char_bases=char_bases,
                         rich_context=rich_context)
    try:
        sdk_root = ensure_ai_sdk()
    except Exception as error:
        print(f"  [lm-error] bootstrap: {error}")
        return None, 0.0, None
    helper = ROOT / "tools" / "jev_choice.cjs"
    env = dict(os.environ)
    env["AI_GATEWAY_API_KEY"] = api_key
    env["NODE_PATH"] = str(sdk_root / "node_modules") + os.pathsep + env.get("NODE_PATH", "")
    try:
        proc = subprocess.run(["node", str(helper), json.dumps(job)],
                              capture_output=True, text=True,
                              timeout=timeout_s, env=env)
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, 0.0, None
    if proc.returncode != 0:
        print(f"  [lm-error] node: {proc.stderr.strip()[-300:]}")
        return None, 0.0, None
    try:
        payload = json.loads(proc.stdout.strip())
        answer = payload["answers"]["pick"]
        usage = payload.get("usage") or {}
        print(f"  [usage] in={usage.get('inputTokens')} "
              f"out={usage.get('outputTokens')}")
    except Exception as error:
        print(f"  [lm-error] bad payload: {error}")
        return None, 0.0, None
    index, maxprob = parse_choice_answer(answer, len(candidates))
    return index, float(payload.get("ms", 0)), maxprob


def jev_choice_job(candidates: list[str], evidence: list[dict[str, str | None]],
                   model: str, *, raw_keys: str = "",
                   metadata: list[dict[str, object]] | None = None,
                   user_context: str = "",
                   user_preferences: list[dict[str, object]] | None = None,
                   prompt_variant: str = "structured",
                   char_bases: dict[str, set[str]] | None = None,
                   rich_context: bool = False) -> dict[str, object]:
    """One Choice job shared by hosted Jev and local Jev-compatible servers,
    so every backend judges byte-identical state and criteria."""
    state = build_jev_state(raw_keys, evidence, candidates, metadata,
                            user_context, user_preferences, char_bases,
                            rich_context)
    return {"model": model, "state": state,
            "questions": {"pick": {
                "type": "choice",
                "instructions": phonetic_instructions(prompt_variant),
                "criteria": {str(i + 1): c for i, c in enumerate(candidates)}}}}


def parse_choice_answer(answer: dict[str, object],
                        count: int) -> tuple[int | None, float | None]:
    """Map a Choice answer to (0-based index | None, max probability)."""
    probs = answer.get("probabilities") or {}
    maxprob = max(probs.values()) if isinstance(probs, dict) and probs else None
    choice = str(answer.get("choice", ""))
    if not choice.isdigit():
        print(f"  [abstain] non-numeric choice: {choice[:60]!r}")
        return None, maxprob
    index = int(choice) - 1
    if index < 0 or index >= count:
        print(f"  [abstain] out-of-list choice: {choice!r}")
        return None, maxprob
    return index, maxprob


def is_loopback_url(url: str) -> bool:
    host = urllib.parse.urlsplit(url).hostname or ""
    return host in ("localhost", "127.0.0.1", "::1")


def local_jev_choose(job: dict[str, object], count: int, url: str,
                     timeout_s: float) -> tuple[int | None, float, float | None]:
    """POST the Jev Choice job to a local Jev-compatible server (jev-local
    /v1/systemone, Laya /predict). Both answer {answers: {pick: {choice,
    probabilities}}}. Loopback only: nothing leaves the machine."""
    body = json.dumps(job, ensure_ascii=False).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(url, data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = json.loads(resp.read())
        answer = payload["answers"]["pick"]
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000, None
    elapsed_ms = (time.perf_counter() - started) * 1000
    probs = answer.get("probabilities") or {}
    print(f"  [probs] {[(k, round(float(v), 3)) for k, v in sorted(probs.items())]}")
    index, maxprob = parse_choice_answer(answer, count)
    return index, elapsed_ms, maxprob


def openai_choose(candidates: list[str], model: str, base_url: str,
                  api_key: str, timeout_s: float) -> tuple[int | None, float]:
    """Same protocol over OpenAI Chat Completions. Only fixture candidate
    lists leave the machine; the key is never printed. Token usage is
    reported per call for cost tracking."""
    body = json.dumps({"model": model,
                       "max_completion_tokens": 16,
                       "messages": [{"role": "user",
                                     "content": choice_prompt(candidates)}]}).encode()
    started = time.perf_counter()
    try:
        req = urllib.request.Request(
            base_url.rstrip("/") + "/chat/completions", data=body,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + api_key})
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            payload = json.loads(resp.read())
        reply = payload["choices"][0]["message"]["content"] or ""
        usage = payload.get("usage") or {}
        print(f"  [usage] in={usage.get('prompt_tokens')} "
              f"out={usage.get('completion_tokens')}")
    except Exception as error:
        print(f"  [lm-error] {type(error).__name__}: {error}")
        return None, (time.perf_counter() - started) * 1000
    elapsed_ms = (time.perf_counter() - started) * 1000
    return parse_pick(reply, len(candidates)), elapsed_ms


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="qwen2.5:1.5b")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--topn", type=int, default=8)
    parser.add_argument("--backend", choices=["ollama", "ollama-logprobs", "openai", "jev",
                                 "jev-local"],
                        default="ollama")
    parser.add_argument("--base-url", default="https://api.openai.com/v1")
    parser.add_argument("--api-key-env", default="OPENAI_API_KEY")
    parser.add_argument("--gateway-model", default="typesafe-ai/jev")
    parser.add_argument(
        "--local-url", default="http://127.0.0.1:8000/v1/systemone",
        help="jev-local only: loopback Jev-compatible endpoint "
             "(jev-local /v1/systemone, Laya /predict)")
    parser.add_argument(
        "--user-context", default="",
        help="optional explicit context sent to Jev; never read from the IME",
    )
    parser.add_argument(
        "--user-lexicon", default=None,
        help="optional local phrase-learning JSON; matching entries are sent to Jev",
    )
    parser.add_argument(
        "--prompt-variant", choices=sorted(PROMPT_VARIANTS), default="structured",
        help="jev only: instruction variant for the prompt sweep",
    )
    parser.add_argument(
        "--rich-context", action="store_true",
        help="jev only: include candidate phonetic alignment, changed positions, "
             "and decoder contract",
    )
    parser.add_argument("--jev-mode", choices=["choice", "noul", "trust"],
                        default="choice",
                        help="jev only: single 8-way Choice vs 8 parallel "
                             "Noul (docs-aligned decompose pattern), "
                             "argmax combined in code, vs trust: one "
                             "boolean on top-1 (interruption triage)")
    parser.add_argument("--min-confidence", type=float, default=0.0,
                        help="jev only: picks below this max-probability "
                             "abstain (post-hoc analysis still prints)")
    parser.add_argument(
        "--suite", choices=["baseline", "context", "all"], default="all",
        help="test suite to evaluate (baseline, context, or all)",
    )
    args = parser.parse_args()
    if args.backend == "jev" and args.api_key_env == "OPENAI_API_KEY":
        args.api_key_env = "AI_GATEWAY_API_KEY"
    api_key = ""
    if args.backend in ("openai", "jev"):
        api_key = (os.environ.get(args.api_key_env, "")
                   or load_dotenv(ROOT / ".env").get(args.api_key_env, ""))
        if not api_key:
            print(f"refusing to run: {args.api_key_env} is absent "
                  f"(environment or .env; never commit it)")
            return 2
    if args.backend == "jev-local" and not is_loopback_url(args.local_url):
        print(f"refusing to run: --local-url must be loopback "
              f"(got host {urllib.parse.urlsplit(args.local_url).hostname!r})")
        return 2
    print(f"backend={args.backend} model={args.model} reps={args.reps} "
          f"topn={args.topn}")
    flips = worsens = abstains = 0
    recall_hits = 0
    recall_total = 0
    jev_shaped = args.backend in ("jev", "jev-local")
    toneless_bases = load_toneless_bases() if jev_shaped else None
    char_bases = (load_char_bases()
                  if jev_shaped and args.rich_context else None)
    active_cases = (BASELINE_CASES if args.suite == "baseline"
                    else CONTEXT_CASES if args.suite == "context"
                    else CASES)
    for case in active_cases:
        print(f"--- {case['name']} expected={case['expected']}")
        candidate_entries, decode_ms = offline_entries(
            case["keys"], limit=args.topn, user_lexicon=args.user_lexicon)
        candidates = [str(entry["text"]) for entry in candidate_entries]
        if not candidates:
            print("  [skip] no offline candidates")
            continue
        top1 = candidates[0]
        base_cer = cer(top1, case["expected"])
        expected_rank = (candidates.index(case["expected"]) + 1
                         if case["expected"] in candidates else None)
        recall_total += 1
        recall_hits += expected_rank is not None
        print(f"  candidate_recall@{args.topn}={'yes' if expected_rank else 'no'} "
              f"expected_rank={expected_rank or '-'}")
        print(f"  offline top1={top1} CER={base_cer:.3f} ({decode_ms:.0f}ms)")
        evidence = (
            parse_evidence(case["keys"], toneless_bases)
            if toneless_bases is not None else []
        )
        user_context = str(case.get("context", "") or args.user_context)
        user_preferences = load_user_preferences(args.user_lexicon, evidence)
        picks: list[int | None] = []
        latencies: list[float] = []
        confidences: list[float | None] = []
        trusts: list[float | None] = []
        for _ in range(args.reps):
            maxprob: float | None = None
            if args.backend == "openai":
                pick, lm_ms = openai_choose(candidates, args.model,
                                            args.base_url, api_key,
                                            args.timeout)
            elif args.backend == "jev":
                if args.jev_mode == "trust":
                    trust, lm_ms = jev_trust(candidates, args.gateway_model,
                                             api_key, args.timeout,
                                             raw_keys=case["keys"],
                                             evidence=evidence,
                                             metadata=candidate_entries,
                                             user_context=user_context,
                                             user_preferences=user_preferences,
                                             prompt_variant=args.prompt_variant,
                                             char_bases=char_bases,
                                             rich_context=args.rich_context)
                    trusts.append(trust)
                    picks.append(0 if trust is not None else None)
                    latencies.append(lm_ms)
                    confidences.append(trust)
                    continue
                elif args.jev_mode == "noul":
                    pick, lm_ms, nouls = jev_noul(
                        candidates, args.gateway_model, api_key,
                        args.timeout, raw_keys=case["keys"],
                        evidence=evidence, metadata=candidate_entries,
                        user_context=user_context,
                        user_preferences=user_preferences,
                        prompt_variant=args.prompt_variant,
                        char_bases=char_bases,
                        rich_context=args.rich_context)
                    maxprob = max(nouls) if nouls else None
                    print(f"  [nouls] "
                          f"{[round(v, 2) for v in nouls]}")
                else:
                    pick, lm_ms, maxprob = jev_choose(
                        candidates, evidence, args.gateway_model, api_key,
                        args.timeout, raw_keys=case["keys"],
                        metadata=candidate_entries,
                        user_context=user_context,
                        user_preferences=user_preferences,
                        prompt_variant=args.prompt_variant,
                        char_bases=char_bases,
                        rich_context=args.rich_context)
                if (pick is not None and maxprob is not None
                        and maxprob < args.min_confidence):
                    print(f"  [abstain] confidence {maxprob:.2f} "
                          f"< {args.min_confidence}")
                    pick = None
            elif args.backend == "jev-local":
                job = jev_choice_job(
                    candidates, evidence, args.model, raw_keys=case["keys"],
                    metadata=candidate_entries, user_context=user_context,
                    user_preferences=user_preferences,
                    prompt_variant=args.prompt_variant,
                    char_bases=char_bases, rich_context=args.rich_context)
                pick, lm_ms, maxprob = local_jev_choose(
                    job, len(candidates), args.local_url, args.timeout)
                if (pick is not None and maxprob is not None
                        and maxprob < args.min_confidence):
                    print(f"  [abstain] confidence {maxprob:.2f} "
                          f"< {args.min_confidence}")
                    pick = None
            elif args.backend == "ollama-logprobs":
                if args.jev_mode == "trust":
                    trust, lm_ms = ollama_logprobs_trust(
                        candidates, args.model, args.timeout)
                    trusts.append(trust)
                    picks.append(0 if trust is not None else None)
                    latencies.append(lm_ms)
                    confidences.append(trust)
                    continue
                pick, lm_ms, maxprob = ollama_logprobs_choose(
                    candidates, args.model, args.timeout)
                if (pick is not None and maxprob is not None
                        and maxprob < args.min_confidence):
                    print(f"  [abstain] confidence {maxprob:.2f} "
                          f"< {args.min_confidence}")
                    pick = None
            else:
                pick, lm_ms = lm_choose(candidates, args.model, args.timeout)
            picks.append(pick)
            latencies.append(lm_ms)
            confidences.append(maxprob)
        p50 = statistics.median(latencies)
        print(f"  picks={[(None if p is None else p + 1) for p in picks]} "
              f"lm_p50={p50:.0f}ms conf={confidences}")
        abstains += sum(p is None for p in picks)
        if args.backend in ("jev", "ollama-logprobs") and args.jev_mode == "trust":
            # Triage pilot: no pick, just trust-vs-correctness. Correct =
            # CER 0; threshold read post-hoc (printed, not fitted).
            correct = base_cer == 0.0
            for rep, trust in enumerate(trusts):
                voted = "hide-panel" if (trust or 0) >= 0.6 else "show-panel"
                right = (voted == "hide-panel") == correct
                print(f"  rep{rep}: trust={trust} -> {voted} "
                      f"[{'HIT' if right else 'MISS'}] "
                      f"({latencies[rep]:.0f}ms)")
            continue
        for rep, pick in enumerate(picks):
            if pick is None:
                mark = "ABSTAIN"
            else:
                after = cer(candidates[pick], case["expected"])
                mark = ("FLIP" if after < base_cer
                        else ("SAME" if after == base_cer else "WORSE"))
                flips += after < base_cer
                worsens += after > base_cer
            print(f"  rep{rep}: {candidates[pick] if pick is not None else top1} "
                  f"[{mark}] ({latencies[rep]:.0f}ms)")
    print(f"result: flips={flips} worsens={worsens} abstains={abstains} "
          f"(reps included)")
    if recall_total:
        print(f"candidate_recall@{args.topn}: {recall_hits}/{recall_total} "
              f"({recall_hits / recall_total:.2f})")
    return 0 if worsens == 0 and flips > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
