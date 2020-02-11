# Solution
Rocket.Chat with Mongodb

# Rationale
  1. Research what is available from the internet. Found
    - https://hub.helm.sh/charts/stable/rocketchat
    - https://hub.helm.sh/charts/stable/mongodb

  2. Evaluation:
    - Number of recent releases/vesions indicates that the charts are well maintained and kept up-to-date
    - Quick look into the features and how they are put together, it looks like they have a secure and mature solution
    - I've had previous experience with using BitNami solutions/stacks and they are prettty solid (MongoDB chart is supported by BitNami)

    Based on that, I've decided to use existing help charts for both MongoDB and RocketChat

# Strategy
  - Leverage as much as possible of community supported helm chart
  - Script the process of transforming from Helm chart, to Openshift template to support fugure updates/upgrades of the helm chart

# Helm Charts in OpenShift
Helm charts are designed to work with any vanilla kubenetes cluster.
However, vanilla kubernetes doesn't take full benefit from Openshift (e.g.: ImageStreams, Triggers, etc)

# OpenShift: My Lessons Learned
  - Import images using `local` reference policy: This ensures that images are cached in the cluster image registry and avoid downloading image directly from the source. In addition, if the source image registry is temporary unavailable it won't impact deployments
  - Use Immutable Image Tags: This ensures that deployments are not affected if a new revision inadvertently breaks existing functionality
  - Check for Immutable Image Tag against a Rolling/LTS image tag: This is how we identify when updates are available
  - Apply [Kubernetes Recommended Labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/)

# Operations
  Please see [OPERATIONS.md](.OPERATIONS.md) for operations manual
# TODO
  - Add `Jenkinsfile` or some CI/CD that calls the script (e.g.: GitHub Actions)
  - Bash/Shell scripts gets big rather quick. Investigate some other framework/language for orchestrating CI/CD tasks.
  - [Security] Investigate enabling MongoDB over TLS to support end-to-end encryption (Zero Trust)
  - Add HorizontalPodAutoScaler to support dynamic scaling
  - Add monitoring/alerts (e.g.: Using Prometheus + Grapana)
  - Write script for update/upgrade
  - Write script for restoring database
  - [BUG] Since secrets are automatically generated, applying the template will always reset passwords which will cause problems when updating/upgrading

# References
- https://hub.helm.sh/charts/bitnami/mongodb
- https://github.com/helm/charts/tree/master/stable/mongodb
- https://hub.helm.sh/charts/stable/rocketchat
- https://github.com/helm/charts/tree/master/stable/rocketchat
- https://docs.bitnami.com/containers/how-to/understand-rolling-tags-containers/