# CloudKitchen — Kubernetes & GitOps: Definitive Reference

> Companion to `cloudkitchen-infra/AWS_CLOUD_REFERENCE.md`. That document covers the
> **AWS cloud** pillar; **this** document covers the **Kubernetes / GitOps** pillar —
> everything that runs *inside* the EKS cluster and the GitOps machinery that puts it
> there. Together they describe the whole platform.

---

## 0. How To Use This Document (instructions for an AI assistant)

You are reading the authoritative description of CloudKitchen's Kubernetes layer.
When answering a question about this project's K8s/GitOps:

1. **Prefer this document over generic Kubernetes knowledge.** Where general K8s
   behaviour and this document differ, this document describes what is actually
   deployed. Generic knowledge fills gaps; it does not override specifics here.
2. **Every claim here is grounded in real files** in the `cloudkitchen-gitops` repo
   (Helm chart under `helm/cloudkitchen/`, `argocd/`, `bootstrap/`, `monitoring/`,
   and the lifecycle scripts). Section 20 maps concepts → files.
3. **Names are exact.** Namespace `production`, chart `cloudkitchen`, Gateway
   `cloudkitchen-gateway`, GatewayClass `kgateway`, Secret `cloudkitchen-secrets`,
   ConfigMap `cloudkitchen-config`, ArgoCD app `cloudkitchen`. Account
   `256603361470`, region `ap-south-1`.
4. **Mind the per-deploy vs static distinction.** IRSA role ARNs and image repo
   names are stable; image tags, NLB DNS, LB hostnames, and Cognito IDs regenerate
   on every destroy/recreate.
5. **The four highest-value "gotchas"** (each has bitten this project and each has a
   section): (a) Gateway API `PathPrefix` matches per path-*segment* (§6.4, §16);
   (b) CloudFront must be re-pointed at the new NLB after every recreate (§7, §16);
   (c) External Secrets serves `external-secrets.io/v1`, not `v1beta1` (§8, §16);
   (d) the AI pod must opt out of CloudWatch OTEL auto-instrumentation (§11.4, §16).

---

## 1. Overview

### 1.1 What the Kubernetes layer is
CloudKitchen runs its four backend microservices as containers on **Amazon EKS**.
The cluster is provisioned by Terraform (`cloudkitchen-infra`), but **what runs on
it** is defined declaratively in the `cloudkitchen-gitops` repo and reconciled onto
the cluster by **ArgoCD**. Nobody runs `kubectl apply` by hand for the application —
they `git push`, and ArgoCD syncs.

### 1.2 The three repositories
The project is split into three repos so each layer has a single responsibility:

| Repo | Owns | Key contents |
|------|------|--------------|
| `cloudkitchen-app` | source code + Dockerfiles for the 4 services + SPA | `menu-service/`, `order-service/`, `auth-service/`, `ai-recommender/`, `frontend/`, CI `build.yml` |
| `cloudkitchen-infra` | AWS infrastructure (Terraform) | `eks.tf`, `irsa.tf`, `addons.tf`, … |
| `cloudkitchen-gitops` | **everything Kubernetes** | Helm chart, ArgoCD app, platform bootstrap, monitoring, deploy/destroy scripts |

This document is about the third repo.

### 1.3 What runs in the cluster (and what does not)
- **In the cluster (pods):** `menu`, `order`, `auth`, `ai`. Plus platform components:
  ArgoCD, kgateway (Envoy), External Secrets Operator, kube-prometheus-stack
  (Prometheus, Grafana, Alertmanager), and the CloudWatch observability agent.
- **NOT in the cluster:** the **frontend** is a static React SPA served from **S3
  via CloudFront** — there is no frontend pod. CloudFront also forwards `/api` and
  `/auth` to the cluster's NLB, so the SPA and the API share one HTTPS origin.

### 1.4 The GitOps mental model (one sentence)
> Git is the desired state; ArgoCD continuously makes the cluster match Git;
> Terraform makes AWS match its own `.tf` files; the only glue between them is the
> NLB DNS name that the second `terraform apply` feeds to CloudFront.

---

## 2. Cluster Topology

### 2.1 The cluster
- **EKS** control plane, Kubernetes **1.30**, in account `256603361470`, region
  `ap-south-1`. Created in `cloudkitchen-infra/eks.tf`.
- **Managed node group** of `t3.medium` EC2 nodes: desired **3**, min **1**, max
  **5**. Nodes live in the private-app subnets across AZs.
- **EBS CSI driver is intentionally omitted** — the workload is stateless (no
  PersistentVolumeClaims). Prometheus uses ephemeral storage with short retention
  (6h). Persistent data lives in RDS/S3/SQS, outside the cluster.

### 2.2 EKS add-ons (managed by Terraform)
- `vpc-cni` — pod networking (each pod gets a VPC IP).
- `coredns` — in-cluster DNS (`menu.production.svc.cluster.local`, etc.).
- `kube-proxy` — Service virtual-IP routing.
- `amazon-cloudwatch-observability` — Container Insights + Application Signals.
  This agent **auto-injects OpenTelemetry** into pods, which is why the AI pod opts
  out (§11.4).

### 2.3 Namespaces (and who lives where)
| Namespace | Contents | Created by |
|-----------|----------|-----------|
| `production` | the 4 app pods, their Services, Gateway, HTTPRoutes, ConfigMap, Secret, ServiceAccounts, NetworkPolicies, RBAC | ArgoCD (`CreateNamespace=true`) |
| `argocd` | ArgoCD server, repo-server, application-controller | `install.sh` |
| `kgateway-system` | kgateway controller + the Envoy data-plane proxy | `install.sh` |
| `external-secrets` | External Secrets Operator controller | `install.sh` |
| `monitoring` | Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics | `install.sh` |
| `amazon-cloudwatch` | CloudWatch observability agent (Container Insights) | EKS add-on |
| `kube-system` | core add-ons (coredns, kube-proxy, vpc-cni) | EKS |

### 2.4 Why these boundaries
Each platform component is isolated in its own namespace so RBAC, NetworkPolicy, and
lifecycle (install/upgrade/delete) are scoped. The app's NetworkPolicy explicitly
allows ingress only from `kgateway-system` (§10.1), so namespace identity is part of
the security model, not just organisation.

---

## 3. The GitOps Model (ArgoCD)

### 3.1 The Application object (`argocd/application.yaml`)
A single ArgoCD `Application` named `cloudkitchen` drives the whole app:

```yaml
spec:
  project: cloudkitchen
  source:
    repoURL: https://github.com/Cloudkitchen007/cloudkitchen-gitops.git
    targetRevision: main
    path: helm/cloudkitchen          # renders the Helm chart
    helm:
      valueFiles: [values.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

What each field means here:
- **`path: helm/cloudkitchen`** — ArgoCD runs `helm template` on the chart and applies
  the result. It is not a raw-manifest app.
- **`automated.prune: true`** — if you delete a resource from Git, ArgoCD deletes it
  from the cluster.
- **`automated.selfHeal: true`** — if the live cluster drifts from Git (e.g. someone
  runs `kubectl edit`), ArgoCD reverts it within ~1 minute. **This is why manual
  `kubectl apply` of a chart resource does not stick** — fix it in Git and push, or
  temporarily pause selfHeal to test (§16, §17).
- **`CreateNamespace=true`** — ArgoCD creates the `production` namespace if absent.
- **`finalizers: [resources-finalizer.argocd.argoproj.io]`** — deleting the
  Application cascades to all its managed resources (used by `destroy.sh`).

### 3.2 The AppProject (`argocd/project.yaml`)
The `cloudkitchen` AppProject scopes what the app may deploy: destination namespace
`production` on the in-cluster API server, with cluster/namespace resource
whitelists currently set to `"*"` (permissive for the demo). `sourceRepos: ["*"]`.
For a production tightening, restrict `sourceRepos` to the gitops repo URL and narrow
the resource whitelists.

### 3.3 The image-tag bump loop (CI ↔ GitOps)
1. A push to `cloudkitchen-app` triggers `build.yml`: lint → test → Semgrep → Trivy
   → build → push to ECR (tags: `:<git-sha>` and `:latest`).
2. The `deploy` job checks out **this** repo (needs `GITOPS_TOKEN`, a fine-grained
   PAT with Contents:write — see §16) and rewrites `global.imageTag` in
   `helm/cloudkitchen/values.yaml` to the new git SHA, then commits/pushes.
3. ArgoCD sees the change and rolls the Deployments to the new image.

`global.imageTag` is therefore the **deployment pointer**: it starts as `latest` but
is normally a commit SHA (immutable, auditable). Example current value in values.yaml:
`a2b81c12f53c3ef39b7bbe369f81d6f1eed822fa`.

### 3.4 Server-side apply for ArgoCD install
`install.sh` installs ArgoCD with `kubectl apply --server-side --force-conflicts`
because the bundled `applicationsets` CRD exceeds the 262 KB client-side
last-applied-annotation limit. Remember this if you ever reinstall ArgoCD by hand.

---

## 4. The Helm Chart (`helm/cloudkitchen`)

### 4.1 Chart metadata
`Chart.yaml`: `name: cloudkitchen`, `version: 0.1.0`, `appVersion: 1.0.0`,
`type: application`. It has no sub-charts (the monitoring stack is a separate
upstream chart installed by `install.sh`, not a dependency here).

### 4.2 values.yaml — the single configuration surface
Top-level keys:
- **`global`** — `region`, `accountId`, `ecrRegistry`, `imageTag`. The ECR registry
  + repo + tag combine into image references via the `cloudkitchen.image` helper.
- **`config`** — STATIC non-secret config (only `hfModel` today). Rendered into the
  `cloudkitchen-config` ConfigMap.
- **`irsa`** — the three deterministic IRSA role ARNs (`ai`, `order`, `eso`). Safe to
  commit because role *names* are fixed in a stable account.
- **`eso`** — Secrets Manager source: `region`, `appSecretName`
  (`cloudkitchen/app/runtime`), `dbSecretName` (`cloudkitchen/db/credentials-new`).
- **`gateway`** — `name`, `className` (`kgateway`), and `lbAnnotations` (the NLB
  annotation propagated to the generated LoadBalancer Service).
- **`services`** — the list that drives Deployments, Services, and HTTPRoutes (§5.1).
- **`resources`** — shared requests/limits applied to every container.

> Historical note: a comment in values.yaml mentions
> `bootstrap/load-runtime-config.sh` injecting the runtime Secret. That script no
> longer exists — **secrets now come from External Secrets Operator** (§8). Treat the
> ESO path as authoritative.

### 4.3 templates/_helpers.tpl
Two named templates:
- `cloudkitchen.image` → `"<ecrRegistry>/<repo>:<imageTag>"`.
- `cloudkitchen.labels` → common labels:
  `app.kubernetes.io/part-of: cloudkitchen` and
  `app.kubernetes.io/managed-by: <Release.Service>`. The `part-of` label is also the
  selector the NetworkPolicy uses to find app pods (§10.1).

### 4.4 The template inventory
| Template | Renders | Section |
|----------|---------|---------|
| `deployment.yaml` | one Deployment per service | §5 |
| `service.yaml` | one ClusterIP Service per service | §6.1 |
| `httproute.yaml` | one HTTPRoute per service | §6.4 |
| `gateway.yaml` | the shared kgateway Gateway | §6.3 |
| `serviceaccount.yaml` | 4 ServiceAccounts (default, ai, order, eso) | §9 |
| `configmap.yaml` | `cloudkitchen-config` | §8.1 |
| `externalsecret.yaml` | SecretStore + ExternalSecret | §8 |
| `networkpolicy.yaml` | default-deny + allow-gateway | §10.1 |
| `rbac.yaml` | Role + RoleBinding | §9.4 |

---

## 5. Workloads (Deployments)

### 5.1 The service list (drives everything)
From `values.yaml.services` — each entry fans out into a Deployment, a Service, and
an HTTPRoute via Helm `range`:

| Service | Image repo | Port | Replicas | ServiceAccount | Notes |
|---------|-----------|------|----------|----------------|-------|
| `menu`  | `cloudkitchen-menu-repo`  | 8080 | 2 | `cloudkitchen-default` | Spring Boot; `/api` catch-all route |
| `order` | `cloudkitchen-order-repo` | 8082 | 2 | `order` | Spring Boot; sends SQS via IRSA |
| `auth`  | `cloudkitchen-auth-repo`  | 8001 | 2 | `cloudkitchen-default` | Spring Boot; `/auth/*` |
| `ai`    | `cloudkitchen-ai-repo`    | 8000 | 1 | `ai` | FastAPI; SQS via IRSA; `disableOtel: true` |

### 5.2 The Deployment template (`deployment.yaml`) field by field
For each service entry the template renders:

- **`replicas`** — from the entry (`default 1`).
- **Pod annotations (conditional)** — if `disableOtel` is set (AI only):
  `instrumentation.opentelemetry.io/inject-python: "false"` (§11.4).
- **`serviceAccountName`** — the entry's `serviceAccount` or `cloudkitchen-default`.
- **Pod `securityContext`** — `runAsNonRoot: true`, `runAsUser/Group/fsGroup`
  (`default 1000`), `seccompProfile: RuntimeDefault`.
- **Container `securityContext`** — `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`.
- **`image`** — via the `cloudkitchen.image` helper; `imagePullPolicy: IfNotPresent`.
- **`envFrom`** — both `configMapRef: cloudkitchen-config` and `secretRef:
  cloudkitchen-secrets`. Every pod gets the full env; each service reads only the
  vars it needs (Spring reads `SPRING_DATASOURCE_*`; AI reads
  `HUGGINGFACEHUB_API_TOKEN`, `SQS_ORDERS_QUEUE_URL`, etc.).
- **Probes** — `readinessProbe` and `livenessProbe` are **TCP socket** checks on the
  service port (`tcpSocket`). Readiness: `initialDelaySeconds 30`, `periodSeconds 10`,
  `failureThreshold 6`. Liveness: `initialDelaySeconds 60`, `periodSeconds 20`.
- **`resources`** — shared block: requests `cpu 100m` / `memory 256Mi`, limit
  `memory 512Mi` (no CPU limit → burstable).

### 5.3 Probe nuance (why JVM startup looks slow, and an AI caveat)
TCP probes pass as soon as the port is *open*. For the Spring services this means a
pod is marked Ready when Tomcat binds — startup logs show ~45–80s before "Started …
Application", and during that window readiness fails with connection-refused, which is
normal warmup, not an error. For the **AI** pod, the TCP port opens before the model
finishes loading, so a brand-new AI pod can be marked Ready slightly before it can
answer — during a rolling update this is the only window where the AI may briefly say
"warming up". An HTTP readiness probe on `/api/health` would close that gap (the AI
service exposes `GET /api/health`).

### 5.4 Rolling updates & availability
Default `RollingUpdate` strategy. For the 2-replica Spring services, old pods serve
while new ones warm up → effectively zero-downtime. For the 1-replica AI service,
`maxSurge` rounds up to 1 and `maxUnavailable` down to 0, so a new AI pod comes up
before the old one is removed (given node capacity), so no hard downtime either.

### 5.5 The frontend is not here
There is deliberately no frontend Deployment/Service. The SPA is built by `deploy.sh`
(`npm run build`) and `aws s3 sync`-ed to the frontend bucket; CloudFront serves it.

---

## 6. In-Cluster & Edge Networking

### 6.1 Services (`service.yaml`)
One **ClusterIP** Service per backend, name = service name, `port = targetPort =`
the container port, selector `app: <name>`. These give stable in-cluster DNS names
(`menu:8080`, `order:8082`, `auth:8001`, `ai:8000`) used by HTTPRoute backendRefs and
for debugging (`kubectl run … curl http://ai:8000/...`).

### 6.2 Gateway API overview
Ingress uses the **Gateway API** (not legacy Ingress). Three resource kinds:
- **GatewayClass** `kgateway` — installed by the kgateway controller; the
  implementation that turns Gateways into real proxies.
- **Gateway** `cloudkitchen-gateway` — one shared HTTP:80 listener; provisions an
  Envoy proxy + a LoadBalancer Service (→ AWS NLB).
- **HTTPRoute** (one per service) — path rules → backend Service.

### 6.3 The Gateway (`gateway.yaml`)
```yaml
spec:
  gatewayClassName: kgateway
  infrastructure:
    annotations:                       # propagated onto the generated LB Service
      service.beta.kubernetes.io/aws-load-balancer-type: nlb
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes: { namespaces: { from: Same } }
```
- `infrastructure.annotations` are copied by kgateway onto the LoadBalancer Service it
  creates, so AWS provisions an internet-facing **NLB** rather than a Classic ELB.
- `allowedRoutes.namespaces.from: Same` — only HTTPRoutes in the *same* namespace
  (`production`) may attach. The Gateway's external address (the NLB DNS) appears in
  `status.addresses[0].value` once provisioned — this is exactly what
  `wire-cloudfront.sh` reads.
- **Production upgrade path** (documented in values.yaml comments): install the AWS
  Load Balancer Controller and switch the annotations to `type: external` +
  `nlb-target-type: ip` + `scheme: internet-facing`. The current in-tree provider
  path needs no controller/IRSA and works out of the box.

### 6.4 HTTPRoutes (`httproute.yaml`) and the per-segment matching gotcha
The template renders one HTTPRoute per service, each with one rule whose `matches`
come from that service's `pathPrefixes`, all pointing at the service's backend.

Current routes:
| Service | pathPrefixes |
|---------|--------------|
| `menu`  | `/api` (catch-all) |
| `order` | `/api/orders` |
| `auth`  | `/auth` |
| `ai`    | `/api/recommend`, `/api/recommend_quick`, `/api/recommend_forecast`, `/api/demand`, `/api/update_user_preferences` |

**Critical:** Gateway API `PathPrefix` matches on **whole path segments**, not string
prefixes. `/api/recommend` matches `/api/recommend` and `/api/recommend/<x>` but
**not** `/api/recommend_quick` (different segment). That is why the AI route must list
`recommend_quick` and `recommend_forecast` explicitly — otherwise those requests fall
through to `menu`'s `/api` catch-all and return a Spring 404, which the frontend shows
as "AI service is warming up". When multiple routes match, the **longest prefix
wins**, so `/api/orders` (order) and `/api/recommend*` (ai) beat `menu`'s `/api`.

### 6.5 The data path inside the cluster
`NLB → Envoy (kgateway data-plane in kgateway-system) → HTTPRoute match → ClusterIP
Service → pod`. The NLB targets the Envoy proxy's node ports; Envoy does the
host/path routing per the Gateway + HTTPRoutes.

---

## 7. End-to-End Ingress (CloudFront → pod) and the recurring rewire

A browser request to the app's single CloudFront URL is split by **path**:

| Path pattern | CloudFront origin | Then |
|--------------|-------------------|------|
| `default` (everything else) | S3 frontend bucket | SPA static files |
| `/api/*` | `eks-api-origin` (the NLB) | Envoy → service → pod |
| `/auth/*` | `eks-api-origin` (the NLB) | Envoy → auth pod |
| `/testimonials/*` | S3 testimonials bucket | uploaded media |

The `eks-api-origin` and the `/api/*` + `/auth/*` cache behaviors are created by
Terraform **only when `var.eks_api_origin` is non-empty** — a value known only after
Kubernetes provisions the NLB. So deployment is two-phase:
1. First `terraform apply` builds everything except the API behaviors.
2. After the Gateway has an NLB address, a **second** `terraform apply
   -var="eks_api_origin=<nlb-dns>"` adds the `/api` + `/auth` behaviors, then the
   CloudFront cache is invalidated.

**Why this recurs:** every destroy/recreate yields a brand-new NLB DNS name, so step 2
must run again. If skipped, CloudFront falls through `/api/menu` to the S3 default
origin and returns `index.html` instead of JSON → **empty menu**; `/api/recommend_*`
fails → **AI "warming up"**. The backend is healthy the whole time. The fix is
`wire-cloudfront.sh` (§13.3), which `deploy.sh` now calls and which fails loudly
instead of skipping.

---

## 8. Secrets (External Secrets Operator)

### 8.1 The two config sources
- **ConfigMap `cloudkitchen-config`** (`configmap.yaml`) — STATIC, in Git:
  `AWS_REGION`, `HF_MODEL`. Safe to commit.
- **Secret `cloudkitchen-secrets`** — DYNAMIC, never in Git. Materialised in-cluster
  by ESO from AWS Secrets Manager.

### 8.2 The chain (no static keys anywhere)
```
AWS Secrets Manager  →  ESO (auth via IRSA)  →  K8s Secret cloudkitchen-secrets  →  pods (envFrom)
```

### 8.3 SecretStore + ExternalSecret (`externalsecret.yaml`)
- **`SecretStore` `aws-secrets-manager`** — provider `aws`, `service: SecretsManager`,
  region from `values.eso.region`, auth `jwt.serviceAccountRef: external-secrets-sa`
  (so ESO assumes the `eso` IRSA role).
- **`ExternalSecret` `cloudkitchen-secrets`** — `refreshInterval: 1h`,
  `target.creationPolicy: Owner` (ESO owns/creates the Secret):
  - `dataFrom.extract` pulls **all** keys from `cloudkitchen/app/runtime` (DB URL/user,
    HF token, SQS URL, Cognito IDs).
  - `data` pulls `SPRING_DATASOURCE_PASSWORD` from the RDS-managed secret
    `cloudkitchen/db/credentials-new`, property `password`.

### 8.4 API version gotcha
The manifests use **`apiVersion: external-secrets.io/v1`** for both SecretStore and
ExternalSecret. The installed ESO serves `v1` (not `v1beta1`). Using `v1beta1` would
leave the resources OutOfSync/Missing in ArgoCD. Always match the served version
(`kubectl api-resources --api-group=external-secrets.io`).

### 8.5 Why this design
Secrets that regenerate every recreate (DB creds, Cognito IDs) must never be committed.
ESO keeps Git clean while pods still get real values, and IRSA means even ESO holds no
static AWS keys. Pods consume the Secret via `envFrom` exactly like the ConfigMap.

---

## 9. Identity & Access (ServiceAccounts, IRSA, RBAC)

### 9.1 ServiceAccounts (`serviceaccount.yaml`)
| ServiceAccount | IRSA annotation (role) | Used by |
|----------------|------------------------|---------|
| `cloudkitchen-default` | none | menu, auth (reach AWS only via the synced Secret) |
| `ai` | `cloudkitchen-ai-irsa` | ai pod (SQS consume) |
| `order` | `cloudkitchen-order-irsa` | order pod (SQS send) |
| `external-secrets-sa` | `cloudkitchen-eso-irsa` | ESO (Secrets Manager read) |

### 9.2 How IRSA works here
Each annotated SA carries `eks.amazonaws.com/role-arn`. The EKS OIDC provider +
`AssumeRoleWithWebIdentity` let the pod's projected SA token be exchanged for
temporary AWS credentials for that role — **no static keys in pods**. The roles and
their policies are defined in `cloudkitchen-infra/irsa.tf`; the ARNs are mirrored
into `values.irsa.*` (deterministic names, so safe to commit).

### 9.3 The role→permission map (summary; infra doc has exact actions)
- `ai` → SQS consume (read order events for demand signals).
- `order` → SQS send (publish OrderPlaced events).
- `eso` → Secrets Manager read on the two CloudKitchen secrets.

### 9.4 In-cluster RBAC (`rbac.yaml`)
A least-privilege namespaced `Role` `cloudkitchen-app-role` grants only
`get/list/watch` on **ConfigMaps**, bound (via `cloudkitchen-app-rolebinding`) to
`cloudkitchen-default` and `ai`. No cluster-wide rights, no Secret writes, no pod
exec. This is the *Kubernetes* permission layer; *AWS* permissions come from IRSA.

---

## 10. Security Hardening

### 10.1 NetworkPolicy (`networkpolicy.yaml`)
Two policies in `production`:
- **`default-deny-ingress`** — `podSelector: {}`, `policyTypes: [Ingress]` with no
  ingress rules → denies all inbound to every pod by default.
- **`allow-gateway-ingress`** — selects pods labelled
  `app.kubernetes.io/part-of: cloudkitchen` and allows ingress only from the
  `kgateway-system` namespace (matched by `kubernetes.io/metadata.name`).

Egress is intentionally left open — pods must reach RDS, SQS, Cognito, Secrets
Manager, the HuggingFace API, and DNS. Kubelet health probes bypass NetworkPolicy, so
probes keep working under default-deny.

### 10.2 Pod & container hardening (recap from §5.2)
`runAsNonRoot` + numeric `runAsUser` (so the kubelet can enforce non-root without
resolving a username), `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation:
false`, and `capabilities.drop: [ALL]`. Images are multistage and non-root: the
frontend uses `nginx-unprivileged` (UID 101, listens on 8080); the AI image runs as
UID 1000 with CPU-only torch.

### 10.3 The layered security story (for the rubric)
1. **Network:** default-deny ingress + gateway-only allow + open egress.
2. **Identity:** dedicated SAs, IRSA (no static AWS keys), least-priv RBAC.
3. **Secrets:** ESO from Secrets Manager, nothing sensitive in Git.
4. **Runtime:** non-root, dropped caps, seccomp, no privilege escalation.
5. **Supply chain:** Semgrep SAST + Trivy fs/image scans in CI; non-root multistage
   images.

---

## 11. Observability & Alerting

### 11.1 The monitoring stack
`install.sh` installs the upstream **kube-prometheus-stack** Helm chart into
`monitoring` with `monitoring/values.yaml`. Components: Prometheus, Grafana,
Alertmanager, node-exporter (DaemonSet), kube-state-metrics, and the Prometheus
Operator.

### 11.2 Grafana (public)
`grafana.service.type: LoadBalancer` with the NLB annotation → a public URL reachable
from any laptop. Admin password `cloudkitchen-admin` (demo). `defaultDashboardsEnabled:
true` provides the standard Kubernetes cluster/node/pod dashboards. There is no
custom CloudKitchen dashboard and the app pods expose no `/metrics` ServiceMonitor yet
(`serviceMonitorSelectorNilUsesHelmValues: false` is set so one can be added later).

### 11.3 Prometheus & Alertmanager → Slack
Prometheus retention is **6h** (small cluster, ephemeral storage). Alertmanager is
enabled and routes `severity =~ warning|critical` to a Slack receiver. The webhook is
read from a mounted secret `alertmanager-slack`
(`api_url_file: /etc/alertmanager/secrets/alertmanager-slack/webhook`), created by
`install.sh` from `$SLACK_WEBHOOK_URL` or `terraform.tfvars` — never committed. Alerts
use the stack's built-in rules (KubePodCrashLooping, KubePodNotReady, KubeNodeNotReady,
etc.); a healthy cluster is silent by design. If the webhook is the `REPLACE-ME`
placeholder, alerts won't deliver.

### 11.4 Container Insights and the AI OTEL opt-out
The `amazon-cloudwatch-observability` add-on auto-instruments pods by injecting
OpenTelemetry. For the **AI** pod this injected OTEL Python clashes with ChromaDB's
bundled opentelemetry (`ModuleNotFoundError: …_exporter_metrics`), crashing the pod on
import. The chart therefore stamps the AI Deployment with
`instrumentation.opentelemetry.io/inject-python: "false"` (driven by `disableOtel:
true` in values.yaml). The Java services keep their OTEL (it works fine for them).

---

## 12. Platform Bootstrap (`bootstrap/install.sh`)

Run once per cluster (or per recreate). It installs platform components **in order**:
1. **Gateway API CRDs** `v1.2.0` (standard-install) — the Gateway/HTTPRoute kinds.
2. **kgateway `v2.0.0`** — CRDs chart then the controller, into `kgateway-system`
   (OCI charts `cr.kgateway.dev/...`). Waits for the deploy rollout.
3. **External Secrets Operator** — `external-secrets/external-secrets` Helm chart,
   `installCRDs=true`, into `external-secrets`.
4. **ArgoCD** — `kubectl apply --server-side --force-conflicts` of the stable
   manifests, then patch `server.insecure=true` and the `argocd-server` Service to
   `LoadBalancer` (public UI over HTTP), then restart/rollout.
5. **kube-prometheus-stack** — creates the `monitoring` ns + `alertmanager-slack`
   secret, then `helm upgrade -i` with `monitoring/values.yaml`.

It prints the public ArgoCD + Grafana links at the end. `helm` is auto-installed by
`deploy.sh` if missing.

> Ordering matters: Gateway API CRDs must exist before kgateway; the app's Gateway/
> HTTPRoutes need kgateway's GatewayClass; ESO must exist before the chart's
> SecretStore/ExternalSecret sync. Because the script uses `set -e`, an early failure
> aborts before later steps — historically this left the `monitoring` stack
> uninstalled (Grafana namespace missing). If a platform piece is absent after a
> deploy, check `helm list -A` and re-run `install.sh`.

---

## 13. Deploy / Destroy Lifecycle (the unified scripts)

All lifecycle scripts live in `cloudkitchen-gitops`. There is **one** deploy
entrypoint and **one** destroy entrypoint; the rest are called by `deploy.sh`.

### 13.1 `deploy.sh` (the one command)
Prereqs: `aws terraform kubectl docker npm git` (+ Docker running, AWS configured);
`helm` auto-installs. Then, in order:
0. **Preflight + bootstrap-from-nothing:** clone the sibling repos
   (`cloudkitchen-infra`, `cloudkitchen-app`) from `$GIT_ORG` (default
   `Cloudkitchen007`) if missing; generate `cloudkitchen-infra/terraform.tfvars` from
   `$HF_API_TOKEN` (required) and `$SLACK_WEBHOOK_URL` (optional).
1. Terraform: bootstrap remote state (S3 + DynamoDB lock) then `terraform apply`.
2. Build + push the **4 backend images** to ECR.
3. `npm run build` the SPA and `aws s3 sync` it to the frontend bucket.
4. `aws eks update-kubeconfig`, run `install.sh`, apply the ArgoCD `project.yaml` +
   `application.yaml`.
5. Run `wire-cloudfront.sh` (the second apply + invalidation).
6. Print all links via `links.sh`.

### 13.2 `destroy.sh` (the one teardown)
Order matters because K8s-created LoadBalancers are **not** in Terraform state:
1. Delete the ArgoCD `cloudkitchen` application (prunes workloads incl. the Gateway).
2. Delete **all** LoadBalancer Services (gateway + ArgoCD + Grafana) and wait until
   none remain — otherwise their ENIs orphan and block VPC deletion.
3. `terraform destroy`. Uses `set -uo pipefail` (not `-e`) so cleanup continues
   through no-ops.

### 13.3 `wire-cloudfront.sh` (idempotent rewire)
Waits up to 10 min for `kubectl get gateway cloudkitchen-gateway -n production
-o jsonpath='{.status.addresses[0].value}'`, then `terraform apply
-var="eks_api_origin=<nlb>"` and a CloudFront invalidation. **Fails loudly** if the
NLB never appears (the old skip-on-timeout behaviour caused §7's outage). Safe to run
standalone any time the menu is empty after a recreate.

### 13.4 `links.sh`
Prints the App (CloudFront), ArgoCD, Grafana URLs and credentials, and the Prometheus
port-forward one-liner. URLs/passwords are fetched live (they regenerate per recreate).

---

## 14. Request Flows (Kubernetes perspective)

### 14.1 Browse the menu
Browser → CloudFront `/api/menu` → NLB → Envoy → HTTPRoute `menu` (`/api` catch-all) →
`menu` Service:8080 → menu pod → RDS query → JSON back up the chain.

### 14.2 AI recommendation
Browser → CloudFront `/api/recommend_quick` → NLB → Envoy → HTTPRoute `ai` (matches
`/api/recommend_quick` exactly, longest prefix beats `menu`) → `ai` Service:8000 → ai
pod → HuggingFace Inference API (or rule-based fallback) → JSON.

### 14.3 Place an order
Browser → `/api/orders` → Envoy → HTTPRoute `order` → `order` pod → writes RDS +
sends SQS via the `order` IRSA role → 200.

### 14.4 Secret sync (startup)
ESO (`external-secrets-sa` → `eso` IRSA role) reads Secrets Manager → writes
`cloudkitchen-secrets` → pods mount it via `envFrom` at start.

---

## 15. Connection Matrix (in-cluster)

| From | To | Via | Why |
|------|----|-----|-----|
| Internet | NLB | TCP 80 | edge ingress (from CloudFront) |
| NLB | Envoy (kgateway-system) | nodePort | data-plane |
| Envoy | menu/order/auth/ai Services | ClusterIP | path routing |
| pods | RDS | egress 5432 | relational data |
| order pod | SQS | egress (IRSA) | publish events |
| ai pod | SQS | egress (IRSA) | consume events |
| ai pod | HuggingFace API | egress 443 | LLM inference |
| ESO | Secrets Manager | egress (IRSA) | secret sync |
| ArgoCD | GitHub gitops repo | egress 443 | desired state |
| Prometheus | pods/nodes | scrape | metrics |
| Alertmanager | Slack | egress 443 | alerts |
| kgateway-system | app pods | ingress (allowed by NetworkPolicy) | only allowed ingress source |

---

## 16. Failure Modes & Troubleshooting

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| **Empty menu** + **AI "warming up"**, pods healthy | CloudFront `/api` not pointed at the new NLB after a recreate | `bash wire-cloudfront.sh`; verify `aws cloudfront get-distribution-config` shows an `/api/*` behavior → `eks-api-origin` |
| **AI "warming up"** but `curl http://ai:8000/api/recommend_quick` works | HTTPRoute missing the `recommend_quick`/`recommend_forecast` segments (per-segment matching) | ensure all 5 AI `pathPrefixes` are present; push (ArgoCD selfHeal reverts manual edits) |
| AI pod **CrashLoopBackOff** with `…opentelemetry…_exporter_metrics` | CloudWatch OTEL injection clashes with ChromaDB | `disableOtel: true` → `inject-python: "false"` annotation (already in chart) |
| ExternalSecret/SecretStore **OutOfSync/Missing** | wrong apiVersion (`v1beta1`) | use `external-secrets.io/v1` |
| Manual `kubectl apply`/`edit` **reverts in ~1 min** | ArgoCD `selfHeal` | change Git + push, or pause selfHeal (§17) to test |
| `namespaces "monitoring" not found` / Grafana missing | `install.sh` aborted before step 5 (`set -e`) | re-run `install.sh`; check `helm list -A` |
| CI `deploy` job: `Error: Input required and not supplied: token` | cross-repo checkout of gitops needs `GITOPS_TOKEN` | add a fine-grained PAT (Contents:write on the gitops repo) as secret `GITOPS_TOKEN` |
| Java pod readiness fails for ~1 min after start | normal JVM/Tomcat warmup (TCP probe) | wait; or raise `initialDelaySeconds` |
| AI gives templated (not LLM) reasons | HF LLM init failed (`sentencepiece` missing) → rule-based fallback | add `sentencepiece` to the AI image requirements + rebuild |
| `terraform plan` in CI: "No value for required variable" | a required var without default not supplied in CI | give it a default or pass `-var`/`TF_VAR_*` |

---

## 17. Common Operations (kubectl recipes)

```bash
# Point kubeconfig at the cluster
aws eks update-kubeconfig --name cloudkitchen-eks --region ap-south-1

# Status
kubectl get pods -n production -o wide
kubectl get gateway,httproute -n production
kubectl get application cloudkitchen -n argocd -o yaml | less

# Test a service from inside the cluster (bypasses CloudFront/gateway)
kubectl run t --rm -i --restart=Never --image=curlimages/curl -n production -- \
  -s http://menu:8080/api/menu

# The current NLB DNS (what CloudFront must point at)
kubectl get gateway cloudkitchen-gateway -n production \
  -o jsonpath='{.status.addresses[0].value}'; echo

# Force an ArgoCD resync
kubectl annotate application cloudkitchen -n argocd argocd.argoproj.io/refresh=hard --overwrite

# Temporarily pause selfHeal (to test a manual change), then re-enable
kubectl patch application cloudkitchen -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false}}}}'
# … test …
kubectl patch application cloudkitchen -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}'

# Roll a service to pick up a new :latest image
kubectl rollout restart deployment ai -n production

# Confirm ESO synced the runtime secret
kubectl get externalsecret,secret cloudkitchen-secrets -n production
```

---

## 18. FAQ

**Q: Where is the frontend pod?** There isn't one — the SPA is static in S3 behind
CloudFront. Only the 4 backends run in K8s.

**Q: Why Gateway API / kgateway instead of an Ingress + ALB controller?** Gateway API
is the modern, role-oriented successor to Ingress; kgateway (Envoy) implements it and
provisions an NLB with no extra controller/IRSA in the default config. The values.yaml
documents the AWS-LB-Controller upgrade path if `nlb-target-type: ip` is wanted.

**Q: Why is the AI service 1 replica but others 2?** Cost and because the AI workload
is lighter-traffic; the Spring services get 2 for rolling-update availability. AI can
be bumped to 2 if seamless rollouts matter.

**Q: How do new images get deployed?** CI builds/pushes to ECR and bumps
`global.imageTag` in this repo; ArgoCD syncs the new tag. Manual alternative:
`kubectl rollout restart`.

**Q: Why no PersistentVolumes / EBS CSI?** The cluster is stateless; all durable data
is in RDS/S3/SQS. Prometheus keeps only 6h ephemerally.

**Q: Can I run the UIs without port-forward?** Yes — ArgoCD and Grafana are public
LoadBalancers. `bash links.sh` prints the URLs. Prometheus is the only port-forward.

**Q: What changes on every destroy/recreate?** NLB DNS, all LB hostnames, CloudFront
domain, Cognito IDs, image tags. Stable: IRSA role names/ARNs, ECR repo names, bucket
naming scheme, account/region.

---

## 19. Glossary

- **GitOps** — operating model where Git is the source of truth and a controller
  (ArgoCD) reconciles the cluster to match it.
- **ArgoCD Application / AppProject** — the CRD that defines *what* to deploy from
  *where* / the policy boundary around it.
- **selfHeal / prune** — ArgoCD auto-revert of drift / auto-delete of resources
  removed from Git.
- **Gateway API** — `GatewayClass` (implementation), `Gateway` (a listener/LB),
  `HTTPRoute` (path/host rules). Successor to Ingress.
- **kgateway** — Envoy-based Gateway API implementation used here.
- **IRSA** — IAM Roles for Service Accounts; pods assume IAM roles via the EKS OIDC
  provider — no static AWS keys.
- **ESO** — External Secrets Operator; syncs AWS Secrets Manager → K8s Secrets.
- **NetworkPolicy** — namespaced L3/L4 firewall for pods.
- **ServiceMonitor** — Prometheus-Operator CRD that declares a scrape target.
- **Container Insights / Application Signals** — CloudWatch's K8s observability + OTEL
  auto-instrumentation (the source of the AI OTEL clash).
- **NLB** — AWS Network Load Balancer; here created by Kubernetes for the Gateway.

---

## 20. File Index (concept → file)

| Concept | File |
|---------|------|
| Chart metadata | `helm/cloudkitchen/Chart.yaml` |
| Configuration surface | `helm/cloudkitchen/values.yaml` |
| Image + label helpers | `helm/cloudkitchen/templates/_helpers.tpl` |
| Deployments (4 services) | `helm/cloudkitchen/templates/deployment.yaml` |
| ClusterIP Services | `helm/cloudkitchen/templates/service.yaml` |
| HTTPRoutes | `helm/cloudkitchen/templates/httproute.yaml` |
| Gateway (NLB) | `helm/cloudkitchen/templates/gateway.yaml` |
| ServiceAccounts (IRSA) | `helm/cloudkitchen/templates/serviceaccount.yaml` |
| ConfigMap | `helm/cloudkitchen/templates/configmap.yaml` |
| SecretStore + ExternalSecret | `helm/cloudkitchen/templates/externalsecret.yaml` |
| NetworkPolicies | `helm/cloudkitchen/templates/networkpolicy.yaml` |
| RBAC Role/RoleBinding | `helm/cloudkitchen/templates/rbac.yaml` |
| ArgoCD Application | `argocd/application.yaml` |
| ArgoCD AppProject | `argocd/project.yaml` |
| Platform bootstrap | `bootstrap/install.sh` |
| Monitoring stack values | `monitoring/values.yaml` |
| Deploy (one command) | `deploy.sh` |
| Destroy (one command) | `destroy.sh` |
| CloudFront rewire | `wire-cloudfront.sh` |
| Access links | `links.sh` |
| Access how-to | `ACCESS.md` |
| Deploy how-to | `DEPLOY.md` |
| IAM roles/policies (AWS side) | `cloudkitchen-infra/irsa.tf` |
| EKS cluster + node group + add-ons | `cloudkitchen-infra/eks.tf` |
| CloudFront + S3 + API behaviors | `cloudkitchen-infra/addons.tf` |

---

*End of CloudKitchen Kubernetes & GitOps Reference. For the AWS cloud layer, see
`cloudkitchen-infra/AWS_CLOUD_REFERENCE.md`.*
