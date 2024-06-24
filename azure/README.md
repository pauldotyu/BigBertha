# Deploy BigBertha on Azure Kubernetes Service (AKS)

This guide will walk you through deploying BigBertha on Azure Kubernetes Service (AKS) using ArgoCD.

## Prerequisites

Before you begin, ensure you have the following installed:

- [Git](https://git-scm.com/downloads) to clone the repository
- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) to provision Azure resources
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/) to interact with the Kubernetes cluster
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) to interact with ArgoCD
- [Argo CLI](https://github.com/argoproj/argo-workflows/releases/) to interact with Argo workflows

With the prerequisites installed, clone the BigBertha repository and navigate to root directory.

```bash
git clone https://github.com/pauldotyu/BigBertha.git
cd BigBertha
```

## Provision an AKS Cluster

Start by logging into Azure and ensure you have all the necessary features registered for your subscription.

```bash
az feature register --namespace Microsoft.ContainerService --name EnableAPIServerVnetIntegrationPreview
az feature register --namespace Microsoft.ContainerService --name NRGLockdownPreview
az feature register --namespace Microsoft.ContainerService --name SafeguardsPreview
az feature register --namespace Microsoft.ContainerService --name NodeAutoProvisioningPreview
az feature register --namespace Microsoft.ContainerService --name DisableSSHPreview
az feature register --namespace Microsoft.ContainerService --name AutomaticSKUPreview
```

Ensure you have the necessary Azure CLI extensions installed.

```bash
az extension add --name aks-preview
az extension add --name amg
```

Create a resource group and an AKS cluster.

```bash
# Set a random resource identifier
RAND=$RANDOM
export RAND
echo "Random resource identifier will be: ${RAND}"

# Set variables
LOCATION=westeurope
RG_NAME=rg-bigbertha$RAND
AKS_NAME=aks-bigbertha$RAND
MONITOR_NAME=mon-bigbertha$RAND
LOGS_NAME=log-bigbertha$RAND
GRAFANA_NAME=amg-bigbertha$RAND

# Create resource group
az group create -n $RG_NAME -l $LOCATION

# Create observability resources
MONITOR_ID=$(az monitor account create -n $MONITOR_NAME -g $RG_NAME --query id -o tsv)
LOGS_ID=$(az monitor log-analytics workspace create -n $LOGS_NAME -g $RG_NAME --query id -o tsv)
GRAFANA_ID=$(az grafana create -n $GRAFANA_NAME -g $RG_NAME --query id -o tsv)

# Create AKS cluster
az aks create -n $AKS_NAME -g $RG_NAME \
  --sku automatic \
  --azure-monitor-workspace-resource-id $MONITOR_ID \
  --workspace-resource-id $LOGS_ID \
  --grafana-resource-id $GRAFANA_ID

# Connect to the AKS cluster
az aks get-credentials -n $AKS_NAME -g $RG_NAME
```

## Edit Karpenter nodepool

Run the command to edit the Karpenter nodepool

```bash
kubectl edit nodepool default
```

Update the `karpenter.azure.com/sku-family` key to the end of the manifest to deploy E series VMs for worker nodes

```yaml
      ...
      - key: karpenter.azure.com/sku-family
        operator: In
        values:
        - E
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

Deploy the underlying components.

```bash
argocd app create kube-prometheus-stack --sync-policy auto -f infra/prometheus.yaml
argocd app create argo-events --sync-policy auto -f infra/argoevents.yaml
argocd app create argowf --sync-policy auto -f infra/argowf.yaml
argocd app create postgres --sync-policy auto -f infra/postgres.yaml
argocd app create milvus --sync-policy auto -f infra/milvus.yaml
argocd app create mlflow --sync-policy auto -f infra/mlflow.yaml
```

Ensure all the components are deployed successfully and showing `Healthy` status.

```bash
argocd app list
```

## Configure MinIO

Run the following commands to get the MinIO username and password.

```bash
kubectl get secret -n milvus milvus-minio -o jsonpath='{.data.root-user}' | base64 --decode && echo && k get secret -n milvus milvus-minio -o jsonpath='{.data.root-password}' | base64 --decode
```

Patch the MinIO service to expose it as a LoadBalancer. We will be coming back to this app later to upload a file.

```bash
kubectl patch -n milvus svc/milvus-minio -p '{"spec": {"type": "LoadBalancer"}}'
```

Get the external IP of the MinIO service and output the URL to the terminal.

```bash
EXTERNAL_IP=$(kubectl get -n milvus svc/milvus-minio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo http://$EXTERNAL_IP:9001
```

Click the link in the termainal to open the MinIO dashboard. Use the username and password from the previous step to login.

Under **User**, click on the **Access Keys** tab and create a new access key and note both the access key and secret key.

Under **Administrator**, click on the **Buckets** tab and create a new bucket named `ingestion`.

## Deploy vector-ingestion and chatbot apps

Open the `infra/bigbertha-vector-ingestion.yaml` file and update the values for `minio.accessKey.value` and `minio.secretKey.value` with the access key and secret key respectively.

Then run the following command to deploy the vector-ingestion app.

```bash
argocd app create bigbertha-vector-ingestion --sync-policy auto -f infra/bigbertha-vector-ingestion.yaml
```

Next head over to [HuggingFace](https://huggingface.co/settings/tokens), login to your account, then get your access token

Open the `infra/bigbertha-chatbot.yaml` file and update the value for `environment.HUGGINGFACEHUB_API_TOKEN` with your access token

Then run the following command to deploy the chatbot app.

```bash
argocd app create bigbertha-llmchatbot --sync-policy auto -f infra/bigbertha-chatbot.yaml
```

Ensure all the components are deployed successfully and showing `Healthy` status.

```bash
argocd app list
```

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

If you port-foward the Prometheus service, you can view the alerts in the Prometheus UI.

```bash
kubectl port-forward svc/prometheus-operated -n prometheus 9090:9090
```

Open the Prometheus UI at http://localhost:9090 and click on the **Alerts** tab to view the alerts. You should see an alert for `thumbs_down_count_exceeded`.

When the alert is in **Firing** state, this will trigger the retraining workflow which can be viewed via the Argo CLI.

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
az group delete -n $RG_NAME --yes --no-wait
```
