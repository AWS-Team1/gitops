#!/usr/bin/env bash
# Render every kustomization under a target directory and stop at the first failure.
# usage: kustomize-build-all.sh <target-dir> <output-dir>
# KUSTOMIZE_CMD overrides the build command (default: "kustomize build").
set -Eeuo pipefail

TARGET=${1:?usage: $0 <target-dir> <output-dir>}
OUT=${2:?usage: $0 <target-dir> <output-dir>}
read -r -a BUILD <<< "${KUSTOMIZE_CMD:-kustomize build}"

[[ -d "$TARGET" ]] || { echo "target directory not found: $TARGET" >&2; exit 2; }
mkdir -p "$OUT"

mapfile -t dirs < <(
  find "$TARGET" -type f \( -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \) \
    -exec dirname {} \; | sort -u
)
(( ${#dirs[@]} > 0 )) || { echo "no kustomization found under $TARGET" >&2; exit 1; }

for dir in "${dirs[@]}"; do
  file="$OUT/$(tr '/' '_' <<< "$dir").yaml"
  if ! "${BUILD[@]}" "$dir" > "$file"; then
    echo "::error::kustomize build failed: $dir"
    exit 1
  fi
  echo "rendered $dir ($(grep -c '^kind:' "$file" || true) resources)"
done
