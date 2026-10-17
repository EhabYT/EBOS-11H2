#!/usr/bin/env python3
"""Build the EBOS playbook into a distributable .apbx.

An .apbx is a 7-Zip archive whose payload sits at the archive root (playbook.conf
first, not nested under a folder), encrypted with the AME Wizard convention:
AES-256, headers encrypted, password "malte". The wizard decrypts on load; the
password is not a secret, it exists to keep browsers and antivirus from scanning
the bundled executables.

The build performs static preflight checks before packaging. These catch known
configuration mistakes; they do not prove successful execution on Windows:

  * playbook.conf parses and carries every required element
  * SupportedBuilds matches the enforcement gate in phase1-prepare.yml
  * every YAML file parses, every !task target exists, no orphan task file
  * every option used by an action is declared in playbook.conf (a typo would
    silently never run), and every declared option is used somewhere
  * every PowerShell snippet balances (delegates to check-ps-syntax.py)
  * recognised literal script/asset references resolve to files on disk
  * direct scheduled-task registrations have matching create assertions (or documented
    lifecycle exclusions); unresolved task names fail the check
  * nothing is zero bytes

The VC++/Brave installers and Windhawk CLI/cache are external build inputs.
Their absence is a warning unless you pass
--require-bundles. Runtime installation and offline readiness also require the
Windows bundle check and a VM test; static preflight alone cannot guarantee them.

Usage:
    python3 tools/build-playbook.py                 # validate + build
    python3 tools/build-playbook.py --dry-run       # validate only
    python3 tools/build-playbook.py --require-bundles
"""

import argparse
import hashlib
import importlib.util
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent

# Exactly what goes into the archive. Anything else in the repo is development
# material (.git, tools/, README) and would only bloat the download.
ROOT_FILES = ["playbook.conf", "playbook.png", "LICENSE.txt", "BUILD-INFO.txt"]
ROOT_REQUIRED = ["playbook.conf"]
PAYLOAD_DIRS = ["Configuration", "Executables", "Images"]

EXCLUDE_DIR_NAMES = {"__pycache__", ".git", "node_modules", ".idea", ".vscode"}
EXCLUDE_SUFFIXES = {".pyc", ".pyo", ".apbx", ".7z"}
EXCLUDE_FILE_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini"}

BUNDLES = [
    ("vc_redist.x64.exe", "Visual C++ runtime (phase 1)"),
    ("BraveSetup.exe", "Brave installer (phase 1)"),
]

# Assets the repo deliberately does not commit. check_assets must not call them
# missing - the bundle section below decides whether absence is a warning or,
# with --require-bundles, a hard error.
BUNDLE_NAMES = {
    "vc_redist.x64.exe", "bravesetup.exe", "brave-setup.exe", "windhawk_setup.exe",
}

REQUIRED_CONF_TAGS = [
    "Name", "Username", "Title", "ShortDescription", "Description",
    "Details", "Version", "UniqueId",
]


# --------------------------------------------------------------------------- #
# YAML with the AME action tags
# --------------------------------------------------------------------------- #

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


def walk(node, fn):
    fn(node)
    if isinstance(node, dict):
        for value in node.values():
            walk(value, fn)
    elif isinstance(node, list):
        for item in node:
            walk(item, fn)


# --------------------------------------------------------------------------- #
# Checks
# --------------------------------------------------------------------------- #

class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []
        self.notes = []

    def error(self, message):
        self.errors.append(message)

    def warn(self, message):
        self.warnings.append(message)

    def note(self, message):
        self.notes.append(message)


def check_conf(report):
    path = ROOT / "playbook.conf"
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        report.error("playbook.conf is not valid XML: %s" % exc)
        return None

    root = tree.getroot()
    for tag in REQUIRED_CONF_TAGS:
        value = (root.findtext(tag) or "").strip()
        if not value:
            report.error("playbook.conf: <%s> is missing or empty" % tag)

    version = (root.findtext("Version") or "").strip()
    if version and not re.fullmatch(r"\d+(\.\d+){0,2}", version):
        report.error("playbook.conf: Version '%s' is not 1 / 0.1 / 0.0.1" % version)

    uid = (root.findtext("UniqueId") or "").strip()
    if uid and not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", uid
    ):
        report.error("playbook.conf: UniqueId '%s' is not a UUID" % uid)

    # The wizard offers the playbook on these builds; phase1 refuses anything else.
    # If the two lists drift, a user gets a "supported" label and then a hard stop.
    declared = sorted(int(x.text) for x in root.findall("./SupportedBuilds/string") if x.text)
    gate = None
    phase1 = ROOT / "Configuration" / "Tasks" / "phase1-prepare.yml"
    if phase1.exists():
        match = re.search(r"\$supported\s*=\s*@\(([^)]*)\)", phase1.read_text(encoding="utf-8"))
        if match:
            gate = sorted(int(x) for x in re.findall(r"\d{5}", match.group(1)))
    if declared and gate and declared != gate:
        report.error(
            "build list mismatch: playbook.conf %s vs phase1 gate %s" % (declared, gate)
        )
    elif declared and gate:
        report.note("SupportedBuilds matches the phase1 gate: %s" % ", ".join(map(str, declared)))

    options = []
    for parent in root.iter():
        if parent.tag.endswith("Options"):
            for child in parent:
                name = (child.findtext("Name") or "").strip()
                if name:
                    options.append(name)
    report.note("%d declared options" % len(options))

    # Image-backed radio pages need Images/<FileName>.png on disk.
    for element in root.iter():
        file_name = (element.findtext("FileName") or "").strip()
        if file_name and not (ROOT / "Images" / (file_name + ".png")).exists():
            report.error("playbook.conf: Images/%s.png missing for option" % file_name)

    return {"root": root, "version": version, "options": options}


def check_yaml(report, declared_options):
    docs = {}
    for path in sorted((ROOT / "Configuration").rglob("*.yml")):
        try:
            docs[path] = yaml.load(path.read_text(encoding="utf-8"), Loader=PlaybookLoader)
        except yaml.YAMLError as exc:
            report.error("%s does not parse: %s" % (path.relative_to(ROOT), exc))

    main = ROOT / "Configuration" / "main.yml"
    if not main.exists():
        report.error("Configuration/main.yml is missing")
        return docs

    referenced = {
        node["path"].replace("\\", "/") for node in _find_task_refs(docs.get(main))
    }
    for ref in sorted(referenced):
        if not (ROOT / "Configuration" / ref).exists():
            report.error("main.yml references a missing task: %s" % ref)

    on_disk = {
        str(p.relative_to(ROOT / "Configuration")).replace("\\", "/")
        for p in (ROOT / "Configuration" / "Tasks").glob("*.yml")
    }
    for orphan in sorted(on_disk - referenced):
        report.warn("task file never referenced from main.yml: %s" % orphan)

    used = set()
    for doc in docs.values():
        def collect(node):
            if isinstance(node, dict) and isinstance(node.get("option"), str):
                used.add(node["option"].lstrip("!"))
        walk(doc, collect)

    if declared_options:
        unknown = sorted(used - set(declared_options))
        for name in unknown:
            report.error("action uses option '%s' which playbook.conf does not declare" % name)
        unused = sorted(set(declared_options) - used)
        for name in unused:
            report.warn("option '%s' is declared but no action is gated on it" % name)
        report.note("%d distinct options used by actions" % len(used))

    report.note("%d task files, %d referenced from main.yml" % (len(on_disk), len(referenced)))
    return docs


def _find_task_refs(node):
    refs = []

    def collect(item):
        if isinstance(item, dict) and isinstance(item.get("path"), str):
            refs.append(item)

    walk(node, collect)
    return refs


def check_powershell(report, docs):
    spec = importlib.util.spec_from_file_location(
        "check_ps_syntax", ROOT / "tools" / "check-ps-syntax.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    snippets = 0
    broken = 0

    for path, doc in docs.items():
        found = []

        def collect(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key in ("command", "args") and isinstance(value, str):
                        found.append(value)

        walk(doc, collect)
        for index, text in enumerate(found):
            snippets += 1
            issues, _ = module.scan(text)
            if issues:
                broken += 1
                line, message = issues[0]
                report.error(
                    "%s snippet #%d line %d: %s"
                    % (path.relative_to(ROOT), index + 1, line, message)
                )

    for path in sorted((ROOT / "Executables").glob("*.ps1")):
        snippets += 1
        issues, _ = module.scan(path.read_text(encoding="utf-8"))
        if issues:
            broken += 1
            line, message = issues[0]
            report.error("%s line %d: %s" % (path.relative_to(ROOT), line, message))

    report.note("%d PowerShell snippets, %d unbalanced" % (snippets, broken))


def check_tasks(report, docs):
    spec = importlib.util.spec_from_file_location(
        "task_coverage", Path(__file__).with_name("task_coverage.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.check(report, ROOT, docs)


def check_assets(report, docs):
    names = set()

    for path, doc in docs.items():
        text = path.read_text(encoding="utf-8")
        for match in re.findall(r"Join-Path\s+\$PWD\s+'([^']+)'", text):
            names.add(match.replace("\\\\", "\\").split("\\")[-1].split("/")[-1])

        def collect(node):
            if isinstance(node, dict) and isinstance(node.get("args"), str):
                for target in re.findall(r"-File\s+(\S+)", node["args"]):
                    names.add(
                        target.replace("\\\\", "\\").replace("\\", "/").split("/")[-1]
                    )

        walk(doc, collect)

    missing = []
    for name in sorted(names):
        if not name or name.lower() in BUNDLE_NAMES:
            continue
        if re.fullmatch(r"windhawk-cli-.*-installer\.exe", name.lower()):
            continue
        if not list((ROOT / "Executables").rglob(name)):
            missing.append(name)

    for name in missing:
        report.error("action refers to Executables/%s which does not exist" % name)
    report.note("%d distinct files referenced from Executables/" % len(names))

    for name, purpose in BUNDLES:
        candidates = [name, "brave-setup.exe"] if name == "BraveSetup.exe" else [name]
        if not any((ROOT / "Executables" / candidate).is_file() for candidate in candidates):
            report.warn("bundle asset missing: %s (%s)" % (name, purpose))
    cache = ROOT / "Executables" / "windhawk-cache"
    if not cache.is_dir():
        report.warn("bundle asset missing: Executables/windhawk-cache/ (phase 7b offline)")
    else:
        # Match the Windows bundle checker: an empty folder is not an offline cache.
        required = {"windows-11-taskbar-styler", "windows-11-file-explorer-styler"}
        mod_names = required | {p.name for p in cache.iterdir() if p.is_dir()}
        for name in sorted(mod_names):
            folder = cache / name
            if not folder.is_dir():
                report.warn("bundle asset missing: windhawk-cache/%s/ (required mod)" % name)
            elif not any(p.is_file() and p.suffix.lower() == ".dll" and p.stat().st_size
                         for p in folder.iterdir()):
                report.warn("bundle asset missing: precompiled DLL in windhawk-cache/%s/" % name)
    # The GUI engine is NOT the CLI installer: phase 7b needs whcli.exe even when
    # phase 7 already installed windhawk_setup.exe. Mirror Find-BundledInstaller.
    have_cli = any(p.is_file() for p in (ROOT / "Executables").glob("windhawk-cli*-installer.exe"))
    if not have_cli:
        report.warn("bundle asset missing: windhawk-cli*-installer.exe (phase 7b offline; GUI is not a substitute)")
    if not (ROOT / "Executables" / "windhawk_setup.exe").is_file():
        report.warn("bundle asset missing: windhawk_setup.exe (phase 7 GUI)")


def collect_files(report):
    files = []
    for name in ROOT_FILES:
        path = ROOT / name
        if path.is_file():
            files.append(path)
        elif name in ROOT_REQUIRED:
            report.error("required file missing: %s" % name)

    for directory in PAYLOAD_DIRS:
        base = ROOT / directory
        if not base.is_dir():
            if directory in ("Configuration", "Executables"):
                report.error("required directory missing: %s/" % directory)
            continue
        for path in sorted(base.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(ROOT)
            if any(part in EXCLUDE_DIR_NAMES for part in rel.parts):
                continue
            if path.suffix.lower() in EXCLUDE_SUFFIXES:
                continue
            if path.name in EXCLUDE_FILE_NAMES:
                continue
            files.append(path)

    for path in files:
        if path.stat().st_size == 0:
            report.error("zero-byte file would ship: %s" % path.relative_to(ROOT))

    return files


# --------------------------------------------------------------------------- #
# Packaging
# --------------------------------------------------------------------------- #

PASSWORD = "malte"


def build(files, destination):
    import py7zr

    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        destination.unlink()

    filters = [{"id": py7zr.FILTER_LZMA2, "preset": 1}]
    with py7zr.SevenZipFile(
        destination, "w", password=PASSWORD, header_encryption=True, filters=filters
    ) as archive:
        for path in files:
            archive.write(path, arcname=str(path.relative_to(ROOT)).replace("\\", "/"))

    return destination


def verify_archive(destination):
    import py7zr

    with py7zr.SevenZipFile(destination, "r", password=PASSWORD) as archive:
        names = archive.getnames()

    problems = []
    if "playbook.conf" not in names:
        problems.append("playbook.conf is not at the archive root")
    if any(name.startswith("./") or name.startswith("/") for name in names):
        problems.append("archive contains absolute or ./ prefixed paths")
    if not any(name.startswith("Configuration/") for name in names):
        problems.append("Configuration/ missing from the archive")

    digest = hashlib.sha256()
    with open(destination, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)

    return names, problems, digest.hexdigest()


def write_build_report(destination, version, names, digest, report):
    """Regenerate the small sidecars; release/ is disposable and gitignored."""
    source = "not available (no Git metadata)"
    try:
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT, text=True, stderr=subprocess.DEVNULL
        ).strip()
        source = revision + (" (working tree modified)" if dirty else " (clean working tree)")
    except (OSError, subprocess.CalledProcessError):
        pass
    lines = [
        "# EBOS %s - build report" % version,
        "",
        "- Built at: %s" % datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "- Source: `%s`" % source,
        "- Artifact: `%s`" % destination.name,
        "- Size: %s bytes" % format(destination.stat().st_size, ","),
        "- Entries: %d" % len(names),
        "- SHA-256: `%s`" % digest,
        '- Format: 7z / LZMA2 / AES-256 / encrypted headers / password `malte`',
        "",
        "## Static preflight",
        "",
    ]
    lines.extend("- " + note for note in report.notes)
    lines.extend(["", "## Build warnings", ""])
    lines.extend("- " + warning for warning in report.warnings)
    if not report.warnings:
        lines.append("- None.")
    lines.extend([
        "", "## Validation limits", "",
        "The builder reads archive entry names and calculates its checksum. Run an independent",
        "`7z t -pmalte` and extract/compare the payload before distribution. Static preflight",
        "does not execute the playbook, validate a Windows logon, or prove offline readiness.",
        "Run the regression suite separately; PowerShell cases need pwsh/Windows PowerShell.",
        "", "Encryption uses random data, so compare extracted files, not hashes of separate builds.",
        "",
    ])
    (destination.parent / "BUILD-REPORT.md").write_text("\n".join(lines), encoding="utf-8")
    (destination.parent / "SHA256SUMS.txt").write_text(
        "%s  %s\n" % (digest, destination.name), encoding="utf-8"
    )
    notes_template = ROOT / "docs" / "releases" / (version + ".md")
    if notes_template.is_file():
        artifact = ("\n## Artifact for this build\n\n- File: `%s`\n- Size: %s bytes\n"
                    "- SHA-256: `%s`\n- Source: `%s`\n" % (
                        destination.name, format(destination.stat().st_size, ","), digest, source))
        (destination.parent / ("RELEASE-NOTES-%s.md" % version)).write_text(
            notes_template.read_text(encoding="utf-8") + artifact, encoding="utf-8"
        )


# --------------------------------------------------------------------------- #

def main():
    parser = argparse.ArgumentParser(description="Build the EBOS .apbx")
    parser.add_argument("--out", default="release", help="output directory (default: release)")
    parser.add_argument("--dry-run", action="store_true", help="validate only")
    parser.add_argument(
        "--require-bundles",
        action="store_true",
        help="fail when a bundled binary is absent (use for offline releases)",
    )
    args = parser.parse_args()

    report = Report()
    conf = check_conf(report)
    docs = check_yaml(report, conf["options"] if conf else [])
    check_powershell(report, docs)
    check_assets(report, docs)
    check_tasks(report, docs)
    files = collect_files(report)

    if args.require_bundles:
        for warning in [w for w in report.warnings if w.startswith("bundle asset missing")]:
            report.error(warning.replace("bundle asset missing", "required bundle missing"))
        report.warnings = [w for w in report.warnings if not w.startswith("bundle asset missing")]

    for note in report.notes:
        print("  ok    %s" % note)
    for warning in report.warnings:
        print("  warn  %s" % warning)
    for error in report.errors:
        print("  FAIL  %s" % error)

    print()
    print("%d file(s) staged, %d error(s), %d warning(s)"
          % (len(files), len(report.errors), len(report.warnings)))

    if report.errors:
        print("\nBuild aborted - fix the errors above.")
        return 1
    if args.dry_run:
        print("Dry run: nothing written.")
        return 0

    version = conf["version"] if conf else "unknown"
    destination = Path(args.out) / ("EBOS-v%s.apbx" % version)
    if not destination.is_absolute():
        destination = ROOT / destination

    print("\nPacking %d files as %s ..." % (len(files), destination.name))
    build(files, destination)

    names, problems, digest = verify_archive(destination)
    size = destination.stat().st_size
    print("  entries  %d" % len(names))
    print("  size     %.1f MiB" % (size / (1024 * 1024)))
    print("  sha256   %s" % digest)
    for problem in problems:
        print("  FAIL     %s" % problem)
    if problems:
        return 1

    write_build_report(destination, version, names, digest, report)
    print("\nBuilt %s" % destination)
    print("Wrote BUILD-REPORT.md and SHA256SUMS.txt alongside the archive.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
