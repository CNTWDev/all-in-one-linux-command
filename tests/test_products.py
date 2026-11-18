import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


OPS = Path(__file__).resolve().parents[1] / "ops.sh"


class ProductTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.state = self.root / "state"
        self.env = dict(os.environ, OPS_PRODUCTS_DIR=str(self.state),
                        OPS_EXTENSION_DIR=str(self.root / "extensions"))
        self.config = self.root / "service.json"
        self.original = b'{"port":8080,"api_key":"test-secret","untouched":true}\n'
        self.config.write_bytes(self.original)
        self.config.chmod(0o640)
        self.manifest = self.root / "manifest.json"
        self.marker = self.root / "command-ran"
        self.manifest.write_text(json.dumps({
            "schema_version": 1,
            "id": "demo",
            "name": "示例",
            "directory": str(self.root),
            "actions": {"check": {"kind": "command", "label": "检查", "argv": ["touch", str(self.marker)]}},
            "configs": {"app": {"path": "service.json", "format": "json", "fields": {
                "port": {"type": "integer"},
                "optional": {"type": "boolean", "delete": True},
                "api_key": {"type": "string", "secret": True},
            }}},
        }), encoding="utf-8")

    def invoke(self, *args, code=0):
        result = subprocess.run([str(OPS), *map(str, args)], env=self.env, cwd=self.root,
                                text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, code, result.stderr)
        self.assertNotIn("test-secret", result.stdout + result.stderr)
        return result.stdout

    def test_import_only_registers_actions_and_paths(self):
        plan = self.invoke("product", "import", self.manifest, "--dry-run")
        self.assertIn(str(self.marker), plan)
        self.assertFalse(self.state.exists())
        self.invoke("product", "import", self.manifest)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.config.read_bytes(), self.original)
        self.invoke("product", "remove", "demo")
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_edits_validate_and_restore_without_exposing_secret(self):
        self.invoke("product", "import", self.manifest)
        self.invoke("config", "set", "demo", "app", "port", "9000", "--dry-run")
        self.invoke("config", "set", "demo", "app", "port", "true", code=1)
        self.invoke("config", "delete", "demo", "app", "port", code=1)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse((self.state / "backups").exists())
        self.invoke("config", "set", "demo", "app", "optional", "true")
        self.invoke("config", "delete", "demo", "app", "optional")
        self.invoke("config", "restore", "demo", "app")
        setting = json.loads(self.config.read_bytes())
        self.assertEqual(setting, {**json.loads(self.original), "optional": True})
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o640)
        for backup in (self.state / "backups").glob("*/*.bak"):
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        secret = self.invoke("config", "get", "demo", "app", "api_key")
        self.assertEqual(json.loads(secret)["value"], "******")


if __name__ == "__main__":
    unittest.main()
