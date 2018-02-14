# kube-deploy - kubernetes deployment scripts

```Warning: there is no cluster redundancy, so don't use scripts for production deployment```

## Features

* Inspired by and based on <https://github.com/kubernetes/kube-deploy/docker-multinode>
* Self-hosted Kubernetes
* Calico networking
* Dashboard
* RBAC
* Optional OpenID with dex
* Useful tools toolbox and http-responder
* By default, only user admin:admin is accepted

### Prerequisites

UNIX system with docker running. Tested on CoreOS

### Master node deployment

To deploy kubernetes, login to the master node server and run

```
master# git clone https://github.com/hfrog/kube-deploy.git
master# cd kube-deploy
master# ./master.sh
```

### Kubectl set up
Fetch kubectl
```
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
```

Set up kubectl config
```
kubectl config set-credentials admin-basic --username=admin --password=admin
kubectl config set-cluster first --server=https://<master ip>:443 --certificate-authority=/srv/kubernetes/crt/ca.crt
kubectl config set-context default --cluster=first --user=admin-basic --namespace=kube-system
kubectl config use-context default
```

kubectl test run
```
kubectl cluster-info
kubectl get all
```

### Dashboard access
Point browser to
```
https://<master ip>/api/v1/proxy/namespaces/kube-system/services/kubernetes-dashboard/
```
and login with user admin and password admin


### Toolbox

This is dataset of pods with handy tools like ping, dig, host, telnet etc

```
# kubectl apply -f toolbox-ds.yaml
# kubectl get pods -o wide | grep toolbox
toolbox-b5xgf  1/1  Running  0  19s  10.168.147.140  192.168.209.138
toolbox-p4mhm  1/1  Running  0  19s  10.168.23.135   192.168.209.141
toolbox-txjzg  1/1  Running  0  19s  10.168.241.132  192.168.209.132
# kubectl exec -ti toolbox-b5xgf bash
bash-4.3# ping -c 3 google.com
PING google.com (173.194.220.101) 56(84) bytes of data.
64 bytes from lk-in-f101.1e100.net (173.194.220.101): icmp_seq=1 ttl=127 time=16.5 ms
64 bytes from lk-in-f101.1e100.net (173.194.220.101): icmp_seq=2 ttl=127 time=16.2 ms
64 bytes from lk-in-f101.1e100.net (173.194.220.101): icmp_seq=3 ttl=127 time=16.1 ms

--- google.com ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 16.193/16.340/16.569/0.194 ms
bash-4.3# host kubernetes.default
kubernetes.default.svc.cluster.local has address 10.24.0.1
bash-4.3# telnet kubernetes.default 443
Trying 10.24.0.1...
Connected to kubernetes.default.svc.cluster.local.
Escape character is '^]'.
^]
q
telnet> Connection closed.
```

### http-responder

This is a trivial http-server to test services, NodePort, ingress traffic and so on

```
# kubectl apply -f http-responder.yaml
# kubectl get all -o wide | grep http-responder
po/http-responder-925862524-18rk0  1/1  Running  0  17s  10.168.241.135  192.168.209.132
po/http-responder-925862524-3vkgn  1/1  Running  0  17s  10.168.147.141  192.168.209.138
po/http-responder-925862524-tbgvn  1/1  Running  0  17s  10.168.23.137   192.168.209.141
svc/http-responder  10.24.0.169   <nodes>  8765:32700/TCP  17s  name=http-responder
deploy/http-responder  3  3  3  3  17s  http-responder  hfrog/http-responder  name=http-responder
rs/http-responder-925862524  3  3  3  17s  http-responder  hfrog/http-responder  name=http-responder,pod-template-hash=925862524
# curl 10.168.241.135
[Jul 10 11:45:45] Req #0 from ::ffff:192.168.209.138:33656 processed by http-responder-925862524-18rk0 ::ffff:10.168.241.135:80 GET / success
138# curl 192.168.209.138:32700
[Jul 10 11:47:34] Req #0 from ::ffff:192.168.209.138:40488 processed by http-responder-925862524-tbgvn ::ffff:10.168.23.137:80 GET / success
138# curl 10.24.0.169:8765
[Jul 10 11:47:46] Req #1 from ::ffff:192.168.209.138:59926 processed by http-responder-925862524-18rk0 ::ffff:10.168.241.135:80 GET / success
138# curl 10.24.0.169:8765
[Jul 10 11:47:49] Req #0 from ::ffff:192.168.209.138:59942 processed by http-responder-925862524-3vkgn ::ffff:10.168.147.141:80 GET / success
```

### Worker node deployment

To deploy additional worker nodes, generate certificates and keys at first
```
master# ./util/make-worker-node-certs.sh <worker ip address>
```
then copy files from master:/root/kube-deploy-data/certs to worker:/root/kube-deploy-data/certs, login to the worker and run
```
worker# git clone https://github.com/hfrog/kube-deploy.git
worker# cd kube-deploy
worker# MASTER_IP=<master ip> ./worker.sh
```

