# Getting Started

This guide walks you through your first ImageEngine Kube deployment end-to-end. Plan on about 10 minutes once you have a cluster ready.

If you just want a one-page reference, the chart [README.md](../README.md) has a quick-start. This document is the slow, step-by-step version.

## Prerequisites

You need:

- A Kubernetes cluster you can install into (1.27+ recommended). See [REQUIREMENTS.md](REQUIREMENTS.md) for hard minimums.
- `kubectl` configured for that cluster.
- `helm` 3.x.
- An **active** ImageEngine Kube subscription or trial. Without it you cannot create the secrets in step 2.

## Step 1 — Pick your provider

ImageEngine Kube ships with presets for the major managed Kubernetes services. Setting `provider:` in your values file auto-configures the right storage class, ingress class, and load balancer annotations for that platform. Pick the doc that matches your cluster:

- [providers/AWS.md](providers/AWS.md)
- [providers/AZURE.md](providers/AZURE.md)
- [providers/DIGITALOCEAN.md](providers/DIGITALOCEAN.md)
- [providers/GKE.md](providers/GKE.md)
- [providers/LINODE.md](providers/LINODE.md)
- [providers/CUSTOM.md](providers/CUSTOM.md) — for bare metal, on-premise, or any other self-managed cluster.

Your provider doc will note any platform-specific prep (LB controller, storage CSI, etc.) that you should do before continuing.

## Step 2 — Create the namespace and the two required secrets

These examples install everything into a dedicated `imageengine` namespace. Create it first so the secrets land in the same place the chart installs into:

```bash
kubectl create namespace imageengine
```

The chart does **not** create the secrets for you. Both must exist in the install namespace before `helm install` runs.

### `ie-kube-api-key` (your ImageEngine API key)

Create the API key in the ImageEngine Control Panel and then:

```bash
kubectl create secret generic ie-kube-api-key -n imageengine \
  --from-literal=KEY=<your-api-key>
```

### `ie-kube-image-pull` (Docker registry credentials)

```bash
kubectl create secret docker-registry ie-kube-image-pull -n imageengine \
  --docker-server=https://docker.scientiamobile.com/v2/ \
  --docker-username=<your-email> \
  --docker-password=<your-api-key> \
  --docker-email=<your-email>
```

The Docker password is the same value as the API key.

## Step 3 — Add the Helm repository

```bash
helm repo add imageengine https://kube.imageengine.io
helm repo update
```

List available chart versions:

```bash
helm search repo imageengine/imageengine-kube --versions
```

## Step 4 — Write a minimal values file

Create `imageengine-values.yaml`. The only thing you really need is `provider:` plus, optionally, your hostnames if you want an Ingress in front of the LoadBalancer:

```yaml
provider: aws

ingress:
  enabled: true
  hosts:
    - images.example.com
```

That's it. Every other setting has a sensible default. When you're ready to scale or customize further, see [SIZING.md](SIZING.md) and [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md).

## Step 5 — Install

```bash
helm install imageengine-kube imageengine/imageengine-kube \
  --namespace imageengine \
  -f imageengine-values.yaml
```

Watch the pods come up:

```bash
kubectl get pods -n imageengine -w
```

You should see seven deployments (edge, varnish, backend, fetcher, processor, osc, rsyslog) settle into `Running` within a minute or two. The OSC pod is the slowest because it has to bind a PersistentVolume.

Get the external IP of the edge load balancer:

```bash
kubectl get svc -n imageengine -l 'app=imageengine-kube,tier=edge'
```

This returns just the `*-edge` Service. With the default `service.type: LoadBalancer`, it will get an external IP from your cloud provider — that may take a minute. If it stays `<pending>` for more than a couple minutes, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Step 6 — Smoke test

Pick a real image URL on a real origin you control, and a hostname that you've already configured in the ImageEngine Control Panel (so the edge knows how to look up its origin config). Then:

```bash
EXTERNAL_IP=<the IP from step 5>
DOMAIN=<your-imageengine-host>     # e.g. abc12345.cdn.imgeng.in
ACCEPT="accept: image/avif,image/webp"

# Basic request
curl -I --resolve "$DOMAIN:80:$EXTERNAL_IP" \
  "http://$DOMAIN/path/to/your/image.jpg"

# Confirm ImageEngine is processing the response
curl -sSI --resolve "$DOMAIN:80:$EXTERNAL_IP" \
  -H "$ACCEPT" \
  -H "imgeng-audit: true" \
  "http://$DOMAIN/path/to/your/image.jpg?imgeng=/w_100" \
  | grep -i ^imgeng
```

The `imgeng-audit: true` header asks the edge to emit `imgeng-*` debug headers describing what device it detected, which transformations it applied, and which cache layer served the response. If you see those headers, you're done.

## Next steps

- [REQUIREMENTS.md](REQUIREMENTS.md) — confirm your cluster meets the hard minimums.
- [SIZING.md](SIZING.md) — pick a sensible footprint for your traffic volume.
- [CUSTOMIZATIONS.md](CUSTOMIZATIONS.md) — replicas, autoscaling, ingress, TLS, OSC sizing, and so on.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — when something doesn't work.

