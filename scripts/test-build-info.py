import importlib.util
import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

loader = importlib.util.spec_from_file_location('build_info', Path(__file__).with_name('build-info.py'))
module = importlib.util.module_from_spec(loader)
loader.loader.exec_module(module)

class BuildIdentityTests(unittest.TestCase):
    def test_uncommitted_source_changes_have_distinct_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            (root / 'VoicePaste').mkdir()
            source = root / 'VoicePaste/App.swift'
            source.write_text('first')
            first = module.source_digest(root)
            self.assertEqual(first, module.source_digest(root))
            source.write_text('second')
            self.assertNotEqual(first, module.source_digest(root))

    def test_receipt_rejects_unidentified_build_without_changing_history(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / 'VoicePaste.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
            ledger = root / 'installations.json'
            ledger.write_text('[]')
            with self.assertRaises(ValueError):
                module.receipt(app, ledger)
            self.assertEqual(json.loads(ledger.read_text()), [])

    def test_missing_signing_preflight_preserves_installed_app(self):
        script = Path(__file__).with_name('install-local.sh')
        with tempfile.TemporaryDirectory() as directory:
            import os
            result = subprocess.run(['zsh', str(script), '/nonexistent/VoicePaste.app'],
                env={**os.environ, 'VOICEPASTE_BUILD_KEYCHAIN': str(Path(directory)/'missing'),
                     'VOICEPASTE_BUILD_KEYCHAIN_SECRET': str(Path(directory)/'missing-secret')},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('не изменены', result.stderr)

if __name__ == '__main__':
    unittest.main()
