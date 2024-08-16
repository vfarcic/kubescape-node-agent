rm $KUBECONFIG

if [[ "$HYPERSCALER" == "google" ]]; then

    gcloud container clusters delete dot --project $PROJECT_ID \
        --zone us-east1-b --quiet

    gcloud projects delete $PROJECT_ID --quiet

elif [[ "$HYPERSCALER" == "azure" ]]; then

    az group delete --name $RESOURCE_GROUP --yes

else

    eksctl delete addon --name aws-ebs-csi-driver --cluster dot \
        --region us-east-1

    eksctl delete cluster --config-file eksctl.yaml --wait

fi