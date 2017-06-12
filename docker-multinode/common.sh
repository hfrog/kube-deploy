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

cd "$(dirname "${BASH_SOURCE}")"
source cni-plugin.sh

kube::multinode::main() {

  # Require root
  if [[ "$(id -u)" != "0" ]]; then
    kube::log::fatal "Please run as root"
  fi

  for tool in curl ip docker; do
    if [[ ! -f $(which ${tool} 2>&1) ]]; then
      kube::log::fatal "The binary ${tool} is required. Install it."
    fi
  done

  # Make sure docker daemon is running
  if [[ $(docker ps 2>&1 1>/dev/null; echo $?) != 0 ]]; then
    kube::log::fatal "Docker is not running on this machine!"
  fi

  # just as note
  LATEST_STABLE_K8S_VERSION=$(curl -sSL "https://storage.googleapis.com/kubernetes-release/release/stable.txt")

  # tunables
  K8S_VERSION=${K8S_VERSION:-"v1.6.4-qiwi.1"}
  REGISTRY=${REGISTRY:-"dcr.qiwi.com"}
  IP_POOL=${IP_POOL:-"10.168.0.0/16"}
  SERVICE_NETWORK=${SERVICE_NETWORK:-"10.24.0"}
  DEX_IP=${DEX_IP:-${MASTER_IP}}


  CURRENT_PLATFORM=$(kube::helpers::host_platform)
  ARCH=${ARCH:-${CURRENT_PLATFORM##*/}}

  ETCD_VERSION=${ETCD_VERSION:-"3.0.17"}
  ETCD_NET_PARAM="--net host"
  ETCD_IP="${ETCD_IP:-${MASTER_IP}}"

  RESTART_POLICY=${RESTART_POLICY:-"unless-stopped"}

  DEFAULT_IP_ADDRESS=$(ip -o -4 addr list $(ip -o -4 route show to default | awk '{print $5}' | head -1) | awk '{print $4}' | cut -d/ -f1 | head -1)
  IP_ADDRESS=${IP_ADDRESS:-${DEFAULT_IP_ADDRESS}}

  TIMEOUT_FOR_SERVICES=${TIMEOUT_FOR_SERVICES:-20}
  USE_CNI=${USE_CNI:-"true"}
  USE_CONTAINERIZED=${USE_CONTAINERIZED:-"true"}
  CNI_ARGS=""

  K8S_KUBESRV_DIR="/srv/kubernetes"
  K8S_ADDONS_DIR="${K8S_KUBESRV_DIR}/addons"
  K8S_MANIFESTS_DIR="${K8S_KUBESRV_DIR}/manifests"
  K8S_CERTS_DIR="${K8S_KUBESRV_DIR}/crt"
  K8S_KEYS_DIR="${K8S_KUBESRV_DIR}/key"
  K8S_KUBELET_DIR="/var/lib/kubelet"
  K8S_KUBECONFIG_DIR="${K8S_KUBELET_DIR}/kubeconfig"

  SRC_CERTS_DIR="/root/certs"

  if [[ ${USE_CONTAINERIZED} == "true" ]]; then
    ROOTFS_MOUNT="-v /:/rootfs:ro"
    KUBELET_MOUNT="-v ${K8S_KUBELET_DIR}:${K8S_KUBELET_DIR}:slave"
    CONTAINERIZED_FLAG="--containerized"
  else
    ROOTFS_MOUNT=""
    KUBELET_MOUNT="-v ${K8S_KUBELET_DIR}:${K8S_KUBELET_DIR}:shared"
    CONTAINERIZED_FLAG=""
  fi

  KUBELET_MOUNTS="\
    ${ROOTFS_MOUNT} \
    -v /sys:/sys:rw \
    -v /var/run:/var/run:rw \
    -v /run:/run:rw \
    -v /var/lib/docker:/var/lib/docker:rw \
    ${KUBELET_MOUNT} \
    -v /var/log/containers:/var/log/containers:rw \
    -v ${K8S_KUBESRV_DIR}:${K8S_KUBESRV_DIR}:ro"

  if [[ ${USE_CNI} == "true" ]]; then
    KUBELET_MOUNTS="\
      ${KUBELET_MOUNTS} \
      -v /etc/cni/net.d:/etc/cni/net.d:rw \
      -v /opt/cni/bin:/opt/cni/bin:rw"

    ETCD_NET_PARAM="-p 2379:2379 -p 2380:2380"
    CNI_ARGS="\
      --network-plugin=cni \
      --cni-conf-dir=/etc/cni/net.d \
      --cni-bin-dir=/opt/cni/bin"
  fi
}

# Ensure everything is OK, docker is running and we're root
kube::multinode::log_variables() {

  # Output the value of the variables
  kube::log::status "MASTER_IP is set to: ${MASTER_IP}"
  kube::log::status "K8S_VERSION is set to: ${K8S_VERSION}"
  kube::log::status "REGISTRY is set to: ${REGISTRY}"
  kube::log::status "IP_POOL is set to: ${IP_POOL}"
  kube::log::status "SERVICE_NETWORK is set to: ${SERVICE_NETWORK}"
  kube::log::status "--------------------------------------------"
  kube::log::status "IP_ADDRESS is set to: ${IP_ADDRESS}"
  kube::log::status "ETCD_IP is set to: ${ETCD_IP}"
  kube::log::status "ETCD_VERSION is set to: ${ETCD_VERSION}"
  kube::log::status "ARCH is set to: ${ARCH}"
  kube::log::status "USE_CNI is set to: ${USE_CNI}"
  kube::log::status "USE_CONTAINERIZED is set to: ${USE_CONTAINERIZED}"
  kube::log::status "--------------------------------------------"
  kube::log::status "SRC_CERTS_DIR is set to: ${SRC_CERTS_DIR}"
  kube::log::status "K8S_KUBESRV_DIR is set to: ${K8S_KUBESRV_DIR}"
  kube::log::status "K8S_KUBELET_DIR is set to: ${K8S_KUBELET_DIR}"
  kube::log::status "K8S_KUBECONFIG_DIR is set to: ${K8S_KUBECONFIG_DIR}"
  kube::log::status "--------------------------------------------"
}

# Start etcd on the master node
kube::multinode::start_etcd() {

  kube::log::status "Launching etcd..."

  docker run -d \
    --name kube_etcd_$(kube::helpers::small_sha) \
    --restart=${RESTART_POLICY} \
    ${ETCD_NET_PARAM} \
    -v ${K8S_KUBELET_DIR}/etcd:/var/etcd \
    gcr.io/google_containers/etcd-${ARCH}:${ETCD_VERSION} \
    /usr/local/bin/etcd \
      --initial-advertise-peer-urls=http://${ETCD_IP}:2379 \
      --initial-cluster=default=http://${ETCD_IP}:2379 \
      --listen-client-urls=http://0.0.0.0:2379 \
      --advertise-client-urls=http://${ETCD_IP}:2379 \
      --listen-peer-urls=http://0.0.0.0:2380 \
      --data-dir=/var/etcd/data

  # Wait for etcd to come up
  local SECONDS=0
  while [[ $(curl -fsSL http://${ETCD_IP}:2379/health 2>&1 1>/dev/null; echo $?) != 0 ]]; do
    ((SECONDS++))
    if [[ ${SECONDS} == ${TIMEOUT_FOR_SERVICES} ]]; then
      kube::log::fatal "etcd failed to start. Exiting..."
    fi
    sleep 1
  done

  sleep 2
}

# Common kubelet runner
kube::multinode::start_k8s() {
  kube::multinode::create_kubeconfig

  kube::multinode::make_shared_kubelet_dir

  docker run -d \
    --net=host \
    --pid=host \
    --privileged \
    --restart=${RESTART_POLICY} \
    --name kube_kubelet_$(kube::helpers::small_sha) \
    ${KUBELET_MOUNTS} \
    ${REGISTRY}/hyperkube-${ARCH}:${K8S_VERSION} \
    /hyperkube kubelet \
      ${KUBELET_ARGS} \
      --allow-privileged \
      --require-kubeconfig \
      --kubeconfig=${K8S_KUBECONFIG_DIR}/kubeconfig-kubelet.yaml \
      --cluster-dns=${SERVICE_NETWORK}.10 \
      --cluster-domain=cluster.local \
      ${CNI_ARGS} \
      ${CONTAINERIZED_FLAG} \
      --hostname-override=${IP_ADDRESS} \
      --v=2
}

# Start kubelet first and then the master components as pods
kube::multinode::start_k8s_master() {
  kube::multinode::create_addons
  kube::multinode::create_manifests
  kube::multinode::create_basic_auth
  kube::multinode::create_worker_certs
  kube::multinode::create_master_certs

  kube::log::status "Launching Kubernetes master components..."
  KUBELET_ARGS="--pod-manifest-path=${K8S_MANIFESTS_DIR}"
  kube::multinode::start_k8s
}

# Start kubelet in a container, for a worker node
kube::multinode::start_k8s_worker() {
  kube::multinode::create_worker_certs

  kube::log::status "Launching Kubernetes worker components..."
  KUBELET_ARGS=""
  kube::multinode::start_k8s
}

# Make shared kubelet directory
kube::multinode::make_shared_kubelet_dir() {

  # This only has to be done when the host doesn't use systemd
  if ! kube::helpers::command_exists systemctl; then
    mkdir -p "${K8S_KUBELET_DIR}"
    mount --bind "${K8S_KUBELET_DIR}" "${K8S_KUBELET_DIR}"
    mount --make-shared "${K8S_KUBELET_DIR}"

    kube::log::status "Mounted ${K8S_KUBELET_DIR} with shared propagnation"
  fi
}

kube::multinode::expand_vars() {
    sed -e "s/REGISTRY/${REGISTRY}/g" -e "s/ARCH/${ARCH}/g" \
        -e "s/VERSION/${K8S_VERSION}/g" -e "s/ETCD_IP/${ETCD_IP}/g" \
        -e "s/MASTER_IP/${MASTER_IP}/g" -e "s/IP_ADDRESS/${IP_ADDRESS}/g" \
        -e "s|K8S_KUBECONFIG_DIR|${K8S_KUBECONFIG_DIR}|g" \
        -e "s|K8S_KUBESRV_DIR|${K8S_KUBESRV_DIR}|g" \
        -e "s|K8S_ADDONS_DIR|${K8S_ADDONS_DIR}|g" \
        -e "s|K8S_CERTS_DIR|${K8S_CERTS_DIR}|g" \
        -e "s|K8S_KEYS_DIR|${K8S_KEYS_DIR}|g" \
        -e "s|SERVICE_NETWORK|${SERVICE_NETWORK}|g" \
        -e "s|IP_POOL|${IP_POOL}|g" -e "s/DEX_IP/${DEX_IP}/g" \
        $1
}

kube::multinode::create_addons() {
  kube::log::status "Creating addons"
  [[ -d ${K8S_ADDONS_DIR} ]] || rm -fr ${K8S_ADDONS_DIR} \
        && mkdir -p ${K8S_ADDONS_DIR}
  for f in addons/*; do
    kube::multinode::expand_vars $f > ${K8S_ADDONS_DIR}/$(basename $f)
  done
}

kube::multinode::create_manifests() {
  kube::log::status "Creating manifests"
  [[ -d ${K8S_MANIFESTS_DIR} ]] || rm -fr ${K8S_MANIFESTS_DIR} \
        && mkdir -p ${K8S_MANIFESTS_DIR}
  for f in manifests/*; do
    kube::multinode::expand_vars $f > ${K8S_MANIFESTS_DIR}/$(basename $f)
  done
}

kube::multinode::create_kubeconfig() {
  kube::log::status "Creating kubeconfigs"
  [[ -d ${K8S_KUBECONFIG_DIR} ]] || rm -fr ${K8S_KUBECONFIG_DIR} \
        && mkdir -p ${K8S_KUBECONFIG_DIR}
  for f in kubeconfig/*; do
    kube::multinode::expand_vars $f > ${K8S_KUBECONFIG_DIR}/$(basename $f)
  done
}

kube::multinode::create_basic_auth() {
  kube::log::status "Creating basic auth"
  [[ -d ${K8S_KUBESRV_DIR} ]] || rm -fr ${K8S_KUBESRV_DIR} \
        && mkdir -p ${K8S_KUBESRV_DIR}
  for f in basic_auth.csv; do
    if [ ! -f ${K8S_KUBESRV_DIR}/$f ]; then
      kube::multinode::expand_vars $f > ${K8S_KUBESRV_DIR}/$f
      chmod 400 ${K8S_KUBESRV_DIR}/$f
    fi
  done
}

kube::multinode::create_cert() {
  file="$1"

  [[ -d ${K8S_CERTS_DIR} ]] || rm -fr ${K8S_CERTS_DIR} \
        && mkdir -p ${K8S_CERTS_DIR}
  [[ -d ${K8S_KEYS_DIR} ]] || rm -fr ${K8S_KEYS_DIR} \
        && mkdir -p ${K8S_KEYS_DIR}

  if [[ "${file}" =~ \.crt$ ]]; then
    dstfile=${K8S_CERTS_DIR}/$file
    mode=444
  elif [[ "${file}" =~ \.key$ ]]; then
    dstfile=${K8S_KEYS_DIR}/$file
    mode=400
  else
    kube::log::fatal "Don't know how to handle ${file}"
  fi

  if [[ ! -f "${dstfile}" ]]; then
    # there is no cert/key file, try to copy it
    srcfile=${SRC_CERTS_DIR}/$file
    if [ -f "${srcfile}" ]; then
      cp -f "${srcfile}" "${dstfile}"
      chmod $mode "${dstfile}"
    else
      kube::log::fatal "There is no src file ${file}, please fix it"
    fi
  fi
}

kube::multinode::create_worker_certs() {
  kube::log::status "Creating worker certs and keys"
  for f in ca.crt ${IP_ADDRESS}-{proxy,kubelet}.{crt,key}; do
    kube::multinode::create_cert $f
  done
}

kube::multinode::create_master_certs() {
  kube::log::status "Creating master certs and keys"
  for f in {kubernetes-master,kubecfg,addon-manager}.{crt,key}; do
    kube::multinode::create_cert $f
  done
}

kube::helpers::confirm() {
  read -p "$1 " input

  return=1
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
  command -v "$@" > /dev/null 2>&1
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
  echo "${host_os}/${host_arch}"
}

# Turndown the local cluster
kube::multinode::turndown() {

  kube::log::status "Killing all kubernetes containers..."

  KUBE_ERE="kube_|k8s_"
  if [[ $(docker ps -a | grep -E "${KUBE_ERE}" | awk '{print $1}' | wc -l) != 0 ]]; then
    # run twice for sure
    docker ps | grep -E "${KUBE_ERE}" | awk '{print $1}' \
        | xargs --no-run-if-empty docker stop | xargs --no-run-if-empty docker rm
    docker ps | grep -E "${KUBE_ERE}" | awk '{print $1}' \
        | xargs --no-run-if-empty docker stop | xargs --no-run-if-empty docker rm

    # also remove stopped containers
    docker ps -a | grep -E "${KUBE_ERE}" | awk '{print $1}' | xargs --no-run-if-empty docker rm
  fi

  if [[ -d "${K8S_KUBELET_DIR}" ]]; then
    read -p "Do you want to clean ${K8S_KUBELET_DIR}? [Y/n] " clean_kubelet_dir

    case $clean_kubelet_dir in
      [nN]*)
        ;; # Do nothing
      *)
        kube::log::status "Cleaning up ${K8S_KUBELET_DIR} directory..."

        # umount if there are mounts in ${K8S_KUBELET_DIR}
        if [[ ! -z $(mount | grep "${K8S_KUBELET_DIR}" | awk '{print $3}') ]]; then

          # The umount command may be a little bit stubborn sometimes, so run the commands twice to ensure the mounts are gone
          mount | grep "${K8S_KUBELET_DIR}/*" | awk '{print $3}' | xargs umount 1>/dev/null 2>/dev/null
          mount | grep "${K8S_KUBELET_DIR}/*" | awk '{print $3}' | xargs umount 1>/dev/null 2>/dev/null
          umount "${K8S_KUBELET_DIR}" 1>/dev/null 2>/dev/null
          umount "${K8S_KUBELET_DIR}" 1>/dev/null 2>/dev/null
        fi

        # Delete the directory
        rm -rf "${K8S_KUBELET_DIR}"
        ;;
    esac
  fi
}

# Print a status line. Formatted to show up in a stream of output.
kube::log::status() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "+++ $timestamp $1"
  shift
  for message; do
    echo "    $message"
  done
}

# Log an error and exit
kube::log::fatal() {
  timestamp=$(date +"[%m%d %H:%M:%S]")
  echo "!!! $timestamp ${1-}" >&2
  shift
  for message; do
    echo "    $message" >&2
  done
  exit 1
}

