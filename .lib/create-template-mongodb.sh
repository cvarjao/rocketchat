#!/usr/bin/env bash
set -e
set -o pipefail

source .portable/activate
source .lib/.functions.sh

helmAddStableRepository


CHART_MONGODB_VERSION=7.8.2
CHART_MONGODB_FILE="mongodb-${CHART_MONGODB_VERSION}.tgz"


mkdir -p .charts
[ ! -f ".charts/${CHART_MONGODB_FILE}" ] && helm pull stable/mongodb --version "${CHART_MONGODB_VERSION}" --destination .charts

#Fetch recommended production values
curl -fsSL https://raw.githubusercontent.com/helm/charts/master/stable/mongodb/values-production.yaml -o "${CHARTS_DIR}/mongodb-values.yaml"

rm -rf .k8s/mongodb/*

helm template rocketchat-prod ".charts/${CHART_MONGODB_FILE}" \
  --namespace "unknown" \
  --values "${CHARTS_DIR}/mongodb-values.yaml" \
  --set 'image.tag=4.2.3-debian-10-r14' \
  --set 'replicaSet.replicas.secondary=0' \
  --set 'persistence.size=200Mi' \
  --set 'replicaSet.pdb.enabled=false,securityContext.enabled=false' \
  --set 'resources.requests.cpu=20m,resources.limits.cpu=50m' \
  --set 'resources.requests.memory=256Mi,resources.limits.memory=512Mi' \
  --set 'replicaSet.replicas.arbiter=0' \
  --set 'resourcesArbiter.requests.cpu=10m,resourcesArbiter.limits.cpu=20m' \
  --set 'resourcesArbiter.requests.memory=200Mi,resourcesArbiter.limits.memory=256Mi' \
  --set 'metrics.enabled=true' \
  --set 'metrics.resources.requests.cpu=20m,metrics.resources.limits.cpu=50m' \
  --set 'metrics.resources.requests.memory=10Mi,metrics.resources.limits.memory=80Mi' \
  --set 'mongodbDatabase=rocketchat,mongodbUsername=rocketchat,mongodbPassword=s3cr3t!2' \
  --set 'mongodbRootPassword=s3cr3t!1' \
  --set 'replicaSet.name=rs0' \
  --set 'mongodbDisableSystemLog=true' \
  --output-dir '.k8s'

# Fix a few oddities and make some changes for openshift

# I prefer to work with json files for processing/manipulation
# So, I will convert the generate yaml files into an openshift template file
oc -n 'unknown' create -f '.k8s/mongodb/templates/' --dry-run=true -o json | jq -s -M '{"kind": "Template", "apiVersion":"v1", "metadata":{"name":"mongodb"}, "parameters":[], "objects":.}' > '.openshift/mongodb.json'

echo "MongoDB: Backup CronJob"
oc -n 'unknown'  run rocketchat-prod-mongodb-backup --dry-run -o json --schedule='0 0 * * *' --image=mongodb:4.2.3 --restart=Never --labels "app.kubernetes.io/name=mongodb" --command -- bash -c 'mongodump  --oplog --gzip "--archive=/media/backup/rocketchat-$(date '"'"'+%Y-%m-%dT%H-%M-%S'"'"').gz"  --host="${MONGODB_REPLICA_SET_NAME}/rocketchat-prod-mongodb:27017" "--username=root" "--password=${MONGODB_ROOT_PASSWORD}" --authenticationDatabase admin && cat <(find /media/backup -maxdepth 1 -type f) <(find /media/backup -maxdepth 1 -type f | sort | tail -n10) | sort | uniq -c | awk '"'"'{if ($1 == 1) {print $2}}'"'"' | xargs -t -I {} rm {} && find /media/backup -maxdepth 1 -type f' > '.openshift/mongodb-cronjob.json'
jq -Ms '.[0].objects += [.[1]] | .[0]' '.openshift/mongodb.json' '.openshift/mongodb-cronjob.json' | sponge '.openshift/mongodb.json'
rm '.openshift/mongodb-cronjob.json'
jq -M '[.objects[] | select(.kind == "StatefulSet" and .metadata.name == "rocketchat-prod-mongodb-primary").spec.template.spec.containers[].env[] | select( .name == "MONGODB_REPLICA_SET_NAME" or .name == "MONGODB_ROOT_PASSWORD")] as $env | (.objects[] | select(.kind == "CronJob")).spec.jobTemplate.spec.template.spec.containers[].env += $env' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "CronJob")).spec.jobTemplate.spec.template.spec.containers[].resources = {"requests":{"cpu": "30m", "memory": "512Mi"}, "limits":{"cpu": "1", "memory": "1Gi"}}' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "MongoDB: Creating PVC for storing backups"
jq -M '.objects += [{"kind":"PersistentVolumeClaim","apiVersion":"v1","metadata":{"name":"rocketchat-prod-mongodb-backup","creationTimestamp":null,"labels":{"backup":"true"}},"spec":{"accessModes":["ReadWriteOnce"], "resources":{"requests":{"storage":"1Gi"}}}}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "CronJob")).spec.jobTemplate.spec.template.spec.containers[].volumeMounts = [{"name":"backup", "mountPath":"/media/backup"}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "CronJob")).spec.jobTemplate.spec.template.spec.volumes = [{"name":"backup", "persistentVolumeClaim":{"claimName": "rocketchat-prod-mongodb-backup"}}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "Deleting .metadata.namespace"
# Remove any reference to a namespace by deleting .metadata.namespace
jq 'del(.objects[] | .metadata.namespace)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Setting .metadata.labels."app.kubernetes.io/name"'
# MongoDB doesn't follow Kubernetes recommended labels, so let's fix that
jq '.objects[].metadata.labels."app.kubernetes.io/name" += "mongodb" | del(.objects[].metadata.labels.app)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq '.objects[].metadata.labels."app.kubernetes.io/managed-by" += "Helm" | del(.objects[].metadata.labels.heritage)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq '.objects[].metadata.labels."app.kubernetes.io/instance" += "rocketchat-prod" | del(.objects[].metadata.labels.release)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq '.objects[].metadata.labels."helm.sh/chart" += "mongodb" | del(.objects[].metadata.labels.chart)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Renaming .spec.selector.matchLabels.app to .selector.matchLabels."app.kubernetes.io/name"'
jq '(.objects[].spec | select(.selector.matchLabels.app !=null)).selector.matchLabels."app.kubernetes.io/name" = "mongodb"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec.selector.matchLabels.app)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Renaming .spec.selector.matchLabels.release to .selector.matchLabels."app.kubernetes.io/instance"'
jq '(.objects[].spec | select(.selector.matchLabels.release !=null)).selector.matchLabels."app.kubernetes.io/instance" = "rocketchat-prod"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec.selector.matchLabels.release)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Renaming .spec.selector.app .selector."app.kubernetes.io/name"'
jq '(.objects[].spec | select(.selector.app !=null)).selector."app.kubernetes.io/name" = "mongodb"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec.selector.app)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Renaming .spec.selector.release .selector."app.kubernetes.io/instance"'
jq '(.objects[].spec | select(.selector.release !=null)).selector."app.kubernetes.io/instance" = "rocketchat-prod"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec.selector.release)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

jq '(.objects[].spec | select(.template.metadata.labels.app !=null)).template.metadata.labels."app.kubernetes.io/name" = "mongodb"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec | select(.template.metadata.labels.app !=null) | .template.metadata.labels.app)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Renaming .spec.template.metadata.labels.release to .spec.template.metadata.labels."app.kubernetes.io/instance"'
jq '(.objects[].spec | select(.template.metadata.labels.release !=null)).template.metadata.labels."app.kubernetes.io/instance" = "rocketchat-prod"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq 'del(.objects[].spec | select(.template.metadata.labels.release !=null) | .template.metadata.labels.release)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo 'Fixing MONGODB_ADVERTISED_HOSTNAME to use downward API'
jq -M '(.objects[] | select(.kind == "StatefulSet") | .spec.template.spec.containers[].env[]? | select(.name == "MONGODB_ADVERTISED_HOSTNAME")).value = "$(MONGODB_POD_NAME).rocketchat-prod-mongodb-headless.$(MONGODB_POD_NAMESPACE).svc.cluster.local"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "StatefulSet") | .spec.template.spec.containers[].env) |= [{"name":"MONGODB_POD_NAMESPACE", "valueFrom": {"fieldRef": {"fieldPath": "metadata.namespace"}}}] + .' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "MongoDB: Importing image as ImageStream"
jq -M '((.objects[] | select(.kind == "StatefulSet")).spec.template.spec.containers[] | select(.image == "docker.io/bitnami/mongodb:4.2.3-debian-10-r14")).image = "docker-registry.default.svc:5000/${NAMESPACE}/mongodb:4.2.3"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '.objects += [{ "kind": "ImageStream", "apiVersion": "image.openshift.io/v1", "metadata": { "name": "mongodb", "creationTimestamp": null }, "spec": { "lookupPolicy": { "local": true },"tags": []},"status": {"dockerImageRepository": ""}}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "ImageStream" and .metadata.name == "mongodb")).spec.tags += [{"name": "4.2.3", "annotations": null, "from": { "kind": "DockerImage", "name": "docker.io/bitnami/mongodb:4.2.3-debian-10-r14" }, "generation": null, "importPolicy": {}, "referencePolicy": { "type": "Local" }}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

jq -M '((.objects[] | select(.kind == "StatefulSet")).spec.template.spec.containers[] | select(.image == "docker.io/bitnami/mongodb-exporter:0.10.0-debian-10-r9")).image = "docker-registry.default.svc:5000/${NAMESPACE}/mongodb-exporter:0.10.0"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '.objects += [{ "kind": "ImageStream", "apiVersion": "image.openshift.io/v1", "metadata": { "name": "mongodb-exporter", "creationTimestamp": null }, "spec": { "lookupPolicy": { "local": true },"tags": []},"status": {"dockerImageRepository": ""}}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "ImageStream" and .metadata.name == "mongodb-exporter")).spec.tags += [{"name": "0.10.0", "annotations": null, "from": { "kind": "DockerImage", "name": "docker.io/bitnami/mongodb-exporter:0.10.0-debian-10-r9" }, "generation": null, "importPolicy": {}, "referencePolicy": { "type": "Local" }}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

jq -M '(.objects[] | select(.kind == "StatefulSet")).spec.template.metadata.annotations["alpha.image.policy.openshift.io/resolve-names"] = "*"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "MongoDB: Setting MONGODB_URI for metrics"
jq -M '((.objects[] | select(.kind == "StatefulSet")).spec.template.spec.containers[] | select(.name == "metrics")).env += [{"name":"MONGODB_URI", "value":"mongodb://root:$(MONGODB_ROOT_PASSWORD)@localhost:27017/admin"}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "Generated passwords/keys"
jq -M 'del(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-prod-mongodb") | .data)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-prod-mongodb")).stringData["mongodb-replica-set-key"] = "${MONGODB_REPLICA_KEY}"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-prod-mongodb")).stringData["mongodb-root-password"] = "${MONGODB_ROOT_PASSWORD}"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M '(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-prod-mongodb")).stringData["mongodb-password"] = "${MONGODB_PASSWORD}"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

#echo "MongoDB: Setting ImageChange trigger"
#jq -M '(.objects[] | select(.kind == "StatefulSet")).spec.template.metadata.annotations["image.openshift.io/triggers"] = "[{\"from\":{\"kind\":\"ImageStreamTag\",\"name\":\"mongodb:4.2.3\"},\"fieldPath\":\"spec.template.spec.containers[?(@.name==\\\"mongodb-primary\\\")].image\"}]"' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'



jq -M '(.objects[] | select(.kind == "StatefulSet") | .spec.template.spec.containers[] | select(.name == "metrics")).command = ["sh", "-c", "curl -fsSL http://localhost:27017 -o /dev/null && exec /bin/mongodb_exporter --mongodb.uri mongodb://root:${MONGODB_ROOT_PASSWORD}@localhost:27017/admin"]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

echo "MongoDB: Setting Template parameters"
jq -M 'walk( if type == "string" then . |= sub( "rocketchat-prod"; "${INSTANCE}")  else . end )' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq '.parameters = [{"name": "INSTANCE", "required": true},{"name": "NAMESPACE", "required": true},{"name": "MONGODB_REPLICA_KEY", "required": true, "generate": "expression", "from": "[a-zA-Z]{1}[a-zA-Z0-9]{8}[a-zA-Z]{1}"},{"name": "MONGODB_ROOT_PASSWORD", "required": true, "generate": "expression", "from": "[a-zA-Z]{1}[a-zA-Z0-9]{12}[a-zA-Z]{1}"},{"name": "MONGODB_PASSWORD", "required": true, "generate": "expression", "from": "[a-zA-Z]{1}[a-zA-Z0-9]{12}[a-zA-Z]{1}"}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'


echo "MongoDB: Replacing PVC with ephemeral storage (Only because I don't have enough storage quota! NOT for production!!!)"
jq -M '(.objects[] | select(.kind == "StatefulSet" and .spec.volumeClaimTemplates != null)).spec.template.spec.volumes = [{"name":"datadir", "emptyDir":{}}]' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'
jq -M 'del(.objects[] | select(.kind == "StatefulSet" and .spec.volumeClaimTemplates != null) | .spec.volumeClaimTemplates)' '.openshift/mongodb.json' | sponge '.openshift/mongodb.json'

