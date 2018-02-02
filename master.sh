#!/bin/bash

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

source $(dirname $BASH_SOURCE)/include/common.sh

kube::multinode::main

kube::multinode::log_master_variables

if kube::helpers::confirm "Continue? [Y/n]"; then
  kube::log::status "Continue"
else
  kube::log::status "Exiting"
  exit 1
fi

kube::multinode::turndown
kube::cni::ensure_docker_settings

kube::multinode::start_etcd

kube::multinode::start_k8s_master

kube::log::status "Done. It may take about a minute before apiserver is up."
