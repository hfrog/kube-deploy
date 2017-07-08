# kube-deploy - kubernetes deployment scripts

```Warning: there is no cluster redundancy, so don't use scripts for production deployment```

## Features

* Kubernetes v1.7.0
* Calico networking
* Dashboard
* RBAC is turned on
* By default, only user admin:admin is accepted

### Prerequisites

UNIX system with docker running. Tested on CoreOS 1451.2.0

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

### Worker node deployment

To deploy additional worker nodes, generate certificates and keys at first
```
master# ./make-worker-node-certs.sh <worker ip address>
```
then copy files from master:/root/k8s-certs to worker:/root/k8s-certs, login to the worker and run
```
worker# git clone https://github.com/hfrog/kube-deploy.git
worker# cd kube-deploy
worker# MASTER_IP=<master ip> ./worker.sh
```

