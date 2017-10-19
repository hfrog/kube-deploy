#!/bin/bash
# vim: set sw=2 :

dex::init() {
  if [[ $OPENID == true ]]; then
    kube::log::status "dex init"
    K8S_OIDC="\
      --oidc-issuer-url=https://$MASTER_IP:32000 \
      --oidc-client-id=kubernetes \
      --oidc-ca-file=$K8S_CERTS_DIR/ca.crt \
      --oidc-username-claim=email \
      --oidc-groups-claim=groups"

    # certs may not be needed in case of external certs,
    # just create them anyway
    pki::create_server_cert dex
    pki::create_server_cert dex-web-app

    local f
    for f in {dex,dex-web-app}.{crt,key}; do
      pki::place_master_file $f
    done

    for f in addons/dex/*yaml; do
      if [[ -f $f ]]; then
        kube::util::expand_vars $f > $K8S_ADDONS_DIR/$(basename $f)
      fi
    done

    local dex_data_dir=$K8S_DATA_DIR/dex
    kube::util::assure_dir $dex_data_dir
    cp -p addons/dex/dex.cfg $dex_data_dir
    eval declare $(grep DEX__LDAP_CA_FILENAME addons/dex/dex.cfg)
    cp -p addons/dex/$DEX__LDAP_CA_FILENAME $dex_data_dir
  fi
}

dex::cleanup() {
  #kube::log::status "dex cleanup"
  :
}

if [[ -z ${1+x} ]]; then
  eval dex::init
else
  eval dex::$1
fi

