#!/usr/bin/env bash
set -e
set -o pipefail

source .portable/activate
source .lib/.functions.sh

helmAddStableRepository

CHART_ROCKETCHAT_VERSION=2.0.0
CHART_ROCKETCHAT_FILE="rocketchat-${CHART_ROCKETCHAT_VERSION}.tgz"

mkdir -p .charts
[ ! -f ".charts/${CHART_ROCKETCHAT_FILE}" ] && helm pull stable/rocketchat --version "${CHART_ROCKETCHAT_VERSION}" --destination .charts

rm -rf .k8s/rocketchat/*


helm template rocketchat-prod ".charts/${CHART_ROCKETCHAT_FILE}" \
  --namespace "unknown" \
  --set 'mongodb.enabled=false' \
  --set 'externalMongodbUrl=mongodb://rocketchat:$(MONGO_PASSWORD)@rocketchat-prod-mongodb:27017/rocketchat' \
  --set 'externalMongodbOplogUrl=mongodb://root:$(MONGO_ROOT_PASSWORD)@rocketchat-prod-mongodb:27017/local?replicaSet=rs0&authSource=admin' \
  --set 'resources.requests.cpu=50m,resources.limits.cpu=500m' \
  --set 'resources.requests.memory=256Mi,resources.limits.memory=700Mi' \
  --set 'securityContext.enabled=false' \
  --set 'serviceAccount.create=false' \
  --set 'ingress.enabled=false' \
  --output-dir '.k8s'

# Fix a few oddities and make some changes for openshift

# I prefer to work with json files for processing/manipulation
# So, I will convert the generate yaml files into an openshift template file
oc -n 'unknown' create -f '.k8s/rocketchat/templates/' --dry-run=true -o json | jq -s -M '{"kind": "Template", "apiVersion":"v1", "metadata":{"name":"rocketchat"}, "parameters":[], "objects":.}' > '.openshift/rocketchat.json'

echo "Deleting .metadata.namespace"
# Remove any reference to a namespace by deleting .metadata.namespace
jq 'del(.objects[] | .metadata.namespace)' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "RocketChat: Adding 'MONGO_PASSWORD' environment variable"
jq -M '(.objects[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env) |= [{"name":"MONGO_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "rocketchat-prod-mongodb", "key":"mongodb-password"}}}] + .' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env) |= [{"name":"MONGO_ROOT_PASSWORD", "valueFrom": {"secretKeyRef": {"name": "rocketchat-prod-mongodb", "key":"mongodb-root-password"}}}] + .' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "RocketChat: Update 'MONGO_URL' and 'MONGO_OPLOG_URL' environment variable to use Downward API"
jq -M 'del(.objects[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env[] | select(.name == "MONGO_URL" or .name == "MONGO_OPLOG_URL"))' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env) += [{"name":"MONGO_URL", "value": "mongodb://rocketchat:$(MONGO_PASSWORD)@rocketchat-prod-mongodb:27017/rocketchat"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment") | .spec.template.spec.containers[].env) += [{"name":"MONGO_OPLOG_URL", "value": "mongodb://root:$(MONGO_ROOT_PASSWORD)@rocketchat-prod-mongodb:27017/local?replicaSet=rs0&authSource=admin"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M 'del(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-prod-rocketchat"))' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'


echo "Create Route (Ingress was turned off from chart)"
jq -M '.objects += [{"kind":"Route","apiVersion":"route.openshift.io/v1","metadata":{"name":"rocketchat-prod-rocketchat","creationTimestamp":null,"labels":{}},"spec":{"host":"","to":{"kind":"Service","name":"rocketchat-prod-rocketchat","weight":100},"port":{"targetPort":"http"},"tls":{"insecureEdgeTerminationPolicy": "Redirect", "termination": "edge"}},"status":{"ingress":null}}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "Apply/normalize Kubernetes recommended labels"
jq '.objects[].metadata.labels."app.kubernetes.io/name" = "rocketchat"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq '.objects[].metadata.labels."app.kubernetes.io/managed-by" = "Helm"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq '.objects[].metadata.labels."app.kubernetes.io/instance" = "rocketchat-prod"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq '.objects[].metadata.labels."helm.sh/chart" = "rocketchat-2.0.0"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "RocketChat: Importing image as ImageStream"
jq -M '(.objects[] | select(.kind == "Deployment" and .metadata.name == "rocketchat-prod-rocketchat")).spec.template.spec.containers[].image = "rocketchat:2.1.1"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment" and .metadata.name == "rocketchat-prod-rocketchat")).spec.template.metadata.annotations["alpha.image.policy.openshift.io/resolve-names"] = "*"' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '.objects += [{ "kind": "ImageStream", "apiVersion": "image.openshift.io/v1", "metadata": { "name": "rocketchat", "creationTimestamp": null }, "spec": { "lookupPolicy": { "local": true },"tags": []},"status": {"dockerImageRepository": ""}}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "ImageStream" and .metadata.name == "rocketchat")).spec.tags += [{"name": "2.1.1", "annotations": null, "from": { "kind": "DockerImage", "name": "docker.io/rocketchat/rocket.chat:2.1.1" }, "generation": null, "importPolicy": {}, "referencePolicy": { "type": "Local" }}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "Disable access to openshift service account"
#jq -M '(.objects[] | select(.kind == "Deployment" and .metadata.name == "rocketchat-prod-rocketchat")).spec.template.spec.enableServiceLinks = false' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment" and .metadata.name == "rocketchat-prod-rocketchat")).spec.template.spec.automountServiceAccountToken = false' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "Set to Recreate deployment strategy"
jq -M '(.objects[] | select(.kind == "Deployment")).spec.strategy += {"type":"Recreate", "activeDeadlineSeconds": 21600, "recreateParams":{"timeoutSeconds":600}}' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

jq -M '.objects += [{"kind":"Secret","apiVersion":"v1","metadata":{"name":"rocketchat-prod-rocketchat-admin","creationTimestamp":null},"stringData":{"admin-user":"${ADMIN_USERNAME}","admin-password":"${ADMIN_PASSWORD}"},"type":"Opaque"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

echo "Set RocketChat settings"
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].env += [{"name": "OVERWRITE_SETTING_Show_Setup_Wizard", "value": "completed"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].env += [{"name": "ADMIN_USERNAME", "valueFrom": {"secretKeyRef": {"name": "rocketchat-prod-rocketchat-admin", "key":"admin-user"}}}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].env += [{"name": "ADMIN_PASS", "valueFrom": {"secretKeyRef": {"name": "rocketchat-prod-rocketchat-admin", "key":"admin-password"}}}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].env += [{"name": "ADMIN_EMAIL", "value": "admin@example.com"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
# For testing, we need to disable the API rate limiter
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].env += [{"name": "OVERWRITE_SETTING_API_Enable_Rate_Limiter", "value": "false"}, {"name": "API_Enable_Rate_Limiter", "value": "false"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'



echo "RocketChat: Setting Template parameters"
jq -M 'walk( if type == "string" then . |= sub( "rocketchat-prod"; "${INSTANCE}")  else . end )' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '.parameters = [{"name": "INSTANCE", "required": true}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '.parameters += [{"name": "ADMIN_USERNAME", "required": true, "value": "admin"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'
jq -M '.parameters += [{"name": "ADMIN_PASSWORD", "required": true, "value": "admin"}]' '.openshift/rocketchat.json' | sponge '.openshift/rocketchat.json'

convertDeployment2DeploymentConfig '.openshift/rocketchat.json'