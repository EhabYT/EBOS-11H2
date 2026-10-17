"""Exercise the parked CI recipe locally with a fake gh; never contact GitHub."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

TOOLS = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((TOOLS / "ci" / "release.yml").read_text(encoding="utf-8"))
STEPS = WORKFLOW["jobs"]["build"]["steps"]
ATTACH = next(s["run"] for s in STEPS if s.get("name") == "Attach to a draft release")


@unittest.skipUnless(os.name == "posix", "CI shell recipe requires bash")
class ReleaseRecipeTests(unittest.TestCase):
    def run_attach(self, release="draft", archives=("EBOS-v11.2.apbx",), checksum=True,
                   tag="11.2", write_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "release").mkdir()
            for name in archives:
                (root / "release" / name).write_text("test fixture, not an archive")
            if checksum:
                (root / "release" / "SHA256SUMS.txt").write_text("test checksum fixture\n")
            bindir = root / "bin"
            bindir.mkdir()
            fake = bindir / "gh"
            fake.write_text("#!" + sys.executable + "\n" + '''import json, os, sys
with open(os.environ["GH_CALLS"], "a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["release", "view"]:
    state = os.environ["MOCK_RELEASE"]
    if state == "absent":
        sys.exit(1)
    print("true" if state == "draft" else "false")
elif sys.argv[1:3] in (["release", "upload"], ["release", "create"]):
    sys.exit(int(os.environ["MOCK_WRITE_EXIT"]))
else:
    sys.exit(99)
''')
            fake.chmod(0o755)
            log = root / "calls.jsonl"
            env = dict(os.environ, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                       GH_CALLS=str(log), MOCK_RELEASE=release, RELEASE_TAG=tag,
                       MOCK_WRITE_EXIT=str(write_exit))
            result = subprocess.run(["bash", "-c", ATTACH], cwd=root, env=env,
                                    capture_output=True, text=True, timeout=20)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls, (root / "injected").exists()

    def test_draft_upload_uses_correct_file_arguments(self):
        result, calls, _ = self.run_attach(archives=("EBOS v11.2.apbx",))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["release", "upload", "11.2", "release/EBOS v11.2.apbx", "release/SHA256SUMS.txt"], calls[-1])
        self.assertNotIn("--clobber", calls[-1])

    def test_missing_release_is_created_as_draft(self):
        result, calls, _ = self.run_attach(release="absent")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["release", "create", "11.2"], calls[-1][:3])
        self.assertIn("--draft", calls[-1])
        self.assertIn("--verify-tag", calls[-1])

    def test_published_release_is_not_changed(self):
        result, calls, _ = self.run_attach(release="published")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(1, len(calls))
        self.assertEqual(["release", "view"], calls[0][:2])

    def test_failed_upload_or_create_remains_a_failure(self):
        for release in ("draft", "absent"):
            result, _, _ = self.run_attach(release=release, write_exit=17)
            self.assertEqual(17, result.returncode)

    def test_requires_exactly_one_archive(self):
        for archives in ((), ("one.apbx", "two.apbx")):
            result, calls, _ = self.run_attach(archives=archives)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual([], calls)

    def test_requires_checksums(self):
        result, calls, _ = self.run_attach(checksum=False)
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], calls)

    def test_untrusted_tag_is_not_shell_code(self):
        result, calls, injected = self.run_attach(tag='11.2"; touch injected; #')
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], calls)
        self.assertFalse(injected)

    def test_bash_steps_parse_and_do_not_interpolate_dispatch_input(self):
        for step in STEPS:
            if "run" not in step or step.get("shell") == "pwsh":
                continue
            with self.subTest(step=step.get("name")):
                result = subprocess.run(["bash", "-n"], input=step["run"],
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertNotIn("${{", step["run"])

    def test_dispatch_checks_out_requested_tag_not_current_branch(self):
        checkout = next(s for s in STEPS if s.get("uses", "").startswith("actions/checkout@"))
        self.assertEqual("refs/tags/${{ inputs.tag || github.ref_name }}", checkout["with"]["ref"])
        self.assertEqual("release-${{ inputs.tag || github.ref_name }}", WORKFLOW["concurrency"]["group"])


if __name__ == "__main__":
    unittest.main()
