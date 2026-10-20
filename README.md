# Kubernetes Home Lab — Debian 13 (Trixie)

Лабораторный кластер Kubernetes, развёрнутый через `kubeadm` для изучения архитектуры «как в проде» (в отличие от k3s/k0s/MicroK8s, где многие компоненты скрыты или упрощены).

## Топология

| Роль           | Hostname     | IP            | OS          |
|----------------|--------------|---------------|-------------|
| control-plane  | kubernetes   | 192.168.64.55 | Debian 13   |
| worker         | k8s-worker   | 192.168.64.57 | Debian 13   |

Control-plane endpoint: `k8s-api.lab.local` → `192.168.64.55` (прописан в `/etc/hosts` на всех нодах).

Кластер из двух нод. На control-plane стоит штатный taint `node-role.kubernetes.io/control-plane:NoSchedule`, обычные нагрузки планируются на worker. Исключение: Vault, Prometheus и Grafana. Их тома на `local-path` привязаны к ноде, где созданы (к control-plane), поэтому в их `values.yaml` прописаны `tolerations` для этого taint (`workloads/vault`: `server.tolerations` строкой, `workloads/monitoring`: `grafana.tolerations` и `prometheus.prometheusSpec.tolerations`). Без них после пересоздания такие поды зависли бы в `Pending`. StatefulSet Vault обновляется по `OnDelete`: после смены шаблона `vault-0` нужно удалить вручную и распечатать.

Файрвол на worker (`ufw`, `default deny incoming`): остались только SSH (22) и весь трафик с control-plane (`sudo ufw allow from 192.168.64.55`). Без второго правила control-plane не достаёт до kubelet (порт 10250), и `kubectl exec`/`logs` для подов на worker падают с `i/o timeout`. Правила под Calico (BGP, VXLAN, Typha, `10.244.0.0/16`) удалены: Cilium ходит между нодами по трафику, разрешённому правилом для control-plane. Отдельно на worker загружается таблица nftables `ansible_nodeport` (`/etc/nftables.d/ansible-nodeport.nft`, юнит `ansible-nodeport-firewall.service`): она пропускает NodePort (30000–32767) только из перечисленных подсетей, в их число добавлена `192.168.64.0/24`, иначе доступ с Mac к ingress-nginx ломается, когда он оказывается на worker. На control-plane `ufw` не установлен.

## Стек

| Компонент        | Версия/примечание                                  |
|------------------|-----------------------------------------------------|
| Kubernetes       | v1.34.12 (через kubeadm), etcd 3.6.5                 |
| Container runtime| containerd (SystemdCgroup=true)                      |
| CNI              | Cilium 1.20.1 под управлением ArgoCD (`platform/cilium/values.yaml`), `kubeProxyReplacement=true` |
| kube-proxy       | удалён, его роль выполняет Cilium (см. раздел «Установка Cilium») |
| Ingress          | ingress-nginx (NodePort: 80→32337, 443→30971)        |
| TLS              | cert-manager + `ClusterIssuer/selfsigned-issuer`     |
| Metrics          | metrics-server (`--kubelet-insecure-tls`)            |
| GitOps           | ArgoCD + ApplicationSet (репозиторий `k8s-lab-apps`) |
| Хранилище        | local-path-provisioner v0.0.37 (default StorageClass `local-path`) |
| Секреты          | Vault (чарт 0.34.0, Vault 2.0.3), Raft на PVC, 1 реплика, ручной unseal; конфигурация в `iac/vault` (OpenTofu) |
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
echo "192.168.64.55 k8s-api.lab.local" | sudo tee -a /etc/hosts
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

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

## Инициализация control-plane

Выполняется **только** на control-plane ноде (192.168.64.55):

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
  --set k8sServiceHost=k8s-api.lab.local \
  --set k8sServicePort=6443
cilium status --wait
```

> **kube-proxy не нужен, но нужен прямой адрес API.** Параметры `k8sServiceHost`/`k8sServicePort` обязательны, если kube-proxy удалён: иначе после перезагрузки агент Cilium пытается дойти до API через ClusterIP `10.96.0.1`, а маршрутизацию этого адреса делает он же (см. Troubleshooting). Имя `k8s-api.lab.local` работает: агент и оператор запускаются в `hostNetwork` и используют `/etc/hosts` ноды, поэтому запись `192.168.64.55 k8s-api.lab.local` на ноде обязательна (Cilium CLI подставляет адрес API из kubeconfig сам). После установки Cilium переводится под управление ArgoCD (раздел «Cilium под управлением ArgoCD»), и `cilium upgrade` больше не используется.
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

# Манифест cloud/deploy.yaml ставит externalTrafficPolicy: Local: NodePort тогда отвечает
# только на той ноде, где стоит под. С двумя нодами это ломает доступ: под может переехать
# на worker, а /etc/hosts на клиенте указывает на control-plane. Переключаем на Cluster.
kubectl -n ingress-nginx patch svc ingress-nginx-controller -p '{"spec": {"externalTrafficPolicy": "Cluster"}}'
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

При `Cluster` NodePort отвечает на любой ноде и пересылает трафик на под, где бы он ни стоял; цена: приложение видит адрес ноды, а не реальный IP клиента (для лабы не важно). Симптом `Local`: `curl` на NodePort control-plane молчит, а напрямую на ноду с подом возвращает 200.

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

Открыть: `https://192.168.64.55:8080` (логин `admin`, пароль — см. выше). Сертификат самоподписанный, браузер предупредит — это ожидаемо.

Сменить пароль после первого входа:

```bash
argocd account update-password
```

## GitOps-репозиторий (`k8s-lab-apps`)

Публичный репозиторий `https://github.com/servik01/k8s-lab-apps`, ветка `main`. ArgoCD читает его без дополнительных credentials.

```
k8s-lab-apps/
├── bootstrap/
│   ├── applicationset.yaml   # применяется вручную один раз
│   └── cilium.yaml           # Application для Cilium, тоже вручную
├── platform/
│   ├── cilium/values.yaml    # значения Helm-чарта Cilium
│   └── kubeadm/config.yaml   # ClusterConfiguration kubeadm (метрики control-plane)
├── iac/
│   └── vault/                # OpenTofu: конфигурация Vault
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
192.168.64.55 nginx.lab.local whoami.lab.local
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

Конфигурация Vault (mount `secret/` KV v2, auth `kubernetes`, политика и роль) описана кодом в `iac/vault/` и применяется OpenTofu, см. раздел «Vault как код (OpenTofu)». Руками остаются только `operator init`, unseal и значения самих секретов.

Токен-ревью Vault делает токеном собственного ServiceAccount: чарт создаёт ему биндинг `vault-server-binding` на `system:auth-delegator`. Приложение `workloads/vault-demo` получает секрет через аннотации `vault.hashicorp.com/*` (injector добавляет init-контейнер и sidecar `vault-agent`, секрет появляется в `/vault/secrets/config.txt`). Проверка отказа: токен чужого ServiceAccount получает `403 service account name not authorized`.

## Vault как код (OpenTofu)

Папка `iac/vault/` лежит вне `workloads/*`, поэтому ArgoCD её не трогает.

- `providers.tf`: провайдер `hashicorp/vault`, адрес и токен берутся из окружения (`VAULT_ADDR`, `VAULT_TOKEN`).
- `main.tf`: mount `secret` (KV v2), auth `kubernetes` с конфигом (`kubernetes_host = https://kubernetes.default.svc:443`, токен ревью берётся у самого Vault), политика `demo-read` и роль `demo` (ServiceAccount `vault-demo` из namespace `vault-demo`).
- `.terraform.lock.hcl` коммитится (фиксирует версию провайдера), `.gitignore` исключает состояние (`*.tfstate`), `.terraform/` и `*.tfvars`.

**Значения секретов в код не входят**: репозиторий публичный, а значения попали бы ещё и в состояние. Секрет записывается отдельно: `vault kv put secret/demo/config username=... password=...`.

Запуск на VM (OpenTofu 1.13.1, установка: `curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh`, прочитать, затем `sudo /tmp/install-opentofu.sh --install-method deb`):

```bash
kubectl -n vault port-forward svc/vault 8200:8200 >/tmp/vault-pf.log 2>&1 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$(jq -r .root_token ~/vault-init.json)"   # только в окружении сессии, не в файлах

cd ~/k8s-lab-apps/iac/vault
tofu init
tofu plan
tofu apply
kill %1    # остановить port-forward
```

**Пересоздание Vault с нуля**: `operator init` и unseal, затем `tofu apply`, затем `kv put` для секретов. Если на живом Vault настройка уже создана руками, `apply` упрётся в «уже существует»: сначала удалить объекты (`vault secrets disable secret`, `vault auth disable kubernetes`, `vault policy delete demo-read`) или импортировать их через `tofu import`. Роль уходит вместе с auth-бэкендом.

**Состояние** лежит локально: `iac/vault/terraform.tfstate` на VM, в Git не попадает. Без него следующий `apply` на живом Vault упрётся в «уже существует», поэтому нужна копия. Секретных значений в нём нет, но файл всё равно не публиковать.

**Дрейф**: ручное удаление политики видно в `tofu plan` как `~ update in-place` (провайдер читает удалённую политику как пустую), а `tofu apply` её возвращает. Проверка привязки роли: токен чужого ServiceAccount получает `403 service account name not authorized`.

```bash
TOKEN=$(kubectl -n rbac-demo create token dev-viewer)
kubectl -n vault exec vault-0 -- vault write auth/kubernetes/login role=demo jwt="$TOKEN"
```

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
- Мониторы control-plane включены: `kubeControllerManager` и `kubeScheduler` по HTTPS с `insecureSkipVerify` (самоподписанные сертификаты), `kubeEtcd` по HTTP на 2381. Метрики открыты правкой kubeadm-конфигурации (раздел «Конфигурация kubeadm»). `kubeProxy` выключен: kube-proxy в кластере нет.
- `kubelet.serviceMonitor.insecureSkipVerify: true`: самоподписанный сертификат kubelet, как и в случае metrics-server.

Доступ: на Mac в `/etc/hosts` добавить `192.168.64.55 grafana.lab.local prometheus.lab.local`, затем `https://grafana.lab.local:30971` (логин `admin`) и `https://prometheus.lab.local:30971`. Prometheus UI открыт без аутентификации, на проде его закрывают. В **Status → Targets** должны быть `UP` apiserver, kubelet (включая cadvisor), kube-state-metrics, node-exporter, coredns.

Полезный запрос в Prometheus: `sum by (namespace) (container_memory_working_set_bytes{container!=""})`, потребление памяти по namespace.

## Наблюдаемость сети (Hubble)

Hubble и метрики включены значениями в `platform/cilium/values.yaml` и применяются через Git и ArgoCD (раздел «Cilium под управлением ArgoCD»). Первоначально они включались командой `cilium upgrade` с теми же параметрами.

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

UI: `https://hubble.lab.local:30971` (запись в `/etc/hosts` на Mac: `192.168.64.55 hubble.lab.local`), namespace выбирается слева сверху. Hubble показывает потоки по мере появления, поэтому в тихом namespace карта пуста. Демонстрация дропа NetworkPolicy: запустить под без метки `role=client` и обращаться из него к `web`, а для сравнения из `client`:

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

## Cilium под управлением ArgoCD

Раньше Cilium ставился и обновлялся через CLI, а его параметры хранились только в Helm-релизе в кластере. После того как на холодном старте это сломало кластер (см. Troubleshooting), параметры перенесены в Git.

- `platform/cilium/values.yaml`: значения чарта, выгруженные из Helm-релиза (`k8sServiceHost: k8s-api.lab.local`, `kubeProxyReplacement`, Hubble, метрики).
- `bootstrap/cilium.yaml`: Application с двумя источниками: чарт `cilium` версии 1.20.1 из `https://helm.cilium.io/` и этот репозиторий как `ref: values`. Применяется вручную. Папка `platform/` лежит вне `workloads/*`, поэтому ApplicationSet её не трогает.

Особенности Application:

- **Нет finalizer**: удаление Application не сносит CNI.
- **`ignoreDifferences` для `/data`** у Secret'ов `cilium-ca`, `hubble-server-certs`, `hubble-relay-client-certs` (вместе с `RespectIgnoreDifferences=true`): чарт генерирует эти сертификаты при каждом рендере, и без правила Argo ротировал бы их при каждой синхронизации.
- **`automated` с `selfHeal: true` и `prune: false`**: ручные правки откатываются к Git, но Argo ничего не удаляет сам.

Выгрузка значений из релиза (Cilium CLI хранит его в Secret'е Helm, без установки `helm`; перед коммитом проверить вывод на секреты):

```bash
REL=$(kubectl -n kube-system get secret -l owner=helm,name=cilium,status=deployed \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system get secret "$REL" -o jsonpath='{.data.release}' \
  | base64 -d | base64 -d | gunzip | jq '.config'
```

Порядок миграции, который сработал без перезапуска подов: Application без `automated`, затем сравнение через `argocd app diff cilium --core` (единственное расхождение: аннотация `argocd.argoproj.io/tracking-id`), ручной `argocd app sync cilium --core` и сверка `startTime` подов до и после, и только потом включение `automated`. CLI `argocd` в режиме `--core` берёт Argo из kubeconfig, ему нужен namespace `argocd` в текущем контексте: `kubectl config set-context --current --namespace=argocd` (после диффа вернуть `default`). Сборка под arm64: `argocd-linux-arm64` со страницы релизов.

**Правило**: все изменения Cilium делаются в `platform/cilium/values.yaml` и `git push`, `cilium upgrade` не используется. CLI остаётся для `cilium status` и диагностики. Значение `k8sServiceHost: k8s-api.lab.local` работает потому, что агент и оператор в `hostNetwork` резолвят имя через `/etc/hosts` ноды.

Установка на чистый кластер: сначала Cilium ставится CLI (раздел «Установка Cilium»), затем `kubectl apply -f bootstrap/cilium.yaml`. Argo «усыновит» ресурсы, различие только в метках трекинга.

## Конфигурация kubeadm (метрики control-plane)

По умолчанию kubeadm привязывает controller-manager (порт 10257), scheduler (10259) и метрики etcd (2381) к `127.0.0.1`, и Prometheus в кластере до них не достаёт. Параметры лежат в `platform/kubeadm/config.yaml` (`kubeadm.k8s.io/v1beta4`, где `extraArgs` это список пар `name`/`value`):

- `controllerManager` и `scheduler`: `bind-address: 0.0.0.0`.
- `etcd`: `listen-metrics-urls: http://127.0.0.1:2381,http://192.168.64.55:2381`. Loopback в списке стоит первым, чтобы пробы etcd остались на `127.0.0.1:2381`; метрики etcd идут по HTTP без аутентификации, поэтому слушаем только адрес ноды, а не все интерфейсы.
- `InitConfiguration` закрепляет `advertiseAddress` и имя ноды, чтобы фаза `etcd` не пересчитала параметры существующего члена кластера.
- `kubernetesVersion` **должен совпадать с реальной версией кластера** (`kubeadm version`, `kubectl get nodes`). Фазы `init phase control-plane` и `init phase etcd local` берут версии образов из этого поля: с устаревшим значением kubeadm соберёт манифесты со старыми образами (например, etcd 3.5 вместо 3.6, apiserver на минорную версию ниже), а etcd не умеет читать данные, записанные более новой версией. После `kubeadm upgrade` значение в `platform/kubeadm/config.yaml` обновляется в Git.

**Манифесты в `/etc/kubernetes/manifests` руками править нельзя**: следующий `kubeadm upgrade` перезапишет их из ConfigMap `kubeadm-config`. Поэтому правится конфигурация, манифесты регенерируются фазами kubeadm, а затем конфигурация загружается обратно в кластер.

Перед правкой резервные копии, которые лежат в домашней директории вне репозитория (в них приватные ключи кластера):

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

Регенерация по одному компоненту, от наименее рискованного. После каждой фазы сверка с резервной копией (`B` это каталог `~/kubernetes-backup-*`), kubelet пересоздаёт static pod сам в течение минуты:

```bash
B=$(ls -d ~/kubernetes-backup-* | tail -1)
sudo kubeadm init phase control-plane scheduler --config platform/kubeadm/config.yaml
sudo diff $B/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
sudo kubeadm init phase control-plane controller-manager --config platform/kubeadm/config.yaml
sudo diff $B/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml
sudo kubeadm init phase etcd local --config platform/kubeadm/config.yaml   # API ненадолго теряет хранилище
sudo diff $B/manifests/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
sudo kubeadm init phase upload-config kubeadm --config platform/kubeadm/config.yaml
```

Допустимый дифф: смысловое изменение только одно (`--bind-address` или `--listen-metrics-urls`). Строка при этом «переезжает» (kubeadm сортирует аргументы), а у scheduler и controller-manager пропадают поля `host: 127.0.0.1` у проб: для `0.0.0.0` kubeadm убирает `host`, и пробы идут на адрес пода (в `hostNetwork` это IP ноды). Откатывать нужно, если изменились `--cluster-cidr`, `--service-cluster-ip-range`, `--initial-cluster`, `--listen-peer-urls`, `--advertise-client-urls`, `--name`, `--data-dir` или образ.

Откат компонента: `sudo cp $B/manifests/<файл>.yaml /etc/kubernetes/manifests/`. Если кластер совсем не поднимается, в запасе снимок etcd.

Проверка: `sudo ss -tlnp | grep -E ':10257|:10259|:2381'` (у первых двух `*`, у `:2381` два адреса), `curl -s http://192.168.64.55:2381/metrics | head -3`, `kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' | grep -A3 extraArgs` (три блока), затем цели `kube-controller-manager`, `kube-scheduler`, `kube-etcd` в Prometheus в состоянии `up`.

## Смена IP ноды (например, после переноса VM)

Симптомы: `kubectl` отвечает `connection refused`, в `journalctl -u kubelet` `dial tcp <старый IP>:6443: no route to host`, etcd и apiserver в CrashLoop (etcd не может занять старый адрес). Старый IP зашит в трёх местах: манифесты static pod'ов (etcd, apiserver), kubeconfig'и компонентов (`kubelet.conf`, `scheduler.conf`, `controller-manager.conf`) и сертификаты (SAN apiserver, etcd server/peer). Список файлов: `sudo grep -rl <старый IP> /etc/kubernetes`.

1. Обновить `/etc/hosts` (`<новый IP> k8s-api.lab.local`) и сделать резервные копии: `sudo cp -a /etc/kubernetes ~/kubernetes-backup-newip` и `sudo cp -a /var/lib/etcd ~/etcd-data-backup`.
2. В `platform/kubeadm/config.yaml` заменить IP (`advertiseAddress`, `listen-metrics-urls`) и **проверить `kubernetesVersion`**: он должен совпадать с реальной версией кластера.
3. Перевести kubeconfig'и с IP на имя:
   ```bash
   sudo sed -i 's#https://<старый IP>:6443#https://k8s-api.lab.local:6443#' \
     /etc/kubernetes/{kubelet,scheduler,controller-manager}.conf
   ```
4. Перевыпустить сертификаты (старые убрать, иначе kubeadm их не пересоздаст):
   ```bash
   mkdir -p ~/old-pki
   sudo mv /etc/kubernetes/pki/apiserver.{crt,key} ~/old-pki/
   sudo mv /etc/kubernetes/pki/etcd/server.{crt,key} ~/old-pki/
   sudo mv /etc/kubernetes/pki/etcd/peer.{crt,key} ~/old-pki/
   sudo kubeadm init phase certs apiserver   --config platform/kubeadm/config.yaml
   sudo kubeadm init phase certs etcd-server --config platform/kubeadm/config.yaml
   sudo kubeadm init phase certs etcd-peer   --config platform/kubeadm/config.yaml
   ```
5. В манифестах etcd и apiserver заменить IP: `sudo sed -i 's/<старый IP>/<новый IP>/g' /etc/kubernetes/manifests/{etcd,kube-apiserver}.yaml`, затем проверить, что образы остались прежними (`grep image: /etc/kubernetes/manifests/*.yaml`). Регенерация через `kubeadm init phase` допустима только при актуальном `kubernetesVersion` (см. раздел «Конфигурация kubeadm»).
6. `sudo systemctl restart kubelet`, затем **перезапустить scheduler и controller-manager**: static pod читает kubeconfig только при старте. Если этого не сделать, поды не создаются и не планируются (scheduler в `0/1 Running`, ReplicaSet не порождает поды):
   ```bash
   sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
   sleep 20
   sudo mv /tmp/kube-scheduler.yaml /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
   ```
7. После подъёма API обновить peer URL в etcd и загрузить конфигурацию обратно:
   ```bash
   kubectl -n kube-system exec etcd-kubernetes -- etcdctl --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key member list -w table
   # затем member update <ID> --peer-urls=https://<новый IP>:2380 (те же флаги)
   sudo kubeadm init phase upload-config kubeadm --config platform/kubeadm/config.yaml
   ```
8. Распечатать Vault, проверить `cilium status`, `kubectl get pods -A | grep -v Running` и статусы Application в ArgoCD. Поды, зависшие в `Unknown` с момента потери ноды, удалить: Deployment создаст новые. Обновить `/etc/hosts` на клиентских машинах. Если Vault-injector не успел стартовать к моменту пересоздания пода, `vault-demo` поднимется без sidecar `vault-agent`: удалить под ещё раз после того, как `vault-agent-injector` станет `Ready`.

Чтобы упростить следующий переезд: DHCP-резервация или статический IP для VM.

## Известные моменты / TODO

- **Vault**: после каждого перезапуска пода нужен ручный unseal (auto-unseal: transit или облачный KMS). Состояние OpenTofu лежит локально на VM: кандидат на удалённый backend. Для провайдера используется root token, лучше отдельный токен с узкой политикой.
- **Cilium под ArgoCD**: Application (`bootstrap/cilium.yaml`) применяется вручную, как и ApplicationSet. `prune: false`, чтобы Argo не удалял ресурсы CNI сам. Версия чарта обновляется правкой `targetRevision` в манифесте Application и повторным `kubectl apply -f bootstrap/cilium.yaml`.
- **Метрики control-plane** открыты на адресе ноды: controller-manager и scheduler требуют токен с правом на `/metrics` (у Prometheus он есть), а метрики etcd идут по HTTP без аутентификации. Для лабы это приемлемо, на проде такие порты закрывают сетевыми политиками или файрволом.
- **IP ноды** не закреплён за VM (меняется при переносе на другой хост): настроить DHCP-резервацию или статический адрес; порядок действий при смене IP — раздел «Смена IP ноды».
- **Данные на `local-path`** привязаны к ноде (control-plane) и не переезжают: при потере этой ноды Vault, Prometheus и Grafana не поднимутся на worker. Для настоящей отказоустойчивости нужно реплицируемое хранилище (Longhorn, Rook-Ceph или NFS) и восстановление из снимков.
- **Файрвол worker**: в `allowed_v4` таблицы `ansible_nodeport` по-прежнему стоит `10.244.0.0/16` от прежнего кластера на Calico, для Cilium он не нужен. При пересоздании worker-VM нужно заново выставить правила `ufw` и подсеть в таблице, иначе будут падать `exec`/`logs` и NodePort.
- **Версия containerd** на нодах разная (control-plane 2.3.6, worker 2.4.2): выровнять и закрепить `apt-mark hold containerd.io`.
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

**`kubeadm join` на новой VM: `FileAvailable--etc-kubernetes-kubelet.conf already exists`, а `hostname -I` показывает IP worker, не control-plane**
На VM остался собственный кластер (в этой лабе: одноузловой кластер на Calico, поднятый при подготовке образа). Признак: в `/etc/kubernetes/manifests` лежат `etcd.yaml` и `kube-apiserver.yaml`, `ss -tlnp` показывает 6443 и 2379. Лечение: `kubeadm reset -f` и очистка из блока выше; предупреждения `calico ... 10.96.0.1:443 connection refused` при `reset` ожидаемы (API старого кластера уже мёртв). Затем `rm -rf /var/lib/cni /var/lib/calico /var/run/calico`, перезагрузка (убирает интерфейсы `cali*`/`tunl0` и зависшие sandbox'ы), проверка `/proc/swaps`, после этого новый `join` со свежим токеном. Перед `reset` обязательно убедиться, что команда выполняется на worker, а не на control-plane.

**`kubectl exec` / `logs` для пода на worker: `dial tcp <worker-ip>:10250: i/o timeout`**
Control-plane не достаёт до kubelet worker: порт закрыт файрволом (`ufw` с `default deny incoming`). Join при этом проходит, потому что идёт в обратную сторону (worker → API). Лечение на worker: `sudo ufw allow from <control-plane-ip>`. Проверка: `nc -zv -w3 <worker-ip> 10250` с control-plane.

**`sudo: unable to resolve host <имя>` на новой VM**
Hostname сменили, а в `/etc/hosts` остался `127.0.1.1 <старое имя>`. Исправить строку `127.0.1.1` на актуальный hostname (kubelet регистрирует ноду по hostname).

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
Cilium заменяет kube-proxy, а kube-proxy в кластере нет: агенту нужен API-сервер, но ClusterIP `10.96.0.1` маршрутизирует сам Cilium, который из-за этого не стартует. Замкнутый круг не виден, пока в памяти ядра живут старые BPF-программы, и проявляется на холодном старте. Лечение: дать Cilium прямой адрес API, то есть `k8sServiceHost` и `k8sServicePort` в `platform/cilium/values.yaml`. Сейчас `cilium upgrade` использовать нельзя: `selfHeal` откатит правку к Git. Если кластер сломан настолько, что Argo не может синхронизироваться, временный выход это `cilium upgrade --reuse-values --set k8sServiceHost=k8s-api.lab.local --set k8sServicePort=6443`, после которого значения обязательно переносятся в Git.
Признак в журнале kubelet: `deletion queue directory /var/run/cilium/deleteQueue has too many entries`. После запуска Cilium при необходимости: `sudo rm -f /var/run/cilium/deleteQueue/*` и `sudo systemctl restart kubelet`.

**Новая папка в `workloads/` не превращается в Application**
ApplicationSet читает Git через кэш repo-server (до нескольких минут). Принудительно обновить: `kubectl -n argocd annotate applicationset workloads argocd.argoproj.io/application-set-refresh=true --overwrite`.

**`kubectl exec` сразу после удаления пода: `container not found`**
Гонка: контейнер ещё не создан. Подожди несколько секунд и повтори.
