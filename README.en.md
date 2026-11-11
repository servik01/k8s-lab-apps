# Kubernetes Home Lab — Debian 13 (Trixie)

[Русский](README.md) | **English**

A Kubernetes lab cluster deployed with `kubeadm` for learning and experimentation.

## Topology

| Role | Hostname | IP | OS | RAM |
|------|----------|----|----|-----|
| control-plane | kubernetes | 192.168.64.55 | Debian 13 | 6 GB |
| worker | k8s-worker | 192.168.64.57 | Debian 13 | 4 GB |

Control-plane endpoint: `k8s-api.lab.local` → `192.168.64.55` (configured in `/etc/hosts` on every node).

The cluster has two nodes. The control-plane has the standard `node-role.kubernetes.io/control-plane:NoSchedule` taint, so regular workloads run on the worker. Vault and Prometheus remain on the control-plane: their `local-path` volumes are tied to that node, so values include tolerations (`workloads/vault`: `server.tolerations` as a string; `workloads/monitoring`: `prometheus.prometheusSpec.tolerations`). Vault's StatefulSet uses `OnDelete`: after changing its template, manually recreate the pod and unseal it.

ArgoCD and Grafana have moved to the worker to reduce control-plane memory usage. Grafana uses a separate static local PV/PVC, `grafana-worker-data`; its data was copied with ownership and permissions preserved. Control-plane RAM was reduced from 8 to 6 GB. After reboot, both nodes were `Ready` and all nine Applications present at that time were `Synced / Healthy`. The latest reading was 2925 MiB (50%) on the control-plane and 2166 MiB (56%) on the worker; this is a post-boot observation, not a peak usage guarantee.

The worker firewall (`ufw`, `default deny incoming`) allows only SSH (22) and all traffic from the control-plane (`sudo ufw allow from 192.168.64.55`). Without the latter rule, the control-plane cannot reach kubelet (port 10250), and `kubectl exec`/`logs` for worker pods fail with `i/o timeout`. Calico rules (BGP, VXLAN, Typha, `10.244.0.0/16`) have been removed: Cilium's traffic between these nodes is covered by the control-plane rule. The worker also loads the nftables table `ansible_nodeport` (`/etc/nftables.d/ansible-nodeport.nft`, unit `ansible-nodeport-firewall.service`). It permits NodePort traffic (30000–32767) only from listed subnets; `192.168.64.0/24` was added so the Mac can access ingress-nginx when it runs on the worker. The control-plane does not have `ufw` installed.

## Stack

| Component | Version / notes |
|-----------|-----------------|
| Kubernetes | v1.36.6 (kubeadm), etcd 3.6.8 |
| Container runtime | containerd (`SystemdCgroup=true`) |
| CNI | Cilium 1.20.1 managed by ArgoCD (`platform/cilium/values.yaml`), `kubeProxyReplacement=true` |
| kube-proxy | Removed; Cilium handles its role (see Installing Cilium) |
| Ingress | ingress-nginx (NodePort: 80→32337, 443→30971) |
| TLS | cert-manager + `ClusterIssuer/selfsigned-issuer` |
| Metrics | metrics-server (`--kubelet-insecure-tls`) |
| GitOps | ArgoCD + ApplicationSet (`k8s-lab-apps` repository) |
| Storage | local-path-provisioner v0.0.37 (default StorageClass `local-path`) |
| Secrets | Vault (chart 0.34.0, Vault 2.0.3), Raft on a PVC, 1 replica, manual unseal; configuration in `iac/vault` (OpenTofu) |
| Monitoring | kube-prometheus-stack 91.9.0 (Prometheus, Grafana, Alertmanager), data on PVCs |
| Network observability | Hubble (relay + UI), Cilium metrics in Prometheus |
| Demo applications | `nginx-demo`, `whoami`, `rbac-demo`, `netpol-demo`, `vault-demo` (multi-arch images supporting arm64) |
| Database | PostgreSQL `postgres:17-bookworm` (verified 17.11, arm64), StatefulSet, 2Gi PVC on worker |
| Service mesh | Linkerd `edge-26.11.1`, Helm charts `2026.11.1`, Gateway API CRDs `v1.5.1`; ingress remains ingress-nginx |
| Secret synchronization | External Secrets Operator, chart `2.14.0`, Vault Kubernetes auth |
| Service access | NetBird Cloud + Operator `0.9.0`, NetBird router: ArgoCD, Grafana, PostgreSQL; Cloud configuration in the private Netbird repository |

## OS preparation (all nodes)

```bash
# Disable swap
sudo swapoff -a
sudo sed -i '/ swap /s/^/#/' /etc/fstab

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# /etc/hosts — on ALL nodes
echo "192.168.64.55 k8s-api.lab.local" | sudo tee -a /etc/hosts
```

## Installing containerd

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg apt-transport-https

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# (using bookworm: the Docker repository did not yet support trixie at installation time)

sudo apt update
sudo apt install -y containerd.io

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

## Installing kubeadm / kubelet / kubectl

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## Initializing the control-plane

Run **only** on the control-plane node (192.168.64.55):

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --control-plane-endpoint "k8s-api.lab.local:6443"

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Join commands (tokens expire after 24 hours; generate a new one with `kubeadm token create --print-join-command` on the control-plane):

```bash
# Worker
kubeadm join k8s-api.lab.local:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>

# Additional control-plane (HA)
kubeadm join k8s-api.lab.local:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane --certificate-key <CERT_KEY>
```

## Installing Cilium

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-arm64.tar.gz
sudo tar xzvfC cilium-linux-arm64.tar.gz /usr/local/bin
rm cilium-linux-arm64.tar.gz

cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=k8s-api.lab.local \
  --set k8sServicePort=6443
cilium status --wait
```

> **Cilium replaces kube-proxy and needs a direct API endpoint.** Set `k8sServiceHost`/`k8sServicePort` when kube-proxy is removed. Otherwise, after a reboot Cilium tries to reach the API through ClusterIP `10.96.0.1`, whose routing depends on Cilium itself (see Troubleshooting). The name `k8s-api.lab.local` works because the agent and operator use `hostNetwork` and the node's `/etc/hosts`; the entry `192.168.64.55 k8s-api.lab.local` is required on each node. The Cilium CLI automatically obtains the API address from kubeconfig. After installation, Cilium is handed over to ArgoCD (see Cilium managed by ArgoCD), and `cilium upgrade` is no longer used.
>
> The nodes are **arm64** (UTM/Apple Virtualization on Apple Silicon), so use `cilium-linux-arm64` rather than `amd64`.

## metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl -n kube-system rollout status deployment metrics-server
kubectl top nodes
```

> Immediately after rollout, `kubectl top nodes` may report `Metrics API not available`. APIService registration takes 30–60 seconds; this is expected.

After installation, a placement patch pins metrics-server to the control-plane: from the worker it could not reach the local kubelet because of a network restriction. The patch is stored in Git but applied manually (this component is installed outside ArgoCD):

```bash
kubectl -n kube-system patch deployment metrics-server --type=strategic \
  --patch-file=platform/metrics-server/placement-patch.yaml
```

## ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/cloud/deploy.yaml

# No cloud LoadBalancer: switch to NodePort
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec": {"type": "NodePort"}}'

# cloud/deploy.yaml sets externalTrafficPolicy: Local, so NodePort responds
# only on the node hosting the pod. With two nodes, access breaks if the pod moves
# to the worker while the client /etc/hosts points to the control-plane. Use Cluster.
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec": {"externalTrafficPolicy": "Cluster"}}'
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

With `Cluster`, NodePort accepts traffic on any node and forwards it to the pod wherever it runs. The application sees the node's address instead of the original client IP, which is acceptable for this lab. A symptom of `Local`: `curl` to the control-plane NodePort gets no response, while the same request to the node hosting the pod returns 200.

## cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

kubectl -n cert-manager rollout status deployment cert-manager
kubectl -n cert-manager rollout status deployment cert-manager-webhook
```

ClusterIssuer (self-signed; Let's Encrypt is unsuitable for this lab without a public domain):

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
```

## ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deployment argocd-server
```

Admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Access the UI (the cluster and browser run on different machines: a Mac and VM on the same `192.168.64.x` network):

```bash
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
```

Open `https://192.168.64.55:8080` (username `admin`, password from above). The browser warning about the self-signed certificate is expected.

Change the password after the first login:

```bash
argocd account update-password
```

### ArgoCD placement

All five active ArgoCD components now run on `k8s-worker`: `argocd-repo-server`, `argocd-application-controller` (StatefulSet), `argocd-redis`, `argocd-server`, and `argocd-applicationset-controller`. Namespace `argocd` has no PVCs. Placement was set through manual patches to `spec.template.spec.nodeSelector` with `kubernetes.io/hostname: k8s-worker`; these settings still need to be captured in the declarative ArgoCD installation. Dex and notifications-controller remain scaled to zero.

## GitOps repository (`k8s-lab-apps`)

Public repository: `https://github.com/servik01/k8s-lab-apps`, branch `main`. ArgoCD reads it without additional credentials.

```
k8s-lab-apps/
├── bootstrap/
│   ├── applicationset.yaml   # applied manually once
│   └── cilium.yaml           # Cilium Application, also applied manually
├── platform/
│   ├── cilium/values.yaml    # Cilium Helm chart values
│   └── kubeadm/config.yaml   # kubeadm ClusterConfiguration (control-plane metrics)
├── iac/
│   └── vault/                # OpenTofu: Vault configuration
└── workloads/                # each directory = one application
    ├── local-path-storage/   # provisioner + default class Kustomize patch
    ├── monitoring/           # kube-prometheus-stack wrapper chart
    ├── vault/                # Vault wrapper chart (Raft)
    ├── vault-demo/           # application using Vault Agent Injector
    ├── rbac-demo/            # ServiceAccount, Role, ClusterRole
    ├── netpol-demo/          # NetworkPolicy in Cilium
    ├── nginx-demo/           # deployment, service, ingress
    └── whoami/               # deployment, service, ingress
```

Additional components: `workloads/postgres/` (StatefulSet and Services), `workloads/mesh-demo/` (Linkerd-enabled client and HTTP server). Mesh configuration lives in `platform/linkerd/` and `platform/linkerd-webhooks/`; dedicated Applications are `bootstrap/linkerd-crds.yaml`, `bootstrap/linkerd-webhooks.yaml`, and `bootstrap/linkerd.yaml`. These are applied manually, outside the `workloads/*` generator.

NetBird manifests live in `workloads/netbird/`, with operator values in `platform/netbird-operator/values.yaml`. Dedicated Applications `bootstrap/external-secrets.yaml` and `bootstrap/netbird-operator.yaml` install the operators; their bootstrap manifests are applied manually.

### ApplicationSet

The Git directory generator turns every `workloads/*` directory into an Application. The directory name becomes both the Application name and its namespace. `automated` sync, `prune`, `selfHeal`, and `CreateNamespace=true` are enabled. Each Application has the `resources-finalizer.argocd.argoproj.io` finalizer.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: workloads
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/servik01/k8s-lab-apps.git
        revision: HEAD
        directories:
          - path: workloads/*
  template:
    metadata:
      name: '{{path.basename}}'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: https://github.com/servik01/k8s-lab-apps.git
        targetRevision: HEAD
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      ignoreDifferences:           # Vault injector writes caBundle into the webhook
        - group: admissionregistration.k8s.io
          kind: MutatingWebhookConfiguration
          jqPathExpressions:
            - '.webhooks[]?.clientConfig.caBundle'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - RespectIgnoreDifferences=true
          - ServerSideApply=true      # large CRDs (kube-prometheus-stack)
```

Apply manually once:

```bash
kubectl apply -f bootstrap/applicationset.yaml
```

### Workflow

- **New application**: create `workloads/<name>/` with manifests and run `git push`. The Application and namespace `<name>` appear after about 3 minutes (the Git polling interval).
- **Change**: edit the manifest in Git and run `git push`. `selfHeal` reverts manual changes in the cluster.
- **Delete**: run `git rm -r workloads/<name>` and `git push`. The Application disappears; its finalizer and `prune` remove its resources too.

Push using a token from an environment variable without saving it in `.git/config`:

```bash
git push "https://<user>:${MY_GH_TOKEN}@github.com/<user>/k8s-lab-apps.git" main
```

### Accessing applications from the Mac

Access is through ingress-nginx on the HTTPS NodePort (30971) with a self-signed certificate. Add to `/etc/hosts` on the Mac:

```
192.168.64.55 nginx.lab.local whoami.lab.local
```

URLs: `https://nginx.lab.local:30971`, `https://whoami.lab.local:30971`.

### Migration history: App of Apps → ApplicationSet

Initially, the App of Apps pattern was used: a root Application named `root` watched `apps/`. During the migration to ApplicationSet, applications were detached from `root` **without deleting their resources**: first remove the Application's finalizer (`kubectl patch ... '{"metadata":{"finalizers":null}}'`), then delete the Application. Deleting an Application with its finalizer causes Argo to cascade-delete all its resources. After applying ApplicationSet, the new Applications adopted the running pods without restarting them.

## Storage (local-path-provisioner)

Application `workloads/local-path-storage`: the v0.0.37 provisioner manifest is vendored unchanged, while `kustomization.yaml` patches StorageClass `local-path` to make it the default. The directory matches the manifest's namespace (`local-path-storage`).

- Data lives on the node's disk in `/opt/local-path-provisioner`, without replication, and is tied to that node.
- `volumeBindingMode: WaitForFirstConsumer`: a PVC remains `Pending` until a pod uses it.
- `reclaimPolicy: Delete`: deleting a PVC deletes its data.

## Vault (Raft, single replica)

Wrapper chart `workloads/vault` (`Chart.yaml` depends on `vault` 0.34.0; settings in `values.yaml` under `vault:`). Key settings: `server.ha.enabled` + `server.ha.raft.enabled` + `replicas: 1`, 2Gi `dataStorage` on `local-path`, `disruptionBudget` disabled (with one replica it would block `kubectl drain`), injector enabled.

Initialize once. Keep the key file **outside this public repository** and back it up:

```bash
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > ~/vault-init.json
chmod 600 ~/vault-init.json
```

Unseal after every pod restart and VM reboot:

```bash
kubectl -n vault exec vault-0 -- vault operator unseal \
  "$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)"
```

Vault configuration (`secret/` KV v2 mount, `kubernetes` auth, policy, and role) is defined in `iac/vault/` and applied with OpenTofu; see Vault as code (OpenTofu). Only `operator init`, unseal, and secret values are managed manually.

Vault performs token reviews using its own ServiceAccount token. The chart creates `vault-server-binding` to `system:auth-delegator`. Application `workloads/vault-demo` receives its secret through `vault.hashicorp.com/*` annotations: the injector adds an init container and a `vault-agent` sidecar, and the secret appears in `/vault/secrets/config.txt`. Negative test: a token from a different ServiceAccount gets `403 service account name not authorized`.

## Vault as code (OpenTofu)

The `iac/vault/` directory is outside `workloads/*`, so ArgoCD does not manage it.

- `providers.tf`: `hashicorp/vault` provider; address and token come from environment variables (`VAULT_ADDR`, `VAULT_TOKEN`).
- `main.tf`: `secret` mount (KV v2), `kubernetes` auth configuration (`kubernetes_host = https://kubernetes.default.svc:443`, Vault uses its own review token), `demo-read` policy, and `demo` role (ServiceAccount `vault-demo` in namespace `vault-demo`).
- `.terraform.lock.hcl` is committed to pin the provider version. `.gitignore` excludes state (`*.tfstate`), `.terraform/`, and `*.tfvars`.

**Secret values are excluded from code**: the repository is public, and values would also end up in state. Write secrets separately: `vault kv put secret/demo/config username=... password=...`.

Run on the VM (OpenTofu 1.13.1; install by downloading `curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh`, reviewing it, then running `sudo /tmp/install-opentofu.sh --install-method deb`):

```bash
kubectl -n vault port-forward svc/vault 8200:8200 >/tmp/vault-pf.log 2>&1 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)"   # session environment only; do not save to files

cd ~/k8s-lab-apps/iac/vault
tofu init
tofu plan
tofu apply
kill %1    # stop port-forward
```

**Recreating Vault from scratch**: run `operator init`, unseal, `tofu apply`, then `kv put` for secrets. If configuration already exists on a running Vault, `apply` fails with “already exists”: first delete the objects (`vault secrets disable secret`, `vault auth disable kubernetes`, `vault policy delete demo-read`) or import them with `tofu import`. Removing the auth backend also removes its role.

**State** is local: `iac/vault/terraform.tfstate` on the VM, excluded from Git. Back it up: without it, the next `apply` against the configured Vault fails with “already exists”. It contains no secret values, but should still remain private.

**Drift**: manually deleting a policy appears in `tofu plan` as `~ update in-place` (the provider reads the deleted policy as empty); `tofu apply` restores it. To verify the role binding, use another ServiceAccount's token and expect `403 service account name not authorized`:

```bash
TOKEN=$(kubectl -n rbac-demo create token dev-viewer)
kubectl -n vault exec vault-0 -- vault write auth/kubernetes/login role=demo jwt="$TOKEN"
```

## RBAC and NetworkPolicy

**`workloads/rbac-demo`**: ServiceAccount `dev-viewer`, Role `pod-reader` (read pods and pods/log in its own namespace), ClusterRole `node-reader`. Check permissions:

```bash
SA=system:serviceaccount:rbac-demo:dev-viewer
kubectl auth can-i delete pods -n rbac-demo --as=$SA     # no
kubectl auth can-i list nodes --as=$SA                   # yes
```

Test with a real token. Use an empty kubeconfig: the API server accepts the admin client certificate from `~/.kube/config` before the token, so otherwise this would test admin permissions:

```bash
TOKEN=$(kubectl -n rbac-demo create token dev-viewer)
KUBECONFIG=/dev/null kubectl --server=https://k8s-api.lab.local:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt --token=$TOKEN \
  delete pod -n rbac-demo -l app=sample                  # Forbidden
```

**`workloads/netpol-demo`**: `web` (nginx) and `client` labeled `role=client`. Policies: `default-deny-ingress`, `allow-client-to-web`, and `client-egress` (only `web:80` and DNS in `kube-system`). Blocked traffic results in a **timeout**, rather than connection refusal; DNS issues produce `bad address` instead. Applying `default-deny-ingress` in a namespace served by ingress-nginx breaks external access unless traffic from namespace `ingress-nginx` is allowed.

## PostgreSQL (StatefulSet)

`workloads/postgres/` is discovered by ApplicationSet as Application `postgres` in namespace `postgres`. One replica, `postgres-0`, runs on `k8s-worker` using `postgres:17-bookworm` (verified as 17.11 on arm64). Requests: 100m CPU / 256Mi; memory limit: 512Mi. Startup/readiness probes use `pg_isready`. The image tag pins the major version, not a minor or digest; a major upgrade requires data migration, not simply changing the tag.

- Headless Service `postgres-headless` provides StatefulSet network identity.
- ClusterIP Service `postgres`: `postgres.postgres.svc.cluster.local:5432`; database `lab`, administrator `postgres`.
- `volumeClaimTemplates` creates PVC `data-postgres-0`: 2Gi, RWO, `local-path` with `WaitForFirstConsumer`. `PGDATA=/var/lib/postgresql/data/pgdata`.
- `persistentVolumeClaimRetentionPolicy` retains PVCs on StatefulSet deletion and scale-down. Manually deleting the PVC with PV policy `Delete` deletes the data. The volume is tied to the worker; one replica is not HA, and increasing replicas does not configure PostgreSQL replication.

Before the first sync, manually create the namespace and Secret `postgres-auth` with key `POSTGRES_PASSWORD`, outside Git. Generate a password without displaying it:

```bash
kubectl create namespace postgres
(
  set -eu
  umask 077
  secret_file=$(mktemp)
  trap 'rm -f "$secret_file"' EXIT
  openssl rand -hex 24 | tr -d '\n' > "$secret_file"
  kubectl -n postgres create secret generic postgres-auth \
    --from-file=POSTGRES_PASSWORD="$secret_file"
)
```

`POSTGRES_*` variables initialize only an empty data directory. Changing the Secret after initialization does not change the database password. Keep the Secret and data backups out of Git.

TCP access through the Service with a password was verified. A record in `public.persistence_check` survived pod deletion: StatefulSet recreated `postgres-0` with a new IP and the same PVC, preserving the record.

```bash
kubectl -n postgres get pods,pvc,svc -o wide
kubectl -n postgres exec postgres-0 -- \
  psql -U postgres -d lab -c 'SELECT * FROM public.persistence_check;'
```

### Limited user

Role `lab_app` was created manually with `LOGIN`, `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOREPLICATION`, and `NOBYPASSRLS`. It was granted `CONNECT` to `lab`, ownership of schema `app`, and a database-specific `search_path` of `app`. Its separate password was set interactively with `\password lab_app`; it is not stored in Git or configured by the administrator Secret.

Verified: password-based TCP login, creating tables and changing its own data in `app`, and `permission denied` when reading administrator-owned `public.persistence_check`. The test table was rolled back. This user owns its schema and is not read-only; shared `PUBLIC` privileges were not separately hardened. The role lives in the database and is not recreated by manifests on a fresh installation. PostgreSQL backups are not configured; etcd snapshots do not include PVC data.

## Linkerd (service mesh)

Installed Linkerd `edge-26.11.1` (Linux ARM64 CLI, Helm charts `2026.11.1`). Its control plane runs on node `kubernetes`, one replica per component, with a control-plane toleration: `linkerd-destination` (4/4), `linkerd-identity` (2/2), and `linkerd-proxy-injector` (2/2). Linkerd Viz and an additional Prometheus were not installed.

### Cilium and Gateway API

`platform/cilium/values.yaml` sets `socketLB.hostNamespaceOnly: true` while retaining `kubeProxyReplacement: true`. Following sync, Cilium agents were restarted one at a time; both reported `Socket LB Coverage: Hostns-only`, and health checks passed for hosts and endpoints on both nodes. This allows Linkerd proxies to intercept traffic before Service load balancing within pod namespaces.

Gateway API CRDs `v1.5.1` were manually installed using server-side apply of the standard bundle. Linkerd uses them for routing and policies; ingress-nginx and existing Ingress resources remain in place. Experimental `TCPRoute` was not installed; the policy-controller warning about skipping its watch did not prevent successful checks.

### Certificates and GitOps

- An ECDSA P-256 mTLS root CA and issuer were generated manually in `~/linkerd-pki` on the control-plane. The root lasts about ten years; the issuer expires on **6 November 2027 at 13:24:20 UTC**. Automatic issuer rotation is not configured.
- Namespace `linkerd` and Secret `linkerd-identity-issuer` were created before installation. The `kubernetes.io/tls` Secret contains `tls.crt`, `tls.key`, and `ca.crt`; `identity.issuer.scheme: kubernetes.io/tls` uses this existing Secret. The root private key was not uploaded to the cluster. Only the public CA is stored in `platform/linkerd/values.yaml`; preserve private keys outside Git.
- Webhooks use a separate cert-manager chain: two Issuers, a CA Certificate, and three server Certificates in `platform/linkerd-webhooks/certificates.yaml`. Server certificates last 90 days and renew 30 days before expiry; `externalSecret` and `injectCaFrom` prevent random certificate generation during Helm rendering. Full CA-chain rotation requires separate planning.
- All three server keys explicitly use `encoding: PKCS8` with usages `digital signature` and `server auth`. Without PKCS8, container `policy` exited with `failed to read TLS key: could not load private key`; it recovered automatically after reissuance.
- Bootstrap Applications `linkerd-crds`, `linkerd-webhooks`, and `linkerd` have no finalizer and use `selfHeal: true`, `prune: false`. `linkerd` has two sources (chart and Git values); Mutating/ValidatingWebhookConfiguration `caBundle` is excluded from comparison with `RespectIgnoreDifferences=true` because cert-manager populates it.

On a fresh cluster, first install Gateway API CRDs and create the namespace and issuer Secret with certificates. Apply `bootstrap/linkerd-crds.yaml`, then `bootstrap/linkerd-webhooks.yaml` (wait for all Certificates to become Ready), then `bootstrap/linkerd.yaml`. The public trust anchor in Git must match the issuer Secret: restoring manifests alone without keys is insufficient. Sync `workloads/mesh-demo` after the control plane is ready; otherwise `failurePolicy: Ignore` may allow pods to start without proxies.

### Mesh and mTLS verification

`workloads/mesh-demo/` contains Deployments `client` (busybox) and `web` (nginx) and Service `web` in namespace `mesh-demo`. Both run on the worker. Injection is enabled through `linkerd.io/inject: enabled` only on these pod templates. Proxy requests: 10m CPU / 32Mi. Other applications are not meshed.

The client requests `http://web` every five seconds. Both pods became `2/2 Running`, the Application was `Synced / Healthy`, and logs showed `HTTP request OK`. Both `linkerd check` and `linkerd check --proxy --namespace mesh-demo` passed, including proxy certificate checks.

```bash
linkerd check
linkerd check --proxy --namespace mesh-demo
kubectl -n mesh-demo logs deployment/client -c client --tail=10
linkerd diagnostics proxy-metrics -n mesh-demo deploy/web \
  > /tmp/mesh-web-proxy-metrics.txt
linkerd diagnostics proxy-metrics -n mesh-demo deploy/client \
  > /tmp/mesh-client-proxy-metrics.txt
grep '^request_total' /tmp/mesh-web-proxy-metrics.txt | grep 'tls="true"'
grep '^request_total' /tmp/mesh-client-proxy-metrics.txt | grep 'tls="true"'
```

mTLS was confirmed: server metrics show `tls="true"` and `client_id`, while client metrics show `tls="true"` and `server_id`. Both identities are `default.mesh-demo.serviceaccount.identity.linkerd.cluster.local` because they share ServiceAccount `default`. Applications use HTTP; the proxy-to-proxy connection is secured. Policy remains `all-unauthenticated`: observing mTLS does not mean unencrypted clients are denied. Dedicated ServiceAccounts and mandatory authorization are not configured yet.

## NetBird: service access without port-forward

ArgoCD is available from the Mac connected to NetBird Cloud: **https://argocd-server.argocd.k8s.lab.internal**. DNS resolves to ClusterIP `10.106.250.7`; access from the Mac was verified with HTTP 200. The self-signed certificate still requires browser trust. Grafana is exposed through NetworkResource and PostgreSQL through Terraform in the separate NetBird repository; addresses and policies are described below.

NetBird Cloud configuration is now managed in the private Netbird repository. Change Cloud groups, policies, resources, and DNS there through Terraform plan/apply. The Kubernetes router and existing operator manifests remain here; agree on field ownership before changing jointly managed objects.

### External Secrets and Vault

`bootstrap/external-secrets.yaml` installs External Secrets Operator (chart `2.14.0`) in namespace `external-secrets`. cert-manager issues its webhook certificate through `ClusterIssuer/selfsigned-issuer`; the built-in cert-controller is disabled. The Application was verified as `Synced / Healthy`.

Secret values were written to Vault manually and are not stored in Git. External Secrets uses Kubernetes auth with audience `vault`, separate ServiceAccounts, and roles granting read access only to their respective paths:

| Vault KV v2 | Field | Kubernetes Secret in `netbird` | Key |
|---|---|---|---|
| `secret/netbird` | `setup_key` | `netbird-setup-key` | `NB_SETUP_KEY` |
| `secret/netbird-operator` | `api_key` | `netbird-mgmt-api-key` | `NB_API_KEY` |

Policies and roles are defined in `iac/vault/netbird.tf` and `iac/vault/netbird-operator.tf` and have been applied with OpenTofu. `workloads/netbird/secrets.yaml` and `operator-secret.yaml` create SecretStore and ExternalSecret resources, with a `1h` refresh interval, `creationPolicy: Orphan`, and `deletionPolicy: Retain`. Both stores were verified as `Valid`, and both ExternalSecrets as `SecretSynced`. Vault must be unsealed for refreshes; existing Kubernetes Secrets remain available when Vault is unavailable.

### Operator, router, and access

`bootstrap/netbird-operator.yaml` installs OCI chart `ghcr.io/netbirdio/helm-charts/netbird-operator` version `0.9.0`, using `platform/netbird-operator/values.yaml`. It runs one replica with cert-manager webhook TLS; ingress and Gateway API integrations are disabled. The PAT belongs to a NetBird user with the **Admin** role: SetupKey creation failed with `permission denied` under Network Admin. The operator creates its own SetupKey for the router; the synced `netbird-setup-key` is not consumed by the current NetworkRouter.

The `k8s-lab-admins` group containing the Mac and the `k8s.lab.internal` DNS zone were created manually in NetBird Cloud. An access policy grants the admin group access to the ArgoCD resource. The default `All ↔ All` peer policy alone did not provide a route to this resource.

- `workloads/netbird/router.yaml`: NetworkRouter `lab` in `netbird`, one replica on `k8s-worker`, referencing the DNS zone.
- `workloads/netbird/argocd-resource.yaml`: NetworkResource `argocd` in namespace `argocd`, referencing Service `argocd-server`, router `netbird/lab`, and group `k8s-lab-admins`.
- `workloads/netbird/grafana-resource.yaml`: Group `grafana` (NetBird group `k8s-lab-grafana`) and NetworkResource `grafana` in namespace `monitoring`, referencing Service `monitoring-grafana` and router `netbird/lab`.
- The `netbird` Application is generated from `workloads/*`; resource manifests explicitly set namespace `argocd` or `monitoring`.

The operator and router were verified ready, and the NetworkResource reported `Ready=True`. NetBird Cloud admin group, DNS zone, and access policies are defined in Terraform in the private Netbird repository.

### Grafana through NetBird

Address: **http://monitoring-grafana.monitoring.k8s.lab.internal**. DNS resolves to ClusterIP `10.103.1.3`; the Service listens on TCP 80 and forwards requests to Grafana on port 3000. On 11 November 2026, the Mac verified the route through `utun100`, HTTP 302 to the login page, and application access. Use the existing Grafana credentials.

The operator manages destination group `k8s-lab-grafana` from Git. Policy `k8s-lab-grafana-admins` was created through the NetBird Cloud API: source `k8s-lab-admins`, destination `k8s-lab-grafana`, TCP port 80 only, directed from client to resource. The policy and other Grafana Cloud objects have been imported into Terraform in the private Netbird repository. Operator 0.9.0's legacy `NBPolicy` expects `NBResource` and skips rule creation without it; Grafana uses `NetworkResource`.

This is direct HTTP access to the Service inside the NetBird tunnel; TLS is not configured on this address. The existing HTTPS ingress address `https://grafana.lab.local:30971` remains available.

Check from the Mac:

```bash
curl -sS --connect-timeout 10 --max-time 20 \
  -o /dev/null -w 'Grafana HTTP: %{http_code}\n' \
  http://monitoring-grafana.monitoring.k8s.lab.internal
```

Expect HTTP 302 redirecting to login. In the cluster, `kubectl -n monitoring get group.netbird.io grafana` and `kubectl -n monitoring get networkresource grafana` should report `Ready=True`.

### PostgreSQL through NetBird

Cloud configuration lives in the Netbird repository: Terraform creates group `k8s-lab-postgres`, network resource `10.98.193.66/32`, an A record, and policy `k8s-lab-postgres-admins`. Only `k8s-lab-admins` receives TCP/5432 access through existing router `lab`. No Kubernetes NetworkResource is created for PostgreSQL, avoiding competing operator and Terraform ownership.

| DBeaver / DataGrip / pgAdmin setting | Value |
| --- | --- |
| Host | `postgres.postgres.k8s.lab.internal` |
| Port | `5432` |
| Database | `lab` |
| User | `lab_app` |
| Password | Previously assigned `lab_app` password; not stored in Git |
| SSL mode | `disable` (PostgreSQL TLS is off; Mac traffic uses the NetBird tunnel) |

No SSH tunnel or port-forward is required. If psql is installed on the Mac:

```bash
psql 'host=postgres.postgres.k8s.lab.internal port=5432 dbname=lab user=lab_app sslmode=disable' -W
```

Enter the password interactively. After login, check `SELECT current_user, current_database();`. `lab_app` is a restricted role for schema `app`; network access does not grant additional database privileges. Service `postgres/postgres` remains a ClusterIP on TCP/5432 with targetPort 5432; if its IP changes, update the Terraform resource and DNS in the Netbird repository.

Check the network from the Mac:

```bash
dscacheutil -q host -a name postgres.postgres.k8s.lab.internal
route -n get 10.98.193.66
nc -vz -w 5 postgres.postgres.k8s.lab.internal 5432
```

On 11 November 2026, Terraform apply in the Netbird repository created four objects without changing existing ones. The Mac verified DNS `10.98.193.66`, routing through `utun100`, TCP/5432, and a SCRAM-SHA-256 authentication challenge for `lab_app`/`lab`. Full SQL login requires the existing password and was not performed by this check.

### Router routes

During troubleshooting, the routing peer had automatically selected `Exit Node (Belgrade)`. ClusterIP, pod IP, and DNS traffic went through `wt0`, causing timeouts from the Mac despite a working tunnel. After `netbird networks deselect "Exit Node (Belgrade)"`, routes returned to `eth0`, TCP connectivity to the Service and pod worked, and ArgoCD returned 200.

In `router.yaml`, ConfigMap `netbird-router-config` sets `NB_DISABLE_CLIENT_ROUTES: "true"`; the `netbird` container receives it through `envFrom`. This disables consumption of client routes, including Exit Nodes, while preserving routing peer functionality for Kubernetes services. A direct `env` override in operator 0.9.0 conflicted with `NB_SETUP_KEY.valueFrom` and was not applied. The ConfigMap fix is `6f14f3b`; after pod recreation on 11 November, the variable was `true`, the route used `eth0`, and the Mac received HTTP 200.

On a cluster node:

```bash
kubectl -n argocd get application netbird netbird-operator external-secrets
kubectl -n netbird get networkrouter,secretstore,externalsecret
kubectl -n argocd get networkresource argocd
kubectl -n netbird exec deployment/networkrouter-lab -c netbird -- printenv NB_DISABLE_CLIENT_ROUTES
kubectl -n netbird exec deployment/networkrouter-lab -c netbird -- ip route get 10.106.250.7
```

Expect `true` and a route through `eth0` rather than `wt0`. On the Mac:

```bash
netbird networks list
route -n get 10.106.250.7
curl -k -sS --connect-timeout 10 --max-time 20 \
  -o /dev/null -w 'ArgoCD HTTP: %{http_code}\n' \
  https://argocd-server.argocd.k8s.lab.internal
```

The resource should be selected, the route should use the NetBird interface (`utun…`), and the response should be HTTP 200. Here `-k` checks connectivity with the self-signed certificate.

## Operations: after a VM reboot

Maintain nodes one at a time. While the control-plane is off, the API, Vault, and Prometheus are unavailable; the worker can remain running. After setting control-plane RAM to 6144 MiB, the VM was started, Vault unsealed, and applications checked. Restarting only the worker does not require unsealing Vault unless `vault-0` also restarted. Check `/proc/swaps` on both nodes.

Kubernetes starts automatically (`containerd` and `kubelet` are enabled at boot); allow 3–5 minutes. Manual steps after reboot:

1. Unseal Vault (command above), otherwise `vault-demo` and other pods using the injector remain unready.
2. Open ArgoCD through NetBird: `https://argocd-server.argocd.k8s.lab.internal`. Port-forward remains a fallback: `kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443`.

Post-boot checks:

```bash
cat /proc/swaps                                  # header only
kubectl get nodes
kubectl get pods -A | grep -v ' Running '
```

## etcd backups

The control-plane runs `/usr/local/sbin/etcd-snapshot.sh`. It creates snapshots using `etcdctl` inside `etcd-kubernetes`, checks readability with `etcdutl snapshot status`, and deletes snapshots older than seven days only after success. Files are stored in `/var/lib/etcd/snapshots` (directory `0700`, files `0600`). Root execution uses `/etc/kubernetes/admin.conf`.

`etcd-snapshot.timer` runs daily at 03:00 UTC with up to five minutes of delay. `Persistent=true` catches up on a missed run after VM boot. `etcd-snapshot.service` uses `Restart=on-failure`, a five-minute retry delay, and a five-minute timeout. The script and units were added to the separate `etcd_backup` role and `etcd-backup.yml` playbook in [ansible-create-kubeadm](https://github.com/servik01/ansible-create-kubeadm/tree/main/roles/etcd_backup). Applying Ansible in the lab is deferred; the current installation was configured manually.

```bash
sudo systemctl start etcd-snapshot.service
sudo systemctl status etcd-snapshot.service --no-pager
sudo systemctl list-timers --all etcd-snapshot.timer
sudo journalctl -u etcd-snapshot.service -n 25 --no-pager
```

For `Type=oneshot`, `inactive (dead)` with `status=0/SUCCESS` is expected after success. Snapshots of about 24 MB were created and a trial `etcdutl snapshot restore` into a separate directory under `/var/lib/etcd` succeeded. The checksum was verified, data was restored, and both nodes remained `Ready`; the test directory was then removed. Starting the restored etcd and full cluster recovery have not been tested.

Snapshots contain Kubernetes Secrets and must stay out of Git. They exclude PVC data, PKI, and external encryption keys. Off-node copying is not configured: losing the control-plane disk would lose both etcd and its local snapshots.

## Drain / uncordon exercise

The only worker was drained with no PDBs present. Regular pods were evicted while DaemonSet pods remained; CoreDNS created a replacement on the control-plane. Applications without a toleration stayed `Pending`: the control-plane was tainted and the worker was unschedulable.

```bash
kubectl drain k8s-worker --ignore-daemonsets --delete-emptydir-data --timeout=180s
kubectl uncordon k8s-worker
```

These maintenance exercise commands cause application downtime; `--delete-emptydir-data` permits deletion of temporary `emptyDir` data. Drain waits for old pods to be deleted, not for replacements to become ready. After `uncordon`, pending pods started automatically, all Applications returned to `Synced / Healthy`, and nginx and whoami returned HTTP 200 through the control-plane NodePort.

The exercise preceded the move of ArgoCD and Grafana and PostgreSQL to the worker. Draining now affects them too, and Grafana's local volume ties it to the worker. Two replicas on a single eligible node do not protect against maintenance of that node. No PDB has been added yet.

## Monitoring (kube-prometheus-stack)

Application `workloads/monitoring`: a wrapper chart (`Chart.yaml` depends on `kube-prometheus-stack` 91.9.0 from `https://prometheus-community.github.io/helm-charts`; settings in `values.yaml` under `kube-prometheus-stack:`).

**Before the first sync**, manually create the namespace and Grafana password. The chart does not generate the password: Helm would generate a random one on every Argo render, causing perpetual Secret drift. The password is excluded from values because the repository is public.

```bash
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"

# read the password:
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The ApplicationSet template includes `ServerSideApply=true`: this chart's CRDs exceed the `last-applied-configuration` annotation limit of regular `kubectl apply`.

Key `values.yaml` settings:

- Alertmanager is enabled: one replica and a 1Gi PVC on the control-plane; external notification channels are not configured yet.
- Grafana and Prometheus are exposed through ingress-nginx with TLS from `selfsigned-issuer` (`grafana.lab.local`, `prometheus.lab.local`).
- Prometheus: 5Gi on control-plane `local-path`, 7-day retention; a toleration allows its pod to restart on that node.
- Grafana: 1Gi, `persistence.existingClaim: grafana-worker-data`, `nodeSelector` targeting `k8s-worker`, no control-plane toleration. Static PV/PVC definitions are in `workloads/monitoring/templates/grafana-worker-storage.yaml`: `storageClassName: ""`, `Retain`, local path `/opt/local-path-provisioner/grafana-worker-data`.
- `serviceMonitorSelectorNilUsesHelmValues: false` and `podMonitorSelectorNilUsesHelmValues: false`: Prometheus discovers ServiceMonitor and PodMonitor resources from all applications, regardless of this release's label.
- cert-manager issues the operator webhook certificates (`admissionWebhooks.certManager.enabled`, jobs disabled), avoiding hook jobs and `caBundle` drift in Argo.
- Control-plane monitors are enabled: `kubeControllerManager` and `kubeScheduler` over HTTPS with `insecureSkipVerify` (self-signed certificates), `kubeEtcd` over HTTP on 2381. Metrics are exposed through kubeadm configuration (see kubeadm configuration). `kubeProxy` is disabled because the cluster has no kube-proxy.
- `kubelet.serviceMonitor.insecureSkipVerify: true`: kubelet has a self-signed certificate, as with metrics-server.

Access: add `192.168.64.55 grafana.lab.local prometheus.lab.local` to `/etc/hosts` on the Mac, then open `https://grafana.lab.local:30971` (username `admin`) and `https://prometheus.lab.local:30971`. The Prometheus UI has no authentication; restrict access in production. **Status → Targets** should show `UP` for apiserver, kubelet (including cadvisor), kube-state-metrics, node-exporter, and coredns.

Useful Prometheus query for memory usage by namespace: `sum by (namespace) (container_memory_working_set_bytes{container!=""})`.

### Application metrics and Alertmanager

PostgreSQL, ArgoCD, and Vault were connected on 11 November 2026. Prometheus remains Grafana's main datasource. Dashboard **Lab Applications** is available through NetBird: **http://monitoring-grafana.monitoring.k8s.lab.internal/d/lab-applications**. Its JSON lives in `workloads/monitoring/dashboards/lab-applications.json`; the standard Grafana sidecar loads the ConfigMap labeled `grafana_dashboard: "1"`.

| Source | Implementation | Verified data |
| --- | --- | --- |
| PostgreSQL | `postgres-exporter:v0.20.1`, Deployment/Service/ServiceMonitor in `workloads/postgres/monitoring.yaml` | `pg_up=1`, connections and transactions by database |
| ArgoCD | Four ServiceMonitors in `workloads/monitoring/templates/argocd-servicemonitors.yaml` | Controller, server, repo-server, ApplicationSet; `argocd_app_info` for 17 Applications |
| Vault | `vault.serverTelemetry.serviceMonitor` and Raft HCL in `workloads/vault/values.yaml` | `vault_core_unsealed=1`, runtime and request metrics |
| Alertmanager | Enabled in kube-prometheus-stack | Alertmanager runtime metrics and active alerts |

The exporter uses a separate PostgreSQL role `postgres_exporter`: `LOGIN` plus `pg_monitor`, without superuser, database/role creation, replication, or bypass RLS. The password is mounted as a file from Secret `postgres-exporter-auth`, not stored in Git, the URI, or container arguments. `lab_app` remains restricted. The exporter runs on the control-plane with a toleration, requests `10m/32Mi`, and a `128Mi` memory limit; PostgreSQL itself was not restarted.

Before the first exporter sync, or after initializing PostgreSQL on an empty PVC, create the role and Secret from the repository root with a working kubectl context:

```bash
python3 scripts/bootstrap-postgres-monitoring.py
```

The script uses administrative local access inside `postgres-0`, creates a random password without printing it, reuses an existing Secret password, and grants `pg_monitor`. It does not change `lab_app`'s password. The role lives in PostgreSQL and the Secret in Kubernetes; if the Secret is recreated with a new password, rerun bootstrap and restart the exporter to reload the file.

Vault retains Prometheus metrics for `60s` with `disable_hostname=true`. Prometheus accesses internal `/v1/sys/metrics?format=prometheus` without a token through `listener.telemetry.unauthenticated_metrics_access=true`; other Vault APIs still require authorization. The metrics endpoint is not exposed through ingress or NetBird. Changing HCL requires restarting `vault-0` (`OnDelete`) and unsealing it; before the initial change, a Raft snapshot was saved at `/root/vault-before-monitoring-20261111T121621Z.snap` on the control-plane.

Alertmanager runs one replica on the control-plane, with a `1Gi` local-path PVC, requests `10m/64Mi`, and a `256Mi` memory limit. Prometheus discovers it automatically. Grafana's **Alertmanager** datasource now points to a running service. External email/Telegram/Slack receivers are not configured: the receiver is `null`, and alerts are available through the UI/API. Prometheus → Alertmanager delivery was verified using the standard `Watchdog` alert, a continuous control signal rather than an application incident.

Rules in `workloads/monitoring/templates/application-alerts.yaml`:

- `LabPostgreSQLUnavailable`: `pg_up=0` for 2 minutes.
- `LabApplicationMetricsUnavailable`: a new metrics endpoint is unavailable for 5 minutes.
- `LabArgoCDApplicationUnhealthy`: application health outside `Healthy/Progressing` for 10 minutes.
- `LabVaultSealed`: `vault_core_unsealed=0` for one minute.

Cluster checks:

```bash
kubectl -n postgres get deployment postgres-exporter
kubectl -n monitoring get alertmanager,pvc,pods
kubectl get servicemonitors -A
kubectl -n monitoring get prometheusrule lab-applications
```

In Grafana Explore, select Prometheus and query `pg_up`, `argocd_app_info`, `vault_core_unsealed`, and `alertmanager_alerts`. New scrape targets were verified `UP`, and rules evaluate without errors. Existing Kubernetes/Cilium dashboards remain available alongside **Lab Applications**.

### Moving Grafana to the worker

Grafana was stopped through `replicas: 0` in Git. After ArgoCD synced and the pod disappeared, its data was archived. The old PV, `pvc-ad02317a-3577-45d3-bcc9-805e5fdfc2c3`, was changed to `Retain`. The archive was transferred to the worker over SSH and its SHA-256 matched. Restored data occupied 55 MB, with owner `472:472`; directory permissions were restricted to `0750`.

Once the new PV/PVC were `Bound`, values were updated with `existingClaim`, worker placement, and `replicas: 1`. Grafana became `3/3 Running`; UI operation and data preservation were confirmed. Archives at `/var/backups/grafana-migration/grafana-data.tar.gz` on both nodes and the original control-plane data remain available for rollback. ArgoCD may have pruned the old PVC; the old PV's `Retain` policy preserves its data directory.

For a fresh installation, create the worker directory first and assign ownership to `472:472`; the static PV manifest does not create the directory or restore data. For future Grafana updates, account for `ReadWriteOnce`: stop the pod during storage migration or maintenance; use the `Recreate` strategy to avoid two pods writing to the volume during updates.

## Network observability (Hubble)

Hubble and metrics are enabled in `platform/cilium/values.yaml` and applied through Git and ArgoCD (see Cilium managed by ArgoCD). Initially, they were enabled with `cilium upgrade` using the same settings.

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      className: nginx
      annotations:
        cert-manager.io/cluster-issuer: selfsigned-issuer
      hosts:
        - hubble.lab.local
      tls:
        - secretName: hubble-tls
          hosts:
            - hubble.lab.local
  metrics:
    enabled: [dns, drop, tcp, flow, port-distribution, icmp]
    serviceMonitor:
      enabled: true
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true
operator:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
```

UI: `https://hubble.lab.local:30971` (add `192.168.64.55 hubble.lab.local` to `/etc/hosts` on the Mac). Select a namespace in the upper left. Hubble displays flows as they occur, so a quiet namespace has an empty map. To demonstrate a NetworkPolicy drop, run a pod without `role=client` and access `web`, then compare with `client`:

```bash
kubectl -n netpol-demo run intruder --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl -n netpol-demo exec intruder -- wget -qO- --timeout=2 http://web
kubectl -n netpol-demo exec deploy/client -- wget -qO- --timeout=2 http://web
kubectl -n netpol-demo delete pod intruder
```

In the UI, `client → web` is a solid line with verdict `forwarded`, while `intruder → web` is a red dashed line with verdict `dropped`. The `intruder` node is labeled with its namespace: Hubble uses the `app` label, which the pod created by `kubectl run` lacks.

Metrics: Prometheus discovers targets `cilium-agent` (port 9962), `cilium-operator` (9963), and `hubble` (9965). Scraping uses node IPs because the agent runs in the host network. Policy drops: `sum by (reason, protocol) (increase(hubble_drop_total[30m]))`.

CLI (arm64 build, like the Cilium CLI):

```bash
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-arm64.tar.gz
sudo tar xzvfC hubble-linux-arm64.tar.gz /usr/local/bin
rm hubble-linux-arm64.tar.gz

cilium hubble port-forward &
hubble observe --namespace netpol-demo --verdict DROPPED --last 20
```

## Cilium managed by ArgoCD

Cilium was originally installed and upgraded through the CLI, with settings stored only in the cluster's Helm release. After this caused a cold-start failure (see Troubleshooting), the configuration was moved to Git.

- `platform/cilium/values.yaml`: chart values exported from the Helm release (`k8sServiceHost: k8s-api.lab.local`, `kubeProxyReplacement`, Hubble, metrics).
- `bootstrap/cilium.yaml`: a two-source Application: chart `cilium` version 1.20.1 from `https://helm.cilium.io/` and this repository as `ref: values`. Applied manually. `platform/` is outside `workloads/*`, so ApplicationSet does not manage it.

Application details:

- **No finalizer**: deleting the Application does not remove the CNI.
- **`ignoreDifferences` for `/data`** on Secrets `cilium-ca`, `hubble-server-certs`, and `hubble-relay-client-certs`, together with `RespectIgnoreDifferences=true`: the chart generates these certificates on every render; without this rule Argo would rotate them on every sync.
- **`automated` with `selfHeal: true` and `prune: false`**: manual changes revert to Git, while Argo does not delete resources automatically.

Export release values (the Cilium CLI stores the release in a Helm Secret; installing `helm` is unnecessary). Check the output for secrets before committing:

```bash
REL=$(kubectl -n kube-system get secret -l owner=helm,name=cilium,status=deployed \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system get secret "$REL" -o jsonpath='{.data.release}' \
  | base64 -d | base64 -d | gunzip | jq '.config'
```

Migration sequence that worked without pod restarts: create the Application without `automated`, compare with `argocd app diff cilium --core` (the only difference was the `argocd.argoproj.io/tracking-id` annotation), run `argocd app sync cilium --core` manually and compare pod `startTime` before and after, then enable `automated`. In `--core` mode, the ArgoCD CLI uses kubeconfig and needs namespace `argocd` in the current context: `kubectl config set-context --current --namespace=argocd` (restore `default` after the diff). Use `argocd-linux-arm64` from the releases page.

**Rule**: make all Cilium changes in `platform/cilium/values.yaml` and run `git push`; do not use `cilium upgrade`. Keep the CLI for `cilium status` and diagnostics. `k8sServiceHost: k8s-api.lab.local` works because the agent and operator use `hostNetwork` and resolve the name through the node's `/etc/hosts`.

For a fresh cluster, install Cilium using the CLI first (see Installing Cilium), then run `kubectl apply -f bootstrap/cilium.yaml`. Argo adopts the resources, adding its tracking metadata.

## Kubernetes 1.35 to 1.36: step-by-step upgrade

This runbook applies to this lab: one control-plane `kubernetes` (`192.168.64.55`) and worker `k8s-worker` (`192.168.64.57`), Debian 13 ARM64, kubeadm, and Cilium without kube-proxy. The target is **v1.36.6**, package version **`1.36.6-1.1`**. For a future upgrade, select an explicit patch release and package version first; these commands do not automatically choose the latest release.

Upgrade the control-plane first, then the worker, one node at a time. References: [kubeadm 1.35 → 1.36 procedure](https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/), [changing the apt repository](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/), and [drain](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/). Check the [Cilium compatibility matrix](https://docs.cilium.io/en/stable/network/kubernetes/requirements/) and [Linkerd Kubernetes support](https://linkerd.io/docs/reference/k8s-versions/).

### 1. Check the baseline and plan downtime

On the control-plane as `k8s`:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl -n argocd get applications
kubectl get pdb -A
kubectl get pvc -A
kubectl -n vault exec vault-0 -- vault status
kubeadm version -o short
apt-cache policy kubeadm kubelet kubectl
apt-mark showhold
sudo -n true
```

Both nodes initially run 1.35.10. Proceed only with a healthy API, ready nodes, and an understood cause for any unhealthy application. Check Cilium, Linkerd, admission webhook, and API compatibility. This lab has no PDBs at upgrade time. If a PDB blocks drain, resolve availability and replica requirements instead of bypassing it with `--disable-eviction`.

The single control-plane causes a brief API outage during static pod replacement. Draining it stops Vault and Prometheus on local PVs; draining the worker affects PostgreSQL, Grafana, ArgoCD, and the NetBird router. Local volumes cannot move to the other node. Use SSH to node addresses because NetBird/ArgoCD access will be interrupted during worker maintenance. Below, `--delete-emptydir-data` permits temporary `emptyDir` data loss; it does not delete PVCs.

### 2. Back up state and configuration

On **each node**, in its own SSH session, before changing packages:

```bash
backup_dir="/root/kubernetes-before-1.36-$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -m 700 "$backup_dir"
sudo cp -a /etc/kubernetes /var/lib/kubelet/config.yaml \
  /etc/apt/sources.list.d/kubernetes.list "$backup_dir/"
sudo sh -c 'dpkg-query -W kubeadm kubelet kubectl > "$1/packages.txt"; apt-mark showhold > "$1/holds.txt"' sh "$backup_dir"
printf 'Backup: %s\n' "$backup_dir"
df -h / /var/lib/containerd
```

Additionally on the **control-plane**, in the same session with `backup_dir` set:

```bash
sudo systemctl start etcd-snapshot.service
sudo systemctl show etcd-snapshot.service -p Result -p ExecMainStatus
sudo ls -lt /var/lib/etcd/snapshots | head -5
kubectl -n kube-system get cm kubeadm-config -o yaml \
  | sudo tee "$backup_dir/kubeadm-config.yaml" >/dev/null
set -o pipefail
kubectl -n postgres exec postgres-0 -- pg_dumpall -U postgres \
  | sudo tee "$backup_dir/postgres-all.sql" >/dev/null
sudo chmod 600 "$backup_dir/postgres-all.sql"
```

Expect `Result=success`, `ExecMainStatus=0`, and a new snapshot; the service validates it with `etcdutl`. PostgreSQL needs a separate dump: etcd snapshots contain Kubernetes objects, not PVC data. Keep the existing `~/vault-init.json` available for unseal without printing its contents. Configuration, dumps, and keys contain secrets and must stay outside Git; a backup on the same VM does not protect against losing its disk.

### 3. Install the new kubeadm on the control-plane

Only on `kubernetes`:

```bash
sudo sed -i 's@core:/stable:/v1\.35/deb/@core:/stable:/v1.36/deb/@' \
  /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
apt-cache madison kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.36.6-1.1
sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade plan v1.36.6
```

Only the Kubernetes channel in the existing apt source changes; retain the installed keyring. Verify that apt lists `1.36.6-1.1` before installation. The kubelet and API still run the old version at this point. `upgrade plan` checks the cluster and lists component changes; stop on an error rather than adding `--ignore-preflight-errors`.

### 4. Upgrade the control-plane

```bash
sudo kubeadm upgrade apply v1.36.6 --skip-phases=addon/kube-proxy --yes
kubectl get --raw='/readyz?verbose'
kubectl -n kube-system get pods -o wide
kubectl -n kube-system get ds kube-proxy --ignore-not-found
```

Kubeadm reads ConfigMap `kubeadm-config` and updates static pods, etcd, CoreDNS, and kubelet configuration. Controller-manager, scheduler, and etcd metrics flags should be preserved. This installation requires `--skip-phases=addon/kube-proxy` because Cilium handles Service/NodePort traffic. A warning about the missing kube-proxy ConfigMap is expected; no kube-proxy DaemonSet should appear. Wait for a healthy API before proceeding.

### 5. Upgrade control-plane kubelet and kubectl

```bash
kubectl drain kubernetes --ignore-daemonsets --delete-emptydir-data --timeout=300s
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.36.6-1.1 kubectl=1.36.6-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
kubectl uncordon kubernetes
kubectl wait --for=condition=Ready node/kubernetes --timeout=180s
kubectl get nodes -o wide
```

Drain stops new scheduling and evicts regular pods; DaemonSet and static pods remain. Replacements using local volumes may wait for `uncordon`. Restart kubelet after upgrading it. `uncordon` restores scheduling; node `Ready` alone does not mean that applications have recovered.

### 6. Recover Vault and check the control-plane before the worker

```bash
kubectl -n vault wait --for=jsonpath='{.status.phase}'=Running pod/vault-0 --timeout=180s
(
  set -euo pipefail
  set +x
  jq -er '.unseal_keys_b64[0]' "$HOME/vault-init.json" \
    | kubectl -n vault exec -i vault-0 -- sh -ec 'IFS= read -r key; vault operator unseal "$key" >/dev/null'
)
kubectl -n vault exec vault-0 -- vault status
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s
kubectl -n linkerd get pods
kubectl -n kube-system get pods
kubectl top nodes
```

The unseal command assumes the existing lab Shamir setup: **1 share / threshold 1** and a local initialization file. It does not print the key. Do not run `vault operator init` again. Before worker maintenance, verify Vault, Linkerd, CoreDNS, Hubble relay, and metrics-server readiness. If metrics-server moved and `top` fails, apply the saved patch from the repository root:

```bash
kubectl -n kube-system patch deployment metrics-server --type=strategic \
  --patch-file platform/metrics-server/placement-patch.yaml
```

### 7. Prepare the worker

In an SSH session on **`k8s@192.168.64.57`**, repeat the repository switch and kubeadm installation from step 3, but replace `upgrade plan/apply` with:

```bash
sudo sed -i 's@core:/stable:/v1\.35/deb/@core:/stable:/v1.36/deb/@' \
  /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
apt-cache madison kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get install -y kubeadm=1.36.6-1.1
sudo apt-mark hold kubeadm
kubeadm version -o short
sudo kubeadm upgrade node
```

Do not run `upgrade apply` on the worker. The control-plane has already been upgraded; `upgrade node` prepares local kubelet configuration. The worker kubelet still runs 1.35.10. Stop if this command fails, before installing the new kubelet.

### 8. Drain the worker, upgrade packages, and restore workloads

From the **control-plane**:

```bash
kubectl drain k8s-worker --ignore-daemonsets --delete-emptydir-data --timeout=300s
```

On the **worker**:

```bash
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.36.6-1.1 kubectl=1.36.6-1.1
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

From the **control-plane**:

```bash
kubectl uncordon k8s-worker
kubectl wait --for=condition=Ready node/k8s-worker --timeout=180s
kubectl get pods -A -o wide
```

Wait for applications, not just drain completion. Verify `postgres-0` readiness and retained data, Grafana's existing PVC, and ArgoCD server/controllers. If the Vault injector or another webhook is unavailable, recover it before recreating dependent pods.

### 9. Verify the result and update Git

On the control-plane:

```bash
kubectl get nodes -o wide
kubectl -n argocd get applications
kubectl get pods -A
kubectl get deployments,statefulsets -A
kubectl top nodes
kubectl -n netbird get networkrouter,secretstore,externalsecret
kubectl -n argocd get networkresource argocd
kubectl -n postgres exec postgres-0 -- pg_isready -U postgres
"$HOME/.linkerd2/bin/linkerd" check
"$HOME/.linkerd2/bin/linkerd" check --proxy --namespace mesh-demo
for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$pod" -- cilium-health status --probe
  kubectl -n kube-system exec "$pod" -- cilium-dbg status
done
sudo systemctl start etcd-snapshot.service
sudo systemctl show etcd-snapshot.service -p Result -p ExecMainStatus
```

On **each node**, check `dpkg-query -W kubeadm kubelet kubectl`, `apt-mark showhold`, and `systemctl is-active kubelet`: all package versions must be `1.36.6-1.1`, with all three packages held. On the Mac, verify ArgoCD through NetBird:

```bash
curl -k -sS --connect-timeout 10 --max-time 20 \
  -o /dev/null -w 'ArgoCD HTTP: %{http_code}\n' \
  https://argocd-server.argocd.k8s.lab.internal
```

Completion criteria: both nodes `Ready` on v1.36.6; Applications `Synced / Healthy`; all expected containers ready; Cilium reaches both nodes and health endpoints; Linkerd checks pass; NetBird and ESO ready; PostgreSQL/Grafana data retained. Check the Linkerd section's mTLS metrics and nginx/whoami ingress HTTP responses. Update `kubernetesVersion` in `platform/kubeadm/config.yaml` and the current version/apt channel in both READMEs; use a Conventional Commit. Preserve historical upgrade records.

If apt/dpkg reports a busy lock, wait for the owning process to finish. Do not delete lock files. Once released, check `sudo dpkg --audit` and `dpkg-query -W kubeadm kubelet kubectl`, then complete the remaining `apt-mark hold`, restart, and uncordon steps. Successful package installation and successful hold configuration are separate checks.

### If a step fails

Do not maintain the second node until the first has recovered. Save the error output; inspect `journalctl -u kubelet -n 100 --no-pager`, pod events, and API health. Do not run `kubeadm reset` or replace `/var/lib/etcd` while etcd is running. Kubeadm stores backup manifests under `/etc/kubernetes/tmp`; downgrading packages alone does not roll back etcd state. Snapshot recovery is a separate disaster recovery procedure requiring stopped components and version checks. If failure occurred before control-plane replacement, compare packages and apt source with the backup; do not blindly restore old files after a successful API upgrade.

### Upgrade result: 11 November 2026

Both nodes were upgraded **1.35.10 → 1.36.6**; all three packages on each node are `1.36.6-1.1` and held. Etcd is `3.6.8-0`, CoreDNS `v1.14.2`; kube-proxy remains absent. Containerd, Cilium 1.20.1, and Linkerd edge-26.11.1 were not upgraded. Metrics flags in `kubeadm-config` were preserved.

Backup directories: control-plane `/root/kubernetes-before-1.36-20261111T094133Z`, worker `/root/kubernetes-before-1.36-20261111T094138Z`. An etcd snapshot and PostgreSQL dump were created before upgrading; a new post-upgrade snapshot was also successfully created and validated by the service.

Three operational issues occurred:

- A brief apt lock after control-plane package installation: the owning process finished, hold was retried, and `dpkg --audit` reported no problems.
- While the NetBird webhook started after worker drain, some pod creation attempts failed with `FailedCreate`. PostgreSQL recovered after the webhook became ready; `vault-demo` and `netpol-demo/client` were recovered with `rollout restart`. Check desired versus ready Deployment/StatefulSet replicas, not just readiness of existing pods.
- Recreating the NetBird router exposed an unapplied `env` override: the operator conflicted with the setup key reference, and the router selected an Exit Node again. The setting was moved to ConfigMap/`envFrom`, deployed through ArgoCD, and verified in the new pod; manual deselection is no longer required.

Final checks: both nodes Ready, 17 Applications Synced/Healthy, expected pods and controllers ready; Cilium host/endpoint health 2/2 from both nodes, successful Linkerd proxy check, and metrics with `tls="true"`. Vault is unsealed, ESO SecretStores Valid and ExternalSecrets SecretSynced, NetBird router/resource Ready. The `public.persistence_check` record and `lab_app` restrictions were retained; nginx/whoami returned 200, Grafana 302, and ArgoCD through NetBird from the Mac 200.

## Kubernetes upgrade to 1.35

On 6 November 2026, both nodes were upgraded sequentially from v1.34.12 to **v1.35.10**. Packages `kubeadm`, `kubelet`, and `kubectl` use version `1.35.10-1.1` from the `v1.35` apt repository and are pinned with `apt-mark hold`. Containerd and Cilium were not upgraded.

Preparation included a fresh etcd snapshot and backups of `/etc/kubernetes`, kubelet configuration, and the apt source in `/root/kubernetes-before-1.35-*` on each node. The same protected directory on the control-plane also holds `postgres-all.sql` from `pg_dumpall` (contains sensitive data and roles; keep it out of Git).

Sequence: upgrade kubeadm and run `upgrade plan`; on the first control-plane run `kubeadm upgrade apply v1.35.10 --skip-phases=addon/kube-proxy --yes`, then drain, upgrade kubelet/kubectl, restart kubelet, and uncordon. On the worker: upgrade kubeadm, run `kubeadm upgrade node`, drain, upgrade kubelet/kubectl, restart, and uncordon. Drain used `--ignore-daemonsets --delete-emptydir-data` with temporary application downtime. After `vault-0` was recreated, it was unsealed with the existing local key.

Kubeadm upgraded etcd to **3.6.6-0** and CoreDNS to **v1.13.1**. The kube-proxy phase was explicitly skipped and no DaemonSet was created: Cilium continues to handle Services and NodePort. `platform/kubeadm/config.yaml` now specifies v1.35.10; control-plane metrics flags were preserved. After drain, Hubble relay landed on the worker and timed out connecting to `hubble-peer`. Cilium values pin it to the control-plane with a toleration, restoring its previous working placement. `vault-demo` was recreated after the Vault injector became ready to restore its sidecar.

Final checks: both nodes Ready on v1.35.10, all 46 pods Ready, 14 Applications Synced/Healthy, Cilium health 2/2 with Hostns-only, and successful Linkerd checks and TLS metrics. PostgreSQL retained its test record and `lab_app` restrictions; nginx/whoami returned 200 and Grafana returned 302. Metrics-server was also restored to the control-plane using the stored placement patch; `kubectl top` sees both nodes again. Snapshot creation with the new etcd succeeded. Latest reading: worker 2405Mi (63%), control-plane 3269Mi (56%).

## kubeadm configuration (control-plane metrics)

By default, kubeadm binds controller-manager (port 10257), scheduler (10259), and etcd metrics (2381) to `127.0.0.1`, making them inaccessible to Prometheus in the cluster. Settings are in `platform/kubeadm/config.yaml` (`kubeadm.k8s.io/v1beta4`, where `extraArgs` is a list of `name`/`value` pairs):

- `controllerManager` and `scheduler`: `bind-address: 0.0.0.0`.
- `etcd`: `listen-metrics-urls: http://127.0.0.1:2381,http://192.168.64.55:2381`. Loopback comes first so etcd probes retain `127.0.0.1:2381`. etcd metrics use unauthenticated HTTP, so bind to the node address rather than all interfaces.
- `InitConfiguration` pins `advertiseAddress` and the node name so the `etcd` phase does not recalculate the existing member's settings.
- `kubernetesVersion` **must match the actual cluster version** (`kubeadm version`, `kubectl get nodes`). `init phase control-plane` and `init phase etcd local` derive image versions from this field. A stale value generates manifests with old images (for example, etcd 3.5 instead of 3.6, or apiserver one minor version behind); etcd cannot read data written by a newer version. After `kubeadm upgrade`, update `platform/kubeadm/config.yaml` in Git.

**Do not manually edit manifests in `/etc/kubernetes/manifests`**: the next `kubeadm upgrade` overwrites them using ConfigMap `kubeadm-config`. Edit the configuration, regenerate manifests using kubeadm phases, then upload the configuration to the cluster.

Before changing anything, create backups in the home directory outside the repository (they contain private cluster keys):

```bash
kubectl -n kube-system exec etcd-kubernetes -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db
sudo cp /var/lib/etcd/snapshot.db ~/etcd-snapshot-$(date +%F).db
sudo cp -a /etc/kubernetes ~/kubernetes-backup-$(date +%F)
sudo chown -R $USER: ~/etcd-snapshot-* ~/kubernetes-backup-*
```

Regenerate one component at a time, starting with the least risky. Compare against the backup after each phase (`B` is the `~/kubernetes-backup-*` directory). Kubelet recreates each static pod automatically within a minute:

```bash
B=$(ls -d ~/kubernetes-backup-* | tail -1)
sudo kubeadm init phase control-plane scheduler --config platform/kubeadm/config.yaml
sudo diff $B/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
sudo kubeadm init phase control-plane controller-manager --config platform/kubeadm/config.yaml
sudo diff $B/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo kubeadm init phase etcd local --config platform/kubeadm/config.yaml   # API briefly loses access to storage
sudo diff $B/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
sudo kubeadm init phase upload-config kubeadm --config platform/kubeadm/config.yaml
```

Expected diff: only one semantic change (`--bind-address` or `--listen-metrics-urls`). The line may move because kubeadm sorts arguments. Scheduler and controller-manager probes also lose `host: 127.0.0.1`: with `0.0.0.0`, kubeadm removes `host` and probes use the pod address (the node IP with `hostNetwork`). Roll back if `--cluster-cidr`, `--service-cluster-ip-range`, `--initial-cluster`, `--listen-peer-urls`, `--advertise-client-urls`, `--name`, `--data-dir`, or an image changes.

Roll back a component: `sudo cp $B/manifests/<file>.yaml /etc/kubernetes/manifests/`. If the cluster cannot recover, the etcd snapshot is available.

Verify with `sudo ss -tlnp | grep -E ':10257|:10259|:2381'` (`*` for the first two, two addresses for `:2381`), `curl -s http://192.168.64.55:2381/metrics | head -3`, and `kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -A3 extraArgs` (three blocks). Prometheus targets `kube-controller-manager`, `kube-scheduler`, and `kube-etcd` should then be `up`.

## Changing a node IP (for example, after moving the VM)

Symptoms: `kubectl` reports `connection refused`; `journalctl -u kubelet` shows `dial tcp <old-ip>:6443: no route to host`; etcd and apiserver crash-loop because etcd cannot bind the old address. The old IP is embedded in three places: static pod manifests (etcd, apiserver), component kubeconfigs (`kubelet.conf`, `scheduler.conf`, `controller-manager.conf`), and certificates (apiserver SANs, etcd server/peer). Find files with `sudo grep -rl <old-ip> /etc/kubernetes`.

1. Update `/etc/hosts` (`<new-ip> k8s-api.lab.local`) and back up: `sudo cp -a /etc/kubernetes ~/kubernetes-backup-newip` and `sudo cp -a /var/lib/etcd ~/etcd-data-backup`.
2. Replace the IP in `platform/kubeadm/config.yaml` (`advertiseAddress`, `listen-metrics-urls`) and **check `kubernetesVersion`**: it must match the actual cluster version.
3. Switch component kubeconfigs from the IP to the hostname:

   ```bash
   sudo sed -i 's#https://<old-ip>:6443#https://k8s-api.lab.local:6443#' \
     /etc/kubernetes/{kubelet,scheduler,controller-manager}.conf
   ```

4. Reissue certificates (remove the old ones first, otherwise kubeadm will not regenerate them):

   ```bash
   mkdir -p ~/old-pki
   sudo mv /etc/kubernetes/pki/apiserver.{crt,key} ~/old-pki/
   sudo mv /etc/kubernetes/pki/etcd/server.{crt,key} ~/old-pki/
   sudo mv /etc/kubernetes/pki/etcd/peer.{crt,key} ~/old-pki/
   sudo kubeadm init phase certs apiserver   --config platform/kubeadm/config.yaml
   sudo kubeadm init phase certs etcd-server --config platform/kubeadm/config.yaml
   sudo kubeadm init phase certs etcd-peer   --config platform/kubeadm/config.yaml
   ```

5. Replace the IP in etcd and apiserver manifests: `sudo sed -i 's/<old-ip>/<new-ip>/g' /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml`, then confirm images are unchanged (`grep image: /etc/kubernetes/manifests/*.yaml`). Regeneration with `kubeadm init phase` is safe only when `kubernetesVersion` is current (see kubeadm configuration).
6. Run `sudo systemctl restart kubelet`, then **restart scheduler and controller-manager**: static pods read kubeconfig only at startup. Otherwise, pods are neither created nor scheduled (scheduler is `0/1 Running`, ReplicaSets create no pods):

   ```bash
   sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
   sleep 20
   sudo mv /tmp/kube-scheduler.yaml /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
   ```

7. Once the API is available, update the etcd peer URL and upload the configuration:

   ```bash
   kubectl -n kube-system exec etcd-kubernetes -- etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key member list -w table
   # then member update <ID> --peer-urls=https://<new-ip>:2380 (same flags)
   sudo kubeadm init phase upload-config kubeadm --config platform/kubeadm/config.yaml
   ```

8. Unseal Vault, check `cilium status`, `kubectl get pods -A | grep -v Running`, and Application statuses in ArgoCD. Delete pods stuck in `Unknown` since the node went offline; Deployments create replacements. Update `/etc/hosts` on client machines. If Vault's injector was not ready when a pod was recreated, `vault-demo` starts without its `vault-agent` sidecar: delete the pod again after `vault-agent-injector` becomes `Ready`.

For easier future moves, configure a DHCP reservation or static IP for the VM.

## Known issues / TODO

- **Linkerd**: renew the mTLS issuer before 6 November 2027, preserve keys outside Git, and capture Gateway API CRD installation declaratively. Next exercise: dedicated ServiceAccounts and authorization in `mesh-demo`; Viz is not installed.
- **PostgreSQL**: configure and test backups of data and roles; the local PV does not protect against worker loss.
- **Vault**: manual unseal is required after every pod restart (auto-unseal options: transit or cloud KMS). OpenTofu state is local to the VM and could move to a remote backend. The provider uses the root token; replace it with a dedicated token with a narrow policy.
- **Cilium under ArgoCD**: apply the Application (`bootstrap/cilium.yaml`) manually, just like ApplicationSet. `prune: false` prevents automatic deletion of CNI resources. To upgrade the chart, change `targetRevision` in the Application manifest and rerun `kubectl apply -f bootstrap/cilium.yaml`.
- **Control-plane metrics** are exposed on the node IP. Controller-manager and scheduler require a token authorized for `/metrics` (Prometheus has one); etcd metrics use unauthenticated HTTP. This is acceptable in the lab; restrict these ports with network policies or a firewall in production.
- **Node IP** is not reserved for the VM and changes when moved to another host. Configure a DHCP reservation or static address; see Changing a node IP for recovery steps.
- **Local volumes** are tied to nodes: Vault and Prometheus to the control-plane, Grafana and PostgreSQL to the worker. Data does not move automatically between nodes; volume backups or storage with suitable fault tolerance are needed.
- **Worker firewall**: `allowed_v4` in table `ansible_nodeport` still includes `10.244.0.0/16` from the previous Calico cluster; Cilium does not need it. When recreating the worker VM, restore `ufw` rules and the subnet in that table, otherwise `exec`/`logs` and NodePort fail.
- **containerd versions** differ between nodes (control-plane 2.3.6, worker 2.4.2): align them and pin with `apt-mark hold containerd.io`.
- **`--pod-network-cidr=10.244.0.0/16`** is a leftover flannel default. Cilium does not require it: it uses its own IPAM (`cluster-pool`) unless explicitly overridden during `cilium install`.
- **ArgoCD installation**: regular `kubectl apply` of `install.yaml` fails to apply CRD `applicationsets.argoproj.io` (see Troubleshooting). Use `kubectl apply --server-side --force-conflicts` for updates.
- **ApplicationSet** lives in `bootstrap/` and is applied manually. It could be managed by a separate GitOps Application, with `syncPolicy.preserveResourcesOnDeletion: true` in its `spec` so deleting ApplicationSet does not remove workloads.
- Common `kubeadm join`/`init` errors encountered in this lab and their fixes are documented below.

## Troubleshooting (lessons from this lab)

**`FileAvailable--etc-kubernetes-kubelet.conf already exists` / `Port 10250 in use` during `kubeadm join`**

Usually means `join` was accidentally run on a node with existing kubeadm configuration (for example, on the control-plane instead of a separate worker). Check `hostname -I` against the intended control-plane IP.

To start over on the node:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd $HOME/.kube /etc/kubernetes/manifests/*
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo systemctl restart containerd kubelet
```

**`kubeadm join` on a new VM: `FileAvailable--etc-kubernetes-kubelet.conf already exists`, but `hostname -I` shows the worker IP**

The VM still has its own cluster (in this lab, a single-node Calico cluster created while preparing the image). Signs: `etcd.yaml` and `kube-apiserver.yaml` in `/etc/kubernetes/manifests`, and ports 6443 and 2379 in `ss -tlnp`. Run `kubeadm reset -f` and the cleanup above. Warnings such as `calico ... 10.96.0.1:443 connection refused` during reset are expected because the old API is already down. Then run `rm -rf /var/lib/cni /var/lib/calico /var/run/calico`, reboot to remove `cali*`/`tunl0` interfaces and stale sandboxes, check `/proc/swaps`, and join with a fresh token. Before resetting, make sure you are on the worker rather than the control-plane.

**`kubectl exec` / `logs` for a worker pod: `dial tcp <worker-ip>:10250: i/o timeout`**

The control-plane cannot reach the worker kubelet: the firewall blocks the port (`ufw` with `default deny incoming`). Join succeeds because it uses the opposite direction (worker → API). On the worker, run `sudo ufw allow from <control-plane-ip>`. Verify from the control-plane with `nc -zv -w3 <worker-ip> 10250`.

**`sudo: unable to resolve host <name>` on a new VM**

The hostname changed, but `/etc/hosts` still contains `127.0.1.1 <old-name>`. Update that line to the current hostname; kubelet registers the node using its hostname.

**`dial tcp <control-plane-ip>:6443: connect: connection refused` during join**

The API server is not listening: either `init` was never run on this node, or control-plane components were accidentally removed (for example, by running `kubeadm reset` on the control-plane). Check `sudo ss -tlnp | grep 6443` and `sudo crictl ps -a` on the intended control-plane node.

**`kubelet.service` crash-loops with `open /var/lib/kubelet/config.yaml: no such file or directory`**

Expected before a successful `kubeadm init`/`join`: kubeadm creates this file during setup. Successful join/init resolves it automatically.

**`cannot execute binary file: Exec format error` when running the Cilium CLI**

Binary and node architectures differ. Check `uname -m`: `aarch64` → download `cilium-linux-arm64.tar.gz`; `x86_64` → `cilium-linux-amd64.tar.gz`.

**`kubectl port-forward` is inaccessible from a browser on another host**

By default, `port-forward` listens only on `127.0.0.1` on the machine running the command. If the browser is on another device (for example, a Mac while port-forward runs in the VM), add `--address 0.0.0.0`:

```bash
kubectl port-forward --address 0.0.0.0 svc/<service> <local-port>:<remote-port>
```

Connect using the IP of the machine running port-forward rather than `localhost`.

**`no matches for kind "ApplicationSet"` and `argocd-applicationset-controller` in `CrashLoopBackOff`**

CRD `applicationsets.argoproj.io` was not installed with ArgoCD: its manifest exceeds the `last-applied-configuration` annotation limit of regular `kubectl apply`. Other resources still apply, so ArgoCD generally works. Check `kubectl get crd | grep argoproj`. Fix:

```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
kubectl -n argocd rollout restart deployment argocd-applicationset-controller
```

**`exec /usr/local/bin/docker-php-entrypoint: exec format error` in a pod**

The image supports only amd64 while the node is arm64. Use multi-arch images (`nginx`, `traefik/whoami`, etc.). Check supported architectures with `docker buildx imagetools inspect <image>` or the image's registry page.

**`Author identity unknown` / `src refspec main does not match any` during `git push`**

No commit was created because `user.name`/`user.email` were unset, so there is no local `main` branch to push. Set identity (`git config user.name ...`, `git config user.email ...`), commit, then run `git branch -M main` and push.

**After reboot, `kubectl` reports `connection refused` and kubelet fails with `running with swap on is not supported`**

Systemd automatically enables the GPT disk's swap partition (a unit such as `dev-disk-by\x2ddiskseq-1\x2dpart4.swap`), even if its `/etc/fstab` entry is commented out. Kubelet and therefore apiserver cannot start. Check `cat /proc/swaps` (`swapon` is in `/usr/sbin`, which may be outside PATH). Apply both steps:

```bash
sudo swapoff -a
sudo systemctl mask "$(systemctl list-units --type=swap --all --no-legend | awk '{print $1}')"
# the unit name includes a disk number assigned at boot; also change the partition type:
sudo sfdisk --part-type /dev/vda 4 0FC63DAF-8483-4772-8E79-3D69D8477DE4
```

The kernel rereads the partition table only after reboot; `Re-reading the partition table failed: Device or resource busy` is expected here. To restore the swap partition type, use GUID `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F`.

**After reboot, all pods are `Unknown` and `cilium-operator` crash-loops with `dial tcp 10.96.0.1:443: i/o timeout`**

Cilium replaces kube-proxy, which is absent from this cluster. The agent needs the API server, but Cilium itself routes ClusterIP `10.96.0.1`, creating a startup dependency cycle. Existing BPF programs in kernel memory hide this until a cold start. Set a direct API endpoint using `k8sServiceHost` and `k8sServicePort` in `platform/cilium/values.yaml`. Avoid `cilium upgrade` during normal operation: `selfHeal` reverts it to Git. If the cluster is too broken for Argo to sync, temporarily run `cilium upgrade --reuse-values --set k8sServiceHost=k8s-api.lab.local --set k8sServicePort=6443`, then make sure to commit those values to Git.

A related kubelet log message is `deletion queue directory /var/run/cilium/deleteQueue has too many entries`. Once Cilium starts, run `sudo rm -f /var/run/cilium/deleteQueue/*` and `sudo systemctl restart kubelet` if needed.

**A new directory in `workloads/` does not become an Application**

ApplicationSet reads Git through the repo-server cache, which can take several minutes. Force a refresh: `kubectl -n argocd annotate applicationset workloads argocd.argoproj.io/application-set-refresh=true --overwrite`.

**`kubectl exec` immediately after deleting a pod: `container not found`**

A race condition: the container has not been created yet. Wait a few seconds and retry.


## AWS EKS GitOps

EKS applications use a separate directory, [`eks/workloads/`](eks/README.md), discovered automatically by ApplicationSet. The home lab continues to use `workloads/*`.
