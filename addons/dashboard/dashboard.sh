#!/bin/bash
# vim: set sw=2 :

dashboard::init() {
  kube::log::status "dashboard init"

  # certs may not be needed in case of external certs,
  # just create them anyway
  pki::create_server_cert dashboard

  for f in dashboard.{crt,key}; do
    pki::place_master_file $f
  done

  for f in addons/dashboard/*yaml; do
    if [[ -f $f ]]; then
      kube::util::expand_vars $f > $K8S_ADDONS_DIR/$(basename $f)
    fi
  done
}

dashboard::cleanup() {
  #kube::log::status "dashboard cleanup"
  :
}

if [[ -z ${1+x} ]]; then
  eval dashboard::init
else
  eval dashboard::$1
fi

