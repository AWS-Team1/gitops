#!/usr/bin/env bash
# Render the canonical EKS desired-state snapshot without contacting a cluster.
set -Eeuo pipefail

OUTPUT=${1:-}
[[ -n "$OUTPUT" ]] || {
  echo "usage: $0 OUTPUT_MANIFEST" >&2
  exit 2
}

command -v kubectl >/dev/null || {
  echo "ERROR: kubectl is required for kustomize rendering." >&2
  exit 1
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
CANONICAL_TARGET="$REPO_ROOT/03_manifests/eks"
OUTPUT=$(cd -- "$(dirname -- "$OUTPUT")" && pwd)/$(basename -- "$OUTPUT")
TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE"' EXIT

kubectl kustomize "$CANONICAL_TARGET" > "$TEMP_FILE"
[[ -s "$TEMP_FILE" ]] || {
  echo "ERROR: canonical AWS render is empty." >&2
  exit 1
}
grep -q '^apiVersion:' "$TEMP_FILE" || {
  echo "ERROR: rendered output contains no Kubernetes resources." >&2
  exit 1
}

# Deployment artifacts may contain SecretProviderClass references, but never a
# Kubernetes Secret or obvious inline credential/private-key material.
if grep -Eq '^kind:[[:space:]]+Secret[[:space:]]*$' "$TEMP_FILE"; then
  echo "ERROR: rendered artifact contains a Kubernetes Secret." >&2
  exit 1
fi
if grep -Eq 'AKIA[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$TEMP_FILE"; then
  echo "ERROR: rendered artifact contains credential-like material." >&2
  exit 1
fi

mv -- "$TEMP_FILE" "$OUTPUT"
trap - EXIT
echo "Rendered canonical AWS desired state: $OUTPUT"
