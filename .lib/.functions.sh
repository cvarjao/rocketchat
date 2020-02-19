#!/usr/bin/env bash


function helmAddStableRepository {
  stable_repo_url="$(helm repo list -o json | jq -r '.[] | select (.name == "stable") | .url')"
  if [ "${stable_repo_url}" != "https://kubernetes-charts.storage.googleapis.com" ]; then
    helm repo add stable 'https://kubernetes-charts.storage.googleapis.com'
  fi
}

# $1 json file path
function convertDeployment2DeploymentConfig {
  echo "Convert Deployment to DeploymentConfig"
  jq '(.objects[] | select(.kind == "Deployment")) += {"kind":"DeploymentConfig", "apiVersion":"v1"}' "$1" | sponge "$1"
  jq '(.objects[] | select(.kind == "DeploymentConfig") | .spec ) |= . + {"selector":.selector.matchLabels}' "$1" | sponge "$1"

  echo "Apply deployment orchestration resource requests/limits"
  jq -M '(.objects[] | select(.kind == "DeploymentConfig")).spec.strategy += {"resources":{"requests":{"cpu": "10m", "memory": "80Mi"}, "limits":{"cpu": "20m", "memory": "80Mi"}}}' "$1" | sponge "$1"
}

# $1 json file path
function importImages {
  while read originalImageRef; do
    echo "Importing image '${originalImageRef}'"
    if [[ "${originalImageRef}" != *':'* ||  "${originalImageRef}" == *:latest ]]; then
      echo "ERROR: Using ':latest' tag must be avoided!" && exit 1
    fi
    imageStreamName="${originalImageRef%:*}"
    imageStreamName="$(tr '/' '-' <<< "${imageStreamName}")"
    imageTagName="${originalImageRef#*:}"
    imageStreamTagName="${imageStreamName}:${imageTagName}"

  done < <(jq -r '.objects[] | select(.kind == "Deployment" or .kind == "DeploymentConfig") | .spec.template.spec | [.containers // [] | .[].image] + [.initContainers // [] | .[].image] | .[]' "$1" | sort |  uniq)
}

# $1 json file path
# $2 name
# $3 instance name
# $4 chart name
function applyRecommendedLabels {
  jq --arg name "$2" '.objects[].metadata.labels."app.kubernetes.io/name" = $name | del(.objects[].metadata.labels.app)' "$1" | sponge "$1"
  jq '.objects[].metadata.labels."app.kubernetes.io/managed-by" = "Helm" | del(.objects[].metadata.labels.heritage)' "$1" | sponge "$1"
  jq --arg instance "$3" '.objects[].metadata.labels."app.kubernetes.io/instance" = $instance | del(.objects[].metadata.labels.release)' "$1" | sponge "$1"
  jq --arg chart "$4" '.objects[].metadata.labels."helm.sh/chart" = $chart | del(.objects[].metadata.labels.chart)' "$1" | sponge "$1"
}

CHARTS_DIR=".charts"
