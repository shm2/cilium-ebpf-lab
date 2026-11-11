# Cilium eBPF networking and kube-proxy-free Kubernetes — hands-on lab

**Environment:** three VMware Ubuntu 24.04 kubeadm VMs (`k8scp2`, `k8s-w1`, `k8s-w2`)  
**Kubernetes:** v1.36.5 (recorded during later exercises)  
**Cilium:** v1.20.2 (historical hands-on test)  
**CNI:** Cilium; eBPF service datapath; kube-proxy replacement is a configuration to **verify** on the target cluster.  
**Network:** `192.168.217.128` (control plane), `.129` and `.130` (workers).  
**Repository purpose:** reproducible operations, targeted L3/L4 policy test, evidence and safe cleanup.

> **Evidence boundary:** The previous Cilium connectivity run reported **82 successful / 53 skipped** tests (135 total), with Hubble Relay unavailable and flow-validation tests skipped. The run used NodePorts **32127** and **30579**. These are historical observations, **not assertions that a fresh test passed today**. Historical full logs are not bundled here. Re-run the commands below to produce current evidence. No live cluster or GitHub repository is modified merely by downloading this package.

## Architecture

```text
VMware NAT network 192.168.217.0/24
  k8scp2 192.168.217.128   kube-apiserver + control plane
  k8s-w1 192.168.217.129   worker + Cilium agent
  k8s-w2 192.168.217.130   worker + Cilium agent
                 |
         Cilium eBPF datapath
  Pod <-> Pod / Service ClusterIP / NodePort
  L3/L4 policy via CiliumNetworkPolicy CRD
```

## Learning outcomes

1. Validate Cilium operator/agent health and cluster CNI readiness.
2. Inspect whether kube-proxy replacement is **actually enabled**, rather than infer it from the Cilium installation.
3. Inspect the eBPF service load-balancing map (read-only).
4. Check the Kubernetes Service and EndpointSlice data plane; optionally inspect existing NodePorts.
5. Demonstrate namespace-scoped Cilium **L3/L4 ingress filtering** with a client allowed on TCP/80 and a client denied by policy.
6. Run the upstream Cilium connectivity suite and preserve console evidence.
7. Clean up **only the lab namespace**, leaving Cilium, existing workloads and cluster networking intact.

## Prerequisites

- `kubectl` access to the **VMware kubeadm** cluster; do not accidentally use `kind-kind`.
- Installed and healthy Cilium agent/Operator; Cilium CRD `ciliumnetworkpolicies.cilium.io` present.
- `cilium` CLI is optional but required for the full upstream connectivity suite.
- An isolated namespace for policy testing; no Clusterwide Cilium policy may inadvertently block it.
- Container images accessible by your nodes: `nginx:1.27-alpine` and `curlimages/curl:8.11.1` (or pin equivalents).

```bash
# Explicitly select the kubeadm context and verify the target cluster.
export KUBECONFIG="$HOME/.kube/k8scp2-admin.conf"
kubectl config current-context
kubectl get nodes -o wide
```

## 1 — Read-only baseline

```bash
# Inspect the agents, Helm release and current CRDs.
bash scripts/01-inspect.sh

# If the CLI is installed, inspect overall Cilium state.
cilium status
```

Expected: three nodes Ready, healthy Cilium agent pods and Cilium CRDs. The script reports real live settings; **the presence of eBPF does not by itself prove kube-proxy replacement is enabled**.

To verify kube-proxy-free operation, check BOTH the Cilium agent's `KubeProxyReplacement` status and whether a `kube-proxy` DaemonSet exists. A kube-proxy DaemonSet being absent alone does not prove that replacement is functioning.

## 2 — Inspect the eBPF service datapath

```bash
# Inspect eBPF load-balancing service entries from a running Cilium agent.
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg service list

# Inspect eBPF LB map (read only; output may be extensive).
kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg bpf lb list

# Inspect existing NodePort Services and EndpointSlices.
kubectl get services -A -o wide | grep -E 'NAMESPACE|NodePort'
kubectl get endpointslices -A
```

**Historical NodePort checks:** `32127` and `30579` were used in the previous exercise. Before retesting, identify the current Service/NodePort mappings with `kubectl get svc -A`; do not assume those Services still exist. To test a confirmed HTTP NodePort from `k8scp2`:

```bash
# Replace NODEPORT with the currently assigned port; these IPs were lab node IPs.
for NODE_IP in 192.168.217.128 192.168.217.129 192.168.217.130; do
  curl --connect-timeout 3 --max-time 6 -sv "http://${NODE_IP}:${NODEPORT}/" -o /dev/null
done
```

Successful NodePort traffic depends on Service configuration, Cilium mode, policy, firewall rules and the availability of healthy endpoints.

## 3 — Isolated CiliumNetworkPolicy exercise

Apply the isolated example namespace + HTTP service + two client Pods:

```bash
# Deploy only objects within the dedicated lab namespace.
kubectl apply -f manifests/00-workloads.yaml

# Wait for the server and test clients to become Ready.
kubectl -n cilium-ebpf-lab rollout status deployment/web --timeout=180s
kubectl -n cilium-ebpf-lab wait --for=condition=Ready pod/allowed-client pod/blocked-client --timeout=180s

# BEFORE the policy: both clients should reach the web Service.
kubectl -n cilium-ebpf-lab exec allowed-client -- curl -fsS --max-time 5 http://web/
kubectl -n cilium-ebpf-lab exec blocked-client -- curl -fsS --max-time 5 http://web/
```

Now enforce ingress to the `web` Pod, allowing only the `role=allowed` source identity on TCP/80:

```bash
# Install an isolated namespace-scoped Cilium policy.
kubectl apply -f manifests/10-policy.yaml

# Wait for policy endpoints to reflect the new policy before testing.
kubectl -n cilium-ebpf-lab get ciliumnetworkpolicy
kubectl -n cilium-ebpf-lab get pods --show-labels

# ALLOW: should return the nginx welcome page.
kubectl -n cilium-ebpf-lab exec allowed-client -- curl -fsS --max-time 5 http://web/

# DENY: a timeout/failure is expected and counted as PASS by the helper.
bash scripts/02-policy-proof.sh
```

If the blocked request succeeds unexpectedly, check Cilium policy realization and effective identity labels; do not claim success. Note that this example restricts **ingress to the `web` Pods**, not all traffic in the namespace.

## 4 — Run official Cilium connectivity suite (optional, heavier)

```bash
# Check the installed CLI and cluster before running the larger suite.
cilium version
cilium status

# Cilium creates temporary connectivity-test objects in isolated namespaces.
# This is intentionally manual because the suite can consume scarce VM memory.
cilium connectivity test 2>&1 | tee evidence/connectivity-current.log
```

Cilium's official test exercises Pod-to-Pod, Pod-to-Service, policy and several datapath paths. The number of tests and skips depends on configuration and CLI/version; **do not copy the historical totals into a newly generated run**. Hubble Relay being disabled may cause flow-validation skips.

## 5 — Cleanup

```bash
# Delete ONLY this lab's policy-test namespace and its contained resources.
kubectl delete -f manifests/10-policy.yaml --ignore-not-found
kubectl delete -f manifests/00-workloads.yaml --ignore-not-found

# Confirm other namespaces and Cilium agents remain intact.
kubectl get namespaces
kubectl -n kube-system get ds cilium
```

This cleanup **does not uninstall Cilium, delete its CRDs, change kube-proxy, or remove Argo CD resources**. If you separately ran `cilium connectivity test`, consult `cilium connectivity test --help` for its cleanup option and inspect the test namespaces before removal.

## Evidence checklist for portfolio publication

| Evidence | Status in this repository |
| --- | --- |
| Three-node VMware kubeadm topology | Previously recorded; verify with `kubectl get nodes` |
| Cilium 1.20.2 installation | Previously recorded; live version check supplied |
| Historical Cilium test: 82 passed, 53 skipped | Previously recorded; fresh output **not included** |
| Hubble Relay absent/disabled during test | Previously recorded |
| NodePorts 32127 and 30579 | Previously recorded; current Service availability unverified |
| Live kube-proxy replacement state | **Must inspect** before claiming enabled in current cluster |
| Isolated policy allow/deny example | Runnable lab; **not claimed as executed** |
| New screenshots/logs | Add only after running verification |

## GitOps and security notes

This lab is deliberately **not** an Argo CD Application because it creates intentionally denied network traffic and disposable test Pods. Keep Cilium installation and its Helm values under their existing ownership; don't let an Argo CD Application prune the production Cilium DaemonSet. You can later add a separately reviewed GitOps Application for policy-only manifests.

Do not publish kubeconfigs, bearer tokens, SSH keys, full Cilium identity secrets, or logs containing private values. Pod IPs and NodePorts in this README are from an isolated private VMware lab.

## Official references

- [Cilium: installation using kubeadm](https://docs.cilium.io/en/stable/installation/k8s-install-kubeadm/)
- [Cilium: Kubernetes without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [Cilium: connectivity testing](https://docs.cilium.io/en/stable/installation/cli-connectivity-test/)
- [Cilium: network policy](https://docs.cilium.io/en/stable/network/kubernetes/policy/)
- [Cilium: troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)
