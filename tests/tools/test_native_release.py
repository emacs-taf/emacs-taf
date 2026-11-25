"""Contract tests for scripts/native-release.py manifest and staging verification."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_release", ROOT / "scripts/native-release.py")
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)


class NativeReleaseTests(unittest.TestCase):
    def sample_manifest(self, package="etaf-md"):
        return {
            "schema": 1,
            "package": package,
            "modules": [
                {
                    "name": "etaf-md-typeset-native",
                    "version": "1",
                    "description": "QuickJS Mermaid and MathJax renderer",
                    "platforms": {
                        "darwin-arm64": {
                            "file": "etaf-md-typeset-native-v1-darwin-arm64.dylib",
                            "urls": [
                                "https://etaf.top/native/etaf-md/1/etaf-md-typeset-native-v1-darwin-arm64.dylib",
                            ],
                            "sha256": "a" * 64,
                            "size": 1024,
                        }
                    },
                }
            ],
        }

    def test_workspace_package_native_manifests_pass_verification(self):
        self.assertEqual([], NATIVE.verify_all(ROOT))
        for pkg in ("etaf-md", "etaf", "ekp"):
            self.assertTrue((ROOT / "packages" / pkg / "native" / "manifest.json").is_file(), pkg)

    def test_validate_manifest_rejects_non_https_bad_sha_and_unsafe_filenames(self):
        self.assertEqual([], NATIVE.validate_manifest(self.sample_manifest(), expected_package="etaf-md"))

        bad_url = self.sample_manifest()
        bad_url["modules"][0]["platforms"]["darwin-arm64"]["urls"] = ["http://example.com/a.dylib"]
        self.assertTrue(any("https://" in e for e in NATIVE.validate_manifest(bad_url)))

        bad_sha = self.sample_manifest()
        bad_sha["modules"][0]["platforms"]["darwin-arm64"]["sha256"] = "not-a-sha"
        self.assertTrue(any("sha256" in e for e in NATIVE.validate_manifest(bad_sha)))

        bad_file = self.sample_manifest()
        bad_file["modules"][0]["platforms"]["darwin-arm64"]["file"] = "../escape.dylib"
        self.assertTrue(any("filename" in e for e in NATIVE.validate_manifest(bad_file)))

        bad_ext = self.sample_manifest()
        bad_ext["modules"][0]["platforms"]["darwin-arm64"]["file"] = "mod.so"
        self.assertTrue(any("filename" in e for e in NATIVE.validate_manifest(bad_ext)))

        bad_pkg = self.sample_manifest(package="other")
        self.assertTrue(any("does not match" in e for e in NATIVE.validate_manifest(bad_pkg, expected_package="etaf-md")))

    def test_assemble_and_stage_verifies_bytes_and_rejects_tampering(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            inp = base / "input"
            payload = b"native-binary-payload-bytes"
            sha = hashlib.sha256(payload).hexdigest()
            rel = "etaf-md/1/etaf-md-typeset-native-v1-darwin-arm64.dylib"
            binary = inp / rel
            binary.parent.mkdir(parents=True)
            binary.write_bytes(payload)
            records = inp / "records"
            records.mkdir()
            (records / "etaf-md-darwin-arm64.json").write_text(json.dumps({
                "package": "etaf-md",
                "module": "etaf-md-typeset-native",
                "version": "1",
                "platform": "darwin-arm64",
                "file": "etaf-md-typeset-native-v1-darwin-arm64.dylib",
                "path": rel,
                "sha256": sha,
                "size": len(payload),
            }))
            stage = base / "staged"
            result = NATIVE.assemble_manifests(inp, write_packages=False, stage=stage, replace=True)
            self.assertEqual([], NATIVE.validate_index_manifest(result["index"], stage))
            self.assertEqual((stage / rel).read_bytes(), payload)

            # Tampering a staged binary must fail index verification.
            (stage / rel).write_bytes(b"corrupted")
            errs = NATIVE.validate_index_manifest(result["index"], stage)
            self.assertTrue(any("mismatch" in e for e in errs))


if __name__ == "__main__":
    unittest.main()
