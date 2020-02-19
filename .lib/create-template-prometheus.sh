#!/usr/bin/env bash
set -e
set -o pipefail

source .portable/activate
source .lib/.functions.sh

helmAddStableRepository

CHART_PROMETHEUS_VERSION=10.4.0
CHART_PROMETHEUS_FILE="prometheus-${CHART_PROMETHEUS_VERSION}.tgz"

openshiftTemplateJsonFile=".openshift/prometheus.json"

mkdir -p .charts
[ ! -f "${CHARTS_DIR}/${CHART_PROMETHEUS_FILE}" ] && helm pull stable/prometheus --version "${CHART_PROMETHEUS_VERSION}" --destination "${CHARTS_DIR}"

rm -rf .k8s/prometheus
helm template rocketchat-prometheus "${CHARTS_DIR}/${CHART_PROMETHEUS_FILE}" \
  --namespace "unknown" \
  --set server.persistentVolume.size=1Gi \
  --set 'server.enabled=true' \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set nodeExporter.enabled=false \
  --set 'serviceAccounts.server.create=true' \
  --set rbac.create=false \
  --set server.securityContext=null \
  --set server.persistentVolume.enabled=false \
  --output-dir '.k8s'

oc -n 'unknown' create -f '.k8s/prometheus/templates/' --dry-run=true -o json | jq -s -M '{"kind": "Template", "apiVersion":"v1", "metadata":{"name":"prometheus"}, "parameters":[], "objects":.}' > "${openshiftTemplateJsonFile}"
jq 'del(.objects[] | .metadata.namespace)' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

echo "Updating Prometheus configuration file"
jq -r '.objects[] | select(.kind == "ConfigMap" and .metadata.name == "rocketchat-prometheus-server") | .data["prometheus.yml"]' "${openshiftTemplateJsonFile}" > "${openshiftTemplateJsonFile}-config.yml"
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-apiservers)'
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-nodes*)'
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-endpoints)'
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-service*)'
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==prometheus-pushgateway)'
yq d -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-pods-slow)'
yq w -i "${openshiftTemplateJsonFile}-config.yml" 'scrape_configs.(job_name==kubernetes-pods).kubernetes_sd_configs.(role==pod).namespaces.names[+]' '${NAMESPACE}'
oc -n 'unknown' create configmap new-config-map --dry-run -o json --from-file=prometheus.yml="${openshiftTemplateJsonFile}-config.yml" > "${openshiftTemplateJsonFile}-config.json"
jq -s -M '.[0].objects += [.[1]] | .[0]' "${openshiftTemplateJsonFile}" "${openshiftTemplateJsonFile}-config.json"  | sponge "${openshiftTemplateJsonFile}"
jq -M '(.objects[] | select(.kind == "ConfigMap" and .metadata.name == "new-config-map").data) as $data | del(.objects[] | select(.kind == "ConfigMap" and .metadata.name == "new-config-map")) | (.objects[] | select(.kind == "ConfigMap" and .metadata.name == "rocketchat-prometheus-server")).data += $data' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"
jq '.parameters = [{"name": "NAMESPACE", "required": true}]' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"
rm "${openshiftTemplateJsonFile}-config.yml" "${openshiftTemplateJsonFile}-config.json"

echo "Update container requests/limits"
jq -M '(.objects[] | select(.kind == "Deployment")).spec.template.spec.containers[].resources = {"requests":{"cpu": "10m", "memory": "80Mi"}, "limits":{"cpu": "200m", "memory": "100Mi"}}' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"


echo "Creating Grafana DataSource for Prometheus"
jq -M '.objects += [{"kind":"ConfigMap", "apiVersion":"v1", "metadata":{"creationTimestamp":null,"labels":{"grafana_datasource":"1"},"name":"prometheus-grafana-datasource"}, "data":{"datasource.yaml":"apiVersion: 1\ndatasources:\n- name: Prometheus\n  type: prometheus\n  access: proxy\n  orgId: 1\n  url: http://rocketchat-prometheus-server:80  \n  isDefault: true\n  version: 1\n  editable: false"}}]' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

echo "Creating RoleBinding"
jq -M '.objects += [{"apiVersion": "rbac.authorization.k8s.io/v1beta1","kind": "RoleBinding","metadata": {"labels": { },"name": "rocketchat-prometheus-server"},"roleRef": {"apiGroup": "rbac.authorization.k8s.io","kind": "ClusterRole","name": "view"},"subjects": [{"kind": "ServiceAccount", "name":"rocketchat-prometheus-server", "namespace": "${NAMESPACE}"}]}]' "${openshiftTemplateJsonFile}" | sponge "${openshiftTemplateJsonFile}"

convertDeployment2DeploymentConfig "${openshiftTemplateJsonFile}"
importImages "${openshiftTemplateJsonFile}"
