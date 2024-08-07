# Deploy BigBertha on Azure Kubernetes Service (AKS)

This guide will walk you through deploying BigBertha on Azure Kubernetes Service (AKS) using ArgoCD.

High-level overview of the components that will be deployed:

![BigBertha on Azure](../assets/bigbertha-on-azure.png)

## Prerequisites

Before you begin, ensure you have the following installed:

- [Git](https://git-scm.com/downloads) to clone the repository
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) to provision Azure resources
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli) to provision Azure resources
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) to interact with the Kubernetes cluster
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) to interact with ArgoCD
- [Argo CLI](https://github.com/argoproj/argo-workflows/releases/) to interact with Argo workflows

With the prerequisites installed, clone the BigBertha repository and navigate to root directory.

```bash
git clone https://github.com/pauldotyu/BigBertha.git
cd BigBertha
```

## Provision an AKS Cluster

Start by logging into Azure CLI and ensure you have all the necessary features registered for your subscription.

```bash
az login
az feature register --namespace Microsoft.ContainerService --name EnableAPIServerVnetIntegrationPreview
az feature register --namespace Microsoft.ContainerService --name NRGLockdownPreview
az feature register --namespace Microsoft.ContainerService --name SafeguardsPreview
az feature register --namespace Microsoft.ContainerService --name NodeAutoProvisioningPreview
az feature register --namespace Microsoft.ContainerService --name DisableSSHPreview
az feature register --namespace Microsoft.ContainerService --name AutomaticSKUPreview
az feature register --namespace Microsoft.ContainerService --name AIToolchainOperatorPreview
```

Run the following command to create a resource group and provision an AKS cluster.

```bash
cd azure/infra/terraform
terraform init
terraform apply
```

> [!NOTE]
> When prompted, enter **yes** to create the resources. This will take a few minutes to complete.

When the deployment is complete, run the following commands to set environment variables and get the AKS credentials.

```bash
# Set environment variables from Terraform output
RG_NAME=$(terraform output -raw rg_name)
AKS_NAME=$(terraform output -raw aks_name)
EH_FQDN=$(terraform output -raw eh_fqdn)
EH_NAME=$(terraform output -raw eh_name)
EH_KEY_NAME=$(terraform output -raw eh_default_primary_key_name)
EH_KEY=$(terraform output -raw eh_default_primary_key)
PSQL_FQDN=$(terraform output -raw psql_fqdn)
PSQL_USER=$(terraform output -raw psql_admin_user)
PSQL_PASSWORD=$(terraform output -raw psql_admin_password)

# Get AKS credentials
az aks get-credentials -n $AKS_NAME -g $RG_NAME

# Restart kaito-gpu-provisioner
kubectl rollout restart deployment/kaito-gpu-provisioner -n kube-system
```

## Deploy components

Create a namespace for ArgoCD and deploy it.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Connect the ArgoCD CLI using .kubeconfig file

```bash
argocd login --core
```

Set the default namespace to `argocd` and deploy the components.

```bash
kubectl config set-context --current --namespace=argocd
```

Navigate to the root of the BigBertha repository and deploy the ArgoCD applications.

```bash
cd ../../../
```

Deploy the underlying components.

```bash
argocd app create argo-events --sync-policy auto -f infra/argoevents.yaml
argocd app create argowf --sync-policy auto -f infra/argowf.yaml
argocd app create milvus --sync-policy auto -f infra/milvus.yaml
```

Ensure all the components are deployed successfully and showing `Healthy` status.

```bash
argocd app list
```

## Configure MinIO

Patch the MinIO service to expose it as a LoadBalancer. We will be coming back to this app later to upload a file.

```bash
kubectl patch -n milvus svc/milvus-minio -p '{"spec": {"type": "LoadBalancer"}}'
```

Run the following commands to get the MinIO username and password.

```bash
kubectl get secret -n milvus milvus-minio -o jsonpath='{.data.root-user}' | base64 --decode && echo && k get secret -n milvus milvus-minio -o jsonpath='{.data.root-password}' | base64 --decode
```

Get the external IP of the MinIO service and output the URL to the terminal.

```bash
EXTERNAL_IP=$(kubectl get -n milvus svc/milvus-minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$EXTERNAL_IP:9001
```

Click the link in the terminal to open the MinIO dashboard. Use the username and password from the previous step to login.

Under **Administrator**, click on the **Buckets** tab and create two new buckets named `ingestion` and `mlflow`.

Under **User**, click on the **Access Keys** tab and create a new access key and save both the access key and secret key to variables.

```bash
MINIO_ACCESS_KEY=<access_key>
MINIO_SECRET_KEY=<secret_key>
```

## Deploy mlflow

```bash
cat << EOF > mlflow-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: mlflow
spec:
  destination:
    name: ''
    namespace: mlflow
    server: 'https://kubernetes.default.svc'
  source:
    path: ''
    repoURL: 'https://community-charts.github.io/helm-charts'
    targetRevision: 0.7.19
    chart: mlflow
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: artifactRoot.s3.bucket
          value: mlflow
        - name: backendStore.postgres.password
          value: $PSQL_PASSWORD
        - name: backendStore.postgres.enabled
          value: 'true'
        - name: backendStore.postgres.user
          value: ${PSQL_USER}@${PSQL_FQDN}
        - name: backendStore.postgres.host
          value: $PSQL_FQDN
        - name: backendStore.postgres.database
          value: mlflow
        - name: artifactRoot.s3.enabled
          value: 'true'
        - name: artifactRoot.s3.awsAccessKeyId
          value: $MINIO_ACCESS_KEY
        - name: artifactRoot.s3.awsSecretAccessKey
          value: $MINIO_SECRET_KEY
        - name: artifactRoot.s3.path
          value: mlflow
      values: |-
        extraEnvVars:
          MLFLOW_S3_ENDPOINT_URL: http://milvus-minio.milvus.svc:9001
  sources: []
  project: default
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
EOF
```

Then run the following command to deploy the mlflow app.

```bash
argocd app create mlflow --sync-policy auto -f mlflow-app.yaml
```

Wait a few minutes then run the following command to ensure the mlflow app is running.

```bash
argocd app get argocd/mlflow
```

If the mlflow app is not running, run the following command to get the logs.

```bash
MLFLOW_POD_NAME=$(kubectl get po -n mlflow -lapp=mlflow -ojsonpath='{.items[0].metadata.name}')
kubectl logs -n mlflow $MLFLOW_POD_NAME
```

## Deploy vector-ingestion app

Create the bigbertha-chatbot app manifest file.

```bash
cat << EOF > vectoringestion-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bigbertha-vector-ingestion
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/pauldotyu/BigBertha'
    path: vector-ingestion
    targetRevision: HEAD
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: minio.accessKey.value
          value: $MINIO_ACCESS_KEY
        - name: minio.secretKey.value
          value: $MINIO_SECRET_KEY
        - name: minio.endpoint
          value: milvus-minio.milvus.svc
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: vector-ingestion
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
EOF
```

Then run the following command to deploy the vector-ingestion app.

```bash
argocd app create bigbertha-vector-ingestion --sync-policy auto -f vectoringestion-app.yaml
```

Wait a few minutes then run the following command to ensure the vector-ingestion app is running.

```bash
argocd app get argocd/bigbertha-vector-ingestion
```

## Deploy chatbot app

Head over to [HuggingFace](https://huggingface.co/settings/tokens), login to your account, then get your access token and save it to a variable.

```bash
HF_API_TOKEN=<your_access_token>
```

Create the bigbertha-chatbot app manifest file.
  
```bash
cat << EOF > chatbot-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: bigbertha-llmchatbot
  namespace: argocd
spec:
  project: default
  source:
    repoURL: 'https://github.com/pauldotyu/BigBertha'
    path: llmops
    targetRevision: HEAD
    helm:
      valueFiles:
        - values.yaml
      parameters:
        - name: chatbotapp.environment.HUGGINGFACEHUB_API_TOKEN
          value: $HF_API_TOKEN
        - name: chatbotapp.image.tag
          value: v1.7
        - name: chatbotapp.replicas
          value: '1'
        - name: chatbotapp.resources.memoryLimit
          value: 5Gi
        - name: chatbotapp.resources.memoryRequest
          value: 3Gi
        - name: chatbotapp.image.repository
          value: aishwaryaprabhat/chatbot
        - name: servicemonitor.useAzureServiceMonitor
          value: "true"
        - name: eventsource.azureEventHub.fqdn
          value: $EH_FQDN
        - name: eventsource.azureEventHub.hubName
          value: $EH_NAME
        - name: eventsource.azureEventHub.sharedAccessKeyName
          value: $EH_KEY_NAME
        - name: eventsource.azureEventHub.sharedAccessKey
          value: $EH_KEY
        - name: alertmanagerconfig.useAzureAlerts
          value: "true"
        - name: prometheusrule.useAzurePrometheusRules
          value: "true"
  destination:
    server: 'https://kubernetes.default.svc'
    namespace: bigbertha
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
EOF
```

Then run the following command to deploy the chatbot app.

```bash
argocd app create bigbertha-llmchatbot --sync-policy auto -f chatbot-app.yaml
```

Wait a few minutes then run the following command to ensure the chatbot app is running.

```bash
argocd app get argocd/bigbertha-llmchatbot
```

Ensure all the components are deployed successfully and showing `Healthy` status.

```bash
argocd app list
```

## Verify the chatbot metrics endpoint is being scraped by Azure Managed Prometheus

Run the following command to port-forward the AMA metrics pod to view the metrics.
```bash
AMA_METRICS_POD_NAME=$(kubectl get po -n kube-system -lrsName=ama-metrics -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $AMA_METRICS_POD_NAME -n kube-system 9090
```

Open the Prometheus UI at http://localhost:9090 and click on the **Status** tab to view the targets. You should see the `serviceMonitor/bigbertha/bigbertha-llmchatbot-servicemonitor` target in **UP** state.

The metrics endpoint should be scraped every minute and you should see the metrics for `thumbs_down_count` and `thumbs_up_count` when using the Prometheus Explorer within the Azure Monitor Workspace in the Azure Portal.

## Verify the model retraining workflow

Patch the LLM chatbot service to expose it as a LoadBalancer. We'll be using this service to trigger retraining workflows.

```bash
kubectl patch -n bigbertha svc/llmchatbot -p '{"spec": {"type": "LoadBalancer"}}'
```

Get the external IP of the LLM chatbot service and output the URL to the terminal.

```bash
EXTERNAL_IP=$(kubectl get -n bigbertha svc/llmchatbot -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$EXTERNAL_IP:8501
echo http://$EXTERNAL_IP:5000/metrics
```

Click the link in the terminal to open the chatbot. Wait for the page to load then click the thumbs up button.

Next, click the link to the metrics endpoint to view the metrics. You should see the metrics for both the `thumbs_down_count` and `thumbs_up_count`.

Refresh the chatbot page and click the thumbs down button a few times. This will trigger a Prometheus alert which will in turn trigger a retraining workflow.

Run the following command to confirm the event source triggered the retraining workflow.

```bash
SENSOR_POD_NAME=$(kubectl get po -n bigbertha -l owner-name=retraining-sensor -ojsonpath='{.items[0].metadata.name}')
kubectl logs -n bigbertha $SENSOR_POD_NAME
```

You should see the logs for the retraining workflow.

```bash
Name:                llm-retraining-pipeline-qt9fv
Namespace:           bigbertha
ServiceAccount:      unset
Status:              Pending
Created:             Mon Jul 01 05:03:54 +0000 (now)
Progress:            
{"level":"info","ts":1719810234.2049482,"logger":"argo-events.sensor","caller":"sensors/listener.go:423","msg":"Successfully processed trigger 'model-retraining-trigger'","sensorName":"retraining-sensor","triggerName":"model-retraining-trigger","triggerType":"ArgoWorkflow","triggeredBy":["retraining-webhook-triggered"],"triggeredByEvents":["66383862323364322d373566362d343734662d393565322d613034393865636432336633"]}
``` 

You should also see an alert in the Alerts blade in the Azure portal. This alert will trigger an Azure Event Hub alert which will trigger Argo Events and the Argo Workflow for model retraining.

Run the following command to watch the retraining workflow.

```bash
argo watch @latest -n bigbertha
```

## Verify the vector ingestion workflow

Next we want to verify the vector ingestion workflow. We will upload a file to the MinIO bucket we created earlier.

Navigate to the MinIO dashboard and click on the **Object Browser** tab. Click on the `ingestion` bucket and upload the `demo-container/ingestion/keiichi_tsuchiya.pdf` file.

This will trigger the vector ingestion workflow which can be viewed via the Argo CLI.

```bash
argo watch @latest -n vector-ingestion
```

If you port-forward the Milvus service, you can view the vectors in the Milvus UI.

```bash
kubectl port-forward svc/milvus-attu -n milvus 8081:80
```

Open the Milvus UI at http://localhost:8081, set the to Milvus address to `milvus-proxy.milvus.svc:19530` then click **Connect**.

You should see a **Loaded Collection** named `llamalection` with a **Approx Entity Count** of 1 or more.

## Clean up

Run the following command to delete the resource group and all resources created.

```bash
cd azure/infra/terraform
terraform destroy
```
