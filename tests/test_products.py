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
        self.root = Path(directory.name).resolve()
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

    def invoke(self, *args, code=0, input_data=None):
        result = subprocess.run([str(OPS), *map(str, args)], env=self.env, cwd=self.root,
                                input=input_data, text=True, capture_output=True, timeout=10)
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

    def fake_command(self, name, source):
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        command = directory / name
        command.write_text("#!/bin/sh\n" + source)
        command.chmod(0o700)
        self.env["PATH"] = str(directory) + os.pathsep + self.env["PATH"]

    def test_discover_and_import_with_configuration_outside_deploy_directory(self):
        deployed = self.root / "deployed"
        deployed.mkdir()
        (deployed / "compose.yaml").touch()
        (deployed / ".env").write_text("PASSWORD=test-secret\n")
        (deployed / "upgrade.sh").write_text("touch " + str(self.marker))
        (deployed / "outside").symlink_to(self.root, target_is_directory=True)
        result = json.loads(self.invoke("product", "discover", deployed, "--config", self.config))
        self.assertEqual({detail["path"]: detail["editable"] for detail in result["configs"]},
                         {str(deployed / ".env"): False, str(self.config): True})
        self.assertEqual(result["scripts"], [str(deployed / "upgrade.sh")])
        self.assertEqual(result["actions"]["compose-1-status"]["argv"],
                         ["docker", "compose", "--project-directory", str(deployed),
                          "-f", str(deployed / "compose.yaml"), "ps", "--all"])
        self.assertFalse(self.state.exists())
        self.assertFalse(self.marker.exists())
        draft = self.root / "draft.json"
        draft.write_text(self.invoke("product", "discover", deployed,
                                     "--config", self.config, "--manifest", "deployed"))
        self.invoke("product", "import", draft, "--dry-run")
        self.invoke("product", "import", draft)
        exported = json.loads(self.invoke("product", "export", "deployed"))
        self.assertEqual(exported["configs"]["service"],
                         {"path": str(self.config), "format": "json", "fields": {}})
        self.assertEqual(self.config.read_bytes(), self.original)

    def test_systemd_discovery_uses_metadata_without_exporting_arguments(self):
        deployed = self.root / "unit cwd"
        deployed.mkdir()
        (deployed / "settings.toml").touch()
        self.fake_command("systemctl", """test "$2" = show || exit 1
printf '%s\\n' 'Id=demo.service' 'LoadState=loaded' "WorkingDirectory=$DISCOVER_WORKDIR"
printf '%s\\n' 'ExecStart=app --token test-secret'
""")
        self.env["DISCOVER_WORKDIR"] = str(deployed)
        result = json.loads(self.invoke("product", "discover", "--unit", "demo"))
        self.assertEqual(result["directory"], str(deployed))
        self.assertEqual(result["configs"][0]["path"], str(deployed / "settings.toml"))
        self.assertEqual(set(result["actions"]), {"status", "logs", "restart"})
        self.assertEqual(result["actions"]["restart"]["unit"], "demo.service")
        draft = json.loads(self.invoke("product", "discover", "--unit", "demo", "--manifest", "demo"))
        self.assertEqual(set(draft["actions"]), {"status", "logs"})
        self.assertFalse(self.state.exists())

    def test_compose_discovery_retains_project_name_and_file_order(self):
        deployed = self.root / "compose deployment"
        deployed.mkdir()
        files = [deployed / "compose.yaml", self.root / "compose.production.yaml"]
        for file in files:
            file.touch()
        self.env["COMPOSE_PROBE_RESULT"] = json.dumps([{
            "Name": "live-demo", "Status": "running(2)", "ConfigFiles": ",".join(map(str, files))
        }])
        self.fake_command("docker", """test "$*" = "compose ls --all --format json" || exit 1
printf '%s\\n' "$COMPOSE_PROBE_RESULT"
""")
        result = json.loads(self.invoke("product", "discover", "--compose", "live-demo"))
        self.assertEqual(result["directory"], str(deployed))
        self.assertEqual(result["actions"]["logs"]["argv"],
                         ["docker", "compose", "--project-directory", str(deployed),
                          "--project-name", "live-demo", "-f", str(files[0]),
                          "-f", str(files[1]), "logs", "--tail", "100"])
        self.assertFalse(result["actions"]["logs"]["change"])

    def test_release_manifest_resolves_paths_against_actual_directory(self):
        deployed = self.root / "release v2"
        deployed.mkdir()
        (deployed / "conf").mkdir()
        (deployed / "conf" / "service.json").write_bytes(self.original)
        product = json.loads(self.manifest.read_text())
        del product["directory"]
        product["configs"]["app"]["path"] = "conf/service.json"
        release = deployed / "ops.product.json"
        release.write_text(json.dumps(product), encoding="utf-8")
        result = json.loads(self.invoke("product", "discover", deployed))
        self.assertEqual(result["release_manifest"], str(release))
        self.assertEqual([entry["path"] for entry in result["configs"]],
                         [str(deployed / "conf" / "service.json")])
        self.invoke("product", "validate", release, "--directory", deployed)
        plan = json.loads(self.invoke("product", "import", release, "--directory", deployed, "--dry-run"))
        self.assertEqual(plan["configs"]["app"]["path"], str(deployed / "conf" / "service.json"))
        self.assertEqual(plan["actions"]["check"]["directory"], str(deployed))
        self.assertFalse(self.marker.exists())

    def test_discovery_menu_binds_only_selected_fields(self):
        deployed = self.root / "deployed"
        deployed.mkdir()
        answers = ["1", "3", str(deployed), "", "", str(self.config), "", "1", "y", "0", "0"]
        output = self.invoke("product", "menu", input_data="\n".join(answers) + "\n")
        self.assertIn("发现已部署产品", output)
        self.assertIn("准备登记 deployed：0 项命令、1 个配置文件", output)
        exported = json.loads(self.invoke("product", "export", "deployed"))
        self.assertEqual(exported["configs"]["service"]["fields"], {"port": {"type": "integer"}})
        self.assertEqual(self.config.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
