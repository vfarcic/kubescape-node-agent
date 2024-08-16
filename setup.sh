gum confirm '
Are you ready to start?
Select "No" if you prefer inspecting the script and executing the instructions manually.
' || exit 0

rm -f .env

export KUBECONFIG=$PWD/kubeconfig.yaml
echo "export KUBECONFIG=$KUBECONFIG" >> .env

rm -f $KUBECONFIG

echo "## Which Hyperscaler do you want to use?" | gum format
HYPERSCALER=$(gum choose "aws" "azure" "google")
echo "export HYPERSCALER=$HYPERSCALER" >> .env

if [[ "$HYPERSCALER" == "google" ]]; then

    export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud auth login

    gcloud projects create $PROJECT_ID

    echo
    echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID in a browser and enable the API." \
        | gum format
    gum input --placeholder "Press the enter key to continue."

    gcloud container clusters create dot --project $PROJECT_ID \
        --zone us-east1-b --machine-type e2-standard-2 \
        --num-nodes 2 --enable-network-policy \
        --no-enable-autoupgrade

elif [[ "$HYPERSCALER" == "azure" ]]; then

    az login --scope https://management.core.windows.net//.default

    RESOURCE_GROUP=dot-$(date +%Y%m%d%H%M%S)
    echo "export RESOURCE_GROUP=$RESOURCE_GROUP" >> .env

    export LOCATION=eastus
    echo "export LOCATION=$LOCATION" >> .env

    az group create --name $RESOURCE_GROUP --location $LOCATION

    az aks create --resource-group $RESOURCE_GROUP --name dot \
        --node-count 2 --node-vm-size Standard_B2ms \
        --enable-managed-identity --generate-ssh-keys --yes

    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name dot --file $KUBECONFIG

else

    AWS_ACCESS_KEY_ID=$(gum input \
        --placeholder "AWS Access Key ID" \
        --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input \
        --placeholder "AWS Secret Access Key" \
        --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" \
        --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    eksctl create cluster --config-file eksctl.yaml \
        --kubeconfig $KUBECONFIG

    eksctl create addon --name aws-ebs-csi-driver --cluster dot \
        --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole \
        --region us-east-1 --force

    kubectl patch storageclass gp2 \
        --patch '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

fi

helm upgrade --install traefik traefik \
    --repo https://helm.traefik.io/traefik \
    --namespace traefik --create-namespace --wait

if [[ "$HYPERSCALER" == "aws" ]]; then

    echo "## Waiting for Ingress hostname to propagate..." \
        | gum format

    INGRESS_IPNAME=$(kubectl --namespace traefik \
        get service traefik \
        --output jsonpath="{.status.loadBalancer.ingress[0].hostname}")

    INGRESS_HOST=$(dig +short $INGRESS_IPNAME) 

    while [ -z "$INGRESS_HOST" ]; do
        sleep 10
        INGRESS_IPNAME=$(kubectl --namespace traefik \
            get service traefik \
            --output jsonpath="{.status.loadBalancer.ingress[0].hostname}")
        INGRESS_HOST=$(dig +short $INGRESS_IPNAME) 
    done

    INGRESS_HOST=$(echo $INGRESS_HOST | awk '{print $1;}')

    INGRESS_HOST_LINES=$(echo $INGRESS_HOST | wc -l | tr -d ' ')

    if [ $INGRESS_HOST_LINES -gt 1 ]; then
        INGRESS_HOST=$(echo $INGRESS_HOST | head -n 1)
    fi

else

    export INGRESS_HOST=$(kubectl --namespace traefik \
        get service traefik \
        --output jsonpath="{.status.loadBalancer.ingress[0].ip}")

fi

echo "export INGRESS_HOST=$INGRESS_HOST" >> .env

yq --inplace ".spec.rules[0].host = \"silly-demo.$INGRESS_HOST.nip.io\"" \
    app/ingress.yaml

yq --inplace \
    ".alertmanager.ingress.hosts[0] = \"alertmanager.$INGRESS_HOST.nip.io\"" \
    prometheus-stack-values.yaml

helm upgrade --install prometheus kube-prometheus-stack \
    --repo https://prometheus-community.github.io/helm-charts \
    --values prometheus-stack-values.yaml \
    --namespace monitoring --create-namespace --wait

kubectl create namespace a-team

kubectl --namespace a-team apply --filename app/
