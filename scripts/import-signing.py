#!/usr/bin/env python3
"""Import owner-provided release secrets into a job-local signing keychain."""
import base64
import json
import os
import re
import shlex
import sys
from pathlib import Path
import secrets
import subprocess
import tempfile


def main():
    required = ("DISPLAYPANEL_SIGNING_P12_BASE64", "DISPLAYPANEL_SIGNING_P12_PASSWORD",
                "DISPLAYPANEL_SIGNING_IDENTITY", "DISPLAYPANEL_SIGNING_KEYCHAIN")
    if any(not os.environ.get(name) for name in required):
        raise SystemExit("Release signing secrets are missing; refusing ad-hoc release")
    identity = os.environ["DISPLAYPANEL_SIGNING_IDENTITY"]
    if len(identity) != 40 or any(c not in "0123456789abcdefABCDEF" for c in identity):
        raise SystemExit("Signing identity must be a 40-character certificate SHA-1")
    keychain = os.environ["DISPLAYPANEL_SIGNING_KEYCHAIN"]
    if Path(keychain).exists():
        raise SystemExit("Refusing to overwrite an existing signing keychain")
    password = secrets.token_hex(32)

    def security(*args):
        # Never print arguments: import/partition commands contain passwords.
        try:
            result = subprocess.run(["security", *args], capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            raise SystemExit(f"security {args[0]} timed out after 30 seconds (output withheld)")
        if result.returncode:
            raise SystemExit(f"security {args[0]} failed (output withheld)")
        return result.stdout.decode()

    with tempfile.TemporaryDirectory(prefix="displaypanel-signing-") as directory:
        certificate = Path(directory) / "identity.p12"
        certificate.write_bytes(base64.b64decode(
            os.environ["DISPLAYPANEL_SIGNING_P12_BASE64"], validate=True))
        certificate.chmod(0o600)
        security("create-keychain", "-p", password, keychain)
        security("set-keychain-settings", "-lut", "21600", keychain)
        security("unlock-keychain", "-p", password, keychain)
        security("import", str(certificate), "-k", keychain,
                 "-P", os.environ["DISPLAYPANEL_SIGNING_P12_PASSWORD"],
                 "-T", "/usr/bin/codesign")
        security("set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", password, keychain)
        # A Developer ID leaf must chain to Apple's root as is; never add trust.
        # Apple's published intermediates cover runners that lack them.
        for intermediate in sorted((Path(__file__).parent / "certificates").glob("*.cer")):
            security("import", str(intermediate), "-k", keychain)
        # --keychain selects the identity, but codesign and validation still build
        # certificate chains through the user's search list. Preserve it for the
        # always() cleanup.
        previous = shlex.split(security("list-keychains", "-d", "user"))
        Path(keychain + ".search-list.json").write_text(json.dumps(previous))
        security("list-keychains", "-d", "user", "-s", keychain, *previous)
        identities = security("find-identity", "-p", "codesigning", keychain)
        if identity.upper() not in identities.upper():
            raise SystemExit("Imported keychain has no matching signing identity; check certificate/private-key export and fingerprint secret")
        valid = security("find-identity", "-v", "-p", "codesigning", keychain)
        if identity.upper() not in valid.upper():
            matching = next(line for line in identities.splitlines() if identity.upper() in line.upper())
            reasons = re.findall(r"CSSMERR_[A-Z_]+", matching)
            raise SystemExit(f"Imported signing identity is not valid for code signing: {', '.join(reasons) or 'unknown reason'}")
        print("Configured signing identity is valid and available to codesign")


def cleanup():
    keychain = os.environ.get("DISPLAYPANEL_SIGNING_KEYCHAIN")
    if not keychain:
        return
    saved = Path(keychain + ".search-list.json")
    if saved.exists():
        subprocess.run(["security", "list-keychains", "-d", "user", "-s",
                        *json.loads(saved.read_text())], check=True, timeout=30,
                       capture_output=True)
    if Path(keychain).exists():
        subprocess.run(["security", "delete-keychain", keychain], check=True,
                       timeout=30, capture_output=True)


if __name__ == "__main__":
    if sys.argv[1:] == ["--cleanup"]:
        cleanup()
    else:
        main()
