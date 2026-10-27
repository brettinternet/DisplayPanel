#!/usr/bin/env python3
"""Offline signing checks: fake tools only; no certificate, TCC or UI access."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
IDENTITY = hashlib.sha1(b"fake certificate").hexdigest().upper()

FAKE_TOOL = '''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["SIGNING_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name == "codesign":
    if os.environ.get("FAIL_SIGN") and "--sign" in args:
        sys.exit(42)
    identifiers = pathlib.Path(os.environ["SIGNING_TEST_LOG"] + ".identifiers.json")
    signed = json.loads(identifiers.read_text()) if identifiers.exists() else {}
    if "--sign" in args:
        signed[args[-1]] = args[args.index("--identifier") + 1]
        identifiers.write_text(json.dumps(signed))
    if args[:2] == ["-d", "-r-"]:
        team = os.environ.get("FAKE_TEAM_ID", "4NQM9EVPZ3")
        print(f'designated => identifier "{signed[args[2]]}" and anchor apple generic and '
              'certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and '
              'certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and '
              f'certificate leaf[subject.OU] = "{team}"')
elif name == "security":
    if args == ["list-keychains", "-d", "user"]:
        print('"/a path/login.keychain-db"')
    if args[0] == "import" and args[1].endswith(".p12"):
        assert pathlib.Path(args[1]).read_bytes() == b"fake certificate"
    if args[0] == "find-identity":
        invalid = os.environ.get("INVALID_IDENTITY")
        if not os.environ.get("MISSING_IDENTITY") and not ("-v" in args and invalid):
            print(os.environ["DISPLAYPANEL_SIGNING_IDENTITY"], invalid or "")
    if os.environ.get("FAIL_SECURITY") == args[0]:
        print("sensitive diagnostic", file=sys.stderr)
        sys.exit(1)
elif name == "lipo":
    if "-create" in args:
        pathlib.Path(args[args.index("-output") + 1]).write_text("fake universal")
    else:
        print("arm64 x86_64")
elif name == "xcrun" and args == ["--show-sdk-version"]:
    print("15.0")
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "fake-id", "status": os.environ.get("FAKE_NOTARY_STATUS", "Accepted")}))
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    print("fake notary log")
elif name == "spctl":
    print("accepted\\nsource=" +os.environ.get("FAKE_SPCTL_SOURCE", "Notarized Developer ID"),
          file=sys.stderr)
elif name == "vtool":
    print("sdk 15.0")
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="displaypanel-signing-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.log = self.directory / "commands.jsonl"
        # The release job exports real signing and notary settings; ignore them.
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith(("DISPLAYPANEL_SIGNING_", "DISPLAYPANEL_NOTARY_",
                                           "DISPLAYPANEL_REQUIRE_"))}
        self.env.update(PATH=f"{self.directory}:{os.environ['PATH']}",
                        SIGNING_TEST_LOG=str(self.log))
        for name in ("codesign", "security", "lipo", "xcrun", "vtool", "spctl"):
            tool = self.directory / name
            tool.write_text(FAKE_TOOL)
            tool.chmod(0o755)

    def run_command(self, *command):
        return subprocess.run(command, env=self.env, capture_output=True, text=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def sign(self):
        return self.run_command("bash", "-euc",
            'source "$1"; displaypanel_signing_configure; displaypanel_sign "$2" com.brettinternet.displaypanel',
            "bash", str(ROOT / "scripts/signing.sh"), str(self.directory / "App with spaces.app"))

    def test_local_adhoc_warns(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING: ad-hoc", result.stderr)
        self.assertEqual(self.calls()[0][3], "-")

    def test_required_missing_or_explicit_adhoc_refuses(self):
        self.env["DISPLAYPANEL_REQUIRE_SIGNING"] = "1"
        for identity in ("", "-"):
            self.env["DISPLAYPANEL_SIGNING_IDENTITY"] = identity
            self.assertNotEqual(self.sign().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_invalid_configuration_refuses(self):
        for identity in ("DisplayPanel Signing", "ABC", '"; echo injected'):
            self.env["DISPLAYPANEL_SIGNING_IDENTITY"] = identity
            self.assertNotEqual(self.sign().returncode, 0)
        self.env["DISPLAYPANEL_SIGNING_IDENTITY"] = IDENTITY
        self.env["DISPLAYPANEL_REQUIRE_SIGNING"] = "true"
        self.assertNotEqual(self.sign().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_developer_id_signing_is_hardened_timestamped_and_keychain_scoped(self):
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY,
                        DISPLAYPANEL_SIGNING_KEYCHAIN="/a path/signing.keychain-db")
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        signing, check = self.calls()
        self.assertEqual(signing[signing.index("--options") + 1], "runtime")
        self.assertIn("--timestamp", signing)
        # The SHA-1 selects the identity only; codesign's default requirement survives renewal.
        self.assertNotIn("--requirements", signing)
        self.assertEqual(signing[signing.index("--keychain") + 1], "/a path/signing.keychain-db")
        self.assertEqual(check[1:], ["-d", "-r-", str(self.directory / "App with spaces.app")])

    def test_signing_refuses_a_different_team(self):
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY, FAKE_TEAM_ID="ABCDE12345")
        result = self.sign()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("team 4NQM9EVPZ3", result.stderr)

    def test_signing_failure_never_falls_back(self):
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY, FAIL_SIGN="1")
        self.assertEqual(self.sign().returncode, 42)
        self.assertEqual(len(self.calls()), 1)

    def notary(self, script):
        return self.run_command("bash", "-euc",
            'source "$1/signing.sh"; displaypanel_signing_configure; '
            'source "$1/notarize.sh"; displaypanel_notary_configure; ' + script,
            "bash", str(ROOT / "scripts"), str(self.directory / "App with spaces.zip"))

    def configure_notary(self):
        key = self.directory / "notary.p8"
        key.write_text("fake key")
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY,
                        DISPLAYPANEL_NOTARY_KEY_PATH=str(key),
                        DISPLAYPANEL_NOTARY_KEY_ID="KEYID", DISPLAYPANEL_NOTARY_ISSUER_ID="issuer")

    def test_local_notarization_skips_with_note_and_required_refuses(self):
        result = self.notary('[[ "$DISPLAYPANEL_NOTARIZE" == 0 ]]')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notarization skipped", result.stderr)
        self.env["DISPLAYPANEL_REQUIRE_NOTARIZATION"] = "1"
        self.assertNotEqual(self.notary("true").returncode, 0)
        self.configure_notary()
        del self.env["DISPLAYPANEL_NOTARY_ISSUER_ID"]
        self.assertNotEqual(self.notary("true").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_rejected_notarization_prints_log_and_fails(self):
        self.configure_notary()
        self.env["FAKE_NOTARY_STATUS"] = "Invalid"
        result = self.notary('displaypanel_notarize "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fake notary log", result.stderr)
        self.assertEqual([call[1:3] for call in self.calls()],
                         [["notarytool", "submit"], ["notarytool", "log"]])
        self.assertEqual(self.calls()[1][3], "fake-id")

    def test_app_verification_requires_gatekeeper_notarized_source(self):
        self.configure_notary()
        self.assertEqual(self.notary('displaypanel_verify_notarized_app "$2"').returncode, 0)
        self.env["FAKE_SPCTL_SOURCE"] = "Developer ID"
        result = self.notary('displaypanel_verify_notarized_app "$2"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not report", result.stderr)

    def package_app(self):
        binary = self.directory / "binary"
        binary.write_text("fake input")
        binary.chmod(0o755)
        return self.run_command("bash", str(ROOT / "scripts/package-app.sh"), "v0.3.0",
                                *([str(binary)] * 4), str(self.directory / "DisplayPanel.app"))

    def test_app_signs_helper_before_bundle_and_verifies(self):
        self.env["DISPLAYPANEL_SIGNING_IDENTITY"] = IDENTITY
        result = self.package_app()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = [call for call in self.calls() if call[0] == "codesign"]
        self.assertEqual(len(calls), 5)
        signs = [call for call in calls if "--sign" in call]
        for call, identifier in zip(signs, ("com.brettinternet.displaypanel.cli", "com.brettinternet.displaypanel")):
            self.assertEqual(call[call.index("--sign") + 1], IDENTITY)
            self.assertEqual(call[call.index("--identifier") + 1], identifier)
            self.assertIn("--timestamp", call)
        # Nested code is signed and checked before the outer bundle.
        self.assertEqual(calls[0], signs[0])
        self.assertTrue(calls[0][-1].endswith("/Contents/Helpers/dp"))
        self.assertEqual(calls[1][1:3], ["-d", "-r-"])
        self.assertEqual(calls[2], signs[1])
        self.assertIn("--verify", calls[4])
        self.assertIn("--strict", calls[4])
        self.assertTrue((self.directory / "DisplayPanel.app/Contents/Helpers/dp").exists())

    def test_packagers_fail_before_build_without_required_identity(self):
        self.env["DISPLAYPANEL_REQUIRE_SIGNING"] = "1"
        self.assertNotEqual(self.package_app().returncode, 0)
        result = self.run_command("bash", str(ROOT / "scripts/package-release.sh"), "v0.3.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release requires", result.stderr)
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY, DISPLAYPANEL_REQUIRE_NOTARIZATION="1")
        result = self.run_command("bash", str(ROOT / "scripts/package-release.sh"), "v0.3.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release requires DISPLAYPANEL_NOTARY", result.stderr)
        self.assertEqual(self.calls(), [])

    def import_identity(self):
        return self.run_command("python3", str(ROOT / "scripts/import-signing.py"))

    def configure_import(self):
        self.env.update(DISPLAYPANEL_SIGNING_IDENTITY=IDENTITY,
                        DISPLAYPANEL_SIGNING_P12_BASE64=base64.b64encode(b"fake certificate").decode(),
                        DISPLAYPANEL_SIGNING_P12_PASSWORD="fake password",
                        DISPLAYPANEL_SIGNING_KEYCHAIN=str(self.directory / "signing.keychain-db"))

    def test_import_missing_secrets_refuses(self):
        self.assertNotEqual(self.import_identity().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_import_scopes_key_access_and_removes_p12(self):
        self.configure_import()
        result = self.import_identity()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call[1] for call in calls], ["create-keychain", "set-keychain-settings",
                         "unlock-keychain", "import", "set-key-partition-list", "import", "import",
                         "list-keychains", "list-keychains", "find-identity", "find-identity"])
        imported = calls[3]
        self.assertFalse(Path(imported[2]).exists())
        self.assertEqual(imported[-2:], ["-T", "/usr/bin/codesign"])
        self.assertNotIn("fake password", result.stdout + result.stderr)
        self.assertEqual(calls[8][2:], ["-d", "user", "-s", self.env["DISPLAYPANEL_SIGNING_KEYCHAIN"],
                                       "/a path/login.keychain-db"])
        cleanup = self.run_command("python3", str(ROOT / "scripts/import-signing.py"), "--cleanup")
        self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
        self.assertEqual(self.calls()[-1][2:], ["-d", "user", "-s", "/a path/login.keychain-db"])

    def test_import_adds_apple_intermediates_without_trust_overrides(self):
        self.configure_import()
        result = self.import_identity()
        self.assertEqual(result.returncode, 0, result.stderr)
        intermediates = [Path(call[2]).name for call in self.calls()[5:7]]
        self.assertEqual(intermediates, ["DeveloperIDCA.cer", "DeveloperIDG2CA.cer"])
        self.assertFalse(any(call[1] in ("add-trusted-cert", "export") for call in self.calls()))

    def test_import_refuses_missing_or_invalid_identity(self):
        self.configure_import()
        for flag, value, message in (("MISSING_IDENTITY", "1", "no matching signing identity"),
                                     ("INVALID_IDENTITY", "CSSMERR_TP_CERT_EXPIRED", "CSSMERR_TP_CERT_EXPIRED"),
                                     ("INVALID_IDENTITY", "CSSMERR_TP_NOT_TRUSTED", "CSSMERR_TP_NOT_TRUSTED")):
            self.env[flag] = value
            result = self.import_identity()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
            self.assertFalse(any(call[1] == "add-trusted-cert" for call in self.calls()))
            self.assertNotIn("fake password", result.stdout + result.stderr)
            del self.env[flag]

    def test_import_failure_hides_diagnostics_and_removes_p12(self):
        self.configure_import()
        self.env["FAIL_SECURITY"] = "import"
        result = self.import_identity()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("sensitive diagnostic", result.stderr)
        self.assertFalse(Path(self.calls()[-1][2]).exists())

    def test_import_refuses_existing_keychain(self):
        self.configure_import()
        Path(self.env["DISPLAYPANEL_SIGNING_KEYCHAIN"]).touch()
        self.assertNotEqual(self.import_identity().returncode, 0)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
