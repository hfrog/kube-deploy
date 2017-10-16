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

# tunables
DEX__LDAP_HOST=${DEX__LDAP_HOST:-"ldaps.company.com:636"}
DEX__LDAP_BIND_DN=${DEX__LDAP_BIND_DN:-"CN=kubernetes,OU=users,DC=example,DC=com"}
DEX__LDAP_BIND_PW=${DEX__LDAP_BIND_PW:-"secret"}
DEX__LDAP_USERSEARCH_BASE_DN=${DEX__LDAP_USERSEARCH_BASE_DN:-"DC=example,DC=com"}
DEX__LDAP_GROUPSEARCH_BASE_DN=${DEX__LDAP_GROUPSEARCH_BASE_DN:-"OU=groups,DC=example,DC=com"}
DEX__STATIC_KUBERNETES_SECRET=${DEX__STATIC_KUBERNETES_SECRET:-"ZXhhbXBsZS1hcHAtc2VjcmV0"}
LDAP_CA_FILENAME=${LDAP_CA_FILENAME:-"ca.crt"}

dex-config::delete_secret() {
  local name=$1
  if kubectl get secret $name >/dev/null 2>&1; then
    kubectl delete secret $name
  fi
}

dex-config::delete_configmap() {
  local name=$1
  if kubectl get configmap $name >/dev/null 2>&1; then
    kubectl delete configmap $name
  fi
}

# creating dex-ldap secret
dex-config::delete_secret dex-ldap
kubectl create secret generic dex-ldap \
    --from-literal=host="$DEX__LDAP_HOST" \
    --from-literal=bindDN="$DEX__LDAP_BIND_DN" \
    --from-literal=bindPW="$DEX__LDAP_BIND_PW" \
    --from-literal=user_baseDN="$DEX__LDAP_USERSEARCH_BASE_DN" \
    --from-literal=group_baseDN="$DEX__LDAP_GROUPSEARCH_BASE_DN"


# creating secret for web-app and kubectl
dex-config::delete_secret dex-static
kubectl create secret generic dex-static \
    --from-literal=kubernetes_secret="$DEX__STATIC_KUBERNETES_SECRET"


# creating configmap with ldap-ca cert
dex-config::delete_configmap ldap-ca-crt
kubectl create configmap ldap-ca-crt \
    --from-file=ldap-ca.crt="$LDAP_CA_FILENAME"

