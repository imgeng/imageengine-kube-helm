# Supply-chain security

Every ImageEngine container image this chart deploys is **cosign-signed**, ships a
**Software Bill of Materials (SBOM)** and **SLSA build provenance**, and is built behind a
vulnerability-scan gate. You can verify — cryptographically — that the images you run are
genuinely ImageEngine's and have not been tampered with, and you can inspect exactly what is
inside them.

This is separate from, and complementary to, the **chart** signature: the Helm `.tgz` is
GPG-signed (see [Verifying the chart signature](../README.md#verifying-the-chart-signature-optional)).
Charts are signed with GPG; images are signed with cosign — two independent keys.

## The images

All customer-facing images are published to `docker.scientiamobile.com/iekube`:

| Component | Image |
|---|---|
| Edge | `docker.scientiamobile.com/iekube/imageengine-frontend.edge` |
| Varnish | `docker.scientiamobile.com/iekube/imageengine-frontend.varnish` |
| Backend | `docker.scientiamobile.com/iekube/imageengine-backend.server` |
| Origin Fetcher | `docker.scientiamobile.com/iekube/imageengine-origin-fetcher.server` |
| Processor | `docker.scientiamobile.com/iekube/imageengine-processor.server` |
| Origin Cache (OSC) | `docker.scientiamobile.com/iekube/object-storage-cache.server` |

The exact tags deployed are pinned in the chart's `images:` map in `values.yaml`.

## 1. Verify image signatures (cosign)

Images are signed with [cosign](https://github.com/sigstore/cosign) using a dedicated
ECDSA-P256 key, distinct from the GPG chart key. The public key is published at
**<https://kube.imageengine.io/cosign.pub>**.

```bash
# One-time: fetch our image-signing public key
curl -fsSLO https://kube.imageengine.io/cosign.pub

# Verify any image, by tag or digest
cosign verify --key cosign.pub \
  docker.scientiamobile.com/iekube/imageengine-backend.server:<tag>
```

`cosign verify` exits non-zero if the signature is missing or does not match the key. The
signature covers the multi-arch image index **and** every per-platform manifest.

For reference, the public key (`cosign.pub`):

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsDbPIydo2RfXKklXnKcGUzQULgyz
T4iyWSnENnDxoyk2QjP/Li8FGrQ3eNq8HewHce8NO0YY80rJEoPPLz/V4g==
-----END PUBLIC KEY-----
```

## 2. Inspect the SBOM and provenance

Each image carries an SPDX SBOM and SLSA build provenance, attached in the registry as
attestations. No key is needed to read them:

```bash
REF=docker.scientiamobile.com/iekube/imageengine-backend.server:<tag>

# SBOM (SPDX JSON) — the full package inventory, per platform
docker buildx imagetools inspect "$REF" --format '{{ json .SBOM }}'

# SLSA provenance — how/where/when the image was built
docker buildx imagetools inspect "$REF" --format '{{ json .Provenance }}'
```

Feed the SBOM into your own tooling (Trivy, Grype, Syft) for inventory or policy checks.

## 3. Vulnerability scanning

Every image is built through a [Trivy](https://trivy.dev/) gate that **fails the build on any
fixable CRITICAL or HIGH** OS/library vulnerability; unfixable findings are tracked and
time-boxed. Nothing is required of you — it is part of how the images are produced — but you
are welcome to scan them yourself:

```bash
trivy image docker.scientiamobile.com/iekube/imageengine-backend.server:<tag>
```

## 4. (Optional) Enforce signatures in your cluster

If you run a policy engine you can require that only signed ImageEngine images are admitted.
Both examples below key on the same `cosign.pub`. **Start in audit/warn mode** and switch to
enforce once you have confirmed every running image verifies.

### Kyverno

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-imageengine-images
spec:
  validationFailureAction: Audit    # flip to Enforce once green
  background: false
  rules:
    - name: verify-iekube-signatures
      match:
        any:
          - resources:
              kinds: [Pod]
      verifyImages:
        - imageReferences:
            - "docker.scientiamobile.com/iekube/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsDbPIydo2RfXKklXnKcGUzQULgyz
                      T4iyWSnENnDxoyk2QjP/Li8FGrQ3eNq8HewHce8NO0YY80rJEoPPLz/V4g==
                      -----END PUBLIC KEY-----
```

### Sigstore policy-controller

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: imageengine-signed
spec:
  images:
    - glob: "docker.scientiamobile.com/iekube/**"
  authorities:
    - key:
        data: |
          -----BEGIN PUBLIC KEY-----
          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEsDbPIydo2RfXKklXnKcGUzQULgyz
          T4iyWSnENnDxoyk2QjP/Li8FGrQ3eNq8HewHce8NO0YY80rJEoPPLz/V4g==
          -----END PUBLIC KEY-----
```

Scope the policy to `iekube/*` (exactly what we sign); do not broaden it to images we do not
publish, or admission will block them.

---

If you hit a signature or SBOM problem, or suspect an image is not what it claims to be, open
an issue on this repository.
