#!/usr/bin/env python3
"""Validate the selected official image against Plex's public release API.

Docker Hub tags/digests identify the image. The public API only confirms release
eligibility and supplies notes; it never silently chooses another image.
"""

import argparse
import json
import os
import re
import sys
import urllib.request

PUBLIC_RELEASE_URL = "https://plex.tv/api/downloads/5.json"
TAG_PATTERN = re.compile(r"^(\d+\.\d+\.\d+\.\d+)-[a-f0-9]+$")


def public_release():
    request = urllib.request.Request(
        PUBLIC_RELEASE_URL, headers={"User-Agent": "lazycat-plex-adapter/1.0"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read(2 * 1024 * 1024 + 1))
    release = data["computer"]["Linux"]
    if not TAG_PATTERN.fullmatch(release.get("version", "")):
        raise ValueError("Plex public API returned an invalid version")
    return release


def release_changelog(release, tag, numeric_version):
    match = TAG_PATTERN.fullmatch(tag)
    if not match or match.group(1) != numeric_version:
        raise ValueError("Selected image tag and full numeric source version disagree")
    if release.get("version") != tag:
        raise ValueError(
            f"Selected image {tag} does not match public release {release.get('version')}; "
            "wait for synchronized metadata rather than using another release's notes"
        )
    sections = [f"Plex Media Server {tag}"]
    for title, key in (("Added", "items_added"), ("Fixed", "items_fixed")):
        notes = release.get(key, "")
        if not isinstance(notes, str):
            raise ValueError(f"Plex public API returned invalid {key}")
        if notes.strip():
            sections.append(f"## {title}\n{notes.strip()}")
    if len(sections) == 1:
        raise ValueError("Public release has no update notes")
    return "\n\n".join(sections)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("changelog", "public-version"))
    args = parser.parse_args()
    release = public_release()
    if args.operation == "public-version":
        print(release["version"])
    else:
        print(release_changelog(
            release,
            os.environ.get("LAZYCAT_SOURCE_TAG", ""),
            os.environ.get("LAZYCAT_SOURCE_VERSION", ""),
        ))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print(f"Plex release validation failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
