# Custom / Self-Managed Kubernetes

For Kubernetes clusters you run yourself: bare metal, on-premise, hybrid, self-managed VMs (kubeadm / k3s / RKE2 / Talos), private clouds (OpenStack), or any cloud-VM-based cluster that isn't using one of the supported managed-Kubernetes offerings.

`provider: custom` is the chart's default. With it, the chart applies no cloud-specific presets and falls back to:

- `storageClass: standard`
- `ingressClass: nginx`
- No extra Service or ingress annotations

You're responsible for telling the chart what storage class to actually use, what ingress class is actually installed, and so on. This doc walks you through the typical baseline.

## What you'll need to install yourself

A self-managed cluster usually doesn't ship with the cloud niceties that the managed offerings bundle. Most likely you'll need:

1. **A LoadBalancer implementation** (only if you use the chart's default `service.type: LoadBalancer`). On bare metal there's no cloud controller to satisfy a `Service type: LoadBalancer`, so the service sits in `<pending>` forever. The standard answer is **MetalLB**. Alternatively, set `service.type: ClusterIP` and front the chart with your own ingress (see Path B below) — no LB controller required.
2. **A storage CSI driver.** The chart needs a `StorageClass` with dynamic provisioning and `ReadWriteOnce` for the OSC PVC. For single-node testing, use **local-path-provisioner**. For a real multi-node deployment, use a real CSI like **Longhorn**, **Rook-Ceph**, **OpenEBS Mayastor**, or your storage vendor's CSI.
3. **(Optional) An ingress controller.** Only needed if you want hostname-based routing or TLS at the ingress layer instead of just exposing the LB IP. **ingress-nginx** is the standard answer.

The rest of this doc covers two common deployment shapes built on these.

## Path A — MetalLB only (LoadBalancer Service exposed directly)

Simplest setup: MetalLB hands a public IP to the chart's edge Service, and you point your DNS at that IP. No ingress involved.

### Install MetalLB

Latest stable is **MetalLB 0.15.3** as of early 2026. Follow the [official install instructions](https://metallb.io/installation/). With Helm:

```bash
helm repo add metallb https://metallb.github.io/metallb
helm install metallb metallb/metallb --namespace metallb-system --create-namespace
```

The 0.15.x line ships several improvements worth knowing about:

- **NetworkPolicy support** in the chart.
- **`ConfigurationState` CRD** that surfaces config errors instead of swallowing them.
- **frrk8s backend** for BGP — better than the legacy `frr` backend if you're doing BGP, including unnumbered BGP peering.
- Layer 2 mode now works correctly when memberlist is disabled.

Define an `IPAddressPool` and `L2Advertisement` on a free range of IPs on your LAN:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: imageengine-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.7.200-192.168.7.210
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: imageengine-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - imageengine-pool
```

`kubectl apply -f` it. (For BGP environments, use a `BGPAdvertisement` and `BGPPeer` instead of `L2Advertisement`.)

### Install storage

For a single-node test cluster:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true
```

For multi-node production, install one of:
- **Longhorn** — easiest replicated block storage; good default for small/medium clusters.
- **Rook-Ceph** — heavier, but the right answer if you need object storage too.
- **OpenEBS Mayastor** — modern NVMe-oriented storage; very fast for SSD-backed clusters.
- Your storage vendor's CSI driver.

### ImageEngine values

```yaml
provider: custom

# service.type defaults to LoadBalancer; MetalLB will assign an IP

objectStorageCache:
  persistence:
    storageClass: local-path        # or your real CSI's class
    size: 100Gi

# ingress is off by default — the LB IP is your entry point
```

`helm install`. Once MetalLB hands an IP to the edge Service, point your DNS at it.

## Path B — MetalLB + ingress-nginx (recommended for production)

Better for any deployment that has a real hostname, multiple sites on one LB IP, or wants TLS termination at the ingress layer. MetalLB hands an IP to the **ingress-nginx controller's** Service; ingress-nginx routes per-hostname to ImageEngine's edge Service.

### Install MetalLB

Same as Path A above.

### Install ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

The ingress-nginx controller exposes itself as a `Service type: LoadBalancer`. MetalLB will assign it an IP from your pool. Point DNS for your hostnames at that IP.

### Install storage

Same as Path A.

### ImageEngine values

```yaml
provider: custom

# Set the chart's edge Service to ClusterIP — ingress-nginx is your external entry
service:
  type: ClusterIP

ingress:
  enabled: true
  className: nginx
  hosts:
    - images.example.com
  # Optional: TLS via cert-manager (HTTP-01 works once your hostname resolves to the ingress LB IP)
  # annotations:
  #   cert-manager.io/cluster-issuer: letsencrypt-prod
  # tls:
  #   - secretName: images-example-com-tls
  #     hosts:
  #       - images.example.com

objectStorageCache:
  persistence:
    storageClass: local-path        # or your real CSI's class
    size: 500Gi
```

By setting `service.type: ClusterIP`, the chart's edge Service won't try to grab a MetalLB IP — only the ingress-nginx controller does. Cleaner setup.

## Storage gotchas

- The OSC PVC is `ReadWriteOnce` — pods are pinned to whichever node owns the underlying volume. With **local-path-provisioner**, that means OSC effectively pins to a single node and won't reschedule if that node dies. For production durability use a CSI that replicates across nodes (Longhorn, Rook-Ceph, OpenEBS Mayastor) or accept the single-node failure mode.
- See [SIZING.md](../SIZING.md) for OSC and Varnish sizing — both want significant disk and RAM at non-PoC traffic levels.

## TLS

cert-manager works the same on a self-managed cluster as anywhere else:

- **HTTP-01:** simplest if your hostname resolves to the ingress-nginx LB IP and ports 80/443 are reachable from Let's Encrypt's validation servers.
- **DNS-01:** required if you're behind a private network or if Let's Encrypt can't reach you. Use the cert-manager webhook for whatever DNS provider you actually use.

## Network egress checklist

Worker nodes need outbound access to:

- `docker.scientiamobile.com` (image pull).
- `https://control-api.imageengine.io` (origin config API).
- `wss://emitter.eleven45.net:443` (config and purge emitter).
- Your customer origins (whatever the fetcher will pull from).

If you're behind a strict firewall or HTTP proxy, allow-list those before installing.

## Sample minimal values

```yaml
provider: custom

service:
  type: ClusterIP

ingress:
  enabled: true
  className: nginx
  hosts:
    - images.example.com

objectStorageCache:
  persistence:
    storageClass: local-path
    size: "500Gi"

processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80

identity:
  PROVIDER: on-prem
  REGION: rack-1
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues, including the LoadBalancer-pending case.
