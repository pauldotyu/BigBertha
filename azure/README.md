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
az feature register --namespace Microsoft.ContainerService --name AIToolchainOperatorPreview
```

Ensure you have the necessary Azure CLI extensions installed.

```bash
az extension add --name aks-preview
az extension add --name amg
az extension add --name alertsmanagement
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
  --grafana-resource-id $GRAFANA_ID \
  --enable-ai-toolchain-operator

# Connect to the AKS cluster
az aks get-credentials -n $AKS_NAME -g $RG_NAME
```

Configure Kaito addon for the AKS cluster.

```bash
# Set variables to configure Kaito
MC_RESOURCE_GROUP=$(az aks show -n $AKS_NAME -g $RG_NAME --query nodeResourceGroup -o tsv)
PRINCIPAL_ID=$(az identity show --n "ai-toolchain-operator-${AKS_NAME}" -g $MC_RESOURCE_GROUP --query principalId -o tsv)
KAITO_IDENTITY_NAME="ai-toolchain-operator-${AKS_NAME}"
AKS_OIDC_ISSUER=$(az aks show -n $AKS_NAME -g $RG_NAME --query oidcIssuerProfile.issuerUrl -o tsv)
AKS_ID=$(az aks show -n $AKS_NAME -g $RG_NAME --query id -o tsv)

# Grant permissions to the AI Toolchain Operator
az role assignment create \
  --role Contributor \
  --assignee-object-id $PRINCIPAL_ID \
  --assignee-principal-type ServicePrincipal \
  --scope $AKS_ID

# Disable AKS Automatic to remove NRG Lockdown
az aks update -n $AKS_NAME -g $RG_NAME --sku base

# Remove the NRG Lockdown to update Kaito managed identity
az aks update -n $AKS_NAME -g $RG_NAME --nrg-lockdown-restriction-level Unrestricted --no-wait

# Create Kaito federated credential
az identity federated-credential create \
  -n kaito-federated-identity \
  -g $MC_RESOURCE_GROUP \
  --identity-name $KAITO_IDENTITY_NAME \
  --issuer $AKS_OIDC_ISSUER \
  --subject system:serviceaccount:kube-system:kaito-gpu-provisioner \
  --audience api://AzureADTokenExchange
```

Create Azure Event Hub and Action Group which will be used to trigger Argo Events and the Argo Workflow for model retraining.

```bash
# Set eventhub name
EH_NAMESPACE=eh-bigbertha$RAND
EH_NAME=myeventhub
AG_NAME=ag-bigbertha$RAND

# Create Azure Event Hub and get the FQDN
EH_FQDN=$(az eventhubs namespace create \
  -g $RG_NAME \
  -n $EH_NAMESPACE \
  -l $LOCATION \
  --sku Basic \
  --query serviceBusEndpoint \
  -o tsv | sed -e 's/https:\/\///' -e 's/:443\///')

# Get the access key name and key
EH_KEY_NAME=$(az eventhubs namespace authorization-rule keys list \
  -g $RG_NAME \
  --namespace-name $EH_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query keyName \
  -o tsv)

EH_KEY=$(az eventhubs namespace authorization-rule keys list \
  -g $RG_NAME \
  --namespace-name $EH_NAMESPACE \
  --name RootManageSharedAccessKey \
  --query primaryKey \
  -o tsv)

# Create Azure Event Hub eventhub
az eventhubs eventhub create \
  -g $RG_NAME \
  -n $EH_NAME \
  --namespace-name $EH_NAMESPACE \
  --cleanup-policy Delete \
  --partition-count 1

# Create Azure Monitor Action Group
AG_ID=$(az monitor action-group create \
  --action eventhub myaction $(az account show --query id -o tsv) $EH_NAMESPACE $EH_NAME usecommonalertschema \
  -n $AG_NAME \
  -g $RG_NAME \
  --query id \
  -o tsv)
```

Create Prometheus Rule Group Alert and configure it to send alerts to the Azure Event Hub via the Action Group.

```bash
# Create a rule json file
cat << EOF > llmops_rule.json
[
  {
    "alert": "thumbs_down_count_exceeded",
    "enabled": true,
    "expression": "thumbs_down_count > thumbs_up_count",
    "severity": 3,
    "for": "PT1M",
    "labels": {},
    "annotations": {},
    "actions": [
      {
        "actionGroupId": "${AG_ID}",
        "actionProperties": {}
      }
    ],
    "resolveConfiguration": {
      "autoResolved": true,
      "timeToResolve": "PT2M"
    }
  }
]
EOF

# Create Prometheus Rule Group and pass in the rule json file
az alerts-management prometheus-rule-group create \
  -n llmops \
  -g $RG_NAME \
  -l $LOCATION \
  --enabled \
  --description "Model retraining required" \
  --interval PT15S \
  --scopes $MONITOR_ID \
  --rules llmops_rule.json
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

Click the link in the terminal to open the MinIO dashboard. Use the username and password from the previous step to login.

Under **Administrator**, click on the **Buckets** tab and create a new bucket named `ingestion`.

Under **User**, click on the **Access Keys** tab and create a new access key and save both the access key and secret key to variables.

```bash
MINIO_ACCESS_KEY=<access_key>
MINIO_SECRET_KEY=<secret_key>
```

## Deploy vector-ingestion and chatbot apps

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

Next head over to [HuggingFace](https://huggingface.co/settings/tokens), login to your account, then get your access token and save it to a variable.

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

## Verify the chatbot metrics endpoint is being scraped by Azure Managed Prometheus

Run the following command to port-forward the AMA metrics pod to view the metrics.
```bash
AMA_METRICS_POD_NAME=$(kubectl get po -n kube-system -lrsName=ama-metrics -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward $AMA_METRICS_POD_NAME -n kube-system 9090
```

Open the Prometheus UI at http://localhost:9090 and click on the **Status** tab to view the targets. You should see the `serviceMonitor/bigbertha/bigbertha-llmchatbot-servicemonitor` target in **UP** state.

The metrics endpoint should be scraped every 15 seconds and you should see the metrics for `thumbs_down_count` and `thumbs_up_count` when using the Prometheus Explorer within the Azure Monitor Workspace in the Azure Portal.

You should also see an alert in the Alerts blade in the AKS portal. This alert will trigger an Azure Event Hub alert which will trigger Argo Events and the Argo Workflow for model retraining.

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
