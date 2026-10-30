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
