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
- **Edge LoadBalancer scheme:** `internet-facing`. EKS (especially Auto Mode) provisions `type: LoadBalancer` Services as **internal** by default; the preset adds `service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing` so the edge gets a public address out of the box. Set it back to `internal` via `service.annotations` for private deployments.
- **Ingress class:** `alb` (only used if you set `ingress.enabled: true`). EKS provides the ALB ingress controller natively in Auto Mode, or via the AWS Load Balancer Controller add-on on standard EKS. The preset also defaults the ALB to `internet-facing` with `target-type: ip`.
- **External DNS provider:** `aws` (used by metric tagging only — the chart doesn't deploy ExternalDNS itself).

You can override any of these explicitly — see [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md).

> **This chart assumes your cluster has AWS load balancer support** — i.e. EKS Auto Mode, or standard EKS with the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) installed. That's the norm on modern EKS. If yours has neither, see [No ALB/NLB support](#no-albnlb-support-self-managed-ingress) below.

## Storage

`provider: aws` sets the storage class to **`gp3`** by default — SSD performance with provisionable IOPS/throughput, and the right answer for most deployments. The OSC PersistentVolumeClaim requests this class, so a `gp3` StorageClass must exist in the cluster or the OSC pod stays `Pending`.

> **EKS does not create a `gp3` StorageClass out of the box.** A fresh cluster typically only has a legacy `gp2` class, so you have to create `gp3` yourself (or override the chart to use an existing class). This catches most first-time deployments.

**Option A — create a `gp3` StorageClass (recommended).** The provisioner differs depending on cluster type:

- **EKS Auto Mode** uses the built-in EBS provisioner `ebs.csi.eks.amazonaws.com` (no add-on to install):

  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: gp3
  provisioner: ebs.csi.eks.amazonaws.com
  volumeBindingMode: WaitForFirstConsumer
  allowVolumeExpansion: true
  parameters:
    type: gp3
  ```

- **Standard EKS** uses the **AWS EBS CSI driver** managed add-on (provisioner `ebs.csi.aws.com`). Enable the add-on first (EKS console, `eksctl`, or Terraform), then create the same StorageClass with `provisioner: ebs.csi.aws.com`.

Apply it with `kubectl apply -f gp3-storageclass.yaml` before (or right after) `helm install`. Optionally make it the cluster default by adding the `storageclass.kubernetes.io/is-default-class: "true"` annotation.

**Option B — reuse an existing class.** If you'd rather use the class your cluster already has (e.g. the default `gp2`), override the preset:

```yaml
objectStorageCache:
  persistence:
    storageClass: gp2
```

**Other notes:**

- For very high traffic deployments where OSC is the bottleneck, consider `io2` (provisioned IOPS) or instance-store-backed nodes for OSC pods.
- `WaitForFirstConsumer` binding (as above) is recommended so the volume is created in the same AZ as the pod that mounts it.

## Exposing the edge — two paths

There are two ways to give the edge a public address. **You only need one.** The default (and simplest) is the LoadBalancer Service; the Ingress is opt-in.

### Path 1 — LoadBalancer Service / NLB (default, recommended)

This is what you get out of the box: the edge Service is `type: LoadBalancer`, and `provider: aws` adds the `internet-facing` scheme so it's publicly reachable. On EKS Auto Mode (or standard EKS with the AWS Load Balancer Controller) this provisions a Network Load Balancer; no Ingress controller and no extra config required.

Leave `ingress.enabled: false` (the default) and you're done. If you want to tune the NLB further — a stable name, IP targets, cross-zone balancing — add the modern annotation set:

```yaml
service:
  type: LoadBalancer
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-name: imageengine-prod
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing   # already set by the aws preset
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
```

For internal-only access, override the scheme back to `internal` and combine with `service.loadBalancerSourceRanges` to lock down inbound CIDRs:

```yaml
service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
```

> Without the AWS Load Balancer Controller (and not on Auto Mode), a plain `type: LoadBalancer` falls back to the legacy in-tree provider, which creates a **Classic Load Balancer** (deprecated but functional). Adding `aws-load-balancer-type: external` forces a modern NLB, but **only works if the controller is installed** — otherwise no load balancer is created at all.

### Path 2 — ALB Ingress

If you want hostname-based routing, native AWS WAF integration, or ACM-managed certificates, use an ALB Ingress instead. With `provider: aws` the ingress class already defaults to `alb` and the ALB is already set to `internet-facing` / `target-type: ip`, so the minimal config is:

```yaml
service:
  type: ClusterIP          # ALB fronts everything; no LB on the Service

ingress:
  enabled: true
  hosts:
    - images.example.com
  # className defaults to "alb" via the provider preset
  # annotations default to scheme: internet-facing + target-type: ip
```

Switch the Service to `ClusterIP` so you don't pay for an NLB *and* an ALB. Add more ALB annotations as needed, e.g.:

```yaml
ingress:
  annotations:
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: <acm-arn>
```

> **ALB health checks:** the ALB health-checks the edge target and expects a 2xx. Until a matching origin config exists, the edge may answer `/` with a 403 and the ALB will mark targets unhealthy. Point the health check at a path the edge always answers, e.g. `alb.ingress.kubernetes.io/healthcheck-path: /healthz` (or your configured probe path).

### No ALB/NLB support (self-managed ingress)

If your cluster has neither EKS Auto Mode nor the AWS Load Balancer Controller, install [`ingress-nginx`](https://kubernetes.github.io/ingress-nginx/) yourself and override the class explicitly:

```yaml
service:
  type: ClusterIP

ingress:
  enabled: true
  className: nginx          # override the aws preset's "alb" default
  hosts:
    - images.example.com
```

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

The smallest config for a publicly reachable deployment — `provider: aws` alone gives you an internet-facing NLB (Path 1), so you don't even need to touch `service` or `ingress`:

```yaml
provider: aws

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

If you'd rather front the edge with an ALB Ingress (Path 2), swap the exposure to:

```yaml
provider: aws

service:
  type: ClusterIP

ingress:
  enabled: true
  hosts:
    - images.example.com
  # className "alb" + internet-facing ALB come from the provider preset
```

## Next

- [GETTING_STARTED.md](../GETTING_STARTED.md) — install steps.
- [CUSTOMIZATIONS.md](../CUSTOMIZATIONS.md) — every override you might want.
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — common issues and fixes.
