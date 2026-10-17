#!/usr/bin/env python3
"""Pin every image in the chart's values.yaml to its digest.

For each images.<name> it looks up the digest the tag points to, checks that
the image carries a valid cosign signature from the ImageEngine image-signing
key, and rewrites the value as "<tag>@sha256:...". It refuses (and changes
nothing) if any image is unsigned or cannot be resolved.

    scripts/pin-digests.py [values.yaml]   (default: charts/imageengine-kube/values.yaml)

Run it after bumping a tag in images:, and commit the result. A value that is
already pinned is re-resolved from its tag, so re-running after a tag bump
replaces the old digest. COSIGN_PUB as in verify-images.sh. Needs PyYAML,
cosign, and crane or docker (buildx).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import yaml

COSIGN_PUB_URL = "https://kube.imageengine.io/cosign.pub"

# images.<name> -> the values path of the component that runs it.
REPOSITORY_OF = {
    "edge": ("edge", "image", "repository"),
    "varnish": ("varnish", "image", "repository"),
    "backend": ("backend", "image", "repository"),
    "fetcher": ("fetcher", "image", "repository"),
    "processor": ("processor", "image", "repository"),
    "osc": ("objectStorageCache", "image", "repository"),
}


def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def run(args):
    """Run a command; return its stdout stripped, or None if it failed."""
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def digest_of(ref):
    if shutil.which("crane"):
        return run(["crane", "digest", ref])
    return run(["docker", "buildx", "imagetools", "inspect", ref,
                "--format", "{{.Manifest.Digest}}"])


def signed(key, ref):
    return run(["cosign", "verify", "--key", key, ref]) is not None


def images_to_pin(values):
    """(name, repository, tag) for each images.<name>; the tag has any
    existing @digest stripped so a pinned value is re-resolved."""
    rows = []
    for name, value in values["images"].items():
        if name not in REPOSITORY_OF:
            fail("error: no repository known for images.%s" % name)
        repo = values
        for key in REPOSITORY_OF[name]:
            repo = repo[key]
        rows.append((name, repo, str(value).split("@", 1)[0]))
    return rows


def rewrite(path, pins):
    """Replace the values under the top-level images: block, keeping comments
    and everything else byte for byte."""
    lines = open(path).read().split("\n")
    inside = False
    for i, line in enumerate(lines):
        if re.match(r"^images:\s*$", line):
            inside = True
            continue
        if inside and line and not line.startswith(" "):
            break
        if not inside:
            continue
        m = re.match(r'^(\s+)(\w+):\s*"?([^"\s#]+)"?(.*)$', line)
        if m and m.group(2) in pins:
            lines[i] = '%s%s: "%s"%s' % (m.group(1), m.group(2), pins[m.group(2)], m.group(4))
    open(path, "w").write("\n".join(lines))


def main():
    values_path = sys.argv[1] if len(sys.argv) > 1 else "charts/imageengine-kube/values.yaml"
    if not shutil.which("cosign"):
        fail("error: cosign not found on PATH", 2)
    if not shutil.which("crane") and not shutil.which("docker"):
        fail("error: neither crane nor docker found on PATH", 2)

    try:
        with open(values_path) as f:
            values = yaml.safe_load(f)
        rows = images_to_pin(values)
    except (OSError, yaml.YAMLError, KeyError, TypeError, AttributeError) as e:
        fail("error: could not read images: from %s: %s" % (values_path, e))
    if not rows:
        fail("error: no images: entries in %s" % values_path)

    key = os.environ.get("COSIGN_PUB")
    tmp = None
    if not key:
        tmp = tempfile.NamedTemporaryFile(suffix=".pub")
        with urllib.request.urlopen(COSIGN_PUB_URL) as resp:
            tmp.write(resp.read())
        tmp.flush()
        key = tmp.name

    pins = {}
    failed = False
    for name, repo, tag in rows:
        ref = "%s:%s" % (repo, tag)
        digest = digest_of(ref)
        if not digest or not digest.startswith("sha256:"):
            print("NOT FOUND   %s" % ref, file=sys.stderr)
            failed = True
            continue
        if not signed(key, "%s@%s" % (repo, digest)):
            print("NOT SIGNED  %s (%s)" % (ref, digest), file=sys.stderr)
            failed = True
            continue
        print("ok          %s -> %s" % (ref, digest))
        pins[name] = "%s@%s" % (tag, digest)
    if tmp:
        tmp.close()
    if failed:
        fail("refusing to pin: every image must exist and be signed. %s is unchanged." % values_path)

    rewrite(values_path, pins)
    print("pinned %d image(s) in %s" % (len(pins), values_path))


if __name__ == "__main__":
    main()
