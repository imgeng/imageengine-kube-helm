# ImageEngine Kube

ImageEngine Kube deploys the [ImageEngine](https://imageengine.io) image-optimization and delivery platform inside your own Kubernetes cluster — device-aware image transformation, multi-tier caching, and edge delivery, all running on infrastructure you control. See [imageengine.io/why-kube/](https://imageengine.io/why-kube/) for what the platform does and why you might want to self-host it.

The chart is published to the Helm repository at `https://kube.imageengine.io`. Source and issue tracking live at [`imgeng/imageengine-kube-helm`](https://github.com/imgeng/imageengine-kube-helm) on GitHub.

> **Active trial or subscription required.** A single ImageEngine API key is used for both runtime authentication (origin configs, device data, purges) and for pulling the chart's container images from `docker.scientiamobile.com`. You cannot install the chart without one. Sign up for a trial or subscription at [imageengine.io](https://imageengine.io) to get your key.

For anything beyond the quick-start below, see the docs linked in [Where to next](#where-to-next) at the bottom of this page.

## Quick start

1. **Add the Helm repository**
   ```bash
   helm repo add imageengine https://kube.imageengine.io
   helm repo update
   ```

2. **Create the two required secrets** (the chart does not create these for you — they must exist before `helm install`):
   ```bash
   kubectl create secret generic ie-kube-api-key \
     --from-literal=KEY=<your-api-key>

   kubectl create secret docker-registry ie-kube-image-pull \
     --docker-server=https://docker.scientiamobile.com/v2/ \
     --docker-username=<your-email> \
     --docker-password=<your-api-key> \
     --docker-email=<your-email>
   ```
   You need an **active** ImageEngine Kube trial or subscription to create the API key.

3. **Write a minimal `imageengine-values.yaml`** — `provider:` is the only must-have:
   ```yaml
   provider: aws

   ingress:
     enabled: true
     hosts:
       - images.example.com
   ```

4. **Install**
   ```bash
   helm install imageengine imageengine/imageengine-kube -f imageengine-values.yaml
   ```

5. **Verify** — pods should settle within a minute or two, and the LoadBalancer service gets an external IP from your cloud provider:
   ```bash
   kubectl get pods
   kubectl get svc -l app=imageengine-kube
   ```

For the full step-by-step including a smoke-test `curl`, see [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

## Verifying the chart signature (optional)

Every published chart `.tgz` is GPG-signed. A matching `.prov` provenance file is published alongside each release, and our public key is available at [kube.imageengine.io/pubkey.asc](https://kube.imageengine.io/pubkey.asc).

**Fingerprint:** `C3A5 5111 ED91 FEDE 4A82 A4B4 4632 6606 0957 C4B3`

To verify a chart before installing:

```bash
# Import the key into a dedicated legacy-format keyring (one-time setup)
# The gnupg-ring: prefix forces the classic OpenPGP keyring format that
# Helm's --verify can read. Without it, GPG 2.1+ creates a keybox (KBX)
# file that Helm rejects with "tag byte does not have MSB set".
curl -fsSL https://kube.imageengine.io/pubkey.asc \
   | gpg --no-default-keyring --no-options \
         --keyring gnupg-ring:$HOME/.gnupg/imageengine-pubring.gpg --import

# Confirm the fingerprint matches what's published above
gpg --no-default-keyring --no-options \
   --keyring gnupg-ring:$HOME/.gnupg/imageengine-pubring.gpg \
   --fingerprint releases@imageengine.io

# Pull, verify, and install in one step
helm install imageengine imageengine/imageengine-kube \
  --verify --keyring ~/.gnupg/imageengine-pubring.gpg \
  -f imageengine-values.yaml
```

`helm install --verify` (or `helm upgrade --verify`) will fail if the chart's signature doesn't match. To verify without installing, use `helm pull --verify imageengine/imageengine-kube --keyring ~/.gnupg/imageengine-pubring.gpg`.

## Provider presets

Setting `provider:` auto-configures the right storage class and ingress class for that platform. Explicit values in your file always take precedence. Cloud-LB-specific annotations (LB name, NLB type, scheme, etc.) live under `service.annotations` — see your provider doc ([AWS](docs/providers/AWS.md), [Azure](docs/providers/AZURE.md), [DigitalOcean](docs/providers/DIGITALOCEAN.md), [GKE](docs/providers/GKE.md), [Linode](docs/providers/LINODE.md), or [self-managed](docs/providers/CUSTOM.md)) for the right keys.

| Provider | Storage Class | Ingress Class | Doc |
|----------|--------------|---------------|-----|
| `aws` | `gp3` | `nginx` | [docs/providers/AWS.md](docs/providers/AWS.md) |
| `azure` | `managed-csi-premium` | `nginx` | [docs/providers/AZURE.md](docs/providers/AZURE.md) |
| `digitalocean` | `do-block-storage` | `nginx` | [docs/providers/DIGITALOCEAN.md](docs/providers/DIGITALOCEAN.md) |
| `gke` | `standard-rwo` | `gce` | [docs/providers/GKE.md](docs/providers/GKE.md) |
| `linode` | `linode-block-storage-retain` | `nginx` | [docs/providers/LINODE.md](docs/providers/LINODE.md) |
| `custom` | `standard` | `nginx` | [docs/providers/CUSTOM.md](docs/providers/CUSTOM.md) — bare metal, on-premise, self-managed |

## Upgrading

```bash
helm repo update
helm upgrade imageengine imageengine/imageengine-kube -f imageengine-values.yaml
```

To pin a specific chart version: `helm upgrade ... --version 1.2.3 -f imageengine-values.yaml`. List available versions with `helm search repo imageengine/imageengine-kube --versions`.

## Where to next

- [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md) — full first-deployment walkthrough.
- [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) — Kubernetes version, storage, network, and compute minimums.
- [docs/SIZING.md](docs/SIZING.md) — recommended footprints for low / medium / high traffic.
- [docs/CUSTOMIZATIONS.md](docs/CUSTOMIZATIONS.md) — replicas, autoscaling, ingress, TLS, OSC sizing, Varnish tuning, and the rest.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common issues and fixes.
- Platform-specific guidance: [AWS](docs/providers/AWS.md), [Azure](docs/providers/AZURE.md), [DigitalOcean](docs/providers/DIGITALOCEAN.md), [GKE](docs/providers/GKE.md), [Linode](docs/providers/LINODE.md), [self-managed / bare metal](docs/providers/CUSTOM.md).
