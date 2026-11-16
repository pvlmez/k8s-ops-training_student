#!/usr/bin/env python3
"""Run the commands in the lab guides against a cluster and report which fail.

    infra/scripts/lab-smoke-test.py                 # all labs
    infra/scripts/lab-smoke-test.py 2 3             # only these labs: any lab numbers, e.g. 4 5 6
    infra/scripts/lab-smoke-test.py --list          # show what would run, run nothing
    infra/scripts/lab-smoke-test.py --disruptive 2  # also run blocks marked disruptive

It catches commands that broke after a version bump or an edit. It does not
judge wording, timing or whether the output teaches anything: a person still
has to walk each lab once.

What it runs: every line that starts with "$ " or "nodeN$ " inside a fenced
code block of labs/lab-NN-*.md. "$" lines run on this machine, "nodeN$" lines
run over "ssh nodeN" (set up with infra/scripts/lab-info.sh --ssh-config).
The "$" lines of one lab share a shell, so variables and "cd" carry over.

What it skips:
  - sections whose heading contains a star (Build, Stretch): Build parts are
    exercised by deploy.sh and the playbooks, and by the bare-cluster dry run
  - a block preceded by  <!-- smoke: skip (reason) -->
  - a block preceded by  <!-- smoke: disruptive -->  unless --disruptive is given
  - lines with a <placeholder>, and a bare "ssh nodeN" (opening a session)

Run it from a workstation that can reach the cluster. It changes the cluster
only as far as the labs themselves do.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The labs say cd "$K8S_COURSE_HOME" (set in ~/.bashrc by install-tools.sh, which a
# non-interactive bash does not read): always test the checkout this script is in.
os.environ["K8S_COURSE_HOME"] = REPO
PROMPT = re.compile(r"^(?:(node\d+))?\$ (.*)$")
MARKER = re.compile(r"<!--\s*smoke:\s*(skip|disruptive)\b[^>]*-->")
PLACEHOLDER = re.compile(r"<[a-z][a-z0-9]*(?:-[a-z0-9]+)*>")
BARE_SSH = re.compile(r"^ssh\s+\S+\s*$")
TIMEOUT = 300  # seconds per command

GREEN, RED, GREY, BLUE, OFF = "\033[1;32m", "\033[1;31m", "\033[0;37m", "\033[1;34m", "\033[0m"


def parse(path):
    """Yield dicts: line number, where (None or 'node1'), command, skip reason or None."""
    in_fence = False
    starred = False       # inside a "★" section
    star_level = 0
    marker = None         # applies to the next fenced block
    block_marker = None
    pending = None        # command being continued with a trailing backslash
    with open(path, encoding="utf-8") as fh:
        for number, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if line.startswith("```"):
                in_fence = not in_fence
                if in_fence:
                    block_marker, marker = marker, None
                else:
                    pending = None
                continue
            if not in_fence:
                heading = re.match(r"^(#+)\s+(.*)$", line)
                if heading:
                    level = len(heading.group(1))
                    if "★" in heading.group(2):
                        starred, star_level = True, level
                    elif starred and level <= star_level:
                        starred = False
                found = MARKER.search(line)
                if found:
                    marker = found.group(1)
                continue
            if pending is not None:
                pending["command"] += "\n" + line
                if not line.endswith("\\"):
                    pending = None
                continue
            match = PROMPT.match(line)
            if not match:
                continue          # expected output, or the body of a here-document
            where, command = match.group(1), match.group(2)
            if starred:
                reason = "optional (★) section"
            elif block_marker == "skip":
                reason = "marked skip"
            elif block_marker == "disruptive":
                reason = "disruptive"
            elif PLACEHOLDER.search(command):
                reason = "has a <placeholder>"
            elif where is None and BARE_SSH.match(command):
                reason = "opens a session"
            elif command.strip() in ("exit", "logout"):
                reason = "closes a session"
            else:
                reason = None
            item = {"line": number, "where": where, "command": command, "skip": reason}
            if command.endswith("\\"):
                pending = item
            yield item


def run_lab(path, items, disruptive):
    """Run one lab's commands. Local commands share one bash process."""
    todo = [i for i in items if i["skip"] is None or (disruptive and i["skip"] == "disruptive")]
    failed = 0
    if not todo:
        return 0, 0
    workdir = tempfile.mkdtemp(prefix="lab-smoke-")
    script = ["cd %s" % shell_quote(REPO)]
    for index, item in enumerate(todo):
        log = os.path.join(workdir, "%d.log" % index)
        body = os.path.join(workdir, "%d.cmd" % index)
        with open(body, "w", encoding="utf-8") as fh:
            fh.write(item["command"] + "\n")
        if item["where"]:
            run = "timeout %d ssh -o BatchMode=yes -o ConnectTimeout=10 %s bash -s < %s" % (
                TIMEOUT, item["where"], shell_quote(body))
        else:
            # "source" keeps variables and the working directory for later commands
            run = "source %s </dev/null" % shell_quote(body)
        script.append("echo '::start %d'" % index)
        script.append("{ %s ; } > %s 2>&1" % (run, shell_quote(log)))
        script.append("echo \"::end %d $?\"" % index)
    proc = subprocess.Popen(["bash", "-c", "\n".join(script)], stdout=subprocess.PIPE, text=True)
    for out in proc.stdout:
        found = re.match(r"::end (\d+) (\d+)", out)
        if not found:
            continue
        index, code = int(found.group(1)), int(found.group(2))
        item = todo[index]
        label = "%s:%d  %s%s" % (os.path.basename(path), item["line"],
                                 (item["where"] + "$ ") if item["where"] else "$ ",
                                 item["command"].splitlines()[0])
        if code == 0:
            print("%s  ✔ %s%s" % (GREEN, label, OFF))
        else:
            failed += 1
            print("%s  ✘ %s  (exit %d)%s" % (RED, label, code, OFF))
            with open(os.path.join(workdir, "%d.log" % index), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
            # Lines that report a failure themselves (verify.sh marks them with ✘)
            # may be far above the end of the output: show them first.
            marked = [text for text in lines[:-12] if "✘" in text]
            for text in marked + lines[-12:]:
                print("      " + text)
    proc.wait()
    return len(todo), failed


def shell_quote(text):
    return "'" + text.replace("'", "'\"'\"'") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("labs", nargs="*", type=int, help="lab numbers to run, e.g. 4 5 6 (default: all labs)")
    parser.add_argument("--list", action="store_true", help="show what would run and what is skipped")
    parser.add_argument("--disruptive", action="store_true", help="also run blocks marked disruptive")
    args = parser.parse_args()

    paths = sorted(glob.glob(os.path.join(REPO, "labs", "lab-[0-9][0-9]-*.md")))
    if args.labs:
        paths = [p for p in paths if int(os.path.basename(p)[4:6]) in args.labs]
    if not paths:
        sys.exit("no lab guides found")

    total = bad = 0
    for path in paths:
        items = list(parse(path))
        print("\n%s==> %s%s" % (BLUE, os.path.basename(path), OFF))
        if args.list:
            for item in items:
                prompt = (item["where"] + "$ ") if item["where"] else "$ "
                first = item["command"].splitlines()[0]
                runs = item["skip"] is None or (args.disruptive and item["skip"] == "disruptive")
                if runs:
                    print("  run   %4d  %s%s" % (item["line"], prompt, first))
                else:
                    print("%s  skip  %4d  %s%s   [%s]%s" % (GREY, item["line"], prompt, first, item["skip"], OFF))
            continue
        ran, failed = run_lab(path, items, args.disruptive)
        skipped = len(items) - ran
        print("  %d run, %d failed, %d skipped" % (ran, failed, skipped))
        total += ran
        bad += failed
    if not args.list:
        print("\nResult: %s%d passed%s, %s%d failed%s" % (GREEN, total - bad, OFF, RED, bad, OFF))
        sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
