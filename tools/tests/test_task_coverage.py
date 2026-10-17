"""Regression tests; no Windows host and no production-file mutation required."""
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import task_coverage as coverage

spec = importlib.util.spec_from_file_location("builder", TOOLS / "build-playbook.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def row(name=r"\EBOS Guard", op="create", gate="", scope=""):
    name = name.replace("'", "''")
    return "  @{t='%s';g='%s';op='%s';scope='%s'}" % (name, gate, op, scope)


class RegistrationTests(unittest.TestCase):
    def names(self, text):
        return [name for name, _ in coverage.registrations(text)]

    def test_quotes_spaces_case_and_optional_root(self):
        for text in (
            "Register-ScheduledTask -TaskName 'EBOS Guard'",
            'register-scheduledtask -TASKNAME "\\EBOS Guard"',
            "schtasks /Create /TN 'EBOS Guard' /SC ONLOGON",
            'SCHTASKS.EXE /tn "\\EBOS Guard" /SC ONLOGON /CREATE',
            "& 'schtasks.exe' /Create /TN 'EBOS Guard'",
        ):
            with self.subTest(text=text):
                self.assertEqual([r"\ebos guard"], self.names(text))

    def test_backslash_is_not_a_powershell_escape(self):
        self.assertEqual([r"\folder\guard"], self.names(
            "Register-ScheduledTask -TaskPath '\\Folder\\' -TaskName 'Guard'"))

    def test_escaped_single_quote(self):
        self.assertEqual(["\\o'brien"], self.names("Register-ScheduledTask -TaskName 'O''Brien'"))

    def test_line_continuations(self):
        for text in (
            "Register-ScheduledTask `\n -TaskName 'EBOS Guard'",
            "schtasks.exe /TN 'EBOS Guard' ^\n /Create /SC ONLOGON",
        ):
            self.assertEqual([r"\ebos guard"], self.names(text))

    def test_constant_variable_case_insensitive(self):
        self.assertEqual([r"\ebos guard"], self.names(
            "$task = '\\EBOS Guard'\n& schtasks.exe /Create /TN $TASK"))

    def test_unresolved_names_are_not_silently_ignored(self):
        for text in (
            "Register-ScheduledTask -TaskName $unknown",
            'Register-ScheduledTask -TaskName "EBOS-$suffix"',
            "Register-ScheduledTask -TaskName $later\n$later = 'Guard'",
            "$x = 'A' + $suffix\nRegister-ScheduledTask -TaskName $x",
            "$x = 'A'\n$x = 'B'\nRegister-ScheduledTask -TaskName $x",
            "Register-ScheduledTask -TaskName 'Guard' -TaskPath $path",
            "Register-ScheduledTask -TaskName",
            "schtasks /Create /SC ONLOGON",
        ):
            with self.subTest(text=text):
                self.assertEqual([None], self.names(text))

    def test_comments_strings_and_unregister_are_not_creations(self):
        for text in (
            "# Register-ScheduledTask -TaskName 'comment'",
            "<#\nRegister-ScheduledTask -TaskName 'comment'\n#>",
            "UnRegister-ScheduledTask -TaskName 'Guard'",
            "Write-Output \"Register-ScheduledTask -TaskName 'text'\"",
            "Write-Output Register-ScheduledTask -TaskName text",
            "'Register-ScheduledTask' -TaskName text",
            "$body = @'\nRegister-ScheduledTask -TaskName 'later'\n'@",
            "schtasks /Query /TN Guard",
            "schtasks /Delete /TN Guard /F",
        ):
            with self.subTest(text=text):
                self.assertEqual([], self.names(text))

    def test_line_number_is_preserved(self):
        self.assertEqual([(r"\guard", 3)], list(coverage.registrations(
            "# comment\n\nRegister-ScheduledTask -TaskName Guard")))

    def test_script_calls_ignore_copies_and_comments(self):
        text = "# .\\ignored.ps1\nCopy-Item '.\\not-called.ps1' 'dst'\n& '.\\called.ps1'"
        self.assertEqual(["called.ps1"], list(coverage.script_calls(text)))

    def test_script_file_argument_with_repeated_separator(self):
        self.assertEqual(["setup.ps1"], list(coverage.script_calls(
            r"-NoP -EP Bypass -File .\\setup.ps1")))


class CoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "Executables").mkdir()
        self.docs = {}

    def write(self, path, text):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        return target

    def commands(self, text, gate="", where="Configuration/Tasks/apply.yml"):
        path = self.write(where, "# fixture\n")
        self.docs[path] = {"actions": [{"command": text, "option": gate}]}

    def check(self, *rows):
        self.write("Executables/ebos-verify.ps1", "$tasks = @(\n" + ",\n".join(rows) + "\n)\n")
        report = builder.Report()
        coverage.check(report, self.root, self.docs)
        return report

    def test_create_passes(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        report = self.check(row())
        self.assertEqual([], report.errors)
        self.assertIn("1 with create assertions", report.notes[0])

    def test_name_match_does_not_let_delete_or_disable_pass(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        for op in ("delete", "disable", "", "typo"):
            with self.subTest(op=op):
                self.assertTrue(self.check(row(op=op)).errors)

    def test_wrong_gate_fails(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'", "option-a")
        self.assertTrue(self.check(row(gate="option-b")).errors)
        self.assertEqual([], self.check(row(gate="option-a")).errors)

    def test_folder_is_part_of_identity(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard' -TaskPath '\\Folder\\'")
        self.assertTrue(self.check(row()).errors)
        self.assertEqual([], self.check(row(r"\FOLDER\ebos guard")).errors)

    def test_unknown_name_is_a_build_error(self):
        self.commands("Register-ScheduledTask -TaskName $computed")
        self.assertIn("cannot resolve", self.check(row(op="delete")).errors[0])

    def test_duplicate_rows_are_not_coverage(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        self.assertTrue(self.check(row(), row()).errors)
        self.assertTrue(self.check(row(), row(op="delete")).errors)

    def test_comment_does_not_count_as_a_verify_row(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        self.assertTrue(self.check("# " + row(), row("Other", op="delete")).errors)

    def test_unrelated_table_does_not_count(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        self.write("Executables/ebos-verify.ps1", "$other = @(\n" + row() + "\n)\n")
        report = builder.Report()
        coverage.check(report, self.root, self.docs)
        self.assertIn("no literal rows", report.errors[0])

    def test_fields_need_not_be_in_fixed_order(self):
        self.commands("Register-ScheduledTask -TaskName 'EBOS Guard'")
        self.assertEqual([], self.check("  @{op='create'; t='\\EBOS Guard'; g=''}").errors)

    def test_unreferenced_create_assertion_is_an_error(self):
        self.assertIn("no direct registration", self.check(row()).errors[0])

    def test_missing_verify_script(self):
        report = builder.Report()
        coverage.check(report, self.root, self.docs)
        self.assertIn("is missing", report.errors[0])

    def test_script_caller_gate_is_checked(self):
        self.commands(r"& '.\setup.ps1'", "selected")
        self.write("Executables/setup.ps1", "schtasks /Create /TN 'EBOS Guard'")
        self.assertTrue(self.check(row()).errors)
        self.assertEqual([], self.check(row(gate="selected")).errors)

    def test_run_args_caller_gate_is_checked(self):
        path = self.write("Configuration/Tasks/apply.yml", "# fixture")
        self.docs[path] = {"actions": [{"exe": "PowerShell", "args": r"-File .\\setup.ps1", "option": "selected"}]}
        self.write("Executables/setup.ps1", "schtasks /Create /TN 'EBOS Guard'")
        self.assertTrue(self.check(row()).errors)
        self.assertEqual([], self.check(row(gate="selected")).errors)

    def test_nested_scripts_are_scanned(self):
        self.write("Executables/subdir/setup.ps1", "schtasks /Create /TN 'EBOS Guard'")
        self.assertTrue(self.check(row(op="delete")).errors)
        self.assertEqual([], self.check(row()).errors)

    def test_yaml_is_parsed_before_scanning(self):
        text = """actions:
  # Register-ScheduledTask -TaskName 'not executable'
  - !cmd: {command: 'schtasks /Create /TN "EBOS Guard"'}
"""
        path = self.write("Configuration/Tasks/apply.yml", text)
        self.docs[path] = builder.yaml.load(text, Loader=builder.PlaybookLoader)
        self.assertEqual([], self.check(row()).errors)

    def test_run_schtasks_executable(self):
        path = self.write("Configuration/Tasks/apply.yml", "# fixture")
        self.docs[path] = {"actions": [{"exe": "schtasks.exe", "args": "/Create /TN 'EBOS Guard'"}]}
        self.assertEqual([], self.check(row()).errors)

    def test_parent_yaml_gate_is_inherited(self):
        path = self.write("Configuration/Tasks/apply.yml", "# fixture")
        self.docs[path] = {"option": "parent", "actions": [{"command": "schtasks /Create /TN 'EBOS Guard'", "option": "child"}]}
        self.assertEqual([], self.check(row(gate="parent+child")).errors)

    def test_lifecycle_exception_is_source_and_gate_scoped(self):
        command = "schtasks /Create /TN EBOSDefenderCleanup"
        self.commands(command, "disable-defender", "Configuration/Tasks/phase2-strip.yml")
        self.assertEqual([], self.check(row("Unrelated", op="delete")).errors)
        self.docs.clear()
        self.commands(command, "disable-defender", "Configuration/Tasks/surprise.yml")
        self.assertTrue(self.check(row("Unrelated", op="delete")).errors)
        self.docs.clear()
        self.commands(command, "", "Configuration/Tasks/phase2-strip.yml")
        self.assertTrue(self.check(row("Unrelated", op="delete")).errors)

    def test_timer_requires_fresh_install_scope(self):
        self.commands(r".\setup-timerresolution.ps1")
        self.write("Executables/setup-timerresolution.ps1", "schtasks /Create /TN EBOS-TimerResolution")
        self.assertTrue(self.check(row("EBOS-TimerResolution")).errors)
        self.assertEqual([], self.check(row("EBOS-TimerResolution", scope="fresh-install")).errors)

    def test_real_repository(self):
        report = builder.Report()
        conf = builder.check_conf(report)
        docs = builder.check_yaml(report, conf["options"])
        coverage.check(report, TOOLS.parent, docs)
        self.assertEqual([], report.errors)
        self.assertIn("6 registered task names: 3 with create assertions, 3 lifecycle exclusions", report.notes[-1])


if __name__ == "__main__":
    unittest.main()
