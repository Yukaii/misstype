"""Calculate a release tag from stable vMAJOR.MINOR.PATCH tags; never mutate git."""

import argparse
import re
import subprocess


STABLE_TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def next_tag(tags, bump):
    versions = [tuple(map(int, match.groups())) for tag in tags
                if (match := STABLE_TAG.fullmatch(tag))]
    major, minor, patch = max(versions, default=(0, 0, 0))
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    elif bump == "patch":
        patch += 1
    else:
        raise ValueError(f"Unknown release bump: {bump}")
    return f"v{major}.{minor}.{patch}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bump", choices=("major", "minor", "patch"))
    args = parser.parse_args()
    tags = subprocess.check_output(["git", "tag", "--list"], text=True).splitlines()
    print(next_tag(tags, args.bump))


if __name__ == "__main__":
    main()
