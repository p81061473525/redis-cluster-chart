# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Bitnami Helm chart for deploying Redis Cluster on Kubernetes. It deploys Redis in cluster mode with sharding (multiple masters and replicas), as opposed to the standard Redis chart which uses master-slave with Sentinel.

## Common Commands

```bash
# Install the chart
helm install my-release .

# Install with custom values
helm install my-release . -f values.yaml

# Install with specific password
helm install my-release . --set password=secretpassword

# Upgrade with extended timeout (cluster init can take time)
helm upgrade --timeout 600s my-release .

# Uninstall
helm delete my-release

# Lint the chart
helm lint .

# Template rendering (dry-run)
helm template my-release .

# Template with debug
helm template my-release . --debug
```

## Architecture

### Chart Structure
- `Chart.yaml` - Chart metadata (version 9.0.13, appVersion 7.2.2)
- `values.yaml` - Default configuration values
- `templates/` - Kubernetes manifest templates
- `charts/common/` - Bitnami common library dependency (helper templates)

### Key Templates
- `redis-statefulset.yaml` - Main StatefulSet for Redis nodes
- `redis-cluster-init.yaml` - ConfigMap for cluster initialization scripts
- `init-cluster-job.yaml` - Job to initialize the cluster (runs on first install)
- `update-cluster.yaml` - Job to add nodes during upgrades (post-upgrade hook)
- `scripts-configmap.yaml` - Shell scripts for Redis operations
- `configmap.yaml` - Redis configuration (redis.conf)
- `_helpers.tpl` - Template helper functions

### Template Helpers (`_helpers.tpl`)
Key helper functions:
- `redis-cluster.image` - Returns the Redis image name
- `redis-cluster.password` - Returns the Redis password (from global, values, or auto-generated)
- `redis-cluster.secretName` - Returns the secret name for password storage
- `redis-cluster.tlsSecretName` - Returns the TLS secret name
- `redis-cluster.createStatefulSet` - Determines if StatefulSet should be created

### Cluster Topology
- Default: 6 nodes (3 masters + 3 replicas)
- Formula: `nodes = numOfMasterNodes + numOfMasterNodes * replicas`
- Configured via `cluster.nodes` (minimum 3 masters required) and `cluster.replicas`

## Key Configuration Values

- `cluster.nodes` - Total number of Redis nodes (default: 6)
- `cluster.replicas` - Replicas per master (default: 1)
- `cluster.init` - Enable cluster initialization on first install (default: true)
- `password` / `existingSecret` - Redis authentication
- `tls.enabled` - Enable TLS for traffic encryption
- `persistence.enabled` - Enable persistent storage (default: true)
- `metrics.enabled` - Enable Prometheus metrics sidecar

## Scaling Operations

### Adding nodes
```bash
helm upgrade --timeout 600s <release> . \
  --set "password=${REDIS_PASSWORD},cluster.nodes=7,cluster.update.addNodes=true,cluster.update.currentNumberOfNodes=6"
```

### Scaling down
```bash
helm upgrade --timeout 600s <release> . \
  --set "password=${REDIS_PASSWORD},cluster.nodes=6,cluster.init=false"
```
After scaling down, use `CLUSTER FORGET` on each node to remove references to deleted nodes.
