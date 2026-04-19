# AWS (EKS)

ImageEngine Kube on Amazon EKS with `provider: aws`.

## Recommended cluster

- **EKS, Kubernetes 1.33+** (1.30 is the chart minimum; running on a still-supported upstream release saves you the EKS extended-support surcharge).
- Cluster mode: **EKS Standard** for full control, or **EKS Auto Mode** if you want AWS to manage node provisioning, scaling, and add-ons (Karpenter, AWS LB Controller, EBS CSI driver) for you.
- Worker nodes (x86-64 only — ImageEngine's arm64/Graviton build is still experimental, so don't put nodes on `m7g`/`c7g`):
  - `m7i.xlarge` (Sapphire Rapids, 4 vCPU / 16 GiB) as the modern default.
  - `m6i.xlarge` (Ice Lake, 4 vCPU / 16 GiB) as the conservative baseline.
  - `c7i.xlarge` for processor pools that need more CPU per pod.
  - PoC clusters can run on `t3.large`.
- At least 3 nodes in 3 AZs so the chart's topology-spread constraint is meaningful.
- **Karpenter** is the standard cluster autoscaler in 2026 — install it (or use EKS Auto Mode, which embeds it) and let it provision nodes on demand based on pod requests.

See [SIZING.md](../SIZING.md) for traffic-tier specific guidance — most importantly, OSC wants a fast disk and Varnish wants a lot of RAM.

## What `provider: aws` configures for you

- **Storage class:** `gp3` (general-purpose SSD; preferred over `gp2` for performance and cost).
- **Ingress class:** `nginx`.
- **External DNS provider:** `aws` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

## Storage

- `gp3` is the default and is the right answer for most deployments. It gives you SSD performance with provisionable IOPS and throughput.
- For very high traffic deployments where OSC is the bottleneck, consider `io2` (provisioned IOPS) or instance-store-backed nodes for OSC pods.
- Make sure the **AWS EBS CSI driver** is installed on your cluster — it's a managed add-on in EKS (enable it in the EKS console or via `eksctl`). On EKS Auto Mode it's included by default.

## LoadBalancer (the ImageEngine Edge Service)

The chart's edge Service defaults to `type: LoadBalancer`. Without further configuration, the legacy in-tree provider creates a Classic Load Balancer — which AWS has deprecated. **Install the [AWS Load Balancer Controller (LBC)](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)** (it's an EKS managed add-on, and is included in EKS Auto Mode) and add the modern annotation set so it provisions an NLB instead:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-name: imageengine-prod
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
```

If you want internal-only access, drop the `scheme` annotation (defaults to internal) and combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs.

## Ingress options

You have two reasonable choices:

1. **nginx-ingress (default preset)** — install the `ingress-nginx` controller. The chart's Ingress resource will route hostnames to the edge service.
2. **AWS Load Balancer Controller (ALB) for ingress** — set `ingress.className: alb` and add ALB-specific annotations:
   ```yaml
   service:
     type: ClusterIP        # ALB ingress fronts everything; no LB on the Service

   ingress:
     enabled: true
     className: alb
     annotations:
       alb.ingress.kubernetes.io/scheme: internet-facing
       alb.ingress.kubernetes.io/target-type: ip
       alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
     hosts:
       - images.example.com
   ```
   ALB ingress is nicer if you want native AWS WAF integration and ACM-managed certificates.

## TLS

Two common paths:

- **ALB + ACM:** request a certificate in ACM, then add `alb.ingress.kubernetes.io/certificate-arn: <arn>` to the ingress annotations.
- **nginx + cert-manager + Route53:** install cert-manager, configure a `ClusterIssuer` with the DNS-01 solver pointed at Route53.

## IAM for cluster-side workloads (ExternalDNS, cert-manager, fetcher S3)

EKS supports two IAM-for-pods mechanisms:

- **EKS Pod Identity** (`eks.amazonaws.com/pod-identity-association`) — the modern, recommended path for new clusters. Attach an IAM role directly to a Kubernetes ServiceAccount via the EKS API, no annotations or OIDC trust dance required.
- **IAM Roles for Service Accounts (IRSA)** — the older mechanism, still fully supported. Uses the cluster's OIDC provider and a `role-arn` annotation on the ServiceAccount.

Both work for ExternalDNS, cert-manager, and the fetcher's optional S3-origin credentials. Prefer Pod Identity on greenfield clusters.

## DNS

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns) for AWS needs `route53:ChangeResourceRecordSets`, `route53:GetChange`, and `route53:ListHostedZonesByName` permissions on the role attached via Pod Identity / IRSA. Once installed and pointed at your hosted zone, it picks up Ingress hosts (or `external-dns.alpha.kubernetes.io/hostname` annotations) and creates/updates the right records automatically.

## Sample minimal values

```yaml
provider: aws

service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-name: imageengine-prod
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip

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
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
