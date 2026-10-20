# Kubernetes Home Lab — Debian 13 (Trixie)

[Русский](README.md) | **English**

A Kubernetes lab cluster deployed with `kubeadm` to study production-style architecture (unlike k3s/k0s/MicroK8s, which hide or simplify many components).

## Topology

| Role | Hostname | IP | OS |
|------|----------|----|----|
| control-plane | kubernetes | 192.168.64.55 | Debian 13 |
| worker | k8s-worker | 192.168.64.57 | Debian 13 |

Control-plane endpoint: `k8s-api.lab.local` → `192.168.64.55` (configured in `/etc/hosts` on every node).

The cluster has two nodes. The control-plane has the standard `node-role.kubernetes.io/control-plane:NoSchedule` taint, so regular workloads run on the worker. Vault, Prometheus, and Grafana are exceptions: their `local-path` volumes are tied to the node where they were created (the control-plane). Their `values.yaml` files therefore include tolerations for this taint (`workloads/vault`: `server.tolerations` as a string; `workloads/monitoring`: `grafana.tolerations` and `prometheus.prometheusSpec.tolerations`). Without these, recreated pods would remain `Pending`. Vault's StatefulSet uses `OnDelete`: after changing its template, manually delete `vault-0` and unseal the replacement.

The worker firewall (`ufw`, `default deny incoming`) allows only SSH (22) and all traffic from the control-plane (`sudo ufw allow from 192.168.64.55`). Without the latter rule, the control-plane cannot reach kubelet (port 10250), and `kubectl exec`/`logs` for worker pods fail with `i/o timeout`. Calico rules (BGP, VXLAN, Typha, `10.244.0.0/16`) have been removed: Cilium's traffic between these nodes is covered by the control-plane rule. The worker also loads the nftables table `ansible_nodeport` (`/etc/nftables.d/ansible-nodeport.nft`, unit `ansible-nodeport-firewall.service`). It permits NodePort traffic (30000–32767) only from listed subnets; `192.168.64.0/24` was added so the Mac can access ingress-nginx when it runs on the worker. The control-plane does not have `ufw` installed.

## Stack

| Component | Version / notes |
|-----------|-----------------|
| Kubernetes | v1.34.12 (kubeadm), etcd 3.6.5 |
| Container runtime | containerd (`SystemdCgroup=true`) |
| CNI | Cilium 1.20.1 managed by ArgoCD (`platform/cilium/values.yaml`), `kubeProxyReplacement=true` |
| kube-proxy | Removed; Cilium handles its role (see Installing Cilium) |
| Ingress | ingress-nginx (NodePort: 80→32337, 443→30971) |
| TLS | cert-manager + `ClusterIssuer/selfsigned-issuer` |
| Metrics | metrics-server (`--kubelet-insecure-tls`) |
| GitOps | ArgoCD + ApplicationSet (`k8s-lab-apps` repository) |
| Storage | local-path-provisioner v0.0.37 (default StorageClass `local-path`) |
| Secrets | Vault (chart 0.34.0, Vault 2.0.3), Raft on a PVC, 1 replica, manual unseal; configuration in `iac/vault` (OpenTofu) |
| Monitoring | kube-prometheus-stack 91.9.0 (Prometheus, Grafana; Alertmanager disabled), data on PVCs |
| Network observability | Hubble (relay + UI), Cilium metrics in Prometheus |
| Demo applications | `nginx-demo`, `whoami`, `rbac-demo`, `netpol-demo`, `vault-demo` (multi-arch images supporting arm64) |

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

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | \
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

## Operations: after a VM reboot

Kubernetes starts automatically (`containerd` and `kubelet` are enabled at boot); allow 3–5 minutes. Manual steps after reboot:

1. Unseal Vault (command above), otherwise `vault-demo` and other pods using the injector remain unready.
2. Start the ArgoCD port-forward if you need the UI: `kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443`.

Post-boot checks:

```bash
cat /proc/swaps                                  # header only
kubectl get nodes
kubectl get pods -A | grep -v ' Running '
```

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

- Alertmanager is disabled to save memory; notifications are unnecessary for this lab.
- Grafana and Prometheus are exposed through ingress-nginx with TLS from `selfsigned-issuer` (`grafana.lab.local`, `prometheus.lab.local`).
- Storage uses `local-path`: Grafana 1Gi, Prometheus 5Gi, retention 7 days.
- `serviceMonitorSelectorNilUsesHelmValues: false` and `podMonitorSelectorNilUsesHelmValues: false`: Prometheus discovers ServiceMonitor and PodMonitor resources from all applications, regardless of this release's label.
- cert-manager issues the operator webhook certificates (`admissionWebhooks.certManager.enabled`, jobs disabled), avoiding hook jobs and `caBundle` drift in Argo.
- Control-plane monitors are enabled: `kubeControllerManager` and `kubeScheduler` over HTTPS with `insecureSkipVerify` (self-signed certificates), `kubeEtcd` over HTTP on 2381. Metrics are exposed through kubeadm configuration (see kubeadm configuration). `kubeProxy` is disabled because the cluster has no kube-proxy.
- `kubelet.serviceMonitor.insecureSkipVerify: true`: kubelet has a self-signed certificate, as with metrics-server.

Access: add `192.168.64.55 grafana.lab.local prometheus.lab.local` to `/etc/hosts` on the Mac, then open `https://grafana.lab.local:30971` (username `admin`) and `https://prometheus.lab.local:30971`. The Prometheus UI has no authentication; restrict access in production. **Status → Targets** should show `UP` for apiserver, kubelet (including cadvisor), kube-state-metrics, node-exporter, and coredns.

Useful Prometheus query for memory usage by namespace: `sum by (namespace) (container_memory_working_set_bytes{container!=""})`.

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

- **Vault**: manual unseal is required after every pod restart (auto-unseal options: transit or cloud KMS). OpenTofu state is local to the VM and could move to a remote backend. The provider uses the root token; replace it with a dedicated token with a narrow policy.
- **Cilium under ArgoCD**: apply the Application (`bootstrap/cilium.yaml`) manually, just like ApplicationSet. `prune: false` prevents automatic deletion of CNI resources. To upgrade the chart, change `targetRevision` in the Application manifest and rerun `kubectl apply -f bootstrap/cilium.yaml`.
- **Control-plane metrics** are exposed on the node IP. Controller-manager and scheduler require a token authorized for `/metrics` (Prometheus has one); etcd metrics use unauthenticated HTTP. This is acceptable in the lab; restrict these ports with network policies or a firewall in production.
- **Node IP** is not reserved for the VM and changes when moved to another host. Configure a DHCP reservation or static address; see Changing a node IP for recovery steps.
- **`local-path` data** is tied to the control-plane and cannot move. If that node is lost, Vault, Prometheus, and Grafana cannot start on the worker. Actual high availability requires replicated storage (Longhorn, Rook-Ceph, or NFS) and recovery from snapshots.
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
