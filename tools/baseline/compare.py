"""Cross-IME comparison on identical noisy keystrokes (Misstype vs vChewing).

Subcommands (see tools/baseline/README.md for the full recipe):

  gen    write inputs.tsv: one row per (probe, noise config, seed), deterministic
  drive-misstype  run inputs.tsv through libMisstypeCAPI.so (ctypes), Enter-commit
  report join outputs and print per-config tables

The unit under test is the end-to-end result a user gets on Enter after typing
the keystrokes: engine + lexicon together. Different lexicons are a known
confound (docs/competitors.md); this measures what the user would see, it does
not isolate decoder quality.

Metrics, per (engine, noise config):
  perfect   share of inputs whose committed text equals the target
  errors    mean character edit distance to the target (chars to fix)
  cer       errors / target length
  ms        median wall time for typing + Enter (in-process, not spawn)
"""
import argparse
import ctypes
import hashlib
import random
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from bench import levenshtein  # noqa: E402
from keynoise import CONFIGS, apply_noise  # noqa: E402

HERE = Path(__file__).resolve().parent


def load_probes(path: Path) -> list[tuple[str, str, str]]:
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        name, keys, expected, _ = line.split("\t")
        rows.append((name, keys, expected))
    return rows


def cmd_gen(args) -> None:
    probes = load_probes(Path(args.probes))
    with open(args.out, "w", encoding="utf-8") as f:
        for name, keys, _ in probes:
            for config, kwargs in CONFIGS.items():
                for seed in range(args.seeds if config != "clean" else 1):
                    digest = hashlib.md5(f"{name}/{config}/{seed}".encode()).digest()
                    rng = random.Random(int.from_bytes(digest[:8], "big"))
                    f.write(f"{name}|{config}|{seed}\t{apply_noise(keys, rng, **kwargs)}\n")


# --- libMisstypeCAPI via ctypes -------------------------------------------

class KeyEvent(ctypes.Structure):
    _fields_ = [("kind", ctypes.c_int32), ("label", ctypes.c_char_p),
                ("text", ctypes.c_char_p), ("modifiers", ctypes.c_uint32),
                ("is_release", ctypes.c_int32), ("native_code", ctypes.c_int32),
                ("timestamp", ctypes.c_double)]


class KeyResult(ctypes.Structure):
    _fields_ = [("consumed", ctypes.c_int32), ("commit", ctypes.POINTER(ctypes.c_char)),
                ("beep", ctypes.c_int32), ("mode_changed", ctypes.c_int32)]


KIND_CHAR, KIND_SPACE, KIND_ENTER = 0, 1, 2


def cmd_drive_misstype(args) -> None:
    lib = ctypes.CDLL(args.lib)
    lib.misstype_engine_new.restype = ctypes.c_void_p
    lib.misstype_engine_new.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    lib.misstype_session_new.restype = ctypes.c_void_p
    lib.misstype_session_new.argtypes = [ctypes.c_void_p]
    lib.misstype_session_free.argtypes = [ctypes.c_void_p]
    lib.misstype_session_handle.restype = KeyResult
    lib.misstype_session_handle.argtypes = [ctypes.c_void_p, ctypes.POINTER(KeyEvent)]
    lib.misstype_string_free.argtypes = [ctypes.c_void_p]
    engine = lib.misstype_engine_new(args.resources.encode(), b"")
    if not engine:
        sys.exit("engine_new failed: need lexicon.tsv in --resources")

    def send(session, kind, label=None) -> str:
        ev = KeyEvent(kind, label, label, 0, 0, -1, -1.0)
        res = lib.misstype_session_handle(session, ctypes.byref(ev))
        out = ""
        if res.commit:
            out = ctypes.cast(res.commit, ctypes.c_char_p).value.decode("utf-8")
            lib.misstype_string_free(res.commit)
        return out

    lines = Path(args.inputs).read_text(encoding="utf-8").splitlines()
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("config\tid\tcommitted\tms\n")
        for line in lines:
            ident, keys = line.split("\t", 1)
            session = lib.misstype_session_new(engine)
            started = time.perf_counter()
            committed = ""
            for ch in keys:
                committed += send(session, KIND_SPACE) if ch == " " else send(
                    session, KIND_CHAR, ch.encode())
            committed += send(session, KIND_ENTER)
            ms = (time.perf_counter() - started) * 1000
            lib.misstype_session_free(session)
            f.write(f"misstype\t{ident}\t{committed}\t{ms:.2f}\n")


# --- libchewing via ctypes --------------------------------------------------

# chewing.h: SIMPLE/CHEWING/FUZZY_CHEWING_CONVERSION_ENGINE.
CHEWING_ENGINES = {"chewing": 1, "fuzzy": 2}


def cmd_drive_libchewing(args) -> None:
    lib = ctypes.CDLL(args.lib)
    lib.chewing_new2.restype = ctypes.c_void_p
    lib.chewing_new2.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
    for name in ("chewing_delete", "chewing_Reset"):
        getattr(lib, name).argtypes = [ctypes.c_void_p]
    for name in ("chewing_handle_Space", "chewing_handle_Enter", "chewing_commit_Check"):
        getattr(lib, name).argtypes = [ctypes.c_void_p]
    lib.chewing_handle_Default.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.chewing_set_KBType.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.chewing_commit_String_static.restype = ctypes.c_char_p
    lib.chewing_commit_String_static.argtypes = [ctypes.c_void_p]
    lib.chewing_config_set_int.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]

    def committed_now(ctx) -> str:
        if lib.chewing_commit_Check(ctx) == 1:
            return lib.chewing_commit_String_static(ctx).decode("utf-8")
        return ""

    lines = Path(args.inputs).read_text(encoding="utf-8").splitlines()
    with open(args.out, "w", encoding="utf-8") as f, tempfile.TemporaryDirectory() as tmp:
        f.write("config\tid\tcommitted\tms\n")
        for engine in args.engines.split(","):
            # A throwaway user dictionary keeps ~/.chewing out of the run; with
            # auto-learn off nothing a probe commits can bias the next one.
            ctx = lib.chewing_new2(args.data.encode(), f"{tmp}/{engine}.dat".encode(), None, None)
            if not ctx:
                sys.exit(f"chewing_new2 failed: no dictionaries under {args.data}")
            if lib.chewing_set_KBType(ctx, 0) != 0:  # KB_DEFAULT = Dachen, as the probes
                sys.exit("chewing_set_KBType failed")
            settings = {"chewing.conversion_engine": CHEWING_ENGINES[engine],
                        "chewing.disable_auto_learn_phrase": 1,
                        "chewing.space_is_select_key": 0,
                        "chewing.auto_commit_threshold": 39}  # longest preedit allowed
            for key, value in settings.items():
                if lib.chewing_config_set_int(ctx, key.encode(), value) != 0:
                    sys.exit(f"chewing_config_set_int({key}, {value}) failed")
            for line in lines:
                ident, keys = line.split("\t", 1)
                lib.chewing_Reset(ctx)
                started = time.perf_counter()
                committed = ""
                for ch in keys:
                    if ch == " ":
                        lib.chewing_handle_Space(ctx)
                    else:
                        lib.chewing_handle_Default(ctx, ord(ch))
                    committed += committed_now(ctx)
                lib.chewing_handle_Enter(ctx)
                committed += committed_now(ctx)
                ms = (time.perf_counter() - started) * 1000
                f.write(f"{engine}\t{ident}\t{committed}\t{ms:.2f}\n")
            lib.chewing_delete(ctx)


# --- report -----------------------------------------------------------------

def cmd_report(args) -> None:
    probes = {n: e for n, _, e in load_probes(Path(args.probes))}
    records = []
    for path in args.outputs:
        for line in Path(path).read_text(encoding="utf-8").splitlines()[1:]:
            engine, ident, committed, ms = line.split("\t")
            name, config, _ = ident.split("|")
            records.append((engine, name, config, committed, ms, ident))
    # A probe says nothing about noise if some engine already misses it on
    # CLEAN keystrokes (homophone ambiguity, lexicon variant). Drop those
    # unless --all, and list them so the exclusion is visible.
    invalid = {name for engine, name, config, committed, *_ in records
               if config == "clean" and committed != probes[name]}
    if args.all:
        invalid = set()
    elif invalid:
        print(f"excluded (not clean-correct on every engine): {', '.join(sorted(invalid))}")
        print(f"kept {len(probes) - len(invalid)} of {len(probes)} probes\n")
    cells: dict[tuple[str, str], list[tuple[bool, int, float, float]]] = {}
    for engine, name, config, committed, ms, _ in records:
        if name in invalid:
            continue
        expected = probes[name]
        dist = levenshtein(expected, committed)
        cells.setdefault((engine, config), []).append(
            (committed == expected, dist, dist / len(expected), float(ms)))
    engines = sorted({e for e, _ in cells})
    configs = [c for c in CONFIGS if any((e, c) in cells for e in engines)]
    print(f"{'config':20} {'engine':10} {'n':>5} {'perfect':>8} {'errors':>7} {'cer':>6} {'ms':>7}")
    for config in configs:
        for engine in engines:
            rows = cells.get((engine, config))
            if not rows:
                continue
            print(f"{config:20} {engine:10} {len(rows):>5} "
                  f"{sum(r[0] for r in rows) / len(rows):>8.2f} "
                  f"{statistics.mean(r[1] for r in rows):>7.2f} "
                  f"{statistics.mean(r[2] for r in rows):>6.3f} "
                  f"{statistics.median(r[3] for r in rows):>7.1f}")
    if args.losses:
        # Inputs where another engine commits the target and ENGINE does not:
        # the cases worth turning into fixtures when tuning ENGINE.
        by_input: dict[str, dict[str, str]] = {}
        for engine, name, _, committed, _, ident in records:
            if name not in invalid:
                by_input.setdefault(ident, {})[engine] = committed
        print(f"\n{args.losses} wrong, another engine exact (input: target / {args.losses} / winners):")
        for ident, outs in sorted(by_input.items()):
            expected = probes[ident.split("|")[0]]
            winners = sorted(e for e, c in outs.items() if c == expected and e != args.losses)
            if winners and outs.get(args.losses) != expected:
                print(f"  {ident}: {expected} / {outs.get(args.losses, '-')} / {','.join(winners)}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--probes", default=str(HERE / "probes.tsv"))
    g.add_argument("--out", required=True)
    g.add_argument("--seeds", type=int, default=10)
    d = sub.add_parser("drive-misstype")
    d.add_argument("--lib", required=True)
    d.add_argument("--resources", required=True)
    d.add_argument("--inputs", required=True)
    d.add_argument("--out", required=True)
    c = sub.add_parser("drive-libchewing")
    c.add_argument("--lib", required=True, help="libchewing.dylib / libchewing.so")
    c.add_argument("--data", required=True, help="search path holding word.dat, tsi.dat")
    c.add_argument("--engines", default="chewing,fuzzy", help="comma list of chewing,fuzzy")
    c.add_argument("--inputs", required=True)
    c.add_argument("--out", required=True)
    r = sub.add_parser("report")
    r.add_argument("--probes", default=str(HERE / "probes.tsv"))
    r.add_argument("--all", action="store_true", help="keep probes that fail on clean keystrokes")
    r.add_argument("--losses", metavar="ENGINE",
                   help="also list inputs ENGINE gets wrong while another engine is exact")
    r.add_argument("outputs", nargs="+")
    args = p.parse_args()
    {"gen": cmd_gen, "drive-misstype": cmd_drive_misstype,
     "drive-libchewing": cmd_drive_libchewing, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    main()
