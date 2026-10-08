# Kubernetes Home Lab — Debian 13 (Trixie)

Лабораторный кластер Kubernetes, развёрнутый через `kubeadm` для изучения архитектуры «как в проде» (в отличие от k3s/k0s/MicroK8s, где многие компоненты скрыты или упрощены).

## Топология

| Роль           | Hostname     | IP            | OS          |
|----------------|--------------|---------------|-------------|
| control-plane  | kubernetes   | 192.168.64.18 | Debian 13   |
| worker         | TBD          | TBD           | Debian 13   |

Control-plane endpoint: `k8s-api.lab.local` → `192.168.64.18` (прописан в `/etc/hosts` на всех нодах).

> ⚠️ На данный момент кластер single-node. Taint `node-role.kubernetes.io/control-plane:NoSchedule` снят с control-plane ноды, чтобы на ней планировались обычные поды. После добавления worker-ноды taint стоит вернуть:
> ```bash
> kubectl taint nodes kubernetes node-role.kubernetes.io/control-plane:NoSchedule
> ```

## Стек

| Компонент        | Версия/примечание                                  |
|------------------|-----------------------------------------------------|
| Kubernetes       | v1.33.13 (через kubeadm)                             |
| Container runtime| containerd (SystemdCgroup=true)                      |
| CNI              | Cilium v1.20.1, `kubeProxyReplacement=true`          |
| kube-proxy       | удалён, его роль выполняет Cilium (см. раздел «Установка Cilium») |
| Ingress          | ingress-nginx (NodePort: 80→32337, 443→30971)        |
| TLS              | cert-manager + `ClusterIssuer/selfsigned-issuer`     |
| Metrics          | metrics-server (`--kubelet-insecure-tls`)            |
| GitOps           | ArgoCD + ApplicationSet (репозиторий `k8s-lab-apps`) |
| Хранилище        | local-path-provisioner v0.0.37 (default StorageClass `local-path`) |
| Секреты          | Vault (чарт 0.34.0, Vault 2.0.3), Raft на PVC, 1 реплика, ручной unseal |
| Мониторинг       | kube-prometheus-stack 91.9.0 (Prometheus, Grafana; Alertmanager выключен), данные на PVC |
| Сеть, наблюдаемость | Hubble (relay + UI), метрики Cilium в Prometheus |
| Тестовые приложения | `nginx-demo`, `whoami`, `rbac-demo`, `netpol-demo`, `vault-demo` (multi-arch образы под arm64) |

## Подготовка ОС (все ноды)

```bash
# Отключить swap
sudo swapoff -a
sudo sed -i '/ swap /s/^/#/' /etc/fstab

# Модули ядра
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

# /etc/hosts — на ВСЕХ нодах
echo "192.168.64.18 k8s-api.lab.local" | sudo tee -a /etc/hosts
```

## Установка containerd

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg apt-transport-https

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# (используется codename bookworm — на момент установки репозиторий Docker ещё не поддерживал trixie)

sudo apt update
sudo apt install -y containerd.io

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd
```

## Установка kubeadm / kubelet / kubectl

```bash
sudo apt install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## Инициализация control-plane

Выполняется **только** на control-plane ноде (192.168.64.18):

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs \
  --control-plane-endpoint "k8s-api.lab.local:6443"

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Join-команды (токен действует 24 часа, пересоздать: `kubeadm token create --print-join-command` на control-plane):

```bash
# Worker
kubeadm join k8s-api.lab.local:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>

# Доп. control-plane (HA)
kubeadm join k8s-api.lab.local:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane --certificate-key <CERT_KEY>
```

## Установка Cilium

```bash
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-arm64.tar.gz
sudo tar xzvfC cilium-linux-arm64.tar.gz /usr/local/bin
rm cilium-linux-arm64.tar.gz

cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.64.18 \
  --set k8sServicePort=6443
cilium status --wait
```

> **kube-proxy не нужен, но нужен прямой адрес API.** Параметры `k8sServiceHost`/`k8sServicePort` обязательны, если kube-proxy удалён: иначе после перезагрузки агент Cilium пытается дойти до API через ClusterIP `10.96.0.1`, а маршрутизацию этого адреса делает он же (см. Troubleshooting). Указывать нужно IP, а не имя: внутри пода `k8s-api.lab.local` не резолвится. Если Cilium уже установлен без них: `cilium upgrade --reuse-values --set k8sServiceHost=192.168.64.18 --set k8sServicePort=6443`.
>
> Архитектура ноды — **arm64** (UTM/Apple Virtualization на Apple Silicon), поэтому используется `cilium-linux-arm64`, а не `amd64`.

## metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

kubectl -n kube-system rollout status deployment metrics-server
kubectl top nodes
```

> Сразу после rollout `kubectl top nodes` может отвечать `Metrics API not available` — APIService регистрируется с задержкой 30–60 сек, это не ошибка.

## ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.0/deploy/static/provider/cloud/deploy.yaml

# Нет облачного LoadBalancer — переключаем на NodePort
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec": {"type": "NodePort"}}'
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

## cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

kubectl -n cert-manager rollout status deployment cert-manager
kubectl -n cert-manager rollout status deployment cert-manager-webhook
```

ClusterIssuer (self-signed — для лабы без публичного домена Let's Encrypt не подходит):

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

Пароль admin:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```

Доступ к UI (кластер и браузер на разных машинах — Mac с VM в одной сети `192.168.64.x`):

```bash
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443
```

Открыть: `https://192.168.64.18:8080` (логин `admin`, пароль — см. выше). Сертификат самоподписанный, браузер предупредит — это ожидаемо.

Сменить пароль после первого входа:

```bash
argocd account update-password
```

## GitOps-репозиторий (`k8s-lab-apps`)

Публичный репозиторий `https://github.com/servik01/k8s-lab-apps`, ветка `main`. ArgoCD читает его без дополнительных credentials.

```
k8s-lab-apps/
├── bootstrap/
│   └── applicationset.yaml   # применяется вручную один раз
└── workloads/                # каждая папка = одно приложение
    ├── local-path-storage/   # провижионер + kustomize-патч default class
    ├── monitoring/           # wrapper-чарт kube-prometheus-stack
    ├── vault/                # wrapper-чарт Vault (Raft)
    ├── vault-demo/           # приложение с Vault Agent Injector
    ├── rbac-demo/            # ServiceAccount, Role, ClusterRole
    ├── netpol-demo/          # NetworkPolicy в Cilium
    ├── nginx-demo/           # deployment, service, ingress
    └── whoami/               # deployment, service, ingress
```

### ApplicationSet

Git directory generator превращает каждую папку `workloads/*` в Application: имя Application и namespace берутся из имени папки. Включены `automated` sync, `prune`, `selfHeal` и `CreateNamespace=true`, на каждом Application стоит finalizer `resources-finalizer.argocd.argoproj.io`.

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
      ignoreDifferences:           # injector Vault сам пишет caBundle в webhook
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
          - ServerSideApply=true      # большие CRD (kube-prometheus-stack)
```

Применить один раз вручную:

```bash
kubectl apply -f bootstrap/applicationset.yaml
```

### Рабочий процесс

- **Новое приложение**: создать папку `workloads/<имя>/` с манифестами, `git push`. Через ~3 минуты (интервал опроса Git) появится Application и namespace `<имя>`.
- **Изменение**: правка манифеста в Git и `git push`. Ручные правки в кластере откатывает `selfHeal`.
- **Удаление**: `git rm -r workloads/<имя>` и `git push`. Application исчезнет, а finalizer вместе с `prune` удалит и его ресурсы.

Push с токеном из переменной окружения, без записи токена в `.git/config`:

```bash
git push "https://<user>:${MY_GH_TOKEN}@github.com/<user>/k8s-lab-apps.git" main
```

### Доступ к приложениям с Mac

Через ingress-nginx по NodePort HTTPS (30971) с самоподписанным сертификатом. На Mac в `/etc/hosts`:

```
192.168.64.18 nginx.lab.local whoami.lab.local
```

Адреса: `https://nginx.lab.local:30971`, `https://whoami.lab.local:30971`.

### История миграции: App of Apps → ApplicationSet

Сначала использовался паттерн App of Apps (корневой Application `root`, следивший за папкой `apps/`). При переходе на ApplicationSet приложения отцеплялись от `root` **без удаления ресурсов**: у Application сначала снимался finalizer (`kubectl patch ... '{"metadata":{"finalizers":null}}'`), и только потом он удалялся. Если удалить Application с finalizer, Argo каскадно снесёт все его ресурсы. После применения ApplicationSet новые Application подхватили уже работающие поды, перезапуска не было.

## Хранилище (local-path-provisioner)

Приложение `workloads/local-path-storage`: манифест провижионера v0.0.37 лежит в репозитории как есть, а `kustomization.yaml` патчит StorageClass `local-path`, делая его default. Папка названа так же, как namespace в манифесте (`local-path-storage`).

- Данные лежат на диске ноды в `/opt/local-path-provisioner`, без репликации и привязаны к одной ноде.
- `volumeBindingMode: WaitForFirstConsumer`: PVC остаётся `Pending`, пока нет пода, который его использует.
- `reclaimPolicy: Delete`: удаление PVC удаляет данные.

## Vault (Raft, одна реплика)

Wrapper-чарт `workloads/vault` (`Chart.yaml` с зависимостью `vault` 0.34.0, значения в `values.yaml` под ключом `vault:`). Ключевые значения: `server.ha.enabled` + `server.ha.raft.enabled` + `replicas: 1`, `dataStorage` 2Gi на `local-path`, `disruptionBudget` выключен (при одной реплике он блокировал бы `kubectl drain`), injector включён.

Инициализация (один раз). Файл с ключами хранить **вне репозитория** (он публичный) и сделать резервную копию:

```bash
kubectl -n vault exec vault-0 -- vault operator init \
  -key-shares=1 -key-threshold=1 -format=json > ~/vault-init.json
chmod 600 ~/vault-init.json
```

Unseal (нужен после каждого перезапуска пода и перезагрузки VM):

```bash
kubectl -n vault exec vault-0 -- vault operator unseal \
  "$(jq -r '.unseal_keys_b64[0]' ~/vault-init.json)"
```

Настройка Kubernetes auth. В не-dev режиме `secret/` нужно смонтировать вручную:

```bash
kubectl -n vault exec -i vault-0 -- \
  env VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)" sh -s <<'EOF'
vault secrets enable -path=secret kv-v2
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"
vault kv put secret/demo/config username=lab password=s3cret
vault policy write demo-read - <<'POLICY'
path "secret/data/demo/*" {
  capabilities = ["read"]
}
POLICY
vault write auth/kubernetes/role/demo \
  bound_service_account_names=vault-demo \
  bound_service_account_namespaces=vault-demo \
  policies=demo-read ttl=1h
EOF
```

Токен-ревью Vault делает токеном собственного ServiceAccount: чарт создаёт ему биндинг `vault-server-binding` на `system:auth-delegator`. Приложение `workloads/vault-demo` получает секрет через аннотации `vault.hashicorp.com/*` (injector добавляет init-контейнер и sidecar `vault-agent`, секрет появляется в `/vault/secrets/config.txt`). Проверка отказа: токен чужого ServiceAccount получает `403 service account name not authorized`.

## RBAC и NetworkPolicy

**`workloads/rbac-demo`**: ServiceAccount `dev-viewer`, Role `pod-reader` (чтение pods и pods/log в своём namespace), ClusterRole `node-reader`. Проверка прав:

```bash
SA=system:serviceaccount:rbac-demo:dev-viewer
kubectl auth can-i delete pods -n rbac-demo --as=$SA     # no
kubectl auth can-i list nodes --as=$SA                   # yes
```

Проверка с настоящим токеном. Нужен пустой kubeconfig: клиентский сертификат админа из `~/.kube/config` API-сервер принимает раньше токена, и без этого проверялись бы права админа:

```bash
TOKEN=$(kubectl -n rbac-demo create token dev-viewer)
KUBECONFIG=/dev/null kubectl --server=https://k8s-api.lab.local:6443 \
  --certificate-authority=/etc/kubernetes/pki/ca.crt --token=$TOKEN \
  delete pod -n rbac-demo -l app=sample                  # Forbidden
```

**`workloads/netpol-demo`**: `web` (nginx) и `client` с меткой `role=client`. Политики: `default-deny-ingress`, `allow-client-to-web` и `client-egress` (только `web:80` и DNS в `kube-system`). Блокировка проявляется как **таймаут**, а не как отказ в соединении; при проблемах с DNS вместо таймаута будет `bad address`. Важно: `default-deny-ingress` в namespace с ingress-nginx сломает доступ извне, если не разрешить трафик из namespace `ingress-nginx`.

## Эксплуатация: после перезагрузки VM

Kubernetes стартует сам (`containerd` и `kubelet` в автозапуске), на подъём нужно 3–5 минут. Вручную после перезагрузки:

1. Распечатать Vault (команда выше), иначе `vault-demo` и все поды с injector'ом остаются не готовы.
2. Запустить port-forward к ArgoCD, если нужен UI: `kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443`.

Проверка после загрузки:

```bash
cat /proc/swaps                                  # только заголовок
kubectl get nodes
kubectl get pods -A | grep -v ' Running '
```

## Мониторинг (kube-prometheus-stack)

Приложение `workloads/monitoring`: wrapper-чарт (`Chart.yaml` с зависимостью `kube-prometheus-stack` 91.9.0 из `https://prometheus-community.github.io/helm-charts`, значения в `values.yaml` под ключом `kube-prometheus-stack:`).

**Перед первым sync** руками создаются namespace и пароль Grafana. Пароль не генерируется чартом: Helm при каждом рендере в Argo создавал бы новый случайный, и Secret вечно расходился бы с Git; в values пароль не кладём, репозиторий публичный.

```bash
kubectl create namespace monitoring
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 18)"

# прочитать пароль:
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

В шаблон ApplicationSet добавлена опция `ServerSideApply=true`: CRD этого чарта слишком велики для обычного `kubectl apply` (лимит на аннотацию `last-applied-configuration`).

Ключевые значения `values.yaml`:

- Alertmanager выключен (экономия памяти, уведомления в лабе не нужны).
- Grafana и Prometheus за ingress-nginx с TLS от `selfsigned-issuer` (`grafana.lab.local`, `prometheus.lab.local`).
- Хранилище на `local-path`: Grafana 1Gi, Prometheus 5Gi, retention 7 дней.
- `serviceMonitorSelectorNilUsesHelmValues: false` и `podMonitorSelectorNilUsesHelmValues: false`: Prometheus подхватывает ServiceMonitor и PodMonitor любых приложений, а не только с меткой этого релиза.
- Сертификаты webhook'а оператора выпускает cert-manager (`admissionWebhooks.certManager.enabled`, джобы выключены): так нет hook-джоб и дрейфа `caBundle` в Argo.
- Мониторы `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy` выключены (kubeadm привязывает эти компоненты к 127.0.0.1).
- `kubelet.serviceMonitor.insecureSkipVerify: true`: самоподписанный сертификат kubelet, как и в случае metrics-server.

Доступ: на Mac в `/etc/hosts` добавить `192.168.64.18 grafana.lab.local prometheus.lab.local`, затем `https://grafana.lab.local:30971` (логин `admin`) и `https://prometheus.lab.local:30971`. Prometheus UI открыт без аутентификации, на проде его закрывают. В **Status → Targets** должны быть `UP` apiserver, kubelet (включая cadvisor), kube-state-metrics, node-exporter, coredns.

Полезный запрос в Prometheus: `sum by (namespace) (container_memory_working_set_bytes{container!=""})`, потребление памяти по namespace.

## Наблюдаемость сети (Hubble)

Hubble и метрики Cilium включены командой `cilium upgrade`. Параметры хранятся только в Helm-релизе (в Git их нет), а `--reuse-values` сохраняет ранее заданные `k8sServiceHost` и `k8sServicePort`. Если Cilium придётся ставить заново, их нужно передать снова.

```bash
cilium upgrade --reuse-values \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.ui.ingress.enabled=true \
  --set hubble.ui.ingress.className=nginx \
  --set 'hubble.ui.ingress.hosts[0]=hubble.lab.local' \
  --set 'hubble.ui.ingress.tls[0].secretName=hubble-tls' \
  --set 'hubble.ui.ingress.tls[0].hosts[0]=hubble.lab.local' \
  --set 'hubble.ui.ingress.annotations.cert-manager\.io/cluster-issuer=selfsigned-issuer' \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --set operator.prometheus.enabled=true \
  --set operator.prometheus.serviceMonitor.enabled=true \
  --set 'hubble.metrics.enabled={dns,drop,tcp,flow,port-distribution,icmp}' \
  --set hubble.metrics.serviceMonitor.enabled=true
```

UI: `https://hubble.lab.local:30971` (запись в `/etc/hosts` на Mac: `192.168.64.18 hubble.lab.local`), namespace выбирается слева сверху. Hubble показывает потоки по мере появления, поэтому в тихом namespace карта пуста. Демонстрация дропа NetworkPolicy: запустить под без метки `role=client` и обращаться из него к `web`, а для сравнения из `client`:

```bash
kubectl -n netpol-demo run intruder --image=busybox:1.37 --restart=Never -- sleep 3600
kubectl -n netpol-demo exec intruder -- wget -qO- --timeout=2 http://web
kubectl -n netpol-demo exec deploy/client -- wget -qO- --timeout=2 http://web
kubectl -n netpol-demo delete pod intruder
```

В UI `client → web` идёт сплошной линией с вердиктом `forwarded`, а `intruder → web` красным пунктиром с вердиктом `dropped`. Узел `intruder` подписан именем namespace: Hubble берёт подпись из метки `app`, а у пода из `kubectl run` её нет.

Метрики: в Prometheus появляются цели `cilium-agent` (порт 9962), `cilium-operator` (9963) и `hubble` (9965). Скрейп идёт по IP ноды, потому что агент работает в сети хоста. Дропы по политикам: `sum by (reason, protocol) (increase(hubble_drop_total[30m]))`.

CLI (сборка под arm64, как и у Cilium CLI):

```bash
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-arm64.tar.gz
sudo tar xzvfC hubble-linux-arm64.tar.gz /usr/local/bin
rm hubble-linux-arm64.tar.gz

cilium hubble port-forward &
hubble observe --namespace netpol-demo --verdict DROPPED --last 20
```

## Известные моменты / TODO

- **Vault**: настройка (auth, политики, роли) делается руками и в Git не лежит, после каждого перезапуска пода нужен ручный unseal. Следующие шаги: провайдер `vault` для Terraform/OpenTofu и auto-unseal (transit или облачный KMS).
- **Cilium** управляется через CLI, его параметры (`k8sServiceHost`, Hubble, метрики) хранятся только в Helm-релизе в кластере. Кандидат на перенос под ArgoCD, тогда значения окажутся в Git.
- **Метрики control-plane** (controller-manager, scheduler, etcd, kube-proxy) отключены: kubeadm привязывает их к 127.0.0.1. Упражнение: открыть метрики и включить мониторы обратно; часть control-plane алертов в Prometheus из-за этого может гореть.
- **Worker-нода** ещё не добавлена — кластер single-node.
- **Taint control-plane** снят ради возможности шедулить поды на единственной ноде — вернуть после добавления worker.
- **`--pod-network-cidr=10.244.0.0/16`** указан по инерции (дефолт для flannel); для Cilium не обязателен — используется его собственный IPAM (`cluster-pool`), если явно не переопределить при `cilium install`.
- **Установка ArgoCD**: манифест `install.yaml` при обычном `kubectl apply` не применяет CRD `applicationsets.argoproj.io` (см. Troubleshooting). Для обновлений использовать `kubectl apply --server-side --force-conflicts`.
- **ApplicationSet** лежит в `bootstrap/` и применяется вручную. Его можно отдать под GitOps отдельным Application, а в `spec` добавить `syncPolicy.preserveResourcesOnDeletion: true`, чтобы удаление ApplicationSet не сносило workloads.
- Частые ошибки `kubeadm join`/`init`, с которыми столкнулись в процессе, и способ их устранения — см. раздел «Troubleshooting» ниже.

## Troubleshooting (из опыта этой лабы)

**`FileAvailable--etc-kubernetes-kubelet.conf already exists` / `Port 10250 in use` при `kubeadm join`**
Обычно значит, что команда `join` по ошибке выполняется на ноде, где уже есть kubeadm-конфигурация (например, на самой control-plane ноде вместо отдельной worker-машины). Проверить `hostname -I` и сверить с тем IP, который должен быть control-plane.

Если нужно начать заново на ноде:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/etcd $HOME/.kube /etc/kubernetes/manifests/*
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
sudo systemctl restart containerd kubelet
```

**`dial tcp <control-plane-ip>:6443: connect: connection refused` при `join`**
API-сервер не слушает порт — либо `init` не выполнялся на этой ноде, либо control-plane компоненты были случайно удалены (например, через `kubeadm reset`, выполненный по ошибке на control-plane ноде). Проверить `sudo ss -tlnp | grep 6443` и `sudo crictl ps -a` на предполагаемой control-plane ноде.

**`kubelet.service` в `CrashLoop` с ошибкой `open /var/lib/kubelet/config.yaml: no such file or directory`**
Нормально и ожидаемо для ноды, которая ещё не прошла успешный `kubeadm init`/`join` — файл создаётся самим kubeadm в процессе. Исправляется автоматически после успешного join/init.

**`cannot execute binary file: Exec format error` при запуске `cilium` CLI**
Несовпадение архитектуры бинарника и ноды. Проверить `uname -m`: `aarch64` → качать `cilium-linux-arm64.tar.gz`, `x86_64` → `cilium-linux-amd64.tar.gz`.

**`kubectl port-forward` недоступен в браузере на другом хосте**
По умолчанию `port-forward` слушает только `127.0.0.1` **внутри** той машины, где выполнена команда. Если браузер открыт на другом устройстве (например, Mac, а port-forward запущен внутри VM) — добавить `--address 0.0.0.0`:
```bash
kubectl port-forward --address 0.0.0.0 svc/<service> <local-port>:<remote-port>
```
и обращаться по IP той машины, где выполнен port-forward, а не по `localhost`.

**`no matches for kind "ApplicationSet"` и `argocd-applicationset-controller` в `CrashLoopBackOff`**
CRD `applicationsets.argoproj.io` не установился вместе с ArgoCD: манифест слишком большой для обычного `kubectl apply` (лимит на аннотацию `last-applied-configuration`), остальные ресурсы при этом применяются, поэтому ArgoCD в целом работает. Проверить: `kubectl get crd | grep argoproj`. Исправление:
```bash
kubectl apply --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/crds/applicationset-crd.yaml
kubectl -n argocd rollout restart deployment argocd-applicationset-controller
```

**`exec /usr/local/bin/docker-php-entrypoint: exec format error` в поде**
Образ собран только под amd64, а нода на arm64. Нужны multi-arch образы (`nginx`, `traefik/whoami` и подобные). Проверить архитектуры образа можно через `docker buildx imagetools inspect <image>` или на странице образа в реестре.

**`Author identity unknown` / `src refspec main does not match any` при `git push`**
Коммит не создался из-за незаданного `user.name`/`user.email`, поэтому ветки `main` локально нет и пушить нечего. Задать identity (`git config user.name ...`, `git config user.email ...`), закоммитить, затем `git branch -M main` и push.

**После перезагрузки `kubectl` отвечает `connection refused`, `kubelet` падает с `running with swap on is not supported`**
Systemd сам включает swap-раздел GPT-диска (юнит вида `dev-disk-by\x2ddiskseq-1\x2dpart4.swap`), даже если строка в `/etc/fstab` закомментирована, поэтому kubelet не стартует, а вместе с ним и apiserver. Проверка: `cat /proc/swaps` (`swapon` лежит в `/usr/sbin` и может быть вне PATH). Лечение, оба шага:
```bash
sudo swapoff -a
sudo systemctl mask "$(systemctl list-units --type=swap --all --no-legend | awk '{print $1}')"
# имя юнита содержит номер диска, который ядро присваивает при загрузке, поэтому дополнительно меняем тип раздела:
sudo sfdisk --part-type /dev/vda 4 0FC63DAF-8483-4772-8E79-3D69D8477DE4
```
Ядро перечитает таблицу разделов только после перезагрузки (`Re-reading the partition table failed: Device or resource busy` здесь нормально). Откат типа раздела: GUID `0657FD6D-A4AB-43C4-84E5-0933C84B4F4F`.

**После перезагрузки все поды в `Unknown`, `cilium-operator` в `CrashLoopBackOff` с `dial tcp 10.96.0.1:443: i/o timeout`**
Cilium заменяет kube-proxy, а kube-proxy в кластере нет: агенту нужен API-сервер, но ClusterIP `10.96.0.1` маршрутизирует сам Cilium, который из-за этого не стартует. Замкнутый круг не виден, пока в памяти ядра живут старые BPF-программы, и проявляется на холодном старте. Лечение: дать Cilium прямой адрес API.
```bash
cilium upgrade --reuse-values \
  --set k8sServiceHost=192.168.64.18 \
  --set k8sServicePort=6443
```
Признак в журнале kubelet: `deletion queue directory /var/run/cilium/deleteQueue has too many entries`. После запуска Cilium при необходимости: `sudo rm -f /var/run/cilium/deleteQueue/*` и `sudo systemctl restart kubelet`.

**Новая папка в `workloads/` не превращается в Application**
ApplicationSet читает Git через кэш repo-server (до нескольких минут). Принудительно обновить: `kubectl -n argocd annotate applicationset workloads argocd.argoproj.io/application-set-refresh=true --overwrite`.

**`kubectl exec` сразу после удаления пода: `container not found`**
Гонка: контейнер ещё не создан. Подожди несколько секунд и повтори.
