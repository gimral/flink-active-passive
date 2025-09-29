minikube ssh -- docker image rm -f gimral/redis-cli:1.0 || true

minikube image load gimral/redis-cli:1.0

minikube image load gimral/flink:2.0.0