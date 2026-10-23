#!/usr/bin/env python3
"""Redact an OpenSCAP HTML report before it is committed.

Reports embed the evidence the scanner matched, including /etc/shadow lines,
the GRUB password hash and the host's addresses.

Usage: python3 -I scripts/redact-openscap-report.py RAW.html REDACTED.html
"""
import re
import sys

PATTERNS = [
    (r"\$(?:1|2[abxy]?|5|6|7|y|gy)\$[./A-Za-z0-9$,=-]{6,}", "[password-hash]"),
    (r"grub\.pbkdf2\.sha\d+\.\d+\.[0-9A-Fa-f.]+", "[grub-hash]"),
    (r'(label-primary">IPv4</span>\s*)(?:\d{1,3}\.){3}\d{1,3}', r"\1[ip-address]"),
    (r"(?<![\w.-])100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+\b", "[tailnet-ip]"),
    (r"(?i)\b(?:fd[0-9a-f]{2}|fe80):[0-9a-f:]+", "[ipv6-address]"),
    (r"(?i)\b(?!00:00:00:00:00:00)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}\b", "[mac-address]"),
]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    for pattern, placeholder in PATTERNS:
        text, count = re.subn(pattern, placeholder, text)
        print(f"{placeholder.replace(chr(92) + '1', '')}: {count}")
    for pattern, _ in PATTERNS[:2]:
        if re.search(pattern, text):
            sys.exit("a credential hash survived redaction; not writing the file")
    with open(sys.argv[2], "w", encoding="utf-8") as handle:
        handle.write(text)


if __name__ == "__main__":
    main()
