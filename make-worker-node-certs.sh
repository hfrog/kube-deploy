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

# Source common.sh
source $(dirname $BASH_SOURCE)/common.sh

kube::multinode::main

if [[ -z ${1+x} ]]; then
  echo "Usage: $0 <worker ip address> [directory where to place files]"
  exit 1
fi
ip=$1

if [[ -z ${2+x} ]]; then
  dstdir=$SRC_CERTS_DIR
else
  dstdir=$2
fi

kube::log::status "Creating worker node certs and keys for $ip"
pki::gen_worker_certs $ip $dstdir
kube::log::status "Please copy files from $dstdir to the worker node"
