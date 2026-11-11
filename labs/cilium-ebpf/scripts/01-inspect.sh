#!/usr/bin/env bash
set -euo pipefail

# Refuse to proceed without an explicitly chosen kubeconfig.
: "${KUBECONFIG:?Export KUBECONFIG for your intended kubeadm cluster first}"

# Identify the cluster and check basic node health.
kubectl config current-context
kubectl get nodes -o wide

# Check Cilium agent and operator health and installation metadata.
kubectl -n kube-system get ds cilium
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get deployments -l io.cilium/app=operator || true
kubectl get crd ciliumnetworkpolicies.cilium.io

# Discover whether kube-proxy still exists; absence alone is not proof of replacement.
kubectl -n kube-system get daemonset kube-proxy --ignore-not-found

# Check reported kube-proxy replacement and eBPF state in one agent.
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose \
  | grep -Ei 'KubeProxyReplacement|Host Routing|BPF|NodePort' || true

# Inspect service objects and endpoint slices (read-only).
kubectl get svc -A -o wide
kubectl get endpointslices -A
