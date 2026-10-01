# Azure (AKS)

ImageEngine Kube on Azure Kubernetes Service with `provider: azure`.

## Recommended cluster

- **AKS, Kubernetes 1.34+** AKS deprecated 1.32 in early 2026, and the chart minimum is 1.30.
- Worker nodes: **arm64 (Cobalt) is recommended where your region offers it.** It's fully supported and gives the best price/performance. The chart's images are multi-arch, so no extra configuration is needed.
  - `Standard_D4ps_v6` (Cobalt 100, 4 vCPU / 16 GiB) as the default.
  - `Standard_D4ps_v5` (Ampere Altra) in regions without Cobalt.
  - `Standard_D2ps_v6` for PoC clusters.
  - x86-64 is also fully supported if arm64 isn't available: `Standard_D4s_v5` (or `Standard_D4s_v6` if available in your region) as the default, `Standard_D2s_v5` for PoC.
- At least 3 nodes across 3 AZs (in regions that support AZs) so the chart's topology-spread is meaningful.
- Use the **Azure Disk CSI driver** (the in-tree driver was removed in k8s 1.26) and the **Azure CNI** networking plugin.

See [SIZING.md](../SIZING.md) for traffic-tier specific guidance.

## What `provider: azure` configures for you

- **Storage class:** `managed-csi-premium` (Premium SSD via the Azure Disk CSI driver). On multi-AZ clusters with k8s 1.29+, AKS automatically backs this with **Premium ZRS** (Zone-Redundant Storage); single-AZ clusters get LRS.
- **Ingress class:** none. AKS's controllers each use their own class, so set `ingress.className` for the one you run; without it, the cluster's default IngressClass serves the Ingress.
- **External DNS provider:** `azure` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

The chart picks `managed-csi-premium` (Premium SSD) by default — the right answer for OSC, which is on the hot path for every cache hit. Other options if your needs differ:

- `managed-csi` — Standard SSD. Cheaper, lower IOPS. Fine for development; will likely bottleneck OSC at production traffic.
- `managed-csi-premium-v2` — Premium SSD v2. Lets you provision IOPS and throughput independently of size. Good for very large OSC volumes.

If your cluster was upgraded from a pre-1.29 version and you expected ZRS, check the actual SKU with `kubectl get pv <pv-name> -o jsonpath='{.spec.csi.volumeAttributes.skuName}'`. Pre-existing clusters may keep LRS until redeployed.

## LoadBalancer (the edge Service)

Azure's cloud controller provisions a Standard SKU Azure Load Balancer for `Service type: LoadBalancer`. Useful annotations:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-resource-group: my-aks-rg
    service.beta.kubernetes.io/azure-pip-name: imageengine-prod-pip   # use a pre-created static public IP
    service.beta.kubernetes.io/azure-pip-tags: "env=prod,team=images"
```

Combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs.

**Client IP:** Azure's Standard Load Balancer can't send PROXY headers, so with a LoadBalancer Service `provider: azure` sets `externalTrafficPolicy: Local` and the edge uses the connection's source address. Behind an Ingress controller, a Gateway or Application Gateway, the edge trusts the `X-Forwarded-For` entry they append instead. See [How do I preserve the client IP?](../CUSTOMIZATIONS.md#how-do-i-preserve-the-client-ip).

## Ingress options

The chart's default LoadBalancer Service needs no Ingress controller. If you want hostname routing in the cluster, three reasonable choices:

1. **AKS application routing add-on** — Microsoft installs and manages the controller. Its class is `webapprouting.kubernetes.azure.com`, so set `ingress.className` to that. The add-on is built on ingress-nginx, which was retired upstream in March 2026, so check Microsoft's support plans for it before you standardize on it.
2. **A Gateway API implementation** (for example Envoy Gateway or Istio) — leave `ingress.enabled: false` and attach the chart's `HTTPRoute` to your Gateway; see [How do I route through a Gateway?](../CUSTOMIZATIONS.md#how-do-i-route-through-a-gateway-gateway-api).
3. **Application Gateway Ingress Controller (AGIC)** — Azure-native, integrates with Application Gateway / WAF. Override:
   ```yaml
   service:
     type: ClusterIP

   ingress:
     enabled: true
     className: azure-application-gateway
     hosts:
       - images.example.com
   ```

## TLS

- **AGIC:** terminate TLS on Application Gateway with a certificate from Key Vault — see Microsoft's AGIC docs for the annotation syntax.
- **Application routing, or your own controller or Gateway:** cert-manager with the DNS-01 solver pointed at Azure DNS (use Workload Identity for credentials), or HTTP-01 once your hostname resolves to the LB.

## Workload Identity (replacing AAD Pod Identity)

**Azure Workload Identity** (federated workload identity using OIDC) is the current path for giving cluster pods access to Azure resources — Key Vault, Azure DNS, Azure Storage for the fetcher's optional origins, etc. The legacy AAD Pod Identity is **deprecated** and removed from new AKS clusters.

Enable Workload Identity on your AKS cluster (`--enable-workload-identity --enable-oidc-issuer`), then federate a Microsoft Entra ID app to a Kubernetes ServiceAccount and add the `azure.workload.identity/client-id` annotation. Used by ExternalDNS, cert-manager, and the fetcher when pulling from private Azure Storage.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) on Azure uses Workload Identity bound to a managed identity with `DNS Zone Contributor` on your zone. Once installed, it picks up Ingress hosts automatically.

## Sample minimal values

With no `service` or `ingress` settings, the edge gets a public Azure Load Balancer.

```yaml
provider: azure

objectStorageCache:
  persistence:
    size: "500Gi"
    # storageClass left empty -> uses the chart's azure preset (managed-csi-premium)

processor:
  autoscaling:
    enabled: true
    minReplicas: 3
    maxReplicas: 16
    targetCPUUtilizationPercentage: 80

identity:
  region: eastus         # provider label follows the top-level `provider: azure`
  availabilityZone: eastus-1
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
