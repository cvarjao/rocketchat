#!/usr/bin/env bash
set -e
set -o pipefail
source .portable/activate


RC_URL="https://$(oc get route/rocketchat-prod-rocketchat -o 'jsonpath={.spec.host}')"

RC_USERNAME="$(oc get secret/rocketchat-prod-rocketchat-admin '--output=jsonpath={.data.admin-user}' | base64 --decode)"
RC_PASSWORD="$(oc get secret/rocketchat-prod-rocketchat-admin '--output=jsonpath={.data.admin-password}' | base64 --decode)"

RC_API_CRED="$(curl -fsSL "${RC_URL}/api/v1/login" -d "user=${RC_USERNAME}&password=${RC_PASSWORD}" | jq -Mc '.data | {"userId":.userId, "authToken":.authToken}')"
RC_API_USER_ID="$(jq -r '.userId' <<< "${RC_API_CRED}")"
RC_API_USER_TOKEN="$(jq -r '.authToken' <<< "${RC_API_CRED}")"

TIMESTAMP="$(date +%s)"

curl -sSL -H "X-Auth-Token: ${RC_API_USER_TOKEN}" \
     -H "X-User-Id: ${RC_API_USER_ID}" \
     -H "Content-type:application/json" \
     "${RC_URL}/api/v1/users.create" \
     -d '{"name": "test-'${TIMESTAMP}'", "email": "'${TIMESTAMP}'@example.com", "password": "'${TIMESTAMP}'", "username": "test-'${TIMESTAMP}'", "verified": true, "roles": ["bot"]}' \
     -o /dev/null


RC_USERNAME="test-${TIMESTAMP}"
RC_PASSWORD="${TIMESTAMP}"
RC_API_CRED="$(curl -fsSL "${RC_URL}/api/v1/login" -d "user=${RC_USERNAME}&password=${RC_PASSWORD}" | jq -Mc '.data | {"userId":.userId, "authToken":.authToken}')"
RC_API_USER_ID="$(jq -r '.userId' <<< "${RC_API_CRED}")"
RC_API_USER_TOKEN="$(jq -r '.authToken' <<< "${RC_API_CRED}")"

curl -sSL -H "X-Auth-Token: ${RC_API_USER_TOKEN}" \
     -H "X-User-Id: ${RC_API_USER_ID}" \
     -H "Content-type:application/json" \
     "${RC_URL}/api/v1/channels.create" \
     -d '{"name": "test"}' \
     -o /dev/null

curl -fsSL -H "X-Auth-Token: ${RC_API_USER_TOKEN}" \
     -H "X-User-Id: ${RC_API_USER_ID}" \
     -H "Content-type:application/json" \
     "${RC_URL}/api/v1/chat.postMessage" \
     -d '{ "channel": "#test", "text": "Getting ready to send lots more messages!!!" }' \
     -o /dev/null

oc run "benchmark-${TIMESTAMP}" --restart=Never --image=jordi/ab:latest --command -- sh -c 'printf '"'"'{"channel":"#test", "text":"Hello world! - pod: '"'"'$(uname -n)'"'"'"}'"'"' > /tmp/rocketchat-post-msg.json && ab -p /tmp/rocketchat-post-msg.json -n 1000 -c 80 -T "application/json" -H "X-User-Id: '${RC_API_USER_ID}'" -H "X-Auth-Token: '${RC_API_USER_TOKEN}'" '${RC_URL}'/api/v1/chat.postMessage'
