#!/usr/bin/env python3

import argparse
import csv
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

import requests
from bs4 import BeautifulSoup


CURL_RELEASES_URL = "https://curl.se/docs/releases.html"
NIXPKGS_REPO_URL = "https://github.com/NixOS/nixpkgs.git"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
NIX_VERSION_RE = re.compile(r'version\s*=\s*"(?P<version>\d+\.\d+\.\d+)"\s*;')
NIX_NAME_VERSION_RE = re.compile(r'name\s*=\s*"curl-(?P<version>\d+\.\d+\.\d+)"\s*;')

# Current path + older historical path candidates.
# The first one is the current canonical source for the curl derivation.
CURL_PACKAGE_PATHS = [
    "pkgs/by-name/cu/curlMinimal/package.nix",
    "pkgs/tools/networking/curl/default.nix",
]


@dataclass
class CurlRelease:
    version: str
    release_date: str


@dataclass
class NixpkgsMatch:
    version: str
    commit: str
    commit_date: str
    path: str


def run(cmd: List[str], cwd: Optional[Path] = None) -> str:
    result = subprocess.run(
        cmd,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Command failed:\n"
            f"  {' '.join(cmd)}\n\n"
            f"stderr:\n{result.stderr}"
        )

    return result.stdout


def fetch_html(url: str) -> str:
    headers = {
        "User-Agent": "curl-nixpkgs-version-history/1.0",
    }
    response = requests.get(url, headers=headers, timeout=30)
    response.raise_for_status()
    return response.text


def extract_curl_releases(html: str) -> List[CurlRelease]:
    soup = BeautifulSoup(html, "html.parser")
    releases: List[CurlRelease] = []

    for row in soup.select("tr"):
        cells = row.find_all(["td", "th"])
        if len(cells) < 3:
            continue

        version = cells[1].get_text(strip=True)
        release_date = cells[2].get_text(" ", strip=True)

        if VERSION_RE.match(version):
            releases.append(
                CurlRelease(
                    version=version,
                    release_date=release_date,
                )
            )

    if not releases:
        raise RuntimeError("Could not extract curl releases from curl.se")

    return releases


def ensure_nixpkgs_repo(repo_dir: Path) -> None:
    if repo_dir.exists():
        print(f"[+] Updating existing nixpkgs clone: {repo_dir}", file=sys.stderr)
        run(["git", "fetch", "origin", "--prune"], cwd=repo_dir)
        return

    print(f"[+] Cloning nixpkgs into: {repo_dir}", file=sys.stderr)
    run(
        [
            "git",
            "clone",
            "--filter=blob:none",
            NIXPKGS_REPO_URL,
            str(repo_dir),
        ]
    )


def git_show_file(repo_dir: Path, commit: str, path: str) -> Optional[str]:
    result = subprocess.run(
        ["git", "show", f"{commit}:{path}"],
        cwd=repo_dir,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    if result.returncode != 0:
        return None

    return result.stdout


def extract_version_from_nix_expression(content: str) -> Optional[str]:
    match = NIX_VERSION_RE.search(content)
    if match:
        return match.group("version")

    # Older nixpkgs style
    match = NIX_NAME_VERSION_RE.search(content)
    if match:
        return match.group("version")


def commits_touching_path(repo_dir: Path, git_ref: str, path: str) -> List[tuple[str, str]]:
    """
    Return commits touching a path in chronological order.

    Each item is:
      (commit_hash, commit_date)
    """
    output = run(
        [
            "git",
            "log",
            "--reverse",
            "--format=%H%x09%cs",
            git_ref,
            "--",
            path,
        ],
        cwd=repo_dir,
    )

    commits = []
    for line in output.splitlines():
        if not line.strip():
            continue

        commit, date = line.split("\t", 1)
        commits.append((commit, date))

    return commits


def build_nixpkgs_version_map(
    repo_dir: Path,
    git_ref: str,
    package_paths: List[str],
    pick: str,
) -> Dict[str, NixpkgsMatch]:
    """
    Build mapping:
      curl version -> nixpkgs commit where that version appears.

    pick = "first":
      first commit in history where this version appears.

    pick = "last":
      last commit in history where this version appears.
      This is sometimes useful if you want the newest nixpkgs commit
      still containing that curl version before the next bump.
    """
    version_map: Dict[str, NixpkgsMatch] = {}

    for path in package_paths:
        print(f"[+] Scanning nixpkgs history for {path}", file=sys.stderr)

        for commit, commit_date in commits_touching_path(repo_dir, git_ref, path):
            content = git_show_file(repo_dir, commit, path)
            if content is None:
                continue

            version = extract_version_from_nix_expression(content)
            if not version:
                continue

            match = NixpkgsMatch(
                version=version,
                commit=commit,
                commit_date=commit_date,
                path=path,
            )

            if pick == "first":
                version_map.setdefault(version, match)
            elif pick == "last":
                version_map[version] = match
            else:
                raise ValueError(f"Unsupported pick mode: {pick}")

    return version_map


def write_csv(
    output_path: Path,
    curl_releases: List[CurlRelease],
    nixpkgs_versions: Dict[str, NixpkgsMatch],
) -> None:
    with output_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "curl_version",
                "curl_release_date",
                "nixpkgs_commit",
                "nixpkgs_commit_date",
                # "nixpkgs_package_path",
            ],
        )

        writer.writeheader()

        for release in curl_releases:
            match = nixpkgs_versions.get(release.version)

            writer.writerow(
                {
                    "curl_version": release.version,
                    "curl_release_date": release.release_date,
                    "nixpkgs_commit": match.commit if match else "",
                    "nixpkgs_commit_date": match.commit_date if match else "",
                    # "nixpkgs_package_path": match.path if match else "",
                }
            )


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Extract curl releases and find corresponding nixpkgs commits "
            "by scanning the curl package expression history."
        )
    )

    parser.add_argument(
        "-o",
        "--output",
        default="curl_nixpkgs_from_expression.csv",
        help="Output CSV file",
    )

    parser.add_argument(
        "--repo-dir",
        default="./nixpkgs",
        help="Local nixpkgs clone directory",
    )

    parser.add_argument(
        "--git-ref",
        default="origin/master",
        help="Git ref to scan, e.g. origin/master, origin/nixos-25.11, master",
    )

    parser.add_argument(
        "--pick",
        choices=["first", "last"],
        default="first",
        help=(
            "Use the first or last nixpkgs commit where a curl version appears. "
            "Default: first"
        ),
    )

    args = parser.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    output_path = Path(args.output).resolve()

    print("[+] Fetching curl release list", file=sys.stderr)
    curl_html = fetch_html(CURL_RELEASES_URL)
    curl_releases = extract_curl_releases(curl_html)

    ensure_nixpkgs_repo(repo_dir)

    nixpkgs_versions = build_nixpkgs_version_map(
        repo_dir=repo_dir,
        git_ref=args.git_ref,
        package_paths=CURL_PACKAGE_PATHS,
        pick=args.pick,
    )

    write_csv(output_path, curl_releases, nixpkgs_versions)

    matched = sum(1 for r in curl_releases if r.version in nixpkgs_versions)
    missing = len(curl_releases) - matched

    print(f"[+] Wrote: {output_path}")
    print(f"[+] curl releases: {len(curl_releases)}")
    print(f"[+] matched nixpkgs versions: {matched}")
    print(f"[+] missing nixpkgs versions: {missing}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())