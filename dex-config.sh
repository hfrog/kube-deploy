#!/bin/sh

# creating dex-ldap secret
DEX__LDAP_HOST="ldaps.company.com:636"
DEX__LDAP_BIND_DN="CN=kubernetes,OU=users,DC=example,DC=com"
DEX__LDAP_BIND_PW="secret"
DEX__LDAP_USERSEARCH_BASE_DN="DC=example,DC=com"
DEX__LDAP_GROUPSEARCH_BASE_DN="OU=groups,DC=example,DC=com"

kubectl delete secret dex-ldap
kubectl create secret generic dex-ldap \
    --from-literal=host="$DEX__LDAP_HOST" \
    --from-literal=bindDN="$DEX__LDAP_BIND_DN" \
    --from-literal=bindPW="$DEX__LDAP_BIND_PW" \
    --from-literal=user_baseDN="$DEX__LDAP_USERSEARCH_BASE_DN" \
    --from-literal=group_baseDN="$DEX__LDAP_GROUPSEARCH_BASE_DN"


# creating secret for web-app and kubectl
DEX__STATIC_KUBERNETES_SECRET="ZXhhbXBsZS1hcHAtc2VjcmV0"
kubectl create secret generic dex-static \
    --from-literal=kubernetes_secret="$DEX__STATIC_KUBERNETES_SECRET"


# creating configmap with ldap-ca cert
LDAP_CA_FILENAME="ca.crt"
kubectl create configmap ldap-ca-crt \
    --from-file=ldap-ca.crt="$LDAP_CA_FILENAME"


# creating secret with dex cert and key
kubectl create secret tls dex-tls \
        --cert=/srv/kubernetes/crt/dex.crt \
        --key=/srv/kubernetes/key/dex.key


# creating secret with dex-web-app cert and key
kubectl create secret tls dex-web-app-tls \
        --cert=/srv/kubernetes/crt/dex-web-app.crt \
        --key=/srv/kubernetes/key/dex-web-app.key

