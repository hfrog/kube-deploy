#!/bin/bash
# vim: set sw=2 :

# Copyright 2016 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o errtrace
set -o nounset
set -o pipefail

error_report() {
  echo "errexit on line $(caller)" >&2
}

trap error_report ERR

DEBUG=${DEBUG:-false}
if [[ $DEBUG == true ]]; then
  set -x
fi

cd $(dirname $(dirname $BASH_SOURCE))
source include/cni-plugin.sh
source include/pki.sh

kube::multinode::main() {

  # Require root
  if [[ $(id -u) != 0 ]]; then
    kube::log::fatal "Please run as root"
  fi

  for tool in curl ip docker openssl; do
    if ! kube::helpers::command_exists $tool; then
      kube::log::fatal "The binary $tool is required. Install it."
    fi
  done

  # Make sure docker daemon is running
  if ! docker ps >/dev/null; then
    kube::log::fatal "Docker is not running on this machine!"
  fi

  DEFAULT_IP_ADDRESS=$(ip -o -4 addr list $(ip -o -4 route show to default | awk '{print $5}' | head -1) | awk '{print $4}' | cut -d/ -f1 | head -1)
  IP_ADDRESS=${IP_ADDRESS:-$DEFAULT_IP_ADDRESS}

  # main tunables
  MASTER_IP=${MASTER_IP:-$IP_ADDRESS}
  K8S_VERSION=${K8S_VERSION:-"v1.8.1"}
  REGISTRY=${REGISTRY:-"gcr.io/google_containers"}
  IP_POOL=${IP_POOL:-"10.168.0.0/16"}
  SERVICE_NETWORK=${SERVICE_NETWORK:-"10.24.0"}
  CLUSTER_DOMAIN=cluster.local
  RBAC=${RBAC:-true}
  OPENID=${OPENID:-false}

  CURRENT_PLATFORM=$(kube::helpers::host_platform)
  K8S_ARCH=${K8S_ARCH:-${CURRENT_PLATFORM##*/}}

  ETCD_VERSION=${ETCD_VERSION:-"3.0.17"}
  ETCD_NET_PARAM="--net host"
  ETCD_IP=${ETCD_IP:-$MASTER_IP}

  RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}

  TIMEOUT_FOR_SERVICES=${TIMEOUT_FOR_SERVICES:-20}
  USE_CONTAINERIZED=${USE_CONTAINERIZED:-"true"}

  K8S_KUBESRV_DIR=/srv/kubernetes
  K8S_AUTH_DIR=$K8S_KUBESRV_DIR/auth
  K8S_ADDONS_DIR=$K8S_KUBESRV_DIR/addons
  K8S_MANIFESTS_DIR=$K8S_KUBESRV_DIR/manifests
  K8S_CERTS_DIR=$K8S_KUBESRV_DIR/crt
  K8S_KEYS_DIR=$K8S_KUBESRV_DIR/key
  K8S_KUBECONFIG_DIR=$K8S_KUBESRV_DIR/kubeconfig
  K8S_DATA_DIR=$K8S_KUBESRV_DIR/data
  K8S_KUBELET_DIR=/var/lib/kubelet
  K8S_LOG_DIR=/var/log/kubernetes

  K8S_CA_DIR=$K8S_KUBESRV_DIR/ca
  SRC_CERTS_DIR=${SRC_CERTS_DIR:-"/root/k8s-certs"}

  ETCD_NET_PARAM="-p 2379:2379 -p 2380:2380"

  if [[ $USE_CONTAINERIZED == true ]]; then
    ROOTFS_MOUNT="-v /:/rootfs:ro"
    KUBELET_MOUNT="-v $K8S_KUBELET_DIR:$K8S_KUBELET_DIR:slave"
    CONTAINERIZED_FLAG="--containerized"
  else
    ROOTFS_MOUNT=""
    KUBELET_MOUNT="-v $K8S_KUBELET_DIR:$K8S_KUBELET_DIR:shared"
    CONTAINERIZED_FLAG=""
  fi

  if [[ $RBAC == true ]]; then
    K8S_AUTHZ_MODE=RBAC
  else
    K8S_AUTHZ_MODE=AlwaysAllow
  fi

  if [[ $OPENID == true ]]; then
    K8S_OIDC="\
      --oidc-issuer-url=https://$MASTER_IP:32000 \
      --oidc-client-id=kubernetes \
      --oidc-ca-file=$K8S_CERTS_DIR/ca.crt \
      --oidc-username-claim=email \
      --oidc-groups-claim=groups"
  else
    K8S_OIDC=""
  fi

  KUBELET_MOUNTS="\
    $ROOTFS_MOUNT \
    -v /sys:/sys:rw \
    -v /var/run:/var/run:rw \
    -v /run:/run:rw \
    -v /var/lib/docker:/var/lib/docker:rw \
    $KUBELET_MOUNT \
    -v $K8S_LOG_DIR:$K8S_LOG_DIR:rw \
    -v $K8S_KUBESRV_DIR:$K8S_KUBESRV_DIR:ro \
    -v /etc/cni/net.d:/etc/cni/net.d:rw \
    -v /opt/cni/bin:/opt/cni/bin:rw"

  CNI_ARGS="\
    --network-plugin=cni \
    --cni-conf-dir=/etc/cni/net.d \
    --cni-bin-dir=/opt/cni/bin"
}

# Ensure everything is OK, docker is running and we're root
kube::multinode::log_variables() {

  # Output the value of the variables
  kube::log::status "MASTER_IP is set to: $MASTER_IP"
  kube::log::status "K8S_VERSION is set to: $K8S_VERSION"
  kube::log::status "REGISTRY is set to: $REGISTRY"
  kube::log::status "IP_POOL is set to: $IP_POOL"
  kube::log::status "SERVICE_NETWORK is set to: $SERVICE_NETWORK"
  kube::log::status "CLUSTER_DOMAIN is set to: $CLUSTER_DOMAIN"
  kube::log::status "Authorization mode is set to: $K8S_AUTHZ_MODE"
  kube::log::status "OPENID is set to: $OPENID"
  kube::log::status "--------------------------------------------"
  kube::log::status "IP_ADDRESS is set to: $IP_ADDRESS"
  kube::log::status "ETCD_IP is set to: $ETCD_IP"
  kube::log::status "ETCD_VERSION is set to: $ETCD_VERSION"
  kube::log::status "K8S_ARCH is set to: $K8S_ARCH"
  kube::log::status "--------------------------------------------"
  kube::log::status "SRC_CERTS_DIR is set to: $SRC_CERTS_DIR"
  kube::log::status "K8S_KUBESRV_DIR is set to: $K8S_KUBESRV_DIR"
  kube::log::status "K8S_KUBELET_DIR is set to: $K8S_KUBELET_DIR"
  kube::log::status "K8S_LOG_DIR is set to: $K8S_LOG_DIR"
  kube::log::status "--------------------------------------------"
}

# Start etcd on the master node
kube::multinode::start_etcd() {

  kube::log::status "Launching etcd..."

  docker run -d \
    --name kube_etcd_$(kube::helpers::small_sha) \
    --restart=$RESTART_POLICY \
    $ETCD_NET_PARAM \
    -v $K8S_KUBELET_DIR/etcd:/var/etcd \
    gcr.io/google_containers/etcd-$K8S_ARCH:$ETCD_VERSION \
    /usr/local/bin/etcd \
      --listen-client-urls=http://0.0.0.0:2379 \
      --advertise-client-urls=http://$ETCD_IP:2379 \
      --listen-peer-urls=http://0.0.0.0:2380 \
      --initial-advertise-peer-urls=http://$ETCD_IP:2380 \
      --initial-cluster=default=http://$ETCD_IP:2380 \
      --data-dir=/var/etcd/data

  # Wait for etcd to come up
  SECONDS=0 # bash special variable
  while ! { sleep 1 && curl -fsSL http://$ETCD_IP:2379/health >/dev/null 2>&1; }; do
    if [[ $SECONDS -gt $TIMEOUT_FOR_SERVICES ]]; then
      kube::log::fatal "etcd failed to start. Exiting..."
    fi
  done
}

# Common kubelet runner
kube::multinode::start_k8s() {
  kube::multinode::make_shared_kubelet_dir

  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=$RESTART_POLICY \
    --name kube_kubelet_$(kube::helpers::small_sha) \
    $KUBELET_MOUNTS \
    $REGISTRY/hyperkube-$K8S_ARCH:$K8S_VERSION \
    /bin/sh -c "/hyperkube kubelet \
      --pod-manifest-path=$K8S_MANIFESTS_DIR \
      --allow-privileged \
      --require-kubeconfig \
      --kubeconfig=$K8S_KUBECONFIG_DIR/kubeconfig-kubelet-$IP_ADDRESS.yaml \
      --cluster-dns=$SERVICE_NETWORK.10 \
      --cluster-domain=$CLUSTER_DOMAIN \
      --client-ca-file=$K8S_CERTS_DIR/ca.crt \
      --tls-cert-file=$K8S_CERTS_DIR/kubelet-server-$IP_ADDRESS.crt \
      --tls-private-key-file=$K8S_KEYS_DIR/kubelet-server-$IP_ADDRESS.key \
      --anonymous-auth=false \
      --authorization-mode=Webhook \
      --authentication-token-webhook \
      --make-iptables-util-chains=true \
      --keep-terminated-pod-volumes=false \
      --streaming-connection-idle-timeout=1h \
      --read-only-port=0 \
      --cadvisor-port=0 \
      --event-qps=0 \
      $CNI_ARGS \
      $KUBELET_LABELS \
      $CONTAINERIZED_FLAG \
      --hostname-override=$IP_ADDRESS \
      --v=2 >$K8S_LOG_DIR/kubelet.log 2>&1"
}

# Start kubelet first and then the master components as pods
kube::multinode::start_k8s_master() {
  kube::multinode::cleanup_master
  kube::multinode::copy_master_pki_files
  kube::multinode::create_basic_auth
  kube::multinode::create_master_manifests
  kube::multinode::create_addons
  kube::multinode::create_master_kubeconfigs
  KUBELET_LABELS="--node-labels role=master"

  kube::log::status "Launching Kubernetes master components..."
  kube::multinode::start_k8s
}

# Start kubelet in a container, for a worker node
kube::multinode::start_k8s_worker() {
  kube::multinode::cleanup_worker
  kube::multinode::copy_worker_pki_files
  kube::multinode::create_worker_manifests
  kube::multinode::create_worker_kubeconfigs
  KUBELET_LABELS="--node-labels role=worker"

  kube::log::status "Launching Kubernetes worker components..."
  kube::multinode::start_k8s
}

# Make shared kubelet directory
kube::multinode::make_shared_kubelet_dir() {

  # This only has to be done when the host doesn't use systemd
  if ! kube::helpers::command_exists systemctl; then
    mkdir -p $K8S_KUBELET_DIR
    mount --bind $K8S_KUBELET_DIR $K8S_KUBELET_DIR
    mount --make-shared $K8S_KUBELET_DIR

    kube::log::status "Mounted $K8S_KUBELET_DIR with shared propagation"
  fi
}

kube::util::assure_dir() {
  dir=$1
  [[ -d $dir ]] || rm -f $dir && mkdir -p $dir
}

kube::util::expand_vars() {
    sed -e "s|REGISTRY|$REGISTRY|g" -e "s/K8S_ARCH/$K8S_ARCH/g" \
        -e "s/K8S_VERSION/$K8S_VERSION/g" -e "s/ETCD_IP/$ETCD_IP/g" \
        -e "s/MASTER_IP/$MASTER_IP/g" -e "s/IP_ADDRESS/$IP_ADDRESS/g" \
        -e "s/CLUSTER_DOMAIN/$CLUSTER_DOMAIN/g" \
        -e "s/K8S_AUTHZ_MODE/$K8S_AUTHZ_MODE/g" \
        -e "s|K8S_KUBECONFIG_DIR|$K8S_KUBECONFIG_DIR|g" \
        -e "s|K8S_KUBESRV_DIR|$K8S_KUBESRV_DIR|g" \
        -e "s|K8S_AUTH_DIR|$K8S_AUTH_DIR|g" \
        -e "s|K8S_ADDONS_DIR|$K8S_ADDONS_DIR|g" \
        -e "s|K8S_CERTS_DIR|$K8S_CERTS_DIR|g" \
        -e "s|K8S_KEYS_DIR|$K8S_KEYS_DIR|g" \
        -e "s|K8S_LOG_DIR|$K8S_LOG_DIR|g" \
        -e "s|K8S_DATA_DIR|$K8S_DATA_DIR|g" \
        -e "s|SERVICE_NETWORK|$SERVICE_NETWORK|g" \
        -e "s|IP_POOL|$IP_POOL|g" \
        -e "s|K8S_OIDC|$K8S_OIDC|g" \
        $1
}

kube::multinode::cleanup_logs() {
  rm -fr $K8S_LOG_DIR/*
}

kube::multinode::cleanup_addons() {
  rm -f $K8S_ADDONS_DIR/*
  source include/dashboard.sh cleanup
  source include/dex.sh cleanup
}

kube::multinode::cleanup_master() {
  kube::log::status "Cleaning up master files"
  kube::multinode::cleanup_addons
  kube::multinode::cleanup_logs
}

kube::multinode::cleanup_worker() {
  kube::log::status "Cleaning up $K8S_KUBESRV_DIR for worker"
  rm -rf $K8S_CERTS_DIR
  rm -rf $K8S_KEYS_DIR
  rm -rf $K8S_CA_DIR
  rm -rf $K8S_ADDONS_DIR
  rm -rf $K8S_AUTH_DIR
  rm -rf $K8S_MANIFESTS_DIR
  kube::multinode::cleanup_logs
}

kube::multinode::create_addons() {
  kube::log::status "Creating addons"
  kube::util::assure_dir $K8S_ADDONS_DIR
  for f in addons/*; do
    [ -f $f ] # * protection. will exit if $f is not a file
    kube::util::expand_vars $f > $K8S_ADDONS_DIR/$(basename $f)
  done
  source include/dashboard.sh init
  if [[ $OPENID == true ]]; then
    source include/dex.sh init
  fi
}

kube::multinode::create_master_manifests() {
  kube::log::status "Creating master manifests"
  kube::util::assure_dir $K8S_MANIFESTS_DIR
  for f in manifests/*; do
    [ -f $f ] # * protection. will exit if $f is not a file
    kube::util::expand_vars $f > $K8S_MANIFESTS_DIR/$(basename $f)
  done
}

kube::multinode::create_worker_manifests() {
  kube::log::status "Creating worker manifests"
  kube::util::assure_dir $K8S_MANIFESTS_DIR
  for f in manifests/kube-proxy.yaml; do
    kube::util::expand_vars $f > $K8S_MANIFESTS_DIR/$(basename $f)
  done
}

kube::multinode::create_kubeconfig() {
  local name=$1
  kube::util::expand_vars kubeconfig/kubeconfig-tmpl.yaml | \
      sed -e "s|K8S_KUBECONFIG_NAME|$name|g" > $K8S_KUBECONFIG_DIR/kubeconfig-$name.yaml
}

kube::multinode::create_master_kubeconfigs() {
  kube::multinode::create_worker_kubeconfigs
  kube::log::status "Creating master kubeconfigs"
  kube::util::assure_dir $K8S_KUBECONFIG_DIR

  local name
  for name in addon-manager controller-manager scheduler; do
    kube::multinode::create_kubeconfig $name
  done
}

kube::multinode::create_worker_kubeconfigs() {
  kube::log::status "Creating worker kubeconfigs"
  kube::util::assure_dir $K8S_KUBECONFIG_DIR

  local name
  for name in {kubelet,kube-proxy}-$IP_ADDRESS; do
    kube::multinode::create_kubeconfig $name
  done
}

kube::multinode::create_basic_auth() {
  kube::log::status "Creating basic auth"
  kube::util::assure_dir $K8S_AUTH_DIR
  for f in basic_auth.csv; do
    if [[ ! -f $K8S_AUTH_DIR/$f ]]; then
      kube::util::expand_vars $f > $K8S_AUTH_DIR/$f
      chmod 400 $K8S_AUTH_DIR/$f
    fi
  done
}

kube::multinode::copy_worker_pki_files() {
  kube::log::status "Creating worker certs and keys for $IP_ADDRESS"
  for f in ca.crt {kubelet,kubelet-server,kube-proxy}-$IP_ADDRESS.{crt,key}; do
    pki::place_worker_file $f
  done
}

kube::multinode::copy_master_pki_files() {
  kube::multinode::copy_worker_pki_files
  kube::log::status "Creating master certs and keys"
  for f in {kubernetes-master,addon-manager,apiserver,controller-manager,scheduler}.{crt,key}; do
    pki::place_master_file $f
  done
}

kube::helpers::confirm() {
  read -p "$1 " input

  local return=1
  case $input in
    [nN]*)
      return=1
      ;;
    *)
      return=0
      ;;
  esac
  return $return
}

# Check if a command is valid
kube::helpers::command_exists() {
  command -v "$@" >/dev/null
}

# Returns five "random" chars
kube::helpers::small_sha() {
  date | md5sum | cut -c-5
}

# Get the architecture for the current machine
kube::helpers::host_platform() {
  local host_os
  local host_arch
  case "$(uname -s)" in
    Linux)
      host_os=linux;;
    *)
      kube::log::fatal "Unsupported host OS. Must be linux.";;
  esac

  case "$(uname -m)" in
    x86_64*)
      host_arch=amd64;;
    i?86_64*)
      host_arch=amd64;;
    amd64*)
      host_arch=amd64;;
    aarch64*)
      host_arch=arm64;;
    arm64*)
      host_arch=arm64;;
    arm*)
      host_arch=arm;;
    ppc64le*)
      host_arch=ppc64le;;
    *)
      kube::log::fatal "Unsupported host arch. Must be x86_64, arm, arm64 or ppc64le.";;
  esac
  echo $host_os/$host_arch
}

# Turndown the local cluster
kube::multinode::turndown() {

  local KUBE_ERE="kube_|k8s_"
  for ((i=0; i<3; i++)) {
    local uuids=$(docker ps -a | { grep -E $KUBE_ERE || true; } | awk '{print $1}')
    if [[ -z $uuids ]]; then
      break
    else
      kube::log::status "Killing all kubernetes containers (pass $i)..."
      docker stop $uuids | xargs docker rm -f
      [[ $i -ne 0 ]] && sleep 2
    fi
  }

  if [[ -d $K8S_KUBELET_DIR ]] && kube::helpers::confirm \
        "Do you want to clean $K8S_KUBELET_DIR? [Y/n]"; then
    kube::log::status "Cleaning up $K8S_KUBELET_DIR directory..."

    for ((i=0; i<3; i++)) {
      local mounts=$(mount | { grep $K8S_KUBELET_DIR/ || true; } | awk '{print $3}')
      if [[ -z $mounts ]]; then
        break
      else
        echo $mounts | xargs umount >/dev/null
        [[ $i -ne 0 ]] && sleep 2
      fi
    }

    for ((i=0; i<3; i++)) {
      local mounts=$(mount | { grep "$K8S_KUBELET_DIR[[:space:]]" || true; } | awk '{print $3}')
      if [[ -z $mounts ]]; then
        break
      else
        echo $mounts | xargs umount >/dev/null
        [[ $i -ne 0 ]] && sleep 2
      fi
    }

    # Delete the directory
    rm -rf $K8S_KUBELET_DIR
  fi
  return 0
}

# Print a status line. Formatted to show up in a stream of output.
kube::log::status() {
  local timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "+++ $timestamp $1"
}

# Log an error and exit
kube::log::fatal() {
  local timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "!!! $timestamp ${1-}" >&2
  exit 1
}

