#!/usr/bin/env bash
#
# Pin every image in the chart's values.yaml to its digest. For each
# images.<name> it looks up the digest the tag points to, checks that the image
# carries a valid cosign signature from the ImageEngine image-signing key, and
# rewrites the value as "<tag>@sha256:...". It refuses (and changes nothing) if
# any image is unsigned or cannot be resolved.
#
#   scripts/pin-digests.sh [values.yaml]   (default: charts/imageengine-kube/values.yaml)
#
# Run it after bumping a tag in images:, and commit the result. A value that is
# already pinned is re-resolved from its tag, so re-running after a tag bump
# replaces the old digest. COSIGN_PUB as in verify-images.sh. Needs python3
# with PyYAML, cosign, and crane or docker (buildx).
set -euo pipefail

values="${1:-charts/imageengine-kube/values.yaml}"
command -v cosign >/dev/null || { echo "error: cosign not found on PATH" >&2; exit 2; }

key="${COSIGN_PUB:-}"
if [ -z "$key" ]; then
  key=$(mktemp)
  trap 'rm -f "$key"' EXIT
  curl -fsSL https://kube.imageengine.io/cosign.pub -o "$key"
fi

digest_of() {
  if command -v crane >/dev/null; then
    crane digest "$1"
  else
    docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}'
  fi
}

# name, repository and tag for each images.<name>, from values.yaml. Read
# through a variable, not a process substitution, so a parser failure (missing
# PyYAML, bad YAML, an unknown image) stops the script instead of leaving
# "rows" short.
parsed=$(python3 - "$values" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
repo_of = {
    "edge": v["edge"]["image"]["repository"],
    "varnish": v["varnish"]["image"]["repository"],
    "backend": v["backend"]["image"]["repository"],
    "fetcher": v["fetcher"]["image"]["repository"],
    "processor": v["processor"]["image"]["repository"],
    "osc": v["objectStorageCache"]["image"]["repository"],
}
for name, value in v["images"].items():
    if name not in repo_of:
        sys.exit("error: no repository known for images.%s" % name)
    print(name, repo_of[name], str(value).split("@", 1)[0])
PY
) || { echo "error: could not read images: from $values" >&2; exit 1; }
mapfile -t rows <<<"$parsed"
[ -n "$parsed" ] || { echo "error: no images: entries in $values" >&2; exit 1; }

pins=()
failed=0
for row in "${rows[@]}"; do
  read -r name repo tag <<<"$row"
  ref="$repo:$tag"
  if ! digest=$(digest_of "$ref" 2>/dev/null) || [[ "$digest" != sha256:* ]]; then
    echo "NOT FOUND   $ref" >&2
    failed=1
    continue
  fi
  if ! cosign verify --key "$key" "$repo@$digest" >/dev/null 2>&1; then
    echo "NOT SIGNED  $ref ($digest)" >&2
    failed=1
    continue
  fi
  echo "ok          $ref -> $digest"
  pins+=("$name $tag@$digest")
done
if [ "$failed" -ne 0 ]; then
  echo "refusing to pin: every image must exist and be signed. values.yaml is unchanged." >&2
  exit 1
fi

# Rewrite only the values under the top-level images: block, keeping comments.
python3 - "$values" "${pins[@]}" <<'PY'
import re, sys
path, pins = sys.argv[1], dict(p.split(" ", 1) for p in sys.argv[2:])
lines = open(path).read().split("\n")
inside = False
for i, line in enumerate(lines):
    if re.match(r"^images:\s*$", line):
        inside = True
        continue
    if inside and line and not line.startswith(" "):
        break
    m = re.match(r'^(\s+)(\w+):\s*"?([^"\s#]+)"?(.*)$', line) if inside else None
    if m and m.group(2) in pins:
        lines[i] = '%s%s: "%s"%s' % (m.group(1), m.group(2), pins[m.group(2)], m.group(4))
open(path, "w").write("\n".join(lines))
PY
echo "pinned ${#pins[@]} image(s) in $values"
