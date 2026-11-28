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
        import sys
        sys.path.insert(0, str(ROOT / "scripts"))
        import workspace_layout
        for pkg in ("etaf-doc", "etaf-media", "ekp"):
            self.assertTrue((workspace_layout.package_path(ROOT, pkg) / "native" / "manifest.json").is_file(), pkg)

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
            rel = "etaf-doc/1/etaf-md-typeset-native-v1-darwin-arm64.dylib"
            binary = inp / rel
            binary.parent.mkdir(parents=True)
            binary.write_bytes(payload)
            records = inp / "records"
            records.mkdir()
            (records / "etaf-doc-darwin-arm64.json").write_text(json.dumps({
                "package": "etaf-doc",
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

    def test_companion_libraries_validate_and_assemble_into_manifest_and_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            mod_src = base / "etaf-video-mpv.dll"
            lib_src = base / "libmpv-2.dll"
            mod_payload = b"windows-mpv-module-v2-bytes"
            lib_payload = b"windows-companion-libmpv-bytes"
            mod_src.write_bytes(mod_payload)
            lib_src.write_bytes(lib_payload)

            inp = base / "builds"
            NATIVE.register_module("etaf-media", "windows-x86_64", mod_src, inp)
            NATIVE.register_library("etaf-media", "windows-x86_64", "libmpv-2.dll", "libmpv-2", lib_src, inp)

            stage = base / "stage"
            result = NATIVE.assemble_manifests(inp, write_packages=False, stage=stage, replace=True)
            manifest = result["manifests"]["etaf-media"]
            self.assertEqual([], NATIVE.validate_manifest(manifest, expected_package="etaf-media"))
            win_entry = manifest["modules"][0]["platforms"]["windows-x86_64"]
            self.assertIn("libraries", win_entry)
            self.assertEqual(1, len(win_entry["libraries"]))
            lib_entry = win_entry["libraries"][0]
            self.assertEqual("libmpv-2.dll", lib_entry["name"])
            self.assertEqual("libmpv-2-v2-windows-x86_64.dll", lib_entry["file"])
            self.assertEqual(len(lib_payload), lib_entry["size"])
            self.assertEqual([], NATIVE.validate_index_manifest(result["index"], stage))
            self.assertEqual(2, len(result["index"]["artifacts"]))
            self.assertEqual(lib_payload, (stage / "etaf-media/2/libmpv-2-v2-windows-x86_64.dll").read_bytes())

            # Invalid companion library filename must be rejected.
            bad = json.loads(json.dumps(manifest))
            bad["modules"][0]["platforms"]["windows-x86_64"]["libraries"][0]["name"] = "../evil.dll"
            self.assertTrue(any("library name" in e for e in NATIVE.validate_manifest(bad)))

            # Assembled hosted index carries enriched catalog + artifact metadata.
            idx = result["index"]
            self.assertIn("modules", idx)
            self.assertEqual("2", idx["modules"]["etaf-video-mpv"]["current_version"])
            self.assertEqual("current", idx["modules"]["etaf-video-mpv"]["versions"]["2"]["status"])
            by_path = {a["path"]: a for a in idx["artifacts"]}
            lib_rec = by_path["etaf-media/2/libmpv-2-v2-windows-x86_64.dll"]
            self.assertEqual("library", lib_rec["role"])
            self.assertEqual("etaf-video-mpv", lib_rec["owner_module"])
            self.assertEqual("libmpv-2.dll", lib_rec["runtime_name"])
            self.assertIn("built_at", lib_rec)

    def test_enrich_index_manifest_backfills_catalog_and_rejects_bad_schema_fields(self):
        legacy = {
            "schema": 1,
            "artifacts": [
                {
                    "package": "etaf",
                    "module": "etaf-video-mpv",
                    "version": "1",
                    "platform": "darwin-arm64",
                    "path": "etaf/1/etaf-video-mpv-v1-darwin-arm64.dylib",
                    "sha256": "1" * 64,
                    "size": 34808,
                },
                {
                    "package": "etaf",
                    "module": "etaf-video-mpv",
                    "version": "2",
                    "platform": "windows-x86_64",
                    "path": "etaf/2/etaf-video-mpv-v2-windows-x86_64.dll",
                    "sha256": "2" * 64,
                    "size": 148712,
                },
                {
                    "package": "etaf",
                    "module": "libmpv-2",
                    "version": "2",
                    "platform": "windows-x86_64",
                    "path": "etaf/2/libmpv-2-v2-windows-x86_64.dll",
                    "sha256": "3" * 64,
                    "size": 121789952,
                },
            ],
        }
        enriched = NATIVE.enrich_index_manifest(legacy)
        self.assertEqual([], NATIVE.validate_index_manifest(enriched, allow_missing=True))
        mod = enriched["modules"]["etaf-video-mpv"]
        self.assertEqual("2", mod["current_version"])
        self.assertEqual("current", mod["versions"]["2"]["status"])
        self.assertEqual("0.1.0", mod["versions"]["2"]["min_package_version"])
        self.assertEqual("archived", mod["versions"]["1"]["status"])
        self.assertEqual("0.3.13", mod["versions"]["1"]["max_package_version"])
        by_path = {a["path"]: a for a in enriched["artifacts"]}
        self.assertEqual("library", by_path["etaf/2/libmpv-2-v2-windows-x86_64.dll"]["role"])
        self.assertEqual("etaf-video-mpv", by_path["etaf/2/libmpv-2-v2-windows-x86_64.dll"]["owner_module"])
        self.assertEqual("3" * 64, by_path["etaf/2/libmpv-2-v2-windows-x86_64.dll"]["sha256"])

        # Reject invalid optional fields and unknown keys.
        bad_role = json.loads(json.dumps(enriched))
        bad_role["artifacts"][0]["role"] = "driver"
        self.assertTrue(any("role" in e for e in NATIVE.validate_index_manifest(bad_role)))

        bad_key = json.loads(json.dumps(enriched))
        bad_key["artifacts"][0]["secret"] = "nope"
        self.assertTrue(any("unexpected fields" in e for e in NATIVE.validate_index_manifest(bad_key)))

        bad_mod = json.loads(json.dumps(enriched))
        bad_mod["modules"]["etaf-video-mpv"]["versions"]["2"]["status"] = "beta"
        self.assertTrue(any("status" in e for e in NATIVE.validate_index_manifest(bad_mod)))


if __name__ == "__main__":
    unittest.main()
