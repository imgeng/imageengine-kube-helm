# Custom / Self-Managed Kubernetes

For Kubernetes clusters you run yourself: bare metal, on-premise, hybrid, self-managed VMs (kubeadm / k3s / RKE2 / Talos), private clouds (OpenStack), or any cloud-VM-based cluster that isn't using one of the supported managed-Kubernetes offerings.

`provider: custom` is the chart's default. With it, the chart applies no cloud-specific presets and falls back to:

- `storageClass: standard`
- No ingress class: the cluster's default IngressClass serves the Ingress
- No extra Service or ingress annotations

You're responsible for telling the chart what storage class to actually use, what ingress class is actually installed, and so on. This doc walks you through the typical baseline.

Both arm64 (e.g. Ampere-based servers) and x86-64 nodes are fully supported, and the chart's images are multi-arch. If you're choosing hardware, arm64 gives the best price/performance.

## What you'll need to install yourself

A self-managed cluster usually doesn't ship with the cloud niceties that the managed offerings bundle. Most likely you'll need:

1. **A LoadBalancer implementation** (only if you use the chart's default `service.type: LoadBalancer`). On bare metal there's no cloud controller to satisfy a `Service type: LoadBalancer`, so the service sits in `<pending>` forever. The standard answer is **MetalLB**. Alternatively, set `service.type: ClusterIP` and front the chart with your own ingress (see Path B below) — no LB controller required.
2. **A storage CSI driver.** The chart needs a `StorageClass` with dynamic provisioning and `ReadWriteOnce` for the OSC PVC. For single-node testing, use **local-path-provisioner**. For a real multi-node deployment, use a real CSI like **Longhorn**, **Rook-Ceph**, **OpenEBS Mayastor**, or your storage vendor's CSI.
3. **(Optional) An ingress controller or Gateway.** Only needed if you want hostname-based routing or TLS at the ingress layer instead of just exposing the LB IP. **Traefik** is a common choice (k3s ships it already). A Gateway API implementation, such as Envoy Gateway or Cilium, works too, through the chart's `httpRoute` (see [How do I route through a Gateway?](../CUSTOMIZATIONS.md#how-do-i-route-through-a-gateway-gateway-api)). Don't start a new cluster on ingress-nginx: it was retired upstream in March 2026.

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

## Path B — MetalLB + an Ingress controller (recommended for production)

Better for any deployment that has a real hostname, multiple sites on one LB IP, or wants TLS termination at the ingress layer. MetalLB hands an IP to the **Ingress controller's** Service, and the controller routes per hostname to ImageEngine's edge Service. The steps below use Traefik.

### Install MetalLB

Same as Path A above.

### Install Traefik

Skip this on k3s, which already runs Traefik.

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set service.spec.externalTrafficPolicy=Local
```

Traefik exposes itself as a `Service type: LoadBalancer`, and MetalLB assigns it an IP from your pool. Point DNS for your hostnames at that IP. Traefik's chart also makes its `traefik` IngressClass the cluster default, which is what the chart's Ingress uses when `ingress.className` is empty.

### Install storage

Same as Path A.

### ImageEngine values

```yaml
provider: custom

# Set the chart's edge Service to ClusterIP — the Ingress controller is your external entry
service:
  type: ClusterIP

ingress:
  enabled: true
  className: traefik             # or leave empty for the cluster's default IngressClass
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

By setting `service.type: ClusterIP`, the chart's edge Service won't try to grab a MetalLB IP — only the Ingress controller does. Cleaner setup.

**Client IP:** the edge trusts the `X-Forwarded-For` entry the Ingress controller appends, so the controller must see the client's address itself. That is why Traefik is installed with `externalTrafficPolicy=Local` (MetalLB then announces only from nodes running a Traefik pod). On Path A the edge uses the connection's source address, which is the client only with `service.externalTrafficPolicy: Local`. A load balancer of your own that speaks PROXY protocol (HAProxy, an F5, Envoy) can send it to the edge instead: set `clientIP.mode: proxyProtocol`. See [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip).

## Storage gotchas

- The OSC PVC is `ReadWriteOnce` — pods are pinned to whichever node owns the underlying volume. With **local-path-provisioner**, that means OSC effectively pins to a single node and won't reschedule if that node dies. For production durability use a CSI that replicates across nodes (Longhorn, Rook-Ceph, OpenEBS Mayastor) or accept the single-node failure mode.
- See [SIZING.md](../SIZING.md) for OSC and Varnish sizing — both want significant disk and RAM at non-PoC traffic levels.

## TLS

cert-manager works the same on a self-managed cluster as anywhere else:

- **HTTP-01:** simplest if your hostname resolves to the Ingress controller's LB IP and ports 80/443 are reachable from Let's Encrypt's validation servers.
- **DNS-01:** required if you're behind a private network or if Let's Encrypt can't reach you. Use the cert-manager webhook for whatever DNS provider you actually use.

## Network egress checklist

Worker nodes need outbound access to:

- `docker.scientiamobile.com` (image pull).
- `https://control-api.imageengine.io` (origin config API).
- `wss://emitter.eleven45.net:443` (config and purge emitter).
- Your image origins (whatever the fetcher will pull from).

If you're behind a strict firewall or HTTP proxy, allow-list those before installing.

## Sample minimal values

```yaml
provider: custom

service:
  type: ClusterIP

ingress:
  enabled: true
  className: traefik             # or leave empty for the cluster's default IngressClass
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
  provider: on-prem
  region: rack-1
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues, including the LoadBalancer-pending case.
