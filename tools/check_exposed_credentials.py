#!/usr/bin/env python3
"""Fail when tracked files or a built app contain recognizable privileged keys."""

from __future__ import annotations

import argparse
import base64
import json
import pathlib
import re
import subprocess
import sys

PATTERNS = {
    "Supabase secret key": re.compile(rb"sb_secret_[A-Za-z0-9_-]{12,}"),
    "GitHub token": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
    "AWS access key": re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}"),
    "OpenAI key": re.compile(rb"sk-[A-Za-z0-9_-]{20,}"),
    "Resend key": re.compile(rb"(?<![A-Za-z0-9_])re_[A-Za-z0-9]{20,}(?![A-Za-z0-9_])"),
    "Stripe secret key": re.compile(rb"sk_(?:live|test)_[A-Za-z0-9]{20,}"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
}
JWT_PATTERN = re.compile(rb"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")


def service_role_jwts(data: bytes) -> bool:
    for match in JWT_PATTERN.finditer(data):
        try:
            payload = match.group().split(b".")[1]
            payload += b"=" * (-len(payload) % 4)
            if json.loads(base64.urlsafe_b64decode(payload)).get("role") == "service_role":
                return True
        except (ValueError, UnicodeError):
            continue
    return False


def scan_file(path: pathlib.Path, label: str) -> list[str]:
    try:
        data = path.read_bytes()
    except OSError as error:
        return [f"{label}: unreadable ({error.__class__.__name__})"]
    findings = [f"{label}: {name}" for name, pattern in PATTERNS.items() if pattern.search(data)]
    if service_role_jwts(data):
        findings.append(f"{label}: Supabase service role JWT")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-bundle", type=pathlib.Path, help="Also scan the contents of a built .app")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
    findings = []
    for raw_path in tracked:
        if not raw_path:
            continue
        relative = pathlib.Path(raw_path.decode())
        findings.extend(scan_file(root / relative, str(relative)))
    if args.app_bundle:
        if not args.app_bundle.is_dir():
            parser.error("--app-bundle must point to an existing directory")
        for path in args.app_bundle.rglob("*"):
            if path.is_file():
                findings.extend(scan_file(path, f"app:{path.relative_to(args.app_bundle)}"))
    for finding in findings:
        print(finding)
    if findings:
        print(f"Credential scan failed: {len(findings)} finding(s); values were not printed.")
        return 1
    print("Credential scan passed: no recognizable privileged keys found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
