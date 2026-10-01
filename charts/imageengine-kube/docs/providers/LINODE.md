# Akamai Linode (LKE)

ImageEngine Kube on Akamai's Linode Kubernetes Engine (LKE) with `provider: linode`.

LKE is Akamai's managed Kubernetes offering. The product name is still "Linode Kubernetes Engine" and the chart's preset value remains `linode` (because the storage class, CCM annotation prefix, and CLI tooling all still use the `linode-` namespace), but Akamai is the parent brand. Akamai's CDN and edge footprint pairs naturally with image-delivery workloads.

## Recommended cluster

- **LKE, Kubernetes 1.33+** (chart minimum is 1.30).
- Worker nodes: arm64 and x86-64 are both fully supported, and the chart's images are multi-arch. **Where Linode offers arm64 plans, prefer them** because arm64 gives the best price/performance. Otherwise use these x86-64 plans:
  - `g6-dedicated-4` (4 vCPU / 8 GiB Dedicated CPU) for production. **Dedicated CPU plans are strongly preferred** over Shared because the processor is CPU-bound during cache misses.
  - `g6-dedicated-8` (8 vCPU / 16 GiB) for processor pools at higher traffic tiers.
- At least 3 nodes for the chart's topology-spread to be meaningful.
- Consider **LKE Enterprise** if you need an HA control plane SLA, etcd backups, and access to **Premium NodeBalancers** (better throughput than the standard tier).

See [SIZING.md](../SIZING.md) for traffic-tier guidance.

## What `provider: linode` configures for you

- **Storage class:** `linode-block-storage-retain` (Linode Block Storage CSI; `retain` keeps the volume on PVC deletion, the safer default for OSC).
- **Ingress class:** `nginx`.
- **External DNS provider:** `linode` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

- `linode-block-storage-retain` is the default. If you'd prefer the volume to be deleted when the PVC is deleted, override to `linode-block-storage`.
- Linode Block Storage volumes range from **10 GB to 10,000 GB (~10 TiB)** per volume. Plan OSC sizing accordingly.

## LoadBalancer (the edge Service)

The Linode CCM provisions a NodeBalancer for any `Service type: LoadBalancer`. Useful annotations:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/linode-loadbalancer-label: imageengine-prod
    service.beta.kubernetes.io/linode-loadbalancer-throttle: "20"   # connections per second per IP
```

LKE Enterprise customers can request a **Premium NodeBalancer** (different SKU, higher throughput) — see Akamai's docs for the additional annotations.

Combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs.

**Client IP:** with a LoadBalancer Service, `provider: linode` has the NodeBalancer send a PROXY v2 header (`linode-loadbalancer-default-proxy-protocol: v2`) and the edge read it, so fair-share admission and the access log see real client addresses. LKE nodes have public IPs, so allow the NodePort range only from the NodeBalancer with a Cloud Firewall; see [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip), including the two-step upgrade for existing installs.

## HTTP/3

Terminating HTTP/3 on an ingress controller or gateway behind a NodeBalancer isn't supported: clients get HTTP/2 and HTTP/1.1 there. NodeBalancers can't yet carry HTTP/3 in a way that keeps fair-share admission working. We tested this on October 1, 2026:

- **UDP needs a Premium NodeBalancer, and is a beta.** Standard NodeBalancers, which the CCM creates by default, have no UDP. UDP on Premium NodeBalancers is a beta API feature that Akamai has to enable for your account. Without it, the API answers `UDP protocol option is not allowed`, even for a Premium NodeBalancer.
- **No PROXY protocol over UDP.** NodeBalancers send PROXY headers only on TCP, and the CCM rejects a Service that combines `linode-loadbalancer-default-proxy-protocol` with a UDP port (`proxy protocol [v2] is not supported for UDP`). Whether a UDP NodeBalancer keeps the client's source address is still unconfirmed. If it doesn't, every HTTP/3 visitor shares one fair-share bucket.
- **No TCP and UDP on the same port.** The CCM matches NodeBalancer configs by port number only, so a Service with both `443/TCP` and `443/UDP` (which HTTP/3 needs) fails to sync.

To offer HTTP/3 to your clients on Linode today, terminate it at a CDN in front of the cluster and use `clientIP.mode: forwardedFor` on the cluster side. See [How do I serve HTTP/3?](../CUSTOMIZATIONS.md#how-do-i-serve-http3) for the general requirements.

## Ingress

The `nginx` preset assumes you've installed `ingress-nginx` via its own Helm chart. The NodeBalancer fronts either the chart's edge Service directly (when `service.type: LoadBalancer`) or the ingress-nginx controller's Service (when `service.type: ClusterIP` and `ingress.enabled: true`).

```yaml
ingress:
  enabled: true
  hosts:
    - images.example.com
```

## TLS

Most common: cert-manager with the DNS-01 solver pointed at the Linode DNS API. cert-manager doesn't ship a built-in Linode provider — you'll need a community webhook (search `cert-manager-webhook-linode` on GitHub). Alternatively, HTTP-01 via your nginx ingress works fine once your hostname resolves to the NodeBalancer.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) for Linode uses a Personal Access Token with read/write permissions on Domains. Once installed, it picks up Ingress hosts and creates the right records in your Linode-managed zone.

## Sample minimal values

```yaml
provider: linode

ingress:
  enabled: true
  hosts:
    - images.example.com

objectStorageCache:
  persistence:
    size: "500Gi"

processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80

identity:
  region: us-east   # provider label follows the top-level `provider: linode`
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
