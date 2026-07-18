#!/usr/bin/env python3
"""
_update_binary_target.py <url> <checksum>

Rewrites the managed binaryTarget url and checksum in Package.swift.
Called by Scripts/release.sh; not intended for direct use.

Matches lines immediately following the marker comments:
  // managed-by-release: url
  // managed-by-release: checksum
"""
import re
import sys
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        sys.exit("Usage: _update_binary_target.py <url> <checksum>")

    url, checksum = sys.argv[1], sys.argv[2]
    pkg = Path("Package.swift")
    if not pkg.exists():
        sys.exit("Package.swift not found — run from the repository root")

    text = pkg.read_text()

    # Replace the URL string on the line that follows the url marker comment.
    text, n_url = re.subn(
        r'(// managed-by-release: url\n\s+url: ")([^"]+)(")',
        r"\g<1>" + url + r"\g<3>",
        text,
    )
    # Replace the checksum string on the line that follows the checksum marker.
    text, n_cs = re.subn(
        r'(// managed-by-release: checksum\n\s+checksum: ")([^"]+)(")',
        r"\g<1>" + checksum + r"\g<3>",
        text,
    )

    if n_url != 1 or n_cs != 1:
        sys.exit(
            f"Expected exactly 1 url marker and 1 checksum marker in Package.swift; "
            f"found url={n_url}, checksum={n_cs}. "
            "Check that the '// managed-by-release:' comments are present."
        )

    pkg.write_text(text)
    print(f"  url      → {url}")
    print(f"  checksum → {checksum}")


if __name__ == "__main__":
    main()
