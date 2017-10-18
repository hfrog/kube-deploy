#!/bin/bash
# vim: set sw=2 :

dex::init() {
  kube::log::status "dex init"
  if [[ $OPENID == true ]]; then
    kube::log::status "OPENID is on, don't forget to run dex-config.sh"

    # certs may not be needed in case of external certs.
    # just create them anyway
    pki::create_server_cert dex
    pki::create_server_cert dex-web-app

    for f in {dex,dex-web-app}.{crt,key}; do
      pki::place_master_file $f
    done
  fi
}

dex::cleanup() {
  kube::log::status "dex cleanup"
}

if [[ -z ${1+x} ]]; then
  eval dex::init
else
  eval dex::$1
fi

