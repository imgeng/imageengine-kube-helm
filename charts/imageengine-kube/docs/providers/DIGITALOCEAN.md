# DigitalOcean (DOKS)

ImageEngine Kube on DigitalOcean Kubernetes with `provider: digitalocean`.

## Recommended cluster

- **DOKS, Kubernetes 1.33+** (chart minimum is 1.30).
- Worker nodes: arm64 and x86-64 are both fully supported, and the chart's images are multi-arch. **Where DO offers arm64 droplet plans, prefer them** because arm64 gives the best price/performance. Otherwise use these x86-64 plans:
  - `s-4vcpu-8gb-amd` (4 vCPU / 8 GiB AMD EPYC) as the default — AMD nodes give better price/performance for image processing than Intel on DO.
  - `s-2vcpu-4gb` for PoC clusters.
- At least 3 nodes for the chart's topology-spread to be meaningful.
- VPC-native networking (the default for new DOKS clusters) unlocks Gateway API support — see the Ingress section below.

See [SIZING.md](../SIZING.md) for traffic-tier sizing — OSC wants a fast, large disk and Varnish wants generous RAM.

## What `provider: digitalocean` configures for you

- **Storage class:** `do-block-storage` (DigitalOcean Block Storage CSI). The CSI driver is bundled with every DOKS cluster.
- **Ingress class:** `nginx`.
- **External DNS provider:** `digitalocean` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

- `do-block-storage` is the default and is correct for most deployments — SSD-backed network volumes.
- DO Block Storage volumes range from **1 GiB to 16 TiB per volume**. Plan OSC sizing accordingly.
- Volumes are regional; OSC pods can only be scheduled on nodes in the same datacenter region as the volume.

## LoadBalancer (the edge Service)

DigitalOcean's cloud controller provisions a managed DO Load Balancer for any `Service type: LoadBalancer`. Useful annotations:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/do-loadbalancer-name: imageengine-prod
    service.beta.kubernetes.io/do-loadbalancer-protocol: "http"
    service.beta.kubernetes.io/do-loadbalancer-size-unit: "2"
```

`size-unit` is the modern way to scale the LB tier — bump it for higher throughput. Each unit costs roughly $12/month.

Combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs.

**Client IP:** with a LoadBalancer Service, `provider: digitalocean` enables PROXY protocol on the load balancer (`do-loadbalancer-enable-proxy-protocol: "true"`) and the edge reads it, so fair-share admission and the access log see real client addresses. DOKS nodes have public IPs, so allow the NodePort range only from the load balancer with a Cloud Firewall; see [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip), including the two-step upgrade for existing installs.

## Ingress options

Two reasonable choices:

1. **Self-managed `ingress-nginx` (default preset)** — install via the upstream Helm chart. The DO LB ends up in front of the ingress-nginx controller's Service.
2. **Gateway API** — enabled by default on DOKS clusters with VPC-native networking running k8s 1.33+. When you create a Gateway, DOKS auto-provisions a DO Network Load Balancer. This is an alternative to the chart's `Ingress` resource. To use it, leave `ingress.enabled: false` and create your own `Gateway` + `HTTPRoute` resources pointing at the chart's `*-edge` Service. Useful when you've standardized on Gateway API across the cluster.

## TLS

Easiest path: cert-manager with the DNS-01 solver pointed at the DO DNS API. Note that cert-manager's DigitalOcean DNS provider is **not built into cert-manager** — you'll need a community webhook (search `cert-manager-webhook-digitalocean` on GitHub). The setup is to deploy the webhook, define a `ClusterIssuer` with the webhook as the solver, then add the `cert-manager.io/cluster-issuer` annotation to your ingress and set the `tls:` block as in [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

Alternatively, terminate TLS at the DO Load Balancer using a DO-managed certificate via the `service.beta.kubernetes.io/do-loadbalancer-certificate-id` annotation.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) for DigitalOcean uses a personal access token. Once installed, it picks up Ingress hosts and creates A records in your DO-managed zone automatically.

## Sample minimal values

```yaml
provider: digitalocean

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
  region: nyc3   # provider label follows the top-level `provider: digitalocean`
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
