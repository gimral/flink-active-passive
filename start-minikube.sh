#!/usr/bin/env bash
set -euo pipefail

# Simple helper to start a local Minikube cluster with sensible defaults.
# Usage:
#   ./start-minikube.sh            # start with defaults
#   DRIVER=hyperkit MEMORY=8192 ./start-minikube.sh
#   ENABLE_INGRESS=true ./start-minikube.sh

DRIVER_DEFAULT="docker"
CPUS_DEFAULT=2
MEMORY_DEFAULT=8192
DISK_DEFAULT=20000
K8S_VERSION_DEFAULT="stable"

# Allow overriding via environment variables
DRIVER=${DRIVER:-$DRIVER_DEFAULT}
CPUS=${CPUS:-$CPUS_DEFAULT}
MEMORY=${MEMORY:-$MEMORY_DEFAULT}
DISK=${DISK:-$DISK_DEFAULT}
K8S_VERSION=${K8S_VERSION:-$K8S_VERSION_DEFAULT}
ENABLE_INGRESS=${ENABLE_INGRESS:-false}
ENABLE_METRICS=${ENABLE_METRICS:-false}

die() { echo "ERROR: $*" >&2; exit 1; }

command -v minikube >/dev/null 2>&1 || die "minikube not found in PATH. Install from https://minikube.sigs.k8s.io/docs/start/"
command -v kubectl >/dev/null 2>&1 || echo "warning: kubectl not found in PATH; some checks may fail"

echo "Starting minikube with driver=${DRIVER}, cpus=${CPUS}, memory=${MEMORY}MB, disk=${DISK}MB, k8s=${K8S_VERSION}"

# macOS-specific driver hint
if [[ "$(uname -s)" == "Darwin" ]] && [[ "$DRIVER" == "hyperkit" ]]; then
	if ! command -v docker >/dev/null 2>&1 && ! command -v hyperkit >/dev/null 2>&1; then
		echo "Note: hyperkit driver may require 'docker' or 'hyperkit' installed. Falling back to 'docker' driver if available."
		if command -v docker >/dev/null 2>&1; then
			DRIVER=docker
		fi
	fi
fi

# Start minikube (idempotent)
set +e
minikube status >/dev/null 2>&1
status_exit=$?
set -e

if [[ $status_exit -eq 0 ]]; then
	echo "minikube already running. Ensuring context is correct..."
	kubectl config use-context minikube >/dev/null 2>&1 || true
else
	echo "Starting a new minikube cluster..."
	minikube start --driver=${DRIVER} --cpus=${CPUS} --memory=${MEMORY} --disk-size=${DISK}mb --kubernetes-version=${K8S_VERSION}
fi

echo "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=120s || true

if [[ "${ENABLE_INGRESS}" == "true" ]]; then
	echo "Enabling ingress addon..."
	minikube addons enable ingress
fi

if [[ "${ENABLE_METRICS}" == "true" ]]; then
	echo "Enabling metrics-server addon..."
	minikube addons enable metrics-server
fi

echo "Minikube started. Status:"
minikube status

echo "Run 'kubectl get pods -A' to see cluster pods. To stop, run 'minikube stop'."

