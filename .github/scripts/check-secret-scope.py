#!/usr/bin/env python3
"""Where the build secrets may appear, read from two policy files.

    check-secret-scope.py [--root DIR] [--containerfile FILE] [--workflows DIR]
                          [--stages FILE] [--jobs FILE]

The MOK private key signs the kernel every device trusts; the cosign key
signs every image. The second review (N1, 2026-10-20) found the MOK key
mounted on the RUN that also installs packages and runs downloaded
programs, and staged on the runner's disk while third-party actions ran.
This check turns the intended scope into data:

  tests/policy/secret-stages.txt   the Containerfile stages whose RUNs may
      mount a secret (--mount=type=secret), and the network those RUNs must
      declare (`none`: RUN --network=none). Every other RUN, and the final
      stage whatever its name, may mount none.
  tests/policy/secret-jobs.txt     the workflow jobs that may name
      secrets.MOK_* and secrets.COSIGN*, and which ones; an entry nobody
      uses is stale and fails too.

And, for every job that stages a MOK secret to disk (a step whose env:
maps one): that step is followed at once by the build step, then at once
by the wipe step (`if: always()`, rm -rf of the staged directory), with no
`uses:` among the three and no other step reading the directory. Secrets
are named in a step's env: only, never in run: text or with:.

Exit 0 when the tree matches the policy, 1 with the violations listed, 2
on a malformed policy file.
"""
import argparse
import glob
import os
import re
import shlex
import sys

import yaml

SECRET_RE = re.compile(r"secrets\.(MOK_[A-Za-z0-9_]*|COSIGN[A-Za-z0-9_]*)")
FINAL = "(final stage)"


class Policy(Exception):
    pass


def read_policy(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                s = line.split("#", 1)[0].strip()
                if s:
                    rows.append((n, s.split()))
    except OSError as e:
        raise Policy(f"{path}: {e}") from None
    return rows


# ---- Containerfile --------------------------------------------------------

def instructions(text):
    """(instruction, first word) with continuation lines joined and comment
    lines dropped, as buildah reads them."""
    out, buf = [], ""
    for raw in text.splitlines():
        if not buf and raw.lstrip().startswith("#"):
            continue
        if raw.rstrip().endswith("\\"):
            buf += raw.rstrip()[:-1] + " "
            continue
        buf += raw
        if buf.strip():
            out.append(buf.strip())
        buf = ""
    if buf.strip():
        out.append(buf.strip())
    return out


def stages_of(text):
    stages, cur = [], None
    for ins in instructions(text):
        word = ins.split(None, 1)[0].upper()
        if word == "FROM":
            parts = ins.split()
            name = parts[3] if len(parts) > 3 and parts[2].upper() == "AS" else ""
            cur = {"name": name, "from": parts[1], "runs": []}
            stages.append(cur)
        elif word == "RUN" and cur is not None:
            try:
                toks = shlex.split(ins)[1:]
            except ValueError:
                toks = ins.split()[1:]
            flags = []
            for t in toks:
                if t.startswith("--"):
                    flags.append(t)
                else:
                    break
            secrets = sorted(m.group(1) for f in flags if "type=secret" in f
                             for m in [re.search(r"(?:^|,)id=([^,]+)", f)] if m)
            cur["runs"].append({"secrets": secrets, "network_none": "--network=none" in flags, "text": ins})
    return stages


def check_containerfile(path, policy_path):
    problems = []
    allowed = {}
    for n, cols in read_policy(policy_path):
        if len(cols) != 2 or cols[1] not in ("none", "any"):
            raise Policy(f"{policy_path}:{n}: expected '<stage> none|any', got {' '.join(cols)}")
        allowed[cols[0]] = cols[1]
    with open(path, encoding="utf-8") as f:
        stages = stages_of(f.read())
    path = os.path.relpath(path)
    if not stages:
        return [f"{path}: no FROM instruction"]
    names = [s["name"] or FINAL for s in stages]
    last = stages[-1]
    for stage in stages:
        label = stage["name"] or FINAL
        is_last = stage is last
        for run in stage["runs"]:
            if not run["secrets"]:
                continue
            if is_last:
                problems.append(f"{path}: the final stage (FROM {stage['from']}) mounts secret(s) "
                                f"{', '.join(run['secrets'])}: the image that ships may never see a secret")
            elif label not in allowed:
                problems.append(f"{path}: stage {label} mounts secret(s) {', '.join(run['secrets'])} but "
                                f"{os.path.relpath(policy_path)} allows: {', '.join(allowed) or 'no stage'}")
            elif allowed[label] == "none" and not run["network_none"]:
                problems.append(f"{path}: stage {label} mounts secret(s) {', '.join(run['secrets'])} "
                                "without --network=none")
    for name in allowed:
        if name not in names:
            problems.append(f"{os.path.relpath(policy_path)} allows stage {name}, which {path} does not have")
        elif name == (last["name"] or FINAL):
            problems.append(f"{os.path.relpath(policy_path)} allows stage {name}, the final stage: "
                            "the image that ships may never see a secret")
    return problems


# ---- workflows --------------------------------------------------------------

def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield str(k)
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)


def secrets_in(node):
    return sorted({m.group(1) for s in strings(node) for m in SECRET_RE.finditer(s)})


def staged_dir(run):
    m = re.search(r"mkdir\s+(?:-p\s+)?(\S+)", run or "")
    return m.group(1) if m else None


def check_job_steps(wf_name, job_id, job):
    problems = []
    steps = job.get("steps") or []
    for i, step in enumerate(steps):
        found = secrets_in(step)
        if not found:
            continue
        where = step.get("name") or f"step {i + 1}"
        outside_env = secrets_in({k: v for k, v in step.items() if k != "env"})
        if outside_env:
            problems.append(f"{wf_name}: job {job_id}, step '{where}' names secrets.{', '.join(outside_env)} "
                            "outside env: (in run: text or with:): secrets go through env: only")
        if "uses" in step:
            problems.append(f"{wf_name}: job {job_id}, step '{where}' hands secrets.{', '.join(found)} to an action")
        if not any(s.startswith("MOK_") for s in secrets_in(step.get("env"))):
            continue
        # A MOK staging step: build next, wipe right after, nothing else near.
        d = staged_dir(step.get("run"))
        if not d:
            problems.append(f"{wf_name}: job {job_id}, step '{where}' takes the MOK secrets but does not "
                            "mkdir the directory it stages them in")
            continue
        build = steps[i + 1] if i + 1 < len(steps) else {}
        wipe = steps[i + 2] if i + 2 < len(steps) else {}
        run_b = build.get("run") or ""
        if "uses" in build or not re.search(r"\b(buildah|podman)\s+build\b", run_b) or f"src={d}/" not in run_b:
            problems.append(f"{wf_name}: job {job_id}: the step after '{where}' must be the build that reads "
                            f"{d} (got '{build.get('name', 'nothing')}')")
        run_w = wipe.get("run") or ""
        if "uses" in wipe or f"rm -rf {d}" not in run_w or str(wipe.get("if", "")).strip() != "always()":
            problems.append(f"{wf_name}: job {job_id}: the step after the build must wipe {d} "
                            f"(rm -rf, if: always()); got '{wipe.get('name', 'nothing')}'")
        for j, other in enumerate(steps):
            if j in (i, i + 1, i + 2):
                continue
            if any(d in s for s in strings(other)):
                problems.append(f"{wf_name}: job {job_id}, step '{other.get('name') or j + 1}' refers to "
                                f"{d}, which only the staging, build and wipe steps may")
    return problems


def check_workflows(directory, policy_path):
    problems = []
    allowed = {}
    for n, cols in read_policy(policy_path):
        if len(cols) < 3 or not cols[0].endswith((".yml", ".yaml")):
            raise Policy(f"{policy_path}:{n}: expected '<workflow.yml> <job> <secret>...', got {' '.join(cols)}")
        for s in cols[2:]:
            allowed.setdefault((cols[0], cols[1]), set()).add(s)
    used = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.yml")) + glob.glob(os.path.join(directory, "*.yaml"))):
        name = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            wf = yaml.safe_load(f) or {}
        top = {k: v for k, v in wf.items() if k != "jobs"}
        if secrets_in(top):
            problems.append(f"{name}: secrets.{', '.join(secrets_in(top))} named outside the jobs "
                            "(a workflow-level env reaches every job)")
        for job_id, job in (wf.get("jobs") or {}).items():
            found = secrets_in(job)
            if not found:
                continue
            used[(name, job_id)] = set(found)
            extra = set(found) - allowed.get((name, job_id), set())
            if extra:
                problems.append(f"{name}: job {job_id} names secrets.{', '.join(sorted(extra))}, not allowed by "
                                f"{os.path.relpath(policy_path)}")
            problems += check_job_steps(name, job_id, job)
    for (name, job_id), secrets in sorted(allowed.items()):
        stale = secrets - used.get((name, job_id), set())
        if stale:
            problems.append(f"{os.path.relpath(policy_path)}: {name} {job_id} may name "
                            f"{', '.join(sorted(stale))} but does not: remove the stale entry")
    return problems


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--containerfile")
    ap.add_argument("--workflows")
    ap.add_argument("--stages")
    ap.add_argument("--jobs")
    a = ap.parse_args(argv)
    containerfile = a.containerfile or os.path.join(a.root, "Containerfile")
    workflows = a.workflows or os.path.join(a.root, ".github", "workflows")
    stages = a.stages or os.path.join(a.root, "tests", "policy", "secret-stages.txt")
    jobs = a.jobs or os.path.join(a.root, "tests", "policy", "secret-jobs.txt")
    try:
        problems = check_containerfile(containerfile, stages) + check_workflows(workflows, jobs)
    except Policy as e:
        print(f"::error::{e}")
        return 2
    for p in problems:
        print(f"::error::{p}")
    if problems:
        print(f"secret scope: {len(problems)} problem(s)")
        return 1
    print("secret scope: the Containerfile and the workflows match tests/policy/secret-stages.txt "
          "and secret-jobs.txt")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
