#!/usr/bin/env python3
"""Check image tags in rendered manifests.

Project images (repository name boa-*) must use an immutable sha-<40 hex> tag.
Mutable tags on third-party images are reported as warnings only.
usage: check-image-tags.py <rendered-dir> [<rendered-dir> ...]
"""
import os
import pathlib
import re
import sys

import yaml

SHA_TAG = re.compile(r"^sha-[0-9a-f]{40}$")
MUTABLE = {"latest", "dev", "main", "master", "release", "stable", "staging", "prod", "production"}


def images(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "image" and isinstance(value, str):
                yield value
            else:
                yield from images(value)
    elif isinstance(node, list):
        for item in node:
            yield from images(item)


def split(ref):
    name = ref.split("@", 1)[0]
    if ":" in name.rsplit("/", 1)[-1]:
        return tuple(name.rsplit(":", 1))
    return name, ""


errors, warnings, project = set(), set(), set()
for root in sys.argv[1:]:
    for path in sorted(pathlib.Path(root).glob("*.yaml")):
        with open(path, encoding="utf-8") as fh:
            refs = {ref for doc in yaml.safe_load_all(fh) for ref in images(doc)}
        for ref in refs:
            repo, tag = split(ref)
            if repo.rsplit("/", 1)[-1].startswith("boa-"):
                project.add(ref)
                if not SHA_TAG.match(tag):
                    errors.add(f"{path.name}: project image must use a sha-<40 hex> tag: {ref}")
            elif not tag or tag in MUTABLE:
                warnings.add(f"{path.name}: third-party image uses a mutable tag: {ref}")

if not project:
    errors.add("no project image (boa-*) found in rendered manifests")

for msg in sorted(warnings):
    print(f"::warning::{msg}")
for msg in sorted(errors):
    print(f"::error::{msg}")

summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as fh:
        fh.write("### Image Tag Policy\n\n")
        fh.write(f"- project images: {len(project)}\n- errors: {len(errors)}\n- warnings: {len(warnings)}\n\n")

print(f"project images: {len(project)}, errors: {len(errors)}, warnings: {len(warnings)}")
sys.exit(1 if errors else 0)
