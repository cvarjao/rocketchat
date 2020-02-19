#!/usr/bin/env bash
set -e
set -o pipefail

source .portable/activate
source .lib/.functions.sh

helmAddStableRepository

CHART_GRAFANA_VERSION=4.6.3
CHART_GRAFANA_FILE="grafana-${CHART_GRAFANA_VERSION}.tgz"

openshiftTemplateJsonFile=".openshift/grafana.json"

mkdir -p .charts
[ ! -f "${CHARTS_DIR}/${CHART_GRAFANA_FILE}" ] && helm pull stable/grafana --version "${CHART_GRAFANA_VERSION}" --destination "${CHARTS_DIR}"

rm -rf .k8s/grafana
helm template rocketchat-grafana "${CHARTS_DIR}/${CHART_GRAFANA_FILE}" \
  --namespace "unknown" \
  --set 'testFramework.enabled=false' \
  --set 'rbac.namespaced=true' \
  --set 'securityContext=null' \
  --set 'rbac.pspEnabled=false' \
  --set 'sidecar.datasources.enabled=true' \
  --set 'sidecar.dashboards.enabled=true' \
  --set 'adminPassword=admin' \
  --output-dir '.k8s'

oc -n 'unknown' create -f '.k8s/grafana/templates/' --dry-run=true -o json | jq -s -M '{"kind": "Template", "apiVersion":"v1", "metadata":{"name":"grafana"}, "parameters":[], "objects":.}' > "${openshiftTemplateJsonFile}"
jq 'del(.objects[] | .metadata.namespace)' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

jq '.parameters = [{"name": "NAMESPACE", "required": true}]' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"
jq '.parameters += [{"name": "ADMIN_PASSWORD", "required": true, "generate": "expression", "from": "[a-zA-Z]{1}[a-zA-Z0-9]{12}[a-zA-Z]{1}"}]' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

jq -M '(.objects[] | select(.kind == "RoleBinding") | .subjects [] | select(.kind == "ServiceAccount")).namespace = "${NAMESPACE}"' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"


echo "Set to Recreate deployment strategy"
jq -M '(.objects[] | select(.kind == "Deployment")).spec.strategy += {"type":"Recreate", "activeDeadlineSeconds": 21600, "recreateParams":{"timeoutSeconds":600}}' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"


echo "Update container requests/limits"
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].resources = {"requests":{"cpu": "10m", "memory": "80Mi"}, "limits":{"cpu": "200m", "memory": "80Mi"}}' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

echo "Create Route"
jq -M '.objects += [{"kind":"Route","apiVersion":"route.openshift.io/v1","metadata":{"name":"rocketchat-grafana","creationTimestamp":null,"labels":{}},"spec":{"host":"","to":{"kind":"Service","name":"rocketchat-grafana","weight":100},"port":{"targetPort":"service"},"tls":{"insecureEdgeTerminationPolicy": "Redirect", "termination": "edge"}},"status":{"ingress":null}}]'  "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"


jq -M 'del(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-grafana") | .data)' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

jq -M '(.objects[] | select(.kind == "Secret" and .metadata.name == "rocketchat-grafana")) += {"stringData":{"admin-password": "${ADMIN_PASSWORD}", "admin-user": "admin", "ldap-toml": ""}}' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"


applyRecommendedLabels "${openshiftTemplateJsonFile}" "rocketchat" "rocketchat-grafana" "grafana-${CHART_GRAFANA_VERSION}"
convertDeployment2DeploymentConfig "${openshiftTemplateJsonFile}"
importImages "${openshiftTemplateJsonFile}"
