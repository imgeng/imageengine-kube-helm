# Google Cloud (GKE)

ImageEngine Kube on Google Kubernetes Engine with `provider: gke`.

## Recommended cluster

- **GKE Standard, Kubernetes 1.34+** (chart minimum is 1.30). GKE Autopilot also works but constrains pod resource shapes — verify the chart's defaults pass Autopilot validation before committing to it.
- Worker nodes (x86-64 only — ImageEngine's arm64/Axion build is still experimental, so don't put nodes on `c4a`/`t2a`):
  - `n2-standard-4` (4 vCPU / 16 GiB) for general use; better single-thread performance than `e2`.
  - `c4-standard-4` for processor pools needing more CPU per pod.
  - `e2-standard-4` for cost-sensitive deployments.
- At least 3 nodes across 3 zones so the chart's topology-spread is meaningful.

See [SIZING.md](../SIZING.md) for traffic-tier sizing.

## What `provider: gke` configures for you

- **Storage class:** `standard-rwo` (the GKE Persistent Disk CSI default — Balanced PD).
- **Ingress class:** `gce` (the built-in GKE Ingress controller, which provisions a Google Cloud HTTP(S) Load Balancer).
- **External DNS provider:** `google` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

- `standard-rwo` is the default and is fine for most deployments.
- For higher OSC IO performance, consider `premium-rwo` (PD-SSD) or one of the **Hyperdisk** classes:

  ```yaml
  objectStorageCache:
    persistence:
      storageClass: hyperdisk-balanced     # provisionable IOPS and throughput
      size: "1Ti"
  ```

  Available Hyperdisk classes (require GKE 1.26+, plus the `pd.csi.storage.gke.io` driver):
  - `hyperdisk-balanced` — modern performance default for stateful workloads.
  - `hyperdisk-throughput` — higher sustained throughput for sequential workloads.
  - `hyperdisk-extreme` — highest IOPS for latency-sensitive workloads.
  - `hyperdisk-balanced-high-availability` — multi-zone replication (requires GKE 1.33+).

## LoadBalancer (the edge Service)

GKE's cloud controller creates a Google Cloud Load Balancer for `Service type: LoadBalancer` automatically. Useful annotations:

```yaml
service:
  type: LoadBalancer
  annotations:
    cloud.google.com/load-balancer-type: "External"
    networking.gke.io/internal-load-balancer-allow-global-access: "true"   # if internal
```

GKE picks the LB name from the Service name; there's no separate "name" annotation to set.

Combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs.

## Ingress options

Three reasonable choices:

1. **GCE Ingress (default preset)** — uses Google's HTTP(S) Load Balancer. Pairs well with Google-managed certificates.
2. **Gateway API** — mature on GKE 1.35.2+ (the GKE Gateway controller passes core conformance tests as of v1.5). An alternative to GCE Ingress, especially if you've standardized on Gateway API across the cluster. Leave `ingress.enabled: false` and create your own `Gateway` + `HTTPRoute` resources pointing at the chart's `*-edge` Service.
3. **Self-managed `ingress-nginx`** — install `ingress-nginx` and override:
   ```yaml
   ingress:
     enabled: true
     className: nginx
     hosts:
       - images.example.com
   ```

## TLS

- **GCE Ingress:** use [Google-managed certificates](https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs) — create a `ManagedCertificate` resource and reference it via the `networking.gke.io/managed-certificates` annotation on the Ingress.
- **Gateway API:** pair Gateway with `Certificate` resources; cert-manager works with Gateway API too.
- **nginx-ingress:** cert-manager with the DNS-01 solver pointed at Cloud DNS, or HTTP-01 if your hostname already resolves to the LB.

## Workload Identity

**Workload Identity Federation for GKE** is the current way to give cluster pods access to Google Cloud resources (Cloud DNS for cert-manager / ExternalDNS, Cloud Storage for the fetcher's optional GCS origins, etc.). Bind a Google Service Account to a Kubernetes ServiceAccount via the `iam.gke.io/gcp-service-account` annotation.

GKE 1.33.0-gke.2248000+ also offers **managed workload identities** (Google-managed workload identity pool, certificates issued via Certificate Authority Service) — a next-gen path that removes a lot of the manual binding setup. Worth investigating for new deployments.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) on GKE uses Workload Identity Federation to call Cloud DNS. Bind a service account with `roles/dns.admin` to the ExternalDNS pod and it picks up Ingress / Gateway hosts automatically.

## Sample minimal values

```yaml
provider: gke

ingress:
  enabled: true
  hosts:
    - images.example.com

objectStorageCache:
  persistence:
    storageClass: hyperdisk-balanced     # better OSC IO than the default
    size: "1Ti"

processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
