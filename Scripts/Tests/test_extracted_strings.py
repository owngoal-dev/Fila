"""Exercise the release localization gate across Xcode build layouts."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "check-extracted-strings.py"
ROOT = SCRIPT.parent.parent
spec = importlib.util.spec_from_file_location("extracted_strings", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class ExtractedStringsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.derived = Path(self.temporary.name)

    def populate(self, suffix=".build", configuration="Release-iphoneos", binary=False):
        for name, project, catalogue in checker.TARGETS:
            directory = self.derived / "Build/Intermediates.noindex" / project / configuration
            directory /= name + (".build" if name == "Fila" else suffix)
            directory /= "Objects-normal/arm64"
            directory.mkdir(parents=True)
            keys = json.loads((ROOT / catalogue).read_text())["strings"]
            data = {"tables": {"Localizable": [{"key": key} for key in keys]}}
            content = plistlib.dumps(data, fmt=plistlib.FMT_BINARY) if binary else json.dumps(data).encode()
            (directory / "Source.stringsdata").write_bytes(content)
        return directory

    def run_check(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.derived), "Release-iphoneos"], capture_output=True, text=True)

    def test_xcode26_layout(self):
        self.populate()
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_xcode27_layout_and_plist(self):
        self.populate("-t.build", binary=True)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_other_configuration_cannot_mask_missing_build(self):
        self.populate(configuration="Debug-iphonesimulator")
        result = self.run_check()
        self.assertEqual(result.returncode, 65)
        self.assertIn("no build directory for FilaFormats", result.stderr)

    def test_generated_symbols_cannot_mask_unextractable_keys(self):
        directory = self.populate()
        (directory / "Source.stringsdata").rename(directory / "GeneratedStringSymbols_Localizable.stringsdata")
        result = self.run_check()
        self.assertEqual(result.returncode, 65)
        self.assertIn("no FilaTerminal source extracts", result.stderr)

    def test_missing_catalogue_key_fails(self):
        directory = self.populate()
        (directory / "New.stringsdata").write_text(json.dumps({"tables": {"Localizable": [{"key": "Untranslated regression fixture"}]}}))
        result = self.run_check()
        self.assertEqual(result.returncode, 65)
        self.assertIn("is missing 1 key(s)", result.stderr)

    def test_empty_target_directory_fails(self):
        directory = self.populate()
        (directory / "Source.stringsdata").unlink()
        self.assertEqual(self.run_check().returncode, 65)


if __name__ == "__main__":
    unittest.main()
