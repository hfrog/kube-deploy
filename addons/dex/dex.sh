#!/bin/bash
# vim: set sw=2 :

dex::init() {
  if kube::helpers::is_true $OPENID; then
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

    # copy certs and keys
    local f
    for f in {dex,dex-web-app}.{crt,key}; do
      pki::place_master_file $f
    done

    # copy manifests
    for f in addons/dex/*yaml; do
      if [[ -f $f ]]; then
        kube::util::expand_vars $f > $K8S_ADDONS_DIR/$(basename $f)
      fi
    done

    # prepare dst dir
    local dex_data_dir=$K8S_DATA_DIR/dex
    kube::util::assure_dir $dex_data_dir

    # prepare src dir and vars
    src_dex_data_dir=$SRC_DATA_DIR/dex
    if [[ -f $src_dex_data_dir/dex.cfg ]]; then
      eval declare $(grep DEX__LDAP_CA_FILENAME $src_dex_data_dir/dex.cfg)
    fi

    # copy data (config) files
    for f in dex.cfg $DEX__LDAP_CA_FILENAME; do
      local ff=$src_dex_data_dir/$f
      if [[ -f $ff ]]; then
        cp -p $ff $dex_data_dir
      else
        kube::log::fatal "There is no file $ff, please create it manually"
      fi
    done

    # copy additional manifests
    for f in $src_dex_data_dir/*yaml; do
      if [[ -f $f ]]; then
        kube::util::expand_vars $f > $K8S_ADDONS_DIR/$(basename $f)
      fi
    done
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

