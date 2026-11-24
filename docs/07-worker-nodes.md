# 07. Worker nodes

This stage installs runc, the CNI plugins, containerd, kubelet, and kube-proxy on `node-0` and `node-1`, registers both workers with the control plane, and verifies cross-node pod networking. It follows the tutorial's "Bootstrapping the Kubernetes Worker Nodes" page, with the changes listed below.

## Differences from the tutorial

- **Login user:** Commands run as `ubuntu` from the jumpbox. Root-only steps use `sudo` on each command, because `sudo` before a loop or a shell redirect doesn't work.
- **Copy method:** Files are copied to `ubuntu@<host>:~/` and moved into place with `sudo`, because root SSH is disabled on the cloud image.
- **Config rendering:** `10-bridge.conf` and `kubelet-config.yaml` are rendered on the jumpbox with each worker's pod subnet from `machines.txt`.
- **Name resolution:** Each worker needs `server.kubernetes.local` in `/etc/hosts`, and cloud-init must not rewrite that file. `server` also needs entries for the workers, because `kubectl exec` and `kubectl logs` connect to the kubelet by node name.
- **Pod routes:** The tutorial relies on cloud route tables for traffic between pod subnets. In this lab, each worker gets a static host route to the other worker's subnet.

## 1. Check name resolution and cloud-init

Run from the jumpbox:

```bash
for h in node-0 node-1; do
  ssh ubuntu@$h "echo 'manage_etc_hosts: false' | sudo tee /etc/cloud/cloud.cfg.d/99-no-hosts.cfg >/dev/null"
  ssh ubuntu@$h "grep -q server.kubernetes.local /etc/hosts || echo '192.168.122.11 server server.kubernetes.local' | sudo tee -a /etc/hosts >/dev/null"
done
```

Verify:

```bash
for h in node-0 node-1; do ssh ubuntu@$h "echo == \$(hostname); getent hosts server.kubernetes.local"; done
```

Expected: `192.168.122.11` for each worker.

On `server`, add the worker names so the API server can reach the kubelets:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.122.12 node-0 node-0.kubernetes.local
192.168.122.13 node-1 node-1.kubernetes.local
EOF
getent hosts node-0 node-1
```

## 2. Render the worker configs

Run from `~/kubernetes-the-hard-way` on the jumpbox. `machines.txt` must exist with one line per machine:

```
192.168.122.11 server.kubernetes.local server
192.168.122.12 node-0.kubernetes.local node-0 10.200.0.0/24
192.168.122.13 node-1.kubernetes.local node-1 10.200.1.0/24
```

Render and copy the files:

```bash
for HOST in node-0 node-1; do
  SUBNET=$(grep ${HOST} machines.txt | cut -d " " -f 4)
  sed "s|SUBNET|$SUBNET|g" configs/10-bridge.conf > 10-bridge.conf
  sed "s|SUBNET|$SUBNET|g" configs/kubelet-config.yaml > kubelet-config.yaml
  scp 10-bridge.conf kubelet-config.yaml ubuntu@${HOST}:~/
done
```

The local copies are overwritten on each pass, so the files left on the jumpbox are for `node-1`. Each worker receives its own values.

Verify:

```bash
for h in node-0 node-1; do ssh ubuntu@$h "echo == \$(hostname); grep -h 10.200 ~/10-bridge.conf ~/kubelet-config.yaml"; done
```

Expected: `node-0` shows `10.200.0.0/24` and `node-1` shows `10.200.1.0/24`.

## 3. Copy binaries, configs, and unit files

Run from the jumpbox:

```bash
for HOST in node-0 node-1; do
  scp \
    downloads/worker/* \
    downloads/client/kubectl \
    configs/99-loopback.conf \
    configs/containerd-config.toml \
    configs/kube-proxy-config.yaml \
    units/containerd.service \
    units/kubelet.service \
    units/kube-proxy.service \
    ubuntu@${HOST}:~/
  ssh ubuntu@${HOST} "mkdir -p ~/cni-plugins"
  scp downloads/cni-plugins/* ubuntu@${HOST}:~/cni-plugins/
done
```

## 4. Install packages and binaries

Run on each worker (`ssh ubuntu@node-0` or `ssh ubuntu@node-1`):

```bash
sudo apt-get update
sudo apt-get -y install socat conntrack ipset kmod
sudo swapoff -a
```

Cloud images normally have no swap, so `swapon --show` should print nothing. If it does, disable swap in `/etc/fstab` as well.

Create the directories:

```bash
sudo mkdir -p /etc/cni/net.d /opt/cni/bin /var/lib/kubelet /var/lib/kube-proxy /var/lib/kubernetes /var/run/kubernetes
```

Install the binaries:

```bash
sudo mv crictl kube-proxy kubelet runc /usr/local/bin/
sudo mv containerd containerd-shim-runc-v2 containerd-stress /bin/
sudo mv cni-plugins/* /opt/cni/bin/
```

## 5. Configure CNI, kernel settings, and containerd

Install the CNI config files:

```bash
sudo mv 10-bridge.conf 99-loopback.conf /etc/cni/net.d/
```

Load the bridge netfilter module and make it persistent. `>>` runs as your user, so use `tee`:

```bash
sudo modprobe br-netfilter
echo "br-netfilter" | sudo tee -a /etc/modules-load.d/modules.conf
```

Set the bridge sysctl values:

```bash
echo "net.bridge.bridge-nf-call-iptables = 1" | sudo tee -a /etc/sysctl.d/kubernetes.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" | sudo tee -a /etc/sysctl.d/kubernetes.conf
sudo sysctl -p /etc/sysctl.d/kubernetes.conf
```

Install the containerd config and unit:

```bash
sudo mkdir -p /etc/containerd/
sudo mv containerd-config.toml /etc/containerd/config.toml
sudo mv containerd.service /etc/systemd/system/
```

## 6. Configure the kubelet and kube-proxy

```bash
sudo mv kubelet-config.yaml /var/lib/kubelet/
sudo mv kubelet.service /etc/systemd/system/
sudo mv kube-proxy-config.yaml /var/lib/kube-proxy/
sudo mv kube-proxy.service /etc/systemd/system/
```

Check that the kubelet's TLS files and kubeconfig from stage 04 are in place:

```bash
sudo ls -l /var/lib/kubelet/ /var/lib/kube-proxy/
```

## 7. Start the worker services

On each worker:

```bash
sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl start containerd kubelet kube-proxy
```

Verify from the jumpbox:

```bash
for h in node-0 node-1; do ssh ubuntu@$h "echo == \$(hostname); systemctl is-active containerd kubelet kube-proxy"; done
```

Expected: `active` three times for each worker.

Confirm the versions on one worker:

```bash
ssh ubuntu@node-0 "containerd --version && kubelet --version"
```

Expected: containerd `2.1.0-beta.0` and kubelet `v1.32.3`.

## 8. Verify registration

On `server`:

```bash
kubectl get nodes -o wide
```

Expected: `node-0` and `node-1` with status `Ready`, `INTERNAL-IP` set to `192.168.122.12` and `192.168.122.13`, and runtime `containerd://2.1.0-beta.0`.

`PODCIDR` shows `<none>` for both nodes. This is expected in this lab, because the pod subnets are set in the CNI bridge config on each worker, not on the node object.

## 9. Pod networking

The tutorial's pod routes come from the cloud route table, which this lab doesn't have. Instead, add a static route on each worker to the other worker's pod subnet, using its VM address as the next hop. Run from the jumpbox:

```bash
ssh ubuntu@node-0 "sudo ip route add 10.200.1.0/24 via 192.168.122.13"
ssh ubuntu@node-1 "sudo ip route add 10.200.0.0/24 via 192.168.122.12"
```

Verify:

```bash
for h in node-0 node-1; do ssh ubuntu@$h "echo == \$(hostname); ip route | grep 10.200"; done
```

Expected: `node-0` shows `10.200.1.0/24 via 192.168.122.13`, and `node-1` shows `10.200.0.0/24 via 192.168.122.12`.

These routes don't survive a reboot. Re-run the two `ip route add` commands after a restart.

Run a test with one pod on each worker, from `server`:

```bash
kubectl run pod-a --image=busybox:1.36 --overrides='{"spec":{"nodeName":"node-0"}}' --command -- sleep 3600
kubectl run pod-b --image=busybox:1.36 --overrides='{"spec":{"nodeName":"node-1"}}' --command -- sleep 3600
kubectl get pods -o wide
```

Expected: `pod-a` at `10.200.0.2` on `node-0`, and `pod-b` at `10.200.1.2` on `node-1`, both `Running`.

Ping across the nodes:

```bash
kubectl exec pod-a -- ping -c 3 10.200.1.2
```

Expected: three replies, with 0% packet loss.

Clean up:

```bash
kubectl delete pod pod-a pod-b
```
![](images/cluster_working.jpg)
## Issues encountered

**`sudo` in front of a shell redirect failed with `Permission denied`.** The `>>` redirect runs as your user, so use `sudo tee -a` instead.

**`sudo` in front of a `while` loop caused a syntax error.** Put `sudo` on the individual commands, not on the loop.

**The render loop failed with `machines.txt: No such file or directory`.** The file was missing from the repo on the jumpbox. Recreate it with the four-column format shown in step 2.

**Running the loop from `server` failed with `Permission denied`.** `server` has no key for the workers, and `sudo ssh` uses root's keys. Run loops that reach the workers from the jumpbox.

**Worker names didn't resolve on `server`.** `server` had no entries for `node-0` or `node-1`. `kubectl exec` failed with a DNS error until the entries were added to `server`'s `/etc/hosts`.

**`/etc/hosts` entries disappeared after reboots.** Cloud-init rewrote the file. Disable its hosts management with `/etc/cloud/cloud.cfg.d/99-no-hosts.cfg` on every VM, and re-add the `server.kubernetes.local` entry where it's missing.

**Netplan routes were tried first.** The tutorial doesn't use Netplan for pod routes, so the Netplan files were removed and replaced with `ip route add`.

**`scp` used `root@` at first.** Ubuntu cloud images disable root SSH, so use `ubuntu@` and move the files with `sudo`.

## Verified

- [x] `server.kubernetes.local` resolves on both workers, and `node-0` and `node-1` resolve on `server`
- [x] `10-bridge.conf` and `kubelet-config.yaml` rendered with the correct subnets on each worker
- [x] `br_netfilter` loaded and bridge sysctl values set on `node-0` and `node-1`
- [x] containerd, kubelet, and kube-proxy active on both workers
- [x] `node-0` and `node-1` registered and `Ready` with the expected internal IPs
- [x] Pod routes present on both workers
- [x] Pods scheduled on each worker with addresses from their own subnet
- [x] Cross-node ping between pods succeeds
