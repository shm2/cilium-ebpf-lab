#!/usr/bin/env bash
set -euo pipefail

# Refuse to use an implicit Kubernetes context.
: "${KUBECONFIG:?Export KUBECONFIG for your intended kubeadm cluster first}"
NAMESPACE=cilium-ebpf-lab

# Positive control: allowed Pod should get an HTTP 200 response.
printf '%s\n' 'Testing allowed-client -> web:80...'
kubectl -n "$NAMESPACE" exec allowed-client -- \
  curl -fsS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 http://web/

# Negative control: policy should block the unauthorized client.
printf '%s\n' 'Testing blocked-client -> web:80 (failure expected)...'
if kubectl -n "$NAMESPACE" exec blocked-client -- \
    curl -fsS -o /dev/null --max-time 5 http://web/; then
  echo 'FAIL: blocked-client was able to reach web.'
  exit 1
else
  echo 'PASS: blocked-client could not reach web after the policy was applied.'
fi

# Record the in-cluster policy object without sensitive values.
kubectl -n "$NAMESPACE" get ciliumnetworkpolicy allow-selected-web-clients
