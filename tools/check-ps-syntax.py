#!/usr/bin/env python3
"""Brace / bracket / quote balance check for PowerShell that lives inside this playbook.

YAML only sees the command as an opaque string, so a missing brace or an unterminated
string inside a `command: |` block survives every YAML validator and only fails on a real
Windows image - the action either dies silently (errorAction: Ignore) or the phase fails.

The checker walks the string with a small state machine: single-quoted strings ('' escape),
double-quoted strings (backtick escape), here-strings, and # comments are skipped, then the
remaining braces, parens and brackets are counted.

Usage, from the repo root:
    python3 tools/check-ps-syntax.py            # everything
    python3 tools/check-ps-syntax.py --quiet    # only failures

Exit code 0 when everything balances, 1 otherwise.
"""

import glob
import sys

import yaml


class PlaybookLoader(yaml.SafeLoader):
    pass


def _any_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.MappingNode):
        return loader.construct_mapping(node, deep=True)
    if isinstance(node, yaml.ScalarNode):
        return loader.construct_scalar(node)
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return None


PlaybookLoader.add_multi_constructor("!", _any_tag)

PAIRS = {"{": "}", "(": ")", "[": "]"}
CLOSERS = {"}": "{", ")": "(", "]": "["}


def scan(text):
    """Return (issues, stats) for one PowerShell snippet.

    issues: list of (line_number, message)
    """
    issues = []
    stack = []  # (opener, line)
    i = 0
    n = len(text)
    line = 1

    while i < n:
        c = text[i]

        if c == "\n":
            line += 1
            i += 1
            continue

        # --- comments ---------------------------------------------------
        # Block comments first: <# ... #> can contain apostrophes and braces that are
        # prose, not code. Missing this made the checker report every .ps1 that has a
        # doc-block with a contraction in it.
        if c == "<" and i + 1 < n and text[i + 1] == "#":
            end = text.find("#>", i + 2)
            if end == -1:
                issues.append((line, "unterminated block comment <#"))
                return issues, len(stack)
            line += text.count("\n", i, end)
            i = end + 2
            continue

        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue

        # --- here-strings ----------------------------------------------
        if c == "@" and i + 1 < n and text[i + 1] in "'\"":
            quote = text[i + 1]
            rest = text[i + 2:i + 3]
            # A here-string opener must be the last thing on the line.
            if rest in ("\n", "\r", ""):
                end = text.find("\n" + quote + "@", i + 2)
                if end == -1:
                    issues.append((line, "unterminated here-string @%s" % quote))
                    return issues, len(stack)
                line += text.count("\n", i, end)
                i = end + 3
                continue

        # --- single-quoted ---------------------------------------------
        if c == "'":
            i += 1
            closed = False
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    closed = True
                    break
                if text[i] == "\n":
                    line += 1
                i += 1
            if not closed:
                issues.append((line, "unterminated single-quoted string"))
            continue

        # --- double-quoted ---------------------------------------------
        if c == '"':
            start_line = line
            i += 1
            closed = False
            while i < n:
                ch = text[i]
                if ch == "`":
                    if i + 1 < n and text[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if ch == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        i += 2
                        continue
                    i += 1
                    closed = True
                    break
                if ch == "\n":
                    line += 1
                i += 1
            if not closed:
                issues.append((start_line, "unterminated double-quoted string"))
            continue

        # --- brackets ---------------------------------------------------
        if c in PAIRS:
            stack.append((c, line))
            i += 1
            continue

        if c in CLOSERS:
            if not stack:
                issues.append((line, "unexpected closing '%s'" % c))
            else:
                opener, opened_at = stack.pop()
                if opener != CLOSERS[c]:
                    issues.append(
                        (line, "'%s' closes '%s' opened on line %d" % (c, opener, opened_at))
                    )
            i += 1
            continue

        i += 1

    for opener, opened_at in stack:
        issues.append((opened_at, "unclosed '%s'" % opener))

    return issues, len(stack)


def walk(node, path, out):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in ("command", "args") and isinstance(value, str):
                out.append((path + "/" + str(key), value))
            else:
                walk(value, path, out)
    elif isinstance(node, list):
        for item in node:
            walk(item, path, out)


def main():
    quiet = "--quiet" in sys.argv
    targets = []  # (label, text)

    for yml in sorted(glob.glob("Configuration/**/*.yml", recursive=True)):
        with open(yml, encoding="utf-8") as fh:
            doc = yaml.load(fh, Loader=PlaybookLoader)
        found = []
        walk(doc, "", found)
        for idx, (key, text) in enumerate(found):
            targets.append(("%s [%s #%d]" % (yml, key, idx + 1), text))

    for ps1 in sorted(glob.glob("Executables/*.ps1")):
        with open(ps1, encoding="utf-8") as fh:
            targets.append((ps1, fh.read()))

    failures = 0
    for label, text in targets:
        issues, _ = scan(text)
        if issues:
            failures += 1
            print("FAIL %s" % label)
            for line, message in issues[:6]:
                print("       line %-5d %s" % (line, message))
        elif not quiet:
            print("ok   %s" % label)

    print()
    print("%d snippet(s) checked, %d with issues" % (len(targets), failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
