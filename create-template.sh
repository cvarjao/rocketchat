#!/usr/bin/env bash
set -e
set -o pipefail

.lib/create-template-mongodb.sh
.lib/create-template-rocketchat.sh
.lib/create-template-prometheus.sh
.lib/create-template-grafana.sh