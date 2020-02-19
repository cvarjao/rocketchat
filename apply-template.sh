#!/usr/bin/env bash
set -e
set -o pipefail
source .portable/activate
CHARTS_DIR=".charts"
CHART_MONGODB_VERSION=7.8.2
CHART_MONGODB_FILE="mongodb-${CHART_MONGODB_VERSION}.tgz"
CHART_ROCKETCHAT_VERSION=2.0.0
CHART_ROCKETCHAT_FILE="rocketchat-${CHART_ROCKETCHAT_VERSION}.tgz"


oc delete all,svc,secret,pvc,sa,cronjob,job,role,rolebinding -l 'app.kubernetes.io/part-of=rocketchat-prod'
oc delete pods --field-selector 'status.phase!=Running'


#oc delete all,svc,secret,pvc,sa -l 'app.kubernetes.io/name=mongodb'
oc process -f .openshift/mongodb.json -p NAMESPACE=req67295 -p INSTANCE=rocketchat-prod -l 'app=rocketchat-prod,app.kubernetes.io/part-of=rocketchat-prod' | oc apply -f -

#TODO: Needs some workaround for StatefulSet to pull image from ImageStream. Pulling doesn't work for the very first pod created.

#oc delete all,svc,secret,pvc,sa -l 'app.kubernetes.io/name=rocketchat'
oc process -f .openshift/rocketchat.json -p INSTANCE=rocketchat-prod -l 'app=rocketchat-prod,app.kubernetes.io/part-of=rocketchat-prod' | oc apply -f -

# oc delete all,svc,secret,pvc,sa -l 'app.kubernetes.io/name=prometheus'
oc process -f .openshift/prometheus.json -p NAMESPACE=req67295 -l 'app=rocketchat-prod,app.kubernetes.io/part-of=rocketchat-prod,app.kubernetes.io/name=prometheus' |  oc apply -f -

# oc delete all,svc,secret,pvc,sa -l 'app.kubernetes.io/name=grafana'
oc process -f .openshift/grafana.json -p NAMESPACE=req67295 -l 'app=rocketchat-prod,app.kubernetes.io/part-of=rocketchat-prod,app.kubernetes.io/name=grafana' |  oc apply -f -
