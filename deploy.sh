#!/bin/bash
set -euo pipefail

helm repo add redis-stack https://redis-stack.github.io/helm-redis-stack/

helm upgrade --install redis-stack redis-stack/redis-stack

kubectl port-forward svc/redis-master 6379:6379

echo "Redis deployed. You can access it on localhost:6379"

helm upgrade --install my-flink ./helm/flink


helm delete my-flink

minikube ssh -- docker image rm -f gimral/redis-cli:1.0 || true

docker build -t gimral/redis-cli:1.0 redis

minikube image load gimral/redis-cli:1.0

helm upgrade --install my-flink ./helm/flink


