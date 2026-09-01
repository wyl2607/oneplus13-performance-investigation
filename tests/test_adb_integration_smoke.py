import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "adb_integration_smoke", ROOT / "tools" / "adb-integration-smoke.py"
)
assert SPEC and SPEC.loader
mod = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = mod
SPEC.loader.exec_module(mod)


class AdbShellCommandTest(unittest.TestCase):
    def test_run_decodes_adb_output_as_utf8(self):
        completed = subprocess.CompletedProcess([], 0, stdout="常开", stderr="")
        with patch.object(mod.subprocess, "run", return_value=completed) as mocked:
            self.assertEqual(mod.run(["adb", "shell"]).stdout, "常开")

        self.assertEqual(mocked.call_args.kwargs["encoding"], "utf-8")

    def test_shell_keeps_script_in_one_adb_argument_on_windows(self):
        script = "if [ -r '/sys/example' ]; then cat '/sys/example'; fi"
        completed = subprocess.CompletedProcess([], 0, stdout="ok", stderr="")
        with patch.object(mod, "run", return_value=completed) as mocked:
            self.assertEqual(mod.Adb("adb").shell(script), "ok")

        command = mocked.call_args.args[0]
        self.assertEqual(command[:2], ["adb", "shell"])
        self.assertEqual(len(command), 3)
        self.assertEqual(command[2], f"sh -c {mod.shell_quote(script)}")

    def test_root_shell_keeps_script_in_one_adb_argument(self):
        completed = subprocess.CompletedProcess([], 0, stdout="uid=0", stderr="")
        with patch.object(mod, "run", return_value=completed) as mocked:
            self.assertEqual(mod.Adb("adb").shell("id", root=True), "uid=0")

        self.assertEqual(mocked.call_args.args[0], ["adb", "shell", "su -c 'id'"])


if __name__ == "__main__":
    unittest.main()
