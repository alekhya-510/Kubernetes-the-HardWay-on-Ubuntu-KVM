# 06. Control plane

This stage installs the Kubernetes control plane on `server`: the API server, controller manager, and scheduler. It follows the tutorial's "Bootstrapping the Kubernetes Control Plane" page, with the changes listed below.

## Differences from the tutorial

- **Login user:** Files are copied to `ubuntu@server:~/` and moved into place with `sudo`. Root SSH is disabled on the cloud image.
- **etcd endpoint:** The API server connects to `https://127.0.0.1:2379` with the etcd client certificate flags. The tutorial's unit file uses `http://`, which doesn't work with the TLS-only etcd from stage 05.
- **Advertised address:** The API server uses `192.168.122.11`, and clients reach it as `server.kubernetes.local`.
- **`kubectl` on `server`:** The tutorial runs `kubectl` only on the jumpbox. In this lab, `admin.kubeconfig` is also copied to `~/.kube/config` on `server` for convenience.

## 1. Copy the control plane files

Run from `~/kubernetes-the-hard-way` on the jumpbox. Don't use `sudo` for this command, because it breaks name resolution and the SSH key lookup:

```bash
scp \
  downloads/controller/kube-apiserver \
  downloads/controller/kube-controller-manager \
  downloads/controller/kube-scheduler \
  downloads/client/kubectl \
  units/kube-apiserver.service \
  units/kube-controller-manager.service \
  units/kube-scheduler.service \
  configs/kube-scheduler.yaml \
  configs/kube-apiserver-to-kubelet.yaml \
  ubuntu@server:~/
```

## 2. Install binaries and configuration on `server`

On `server`, as root (`sudo -i`), from `/home/ubuntu`:

```bash
mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
chown root:root /usr/local/bin/kube-apiserver /usr/local/bin/kube-controller-manager /usr/local/bin/kube-scheduler /usr/local/bin/kubectl
mv kube-apiserver.service kube-controller-manager.service kube-scheduler.service /etc/systemd/system/
mkdir -p /etc/kubernetes/config
mv kube-scheduler.yaml /etc/kubernetes/config/
```

## 3. Correct the API server unit file

The tutorial's `kube-apiserver.service` needs two changes for this lab. Apply them on `server`:

```bash
sed -i 's|--etcd-servers=http://127.0.0.1:2379|--etcd-servers=https://127.0.0.1:2379 --etcd-cafile=/var/lib/kubernetes/ca.crt --etcd-certfile=/var/lib/kubernetes/kube-api-server.crt --etcd-keyfile=/var/lib/kubernetes/kube-api-server.key|' /etc/systemd/system/kube-apiserver.service
grep -n 'etcd' /etc/systemd/system/kube-apiserver.service
```

The `grep` should show the `https://` URL and all three `--etcd-*` flags on one line.

## 4. Start the control plane

```bash
systemctl daemon-reload
systemctl enable kube-apiserver kube-controller-manager kube-scheduler
systemctl start kube-apiserver kube-controller-manager kube-scheduler
systemctl is-active kube-apiserver kube-controller-manager kube-scheduler
```

Expected: `active` for all three.

## 5. Verify the API server

On `server`, the API server must resolve its own name. Add it to `/etc/hosts` if missing:

```bash
sudo tee -a /etc/hosts <<EOF
192.168.122.11 server server.kubernetes.local api-server.kubernetes.local
EOF
getent hosts server.kubernetes.local
```

Check TLS with the CA:

```bash
curl --cacert /var/lib/kubernetes/ca.crt https://server.kubernetes.local:6443/version
```

Expected: JSON with `"gitVersion": "v1.32.3"`.

Check the cluster from `server`, after copying `admin.kubeconfig` to `~/.kube/config`:

```bash
kubectl cluster-info
```

Expected: `Kubernetes control plane is running at https://server.kubernetes.local:6443`.

## 6. Apply the kubelet RBAC rules

The API server needs permission to call the kubelets on the workers:

```bash
kubectl apply -f ~/kube-apiserver-to-kubelet.yaml
kubectl get clusterrole system:kube-apiserver-to-kubelet
```
![](images/controlplane.jpg)

![](images/cluster-role.jpg)
## Issues encountered

**The API server exited with `Error creating leases: context deadline exceeded`.** The unit file pointed at `http://127.0.0.1:2379`, but etcd only accepts TLS. The log showed repeated `error reading server preface: EOF` messages. Fix: use `https://` and add the etcd CA and client certificate flags, as in step 3.

**`sudo` before `scp` broke name resolution.** Under `sudo`, the jumpbox couldn't resolve `server` and couldn't find the SSH key. Run `scp` as `ubuntu` without `sudo`.

**`systemctl enable` and `start` prompted for a password.** Only the first `systemctl` line had `sudo`. Put `sudo` on every root command, or run the block from a root shell.

**`kubectl` on `server` failed with `lookup server.kubernetes.local ... server misbehaving`.** The VM had no entry for its own FQDN. Add the `/etc/hosts` line from step 5.

**The jumpbox's `/etc/hosts` entries disappeared.** Cloud-init rewrote `/etc/hosts`. Cloud-init's hosts management was disabled with `/etc/cloud/cloud.cfg.d/99-no-hosts.cfg`, and the entries were re-added.

**`admin.kubeconfig` pointed at `127.0.0.1`.** The jumpbox's kubeconfig used the loopback address, so `kubectl` on the jumpbox couldn't reach the API server. Fix: `kubectl config set-cluster kubernetes-the-hard-way --server=https://server.kubernetes.local:6443 --kubeconfig=admin.kubeconfig`.

## Verified

- [x] `kube-apiserver`, `kube-controller-manager`, and `kube-scheduler` are `active`
- [x] API server serves TLS and reports `v1.32.3` at `https://server.kubernetes.local:6443/version`
- [x] `kubectl cluster-info` works from the jumpbox and from `server`
- [x] `system:kube-apiserver-to-kubelet` clusterrole exists
