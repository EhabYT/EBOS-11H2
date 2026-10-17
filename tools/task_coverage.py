"""Conservative coverage check for direct scheduled-task registrations.

This is not a PowerShell interpreter. It recognises literal names, simple constant
variables, -TaskPath, and line continuations in YAML command bodies and .ps1 files.
Comments and string contents are not commands. A recognised registration with a
computed/ambiguous name is an error, never silently counted as covered. Generated
scripts, aliases, splatting and runtime control flow still need a manual audit.
"""

import re
from collections import defaultdict

# Source-scoped exclusions, not a global allowlist of names. These describe a
# verification LIMIT, not proof that the task registered or completed successfully.
LIFECYCLE_EXCLUSIONS = {
    ("Configuration/Tasks/phase2-strip.yml", "\\ebosdefendercleanup"): (
        "disable-defender",
        "registered during apply; removes itself only when cleanup folders are gone, "
        "possibly after several logons; phase-8 presence cannot prove completion",
    ),
    ("Configuration/Tasks/phase2-strip.yml", "\\ebosdefenderrestartnotice"): (
        "disable-defender",
        "registered during apply; unregisters at its first logon execution, so a "
        "later verification cannot require permanent presence",
    ),
    ("Executables/nuke-defender-files.ps1", "\\ebosdefenderkeepdisabled"): (
        None,
        "registered by the deferred logon cleanup, not directly during apply",
    ),
}

# These registrations are deliberately conditional inside their script. The runtime
# verifier must use the pre-apply context, not the Installed stamp written in phase 7.
REGISTRATION_SCOPES = {
    ("Executables/setup-timerresolution.ps1", "\\ebos-timerresolution"): "fresh-install",
}

_TOKEN = re.compile(
    r"(?P<comment><\#.*?\#>|\#[^\n]*)"
    r"|(?P<here>@'\r?\n.*?\n'@|@\"\r?\n.*?\n\"@)"
    r"|(?P<string>'(?:[^']|'')*'|\"(?:`.|[^\"`])*\")"
    r"|(?P<continuation>[`^]\r?\n)"
    r"|(?P<space>[^\S\n]+)"
    r"|(?P<separator>[\n;|{}&()=,])"
    r"|(?P<word>[^\s'\";|{}&()=,]+)",
    re.S,
)
_BOUNDARIES = {"\n", ";", "|", "{", "}", "&", "(", "=", "."}


def tokens(text):
    """(kind, spelling, offset); keep strings whole and omit comments/continuations."""
    return [
        (m.lastgroup, m.group(), m.start()) for m in _TOKEN.finditer(text)
        if m.lastgroup not in {"comment", "space", "continuation"}
    ]


def literal(token):
    kind, word, _ = token
    if kind == "string" and word.startswith("'"):
        return word[1:-1].replace("''", "'")
    if kind == "string":
        # Interpolation/escapes need an interpreter. Refuse instead of guessing.
        return word[1:-1] if not any(c in word for c in "$`") else None
    if kind == "word" and not any(c in word for c in "$%@`"):
        return word
    return None


def task_path(name, folder=""):
    """Task Scheduler paths are case-insensitive; only the root slash is optional."""
    return ("\\" + "\\".join(p.strip("\\") for p in (folder, name) if p)).casefold()


def _constants(parts):
    values = defaultdict(set)
    for i in range(len(parts) - 2):
        if re.fullmatch(r"\$\w+", parts[i][1]) and parts[i + 1][1] == "=":
            value = literal(parts[i + 2])
            # A literal prefix of a computed expression is not a constant.
            if i + 3 < len(parts) and parts[i + 3][1] not in {"\n", ";", "}"}:
                value = None
            values[parts[i][1].casefold()].add(value)
    return {k: next(iter(v)) for k, v in values.items() if len(v) == 1 and None not in v}


def registrations(text):
    """Yield (normalised path or None, line). None is an unresolved registration."""
    parts = tokens(text)
    for i, token in enumerate(parts):
        command = literal(token)
        if not command or command.casefold() not in {
            "register-scheduledtask", "schtasks", "schtasks.exe"}:
            continue
        if i and parts[i - 1][1] not in _BOUNDARIES:
            continue
        if token[0] == "string" and (not i or parts[i - 1][1] not in {"&", "."}):
            continue
        end = i + 1
        while end < len(parts) and parts[end][1] not in {"\n", ";", "|", "}", "&"}:
            end += 1
        args = parts[i + 1:end]
        is_ps = command.casefold() == "register-scheduledtask"
        if not is_ps and not any(t[1].casefold() == "/create" for t in args):
            continue
        # Only preceding assignments count; a later assignment cannot resolve a name.
        constants = _constants(parts[:i])

        def parameter(flag, default=None):
            hits = [j for j, t in enumerate(args) if t[1].casefold() == flag]
            if not hits:
                return default
            if len(hits) != 1 or hits[0] + 1 == len(args):
                return None
            value = args[hits[0] + 1]
            if value[0] == "word" and value[1].startswith("$"):
                return constants.get(value[1].casefold())
            return literal(value)

        name = parameter("-taskname" if is_ps else "/tn")
        folder = parameter("-taskpath", "") if is_ps else ""
        resolved = task_path(name, folder) if name and folder is not None else None
        yield resolved, text.count("\n", 0, token[2]) + 1


def command_sources(node, gate=""):
    """Yield parsed YAML command/args strings and their inherited option gates."""
    if isinstance(node, dict):
        own_gate = node.get("option", "")
        if own_gate:
            gate = "+".join(filter(None, (gate, own_gate)))
        for key, value in node.items():
            if key in {"command", "args"} and isinstance(value, str):
                # !run can invoke schtasks as an executable rather than a command.
                exe = node.get("exe", "")
                if key == "args" and exe.casefold() in {"schtasks", "schtasks.exe"}:
                    value = exe + " " + value
                yield value, gate
            elif isinstance(value, (dict, list)):
                yield from command_sources(value, gate)
    elif isinstance(node, list):
        for child in node:
            yield from command_sources(child, gate)


def script_calls(text):
    """Direct local script invocations, enough to carry YAML option gates into .ps1."""
    parts = tokens(text)
    for i, token in enumerate(parts):
        name = literal(token)
        if not name or not name.casefold().endswith(".ps1"):
            continue
        previous = parts[i - 1][1].casefold() if i else "\n"
        if previous != "-file":
            if token[0] == "string" and previous not in {"&", "."}:
                continue
            if previous not in _BOUNDARIES:
                continue
        name = re.sub(r"/+", "/", name.replace("\\", "/"))
        if name.startswith("./"):
            name = name[2:]
        if ":" not in name and not name.startswith("/") and ".." not in name.split("/"):
            yield name.casefold()


def verify_rows(text):
    # Work on the task table only, never a commented-out row or an unrelated table.
    clean = _TOKEN.sub(lambda m: " " * len(m.group()) if m.lastgroup == "comment" else m.group(), text)
    match = re.search(r"(?ms)^\s*\$tasks\s*=\s*@\((.*?)^\s*\)", clean)
    if not match:
        return []
    rows = []
    for row in re.findall(r"@\{([^{}]*)\}", match.group(1)):
        fields = {
            key.casefold(): value.replace("''", "'")
            for key, value in re.findall(r"(\w+)\s*=\s*'((?:[^']|'')*)'", row)
        }
        if fields.get("t"):
            fields["t"] = task_path(fields["t"])
            fields.setdefault("op", "disable")
            fields.setdefault("g", "")
            fields.setdefault("scope", "")
            rows.append(fields)
    return rows


def check(report, root, docs):
    verify = root / "Executables" / "ebos-verify.ps1"
    if not verify.is_file():
        report.error("scheduled-task coverage: Executables/ebos-verify.ps1 is missing")
        return
    rows = verify_rows(verify.read_text(encoding="utf-8"))
    if not rows:
        report.error("scheduled-task coverage: no literal rows found in the $tasks table")
        return

    sources = []
    calls = defaultdict(set)
    for path, doc in sorted(docs.items()):
        for text, gate in command_sources(doc):
            sources.append((path.relative_to(root).as_posix(), text, gate))
            for script in script_calls(text):
                calls[script].add(gate)
    for path in sorted((root / "Executables").rglob("*.ps1")):
        if path == verify:
            continue
        name = path.relative_to(root / "Executables").as_posix().casefold()
        for gate in sorted(calls[name]) if calls[name] else [None]:
            sources.append((path.relative_to(root).as_posix(), path.read_text(encoding="utf-8"), gate))

    registered, covered, excluded = set(), set(), set()
    for where, text, gate in sources:
        for name, line in registrations(text):
            if name is None:
                report.error("%s command line %d: cannot resolve scheduled-task registration; "
                             "use a literal name/path or a single constant assignment" % (where, line))
                continue
            registered.add(name)
            exclusion = LIFECYCLE_EXCLUSIONS.get((where, name))
            if exclusion and gate == exclusion[0]:
                excluded.add(name)
                continue
            if gate is None:
                report.warn("task '%s' in %s: no direct YAML caller found; review its runtime gate manually" % (name, where))
            matching = [r for r in rows if r["t"] == name and (gate is None or r["g"] == gate)]
            scope = REGISTRATION_SCOPES.get((where, name), "")
            if len(matching) != 1 or matching[0]["op"] != "create" or matching[0]["scope"] != scope:
                report.error("task '%s' registered in %s (gate=%r) needs exactly one "
                             "op='create' verify row with matching gate and scope=%r" % (name, where, gate, scope))
            else:
                covered.add(name)

    for row in rows:
        if row["op"] == "create" and row["t"] not in registered:
            report.error("create verify row '%s' has no direct registration in the scanned sources" % row["t"])

    report.note("%d registered task names: %d with create assertions, %d lifecycle exclusions "
                "(static coverage, not a runtime test)" % (len(registered), len(covered), len(excluded)))
