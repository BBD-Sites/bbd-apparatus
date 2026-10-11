#!/usr/bin/env python3
"""multi_trigger_predicate.py: the ONE definition of the double trigger.

A workflow carries the double trigger when one change runs it more than once:
a pull_request (or merge_group) run, and then a push run on the branch that
change lands on, with nothing that skips the second run when the first already
proved the tree. That is the class es-runtime found in May 2026, Restorah-Foods
/yahs-way-pwa in September and builtbyduo-ops in October, each fixed in one
repository and reaching nobody else (OpenSpec change
what-was-fixed-once-is-fixed-everywhere, capability fleet-ci-shape).

Three readers consume this file and none of them may carry its own copy:
  - inventory-list-multi-trigger-workflows.sh (the local and API scans),
  - the daily fleet scan in Personal-Tooling/system (it runs that script),
  - the repository check the personal-side installer places in each
    repository (the installer vendors THIS file byte for byte, so the check
    and the scan cannot disagree).

The predicate, stated once:
  A workflow is flagged when it declares a branch `push` trigger whose branches
  overlap the base branches of a `pull_request` (or `pull_request_target`)
  trigger that runs on code changes, or declares `merge_group` beside such a
  push. The one exemption is a skip that is wired, not one that is named. The
  push is scoped to the base branch only (main or master), and:
    - a lookup job can run on push, declares `outputs:`, has a run step
      that calls `tree-already-green` or queries
      `artifacts?name=full-suite-<tree>`, and runs nothing else: every other
      step is a setup-only action or, after the lookup, gated on it;
    - every other job that can run on push and on the earlier run (the
      pull request or the queue) either needs the lookup job and has an `if:`
      that reads the lookup job's outputs, or has an `if:` that excludes push;
      a job that runs only on push counts too, unless it needs a gated job
      and is skipped with it (or runs on push alone, deploys and runs no
      suite, as a deploy after the build does);
    - or, in place of a lookup job, one job does the lookup and gates each
      later step on it at step level (`if: steps.<id>.outputs.skip !=
      'true'`), or reads it through a later step that turns it into a gate;
    - at least one job reads those outputs.
  It exempts with or without `merge_group`. A marker named anywhere else (a
  comment, a step that ignores the lookup's answer, a job whose outputs nothing
  reads) does not exempt. A push on any branch other than the base branch is
  never exempt: it checks out a tree no earlier run named, so its skip never
  fires.

Not flagged:
  - a push trigger with only `tags` (no branch push),
  - a pull_request trigger whose `types` name none of opened, synchronize,
    reopened (for example `[closed]`, the post-merge cleanup pattern): it does
    not run on a code change,
  - push and pull_request on branch lists that do not overlap,
  - pull_request plus merge_group with no push (one scoped run, one full run in
    the queue: the shape this change asks for).

CLI:
  multi_trigger_predicate.py [--slug SLUG] [--all] [--strict] FILE...
    Prints one row per flagged workflow (every workflow with --all):
      slug|file|verdict|events|rationale
    verdict is one of: double-trigger, clean, unreadable.
    --strict exits 1 when any file is flagged or unreadable (the repository
    check), and 3 when PyYAML is not importable (a check that cannot read
    the file must not pass).
  Without --strict the exit is 0 whatever is found (the scan reports; it does
  not gate).
"""

import fnmatch
import os
import re
import sys

LOOKUP_MARKERS = ("tree-already-green", "artifacts?name=full-suite-")
BASE_BRANCHES = ("main", "master")
CODE_CHANGE_PR_TYPES = {"opened", "synchronize", "reopened"}
PR_EVENTS = ("pull_request", "pull_request_target")


def _as_list(value):
    if value is None:
        return None
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [str(v) for v in value]
    return None


def normalize_on(doc):
    """Return the `on:` block as a dict of event -> config (None when bare)."""
    if not isinstance(doc, dict):
        return {}
    # YAML 1.1 reads a bare `on` key as the boolean True.
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {str(e): None for e in on}
    if isinstance(on, dict):
        return on
    return {}


def _push_branches(cfg):
    """None means every branch; [] means no branch push (tags only)."""
    if not isinstance(cfg, dict):
        return None
    branches = _as_list(cfg.get("branches"))
    if branches is not None:
        return branches
    if "branches-ignore" in cfg:
        return None
    if "tags" in cfg or "tags-ignore" in cfg:
        return []
    return None


def _pr_runs_on_code(cfg):
    if not isinstance(cfg, dict):
        return True
    types = _as_list(cfg.get("types"))
    if types is None:
        return True
    return bool(set(types) & CODE_CHANGE_PR_TYPES)


def _pr_branches(cfg):
    if not isinstance(cfg, dict):
        return None
    branches = _as_list(cfg.get("branches"))
    if branches is not None:
        return branches
    return None


def _overlap(a, b):
    """True when two branch scopes (None = every branch) share a branch."""
    if a is None or b is None:
        return True
    for x in a:
        for y in b:
            if x == y or fnmatch.fnmatch(x, y) or fnmatch.fnmatch(y, x):
                return True
    return False


def _scope(branches):
    return "all branches" if branches is None else ",".join(branches)


_EVENT_TEST = re.compile(r"^github\.event_name\s*(==|!=)\s*'([^']*)'$", re.IGNORECASE)


def _split_top(expr, op):
    parts, depth, quoted, start, i = [], 0, False, 0, 0
    while i < len(expr):
        c = expr[i]
        if c == "'":
            quoted = not quoted
        elif not quoted:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif depth == 0 and expr.startswith(op, i):
                parts.append(expr[start:i].strip())
                i += len(op)
                start = i
                continue
        i += 1
    parts.append(expr[start:].strip())
    return parts


def _unwrap(expr):
    expr = expr.strip()
    if expr.startswith("${{") and expr.endswith("}}"):
        expr = expr[3:-2].strip()
    while expr.startswith("(") and expr.endswith(")"):
        depth = 0
        for i, c in enumerate(expr):
            depth += c == "("
            depth -= c == ")"
            if depth == 0 and i < len(expr) - 1:
                return expr
        expr = expr[1:-1].strip()
    return expr


def _holds_on(event, expr, leaf):
    """True when, on `event`, the job runs only if some `leaf` term holds.

    Only an event test or a `leaf` term can hold; any other term counts as not
    holding, so an `if:` this cannot read leaves the job unwired."""
    expr = _unwrap(expr)
    ors = _split_top(expr, "||")
    if len(ors) > 1:
        return all(_holds_on(event, t, leaf) for t in ors)
    ands = _split_top(expr, "&&")
    if len(ands) > 1:
        return any(_holds_on(event, t, leaf) for t in ands)
    m = _EVENT_TEST.match(expr)
    if m:
        op, named = m.group(1), m.group(2).lower()
        return (op == "!=") == (named == event)
    return leaf(expr)


def _if_text(job):
    cond = job.get("if")
    return "" if cond is None else str(cond)


def _excludes(job, event):
    return _holds_on(event, _if_text(job), lambda term: False)


def _excludes_push(job):
    return _excludes(job, "push")


# Read only where a job runs on push alone past an always() override; it does
# not know every runner, so nothing that decides a job is skipped may use it.
_SUITE_RUN = re.compile(
    r"\b(npm|pnpm|yarn|bun)\s+(run\s+)?test\b|\bvitest(\s+run)?\b(?!\s+list)"
    r"|\bjest\b|\bpytest\b|\bmake\s+test\b|\bgo\s+test\b|\bcargo\s+test\b")


def _runs_suite(job):
    return any(isinstance(st, dict) and isinstance(st.get("run"), str) and _SUITE_RUN.search(st["run"])
               for st in job.get("steps") or [])


def _lookup_steps(job):
    """Ids of the steps that do the lookup, and of every later step whose run
    or env reads one of their outputs (a step that turns the lookup's answer
    into a gate value, as the system CI's `detect` step does)."""
    steps = [st for st in job.get("steps") or [] if isinstance(st, dict)]
    ids = {str(st["id"]) for st in steps
           if st.get("id") and isinstance(st.get("run"), str)
           and any(m in st["run"] for m in LOOKUP_MARKERS)}
    changed = True
    while ids and changed:
        changed = False
        ref = re.compile(r"\bsteps\.(%s)\.outputs\." % "|".join(map(re.escape, ids)))
        for st in steps:
            sid = st.get("id")
            if sid and str(sid) not in ids and (ref.search(str(st.get("run", "")))
                                                 or ref.search(str(st.get("env", "")))):
                ids.add(str(sid)); changed = True
    return ids


def _lookup_outputs(job):
    """Names of the job outputs taken from a lookup step or a step derived
    from one. A constant output, or one from any other step, proves nothing."""
    outs = job.get("outputs")
    ids = _lookup_steps(job)
    if not isinstance(outs, dict) or not ids:
        return set()
    ref = re.compile(r"\bsteps\.(%s)\.outputs\." % "|".join(map(re.escape, ids)))
    return {str(k) for k, v in outs.items() if ref.search(str(v))}


# The gate forms this reads, and no others; each runs the work only when the
# lookup did NOT prove the tree. `!= 'true'` counts only on an output whose
# name says it is the hit, `== 'true'` only on one whose name does not, and
# the mode tests only on an output named mode. Anything else fails closed.
_HIT_NAMES = re.compile(r"(hit|skip|proven|green|found|cached)", re.I)
_MODE_NAMES = re.compile(r"mode", re.I)


def _gate_term_reads(prefix, names):
    names = sorted(names)
    if not names:
        return lambda term: False
    alt = "|".join(map(re.escape, names))
    neg = re.compile(r"\b%s\.(%s)\s*!=\s*['\"](true|none)['\"]" % (prefix, alt))
    mode = re.compile(r"\b%s\.(%s)\s*==\s*['\"](full|related)['\"]" % (prefix, alt))
    pos = re.compile(r"\b%s\.(%s)\s*==\s*['\"]true['\"]" % (prefix, alt))

    def reads(term):
        # A negated term (`!(...)`) flips whatever it holds; it is not read.
        if _unwrap(term).lstrip().startswith("!"):
            return False
        m = mode.search(term)
        if m:
            return bool(_MODE_NAMES.fullmatch(m.group(1)))
        m = neg.search(term)
        if m:
            if m.group(2) == "none":
                return bool(_MODE_NAMES.fullmatch(m.group(1)))
            return bool(_HIT_NAMES.search(m.group(1)))
        m = pos.search(term)
        return bool(m) and not _HIT_NAMES.search(m.group(1))
    return reads


def _reads_outputs_of(name, job, outputs):
    if name not in (_as_list(job.get("needs")) or []):
        return False
    reads = _gate_term_reads(r"needs\.%s\.outputs" % re.escape(name), outputs)
    return _holds_on("push", _if_text(job), reads)


# Setup-only actions: they prepare the tree (checkout a ref, install a
# toolchain, warm a cache) and do no work of their own. Named once; every
# other `uses:` step is read like a `run:` step.
_SETUP_ONLY_USES = re.compile(
    r"^(actions/checkout|actions/setup-[\w.-]+|actions/cache(/(save|restore))?"
    r"|pnpm/action-setup)@")


def _answers_to_lookup(job):
    """The lookup step ids when every step of the job is a setup-only action,
    a lookup step, or a later step gated at step level on the lookup
    (`if: steps.<id>.outputs.skip != 'true'`); otherwise None."""
    ids = _lookup_steps(job)
    if not ids:
        return None
    seen_lookup = False
    gate_names = {"skip", "relevant", "run", "mode", "hit"}
    for st in job.get("steps") or []:
        if not isinstance(st, dict):
            continue
        if str(st.get("id")) in ids:
            seen_lookup = True
            continue
        if _SETUP_ONLY_USES.match(str(st.get("uses", ""))):
            continue
        if not isinstance(st.get("run"), str) and not st.get("uses"):
            continue
        if not seen_lookup or not any(
                _holds_on("push", str(st.get("if", "")),
                          _gate_term_reads(r"steps\.%s\.outputs" % re.escape(sid), gate_names))
                for sid in ids):
            return None
    return ids


def _is_lookup_job(job):
    return (not _excludes_push(job) and _answers_to_lookup(job) is not None
            and bool(_lookup_outputs(job)))


def _self_gated(job):
    """One job that does the lookup and then gates every later step on it at
    step level, as `_answers_to_lookup` reads it, with at least one such
    gated step."""
    if _excludes_push(job) or _answers_to_lookup(job) is None:
        return False
    return any(isinstance(st, dict) and (isinstance(st.get("run"), str) or st.get("uses"))
               and str(st.get("id")) not in _lookup_steps(job)
               and not _SETUP_ONLY_USES.match(str(st.get("uses", "")))
               for st in job.get("steps") or [])


def _skip_is_wired(doc, earlier):
    """Clean only when every job a push can run is accounted for: a lookup job
    (its gate output taken from the lookup), a job gated on such an output in
    a read form, a job that gates its own steps on its own lookup, or a job
    that needs an accounted job and is skipped with it (or runs no suite past
    it, as a deploy does). Any other job a push can run is a second run."""
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        return False
    jobs = {str(k): v for k, v in jobs.items() if isinstance(v, dict)}
    lookups = {n: _lookup_outputs(j) for n, j in jobs.items() if _is_lookup_job(j)}
    # A self-gated job always runs (it skips only its own steps), so a job
    # that needs it is NOT skipped with it: it is accounted, but it does not
    # carry the skip to its dependents the way a job-level gate does.
    self_gated = {n for n, j in jobs.items() if _self_gated(j)}
    gated = set()
    for n, j in jobs.items():
        if n in lookups or _excludes_push(j):
            continue
        if any(_reads_outputs_of(l, j, outs) for l, outs in lookups.items()):
            gated.add(n)
    if not gated and not self_gated:
        return False
    accounted = gated | self_gated | set(lookups)
    changed = True
    while changed:
        changed = False
        for n, j in jobs.items():
            if n in accounted or _excludes_push(j):
                continue
            if not any(d in gated for d in (_as_list(j.get("needs")) or [])):
                continue
            # A job that overrides the skip with always()/failure()/cancelled()
            # runs even when the gated job was skipped. It counts only when it
            # runs on push alone and deploys (wrangler, deploy, publish) without
            # running a suite; anything else it might run fails closed.
            if re.search(r"\b(always|failure|cancelled)\(\)", _if_text(j)):
                deploys = any(re.search(r"\b(wrangler|deploy|publish)\b", str(st.get("run", "")) + str(st.get("uses", "")))
                              for st in j.get("steps") or [] if isinstance(st, dict))
                # An aggregator (every run step only reads the needs results, as a
                # required-check job like cs-ok does) runs no work of its own.
                runs = [str(st.get("run")) for st in j.get("steps") or []
                        if isinstance(st, dict) and st.get("run")]
                aggregates = bool(runs) and all(re.search(r"\bneeds\b", r) for r in runs) \
                    and not any(st.get("uses") for st in j.get("steps") or [] if isinstance(st, dict))
                push_deploy = all(_excludes(j, ev) for ev in earlier) and deploys
                if _runs_suite(j) or not (aggregates or push_deploy):
                    continue
            gated.add(n); accounted.add(n); changed = True
    return not [n for n, j in jobs.items() if n not in accounted and not _excludes_push(j)]


def classify(doc):
    """Return (verdict, events, rationale) for one parsed workflow."""
    on = normalize_on(doc)
    push_cfg_present = "push" in on
    push_branches = _push_branches(on.get("push")) if push_cfg_present else []
    branch_push = push_cfg_present and push_branches != []

    pr_scopes = []
    for ev in PR_EVENTS:
        if ev in on and _pr_runs_on_code(on.get(ev)):
            pr_scopes.append((ev, _pr_branches(on.get(ev))))
    has_queue = "merge_group" in on

    events = [e for e in ("pull_request", "pull_request_target", "merge_group", "push") if e in on]
    events_s = "+".join(events) if events else "(none)"

    if not branch_push:
        return "clean", events_s, "no branch push trigger"

    overlapping = [(ev, b) for ev, b in pr_scopes if _overlap(push_branches, b)]
    if not overlapping and not has_queue:
        if pr_scopes:
            return "clean", events_s, "push and pull_request branch scopes do not overlap"
        if any(ev in on for ev in PR_EVENTS):
            return "clean", events_s, "pull_request runs on no code change (its types); the push is the one run"
        return "clean", events_s, "push only; no earlier run of the same change"

    # The marker only proves a tree an earlier run built (the queue's, or the
    # pull request's on its merge ref), and both build only what lands on the
    # base branch: a push on any other branch checks out a tree no earlier run
    # named, so the exemption needs the push scoped to the base branch.
    push_base_only = push_branches is not None and bool(push_branches) and all(
        b in BASE_BRANCHES for b in push_branches)
    earlier = [ev for ev, _ in overlapping] + (["merge_group"] if has_queue else [])
    if push_base_only and _skip_is_wired(doc, earlier):
        return "clean", events_s, (
            "every job a push runs a second time is gated on a proven-tree lookup job's outputs")

    first = []
    if overlapping:
        first.extend(f"{ev} on {_scope(b)}" for ev, b in overlapping)
    if has_queue:
        first.append("merge_group")
    rationale = (
        f"push on {_scope(push_branches)} runs again after {' and '.join(first)} "
        "already ran this change, and nothing skips it; replace with pull_request "
        "(scoped) + merge_group (the one full run, publishing full-suite-<tree>) + "
        "push on the base branch with a lookup job (calls tree-already-green.sh or "
        "looks up the full-suite-<tree> artifact, declares outputs) whose outputs "
        "every other push-run job reads in its if:, or drop the push trigger"
    )
    return "double-trigger", events_s, rationale


def classify_file(path):
    """Return (verdict, events, rationale); raises ImportError without PyYAML."""
    import yaml  # noqa: PLC0415  (import here so --help works without it)

    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except Exception as exc:  # noqa: BLE001
        return "unreadable", "(unparsed)", f"could not parse: {type(exc).__name__}"
    if not isinstance(doc, dict):
        return "unreadable", "(unparsed)", "not a workflow mapping"
    return classify(doc)


def main(argv):
    slug = "(local)"
    show_all = False
    strict = False
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--slug":
            slug = argv[i + 1]
            i += 2
            continue
        if a == "--all":
            show_all = True
        elif a == "--strict":
            strict = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            files.append(a)
        i += 1

    try:
        import yaml  # noqa: F401,PLC0415
    except ImportError:
        print("multi_trigger_predicate: PyYAML is not importable; cannot read workflows", file=sys.stderr)
        return 3 if strict else 0

    bad = 0
    for fp in files:
        verdict, events, rationale = classify_file(fp)
        if verdict != "clean":
            bad += 1
        if verdict != "clean" or show_all:
            print(f"{slug}|{os.path.basename(fp)}|{verdict}|{events}|{rationale}")
    if strict and bad:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
