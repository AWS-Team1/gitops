#!/usr/bin/env python3
"""Parse every tracked YAML file. Helm chart templates are skipped because they are Go templates."""
import subprocess
import sys

import yaml

files = subprocess.run(
    ["git", "ls-files", "-z", "--", "*.yaml", "*.yml"],
    check=True, capture_output=True, text=True,
).stdout.split("\0")
files = [f for f in files if f and "/templates/" not in f]

failed = 0
for path in files:
    try:
        with open(path, encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))
    except (yaml.YAMLError, UnicodeDecodeError) as exc:
        failed += 1
        print(f"::error file={path}::invalid YAML: {exc}")

print(f"checked {len(files)} YAML files, {failed} invalid")
sys.exit(1 if failed else 0)
