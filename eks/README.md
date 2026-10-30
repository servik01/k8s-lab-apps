# EKS GitOps

Каталоги `eks/workloads/*` автоматически обнаруживаются ApplicationSet `eks-workloads` в EKS. Ветка — `main`, период проверки — 60 секунд. Домашний кластер продолжает использовать `workloads/*` и свой bootstrap.

Для нового приложения создайте `eks/workloads/<name>/` с Kubernetes manifests, `kustomization.yaml` или Helm `Chart.yaml` и `values.yaml`, затем выполните commit/push в этот репозиторий. Отдельный Argo CD Application YAML и изменения инфраструктурного репозитория не нужны. Argo CD определяет тип источника автоматически. Имя каталога должно быть допустимым именем Kubernetes namespace; используйте короткие уникальные имена в lowercase с дефисами. Не задавайте в manifests другой namespace.

Каждый каталог создаёт Application и namespace с тем же именем. Включены auto-sync, self-heal, prune и CreateNamespace. Изменение файлов автоматически обновляет workload. Удаление каталога с push удаляет Application и его ресурсы, в том числе последнего приложения. Namespace, созданный CreateNamespace, может остаться. Переименование каталога означает удаление старого приложения и создание нового.

`whoami` — EKS-вариант: две реплики и ClusterIP Service, без домашнего Ingress и зависимостей nginx/cert-manager. Он независим от `workloads/whoami`: изменения для EKS вносите сюда. Перед добавлением приложений проверяйте CPU, память, Pod IP, storage и зависимости. Не храните секреты в Git.

Bootstrap и инструкция установки Argo CD: https://github.com/servik01/tf-aws-create-eks-cluster/tree/main/examples/terragrunt/argocd/bootstrap

Проверка:

```sh
kubectl --context example-eks -n argocd get applicationsets,applications
kubectl --context example-eks -n whoami get pods,service
```

## Дополнительные демо

- `nginx-demo`: две реплики nginx, ClusterIP Service, без Ingress. Открыть: `kubectl --context example-eks -n nginx-demo port-forward svc/nginx-demo 8082:80`, затем http://localhost:8082.
- `rbac-demo`: Deployment/sample и ServiceAccount/dev-viewer. Role разрешает чтение pods и pods/log в namespace rbac-demo; ClusterRole/eks-demo-node-reader разрешает чтение nodes. Изменение ресурсов не разрешено. ClusterRole и ClusterRoleBinding имеют отдельные имена для EKS-демо.

Проверка RBAC от имени ServiceAccount (команды выполняет администратор с правом impersonate):

```sh
kubectl --context example-eks auth can-i list pods -n rbac-demo --as=system:serviceaccount:rbac-demo:dev-viewer
kubectl --context example-eks auth can-i get nodes --as=system:serviceaccount:rbac-demo:dev-viewer
kubectl --context example-eks auth can-i delete pods -n rbac-demo --as=system:serviceaccount:rbac-demo:dev-viewer
kubectl --context example-eks auth can-i get secrets -n rbac-demo --as=system:serviceaccount:rbac-demo:dev-viewer
```

Ожидается: yes, yes, no, no. На EKS не добавлены домашние local-path, Vault, monitoring и netpol-demo: им нужна отдельная настройка storage, зависимостей или enforcement сетевых политик.
