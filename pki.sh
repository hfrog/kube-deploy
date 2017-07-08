#!/bin/bash
# vim: set sw=2 :

# Copyright 2014 The Kubernetes Authors.
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

pki::init() {
  easyrsa_dir=$CA_DIR/easy-rsa-master/easyrsa3
  initialized=1
}

pki::create_easyrsa() {
  # TODO: For now, this is a patched tool that makes subject-alt-name work, when
  # the fix is upstream  move back to the upstream easyrsa.  This is cached in GCS
  # but is originally taken from:
  #   https://github.com/brendandburns/easy-rsa/archive/master.tar.gz
  #
  # To update, do the following:
  # curl -o easy-rsa.tar.gz https://github.com/brendandburns/easy-rsa/archive/master.tar.gz
  # gsutil cp easy-rsa.tar.gz gs://kubernetes-release/easy-rsa/easy-rsa.tar.gz
  # gsutil acl ch -R -g all:R gs://kubernetes-release/easy-rsa/easy-rsa.tar.gz
  #
  # Due to GCS caching of public objects, it may take time for this to be widely
  # distributed.

  if [[ $MASTER_IP != $IP_ADDRESS ]]; then
    kube::log::fatal "Won't create PKI on worker node"
  fi

  if [[ ! -v initialized ]]; then
    pki::init
  fi

  kube::util::assure_dir $CA_DIR && chmod 700 $CA_DIR

  # Use ~/kube/easy-rsa.tar.gz if it exists, so that it can be
  # pre-pushed in cases where an outgoing connection is not allowed.
  if [[ ! -d $easyrsa_dir ]]; then
    if [[ -f ~/kube/easy-rsa.tar.gz ]]; then
      cat ~/kube/easy-rsa.tar.gz
    else
      curl -# -L https://storage.googleapis.com/kubernetes-release/easy-rsa/easy-rsa.tar.gz
    fi | tar xz -C $CA_DIR -f -
  fi

  if [[ ! -d $easyrsa_dir/pki ]]; then
    (
      kube::log::status "PKI creating new PKI"
      cd $easyrsa_dir
      ./easyrsa init-pki >/dev/null
    )
  fi
  easyrsa_created=1
}

pki::create_ca() {
  if [[ $MASTER_IP != $IP_ADDRESS ]]; then
    kube::log::fatal "Won't create new CA on worker node"
  fi

  if [[ ! -v easyrsa_created ]]; then
    pki::create_easyrsa
  fi

  if [[ ! -f $easyrsa_dir/pki/ca.crt ]]; then
    (
      kube::log::status "PKI creating new CA"
      cd $easyrsa_dir
      ./easyrsa --batch "--req-cn=${MASTER_IP}@`date +%s`" build-ca nopass >/dev/null 2>&1
    )
  fi
  ca_created=1
}

pki::create_client_cert() {
  local name=$1

  if [[ ! -v ca_created ]]; then
    pki::create_ca
  fi

  if [[ ! -f $easyrsa_dir/pki/issued/$name.crt ]]; then
    (
      cd $easyrsa_dir
      # Make a superuser client cert with subject "O=system:masters, CN=kubecfg"
      ./easyrsa --dn-mode=org \
                --req-cn=$name --req-org=system:masters \
                --req-c= --req-st= --req-city= --req-email= --req-ou= \
                build-client-full $name nopass >/dev/null 2>&1
    )
  fi
}

pki::create_worker_certs() {
  local ip=$1

  if [[ ! -v master_certs_created ]]; then
    pki::create_master_certs
  fi

  pki::create_client_cert kubelet-$ip
  pki::create_client_cert proxy-$ip
}

pki::create_master_certs() {
  if [[ $MASTER_IP != $IP_ADDRESS ]]; then
    kube::log::fatal "Won't create certs on worker node"
  fi

  if [[ ! -v ca_created ]]; then
    pki::create_ca
  fi

  local name sans
  for name in kubernetes-master dex; do
    if [[ ! -f $easyrsa_dir/pki/issued/$name.crt ]]; then
      kube::log::status "PKI creating server cert for $name"

      if [[ $name == kubernetes-master ]]; then
        sans="IP:$MASTER_IP,IP:$SERVICE_NETWORK.1,DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.$CLUSTER_DOMAIN"
      elif [[ $name == dex ]]; then
        sans=IP:$MASTER_IP
      else
        kube::log::fatal "Unknown master cert $name"
      fi
      (
        cd $easyrsa_dir
        ./easyrsa --subject-alt-name=$sans build-server-full $name nopass >/dev/null 2>&1
      )
    fi
  done

  pki::create_client_cert kubecfg
  pki::create_client_cert addon-manager
  master_certs_created=1

  pki::create_worker_certs $MASTER_IP
}

pki::pki_srcfile() {
  local file=$1 pki_srcfile

  if [[ ! -v initialized ]]; then
    pki::init
  fi

  if [[ $file =~ \.crt$ ]]; then
    if [[ $file == ca.crt ]]; then
      pki_srcfile=$easyrsa_dir/pki/$file
    else
      pki_srcfile=$easyrsa_dir/pki/issued/$file
    fi
  elif [[ $file =~ \.key$ ]]; then
    pki_srcfile=$easyrsa_dir/pki/private/$file
  else
    kube::log::fatal "Don't know how to handle $file"
  fi
  echo $pki_srcfile
}

pki::dstfile() {
  local file=$1 dstfile
  if [[ $file =~ \.crt$ || $file =~ \.pem$ ]]; then
    dstfile=$K8S_CERTS_DIR/$file
  elif [[ $file =~ \.key$ ]]; then
    dstfile=$K8S_KEYS_DIR/$file
  else
    kube::log::fatal "Don't know how to handle $file"
  fi
  echo $dstfile
}

pki::dstfile_mode() {
  local file=$1 mode
  if [[ $file =~ \.key$ ]]; then
    mode=400
  else
    mode=444
  fi
  echo $mode
}

pki::verify_crt() {
  local ca=$1
  local crt=$2
  if ! openssl verify -CAfile $ca $crt >/dev/null; then
    kube::log::fatal "Failed openssl verify $crt on $ca. May be you've forgotten to clear $K8S_CERTS_DIR and $K8S_KEYS_DIR"
  fi
}

pki::verify_key() {
  local key=$1
  if ! openssl rsa -check -noout -in $key >/dev/null; then
    kube::log::fatal "Failed openssl rsa check $key"
  fi
}

pki::verify_crt_key() {
  local crt=$1
  local key=$2
  local crt_modulus=$(openssl x509 -noout -modulus -in $crt)
  local key_modulus=$(openssl rsa -noout -modulus -in $key)
  if [[ $crt_modulus != $key_modulus ]]; then
    kube::log::fatal "Don't pairing $crt $key"
  fi
}

pki::verify_file() {
  local dstfile=$1
  if [[ $dstfile =~ \.crt$ ]]; then
    # verify crt issuer
    pki::verify_crt $(pki::dstfile ca.crt) $dstfile
  elif [[ $dstfile =~ \.key$ ]]; then
    # verify key consistency
    pki::verify_key $dstfile

    # verify that crt and key match together
    pki::verify_crt_key $(pki::dstfile $(basename $dstfile | sed 's/key$/crt/')) $dstfile
  fi
}

pki::place_tls_cert_bundle() {
  # make bundle for apiserver
  local tls_cert_bundle=$(pki::dstfile kubernetes-master-bundle.pem)
  if [[ ! -f $tls_cert_bundle ]]; then
    local crt
    for crt in kubernetes-master.crt ca.crt; do
      openssl x509 -outform PEM < $(pki::dstfile $crt) >> $tls_cert_bundle
    done
    chmod $(pki::dstfile_mode $tls_cert_bundle) $tls_cert_bundle
  fi
}

pki::get_cert_bundle_from_master() {
  local bundle=$1
  if [[ ! -v got_bundle || ! -f $bundle ]]; then
    # get tls cert bundle from the https cerver
    if ! openssl s_client -connect $MASTER_IP:443 -showcerts </dev/null 2>/dev/null >$bundle; then
      kube::log::fatal "Openssl can't connect to master $MASTER_IP:443"
    fi
    got_bundle=1
  fi
}

pki::srcbase() {
  local srcfile=$1 srcbase

  if [[ ! -v initialized ]]; then
    pki::init
  fi

  if [[ $srcfile =~ ^$easyrsa_dir ]]; then
    srcbase=$easyrsa_dir
  elif [[ $srcfile == $SRC_CERTS_DIR/$(basename $srcfile) ]]; then
    srcbase=$SRC_CERTS_DIR
  else
    kube::log::fatal "Can't detect source base of $srcfile"
  fi
  echo $srcbase
}

pki::detect_source_mixing() {
  local srcfile=$1
  if [[ ! -v source ]]; then
    source=$(pki::srcbase $srcfile)
    kube::log::status "PKI source: $source"
  else
    if [[ $source != $(pki::srcbase $srcfile) ]]; then
      kube::log::status "Warning: PKI source mixing, was $source, now $(pki::srcbase $srcfile)"
    fi
  fi
}

pki::find_src() {
  local file=$1 srcfile result=''
  # find $file first in $SRC_CERTS_DIR then in PKI
  for srcfile in $SRC_CERTS_DIR/$file $(pki::pki_srcfile $file); do
    if [[ -f $srcfile ]]; then
      result=$srcfile
      break
    fi
  done
  echo $result
}

pki::copy_file() {
  local file=$1

  # create dst dirs
  local d
  for d in $K8S_CERTS_DIR $K8S_KEYS_DIR; do
    kube::util::assure_dir $d
  done

  if [[ ! -f $(pki::dstfile $file) ]]; then
    local srcfile=$(pki::find_src $file)
    if [[ -z $srcfile ]]; then
      return 1
    else
      pki::detect_source_mixing $srcfile
      cp -f $srcfile $(pki::dstfile $file)
      chmod $(pki::dstfile_mode $file) $(pki::dstfile $file)
      pki::verify_file $(pki::dstfile $file)
    fi
  fi

  if [[ $file == kubernetes-master.crt ]]; then
    pki::place_tls_cert_bundle
  fi
}

pki::place_worker_file() {
  local file=$1
  if ! pki::copy_file $file; then
    # if copy was unsuccessful, then create file and try to copy it again
    pki::create_worker_certs $IP_ADDRESS
    if ! pki::copy_file $file; then
      kube::log::fatal "There is no src file $file, please fix it"
    fi
  fi

  # verify worker PKI files with CA from https server cert bundle
  if [[ $file =~ \.crt$ && $MASTER_IP != $IP_ADDRESS ]]; then
    local tls_cert_bundle_from_master=$(pki::dstfile tls_cert_bundle_from_master.pem)
    pki::get_cert_bundle_from_master $tls_cert_bundle_from_master
    pki::verify_crt $tls_cert_bundle_from_master $(pki::dstfile $file)
  fi
}

pki::place_master_file() {
  local file=$1
  if ! pki::copy_file $file; then
    # if copy was unsuccessful, then create file and try to copy it again
    pki::create_master_certs
    if ! pki::copy_file $file; then
      kube::log::fatal "There is no src file $file, please fix it"
    fi
  fi
}

pki::gen_worker_certs() {
  local ip=$1 dstdir=$2 f
  pki::create_worker_certs $ip
  kube::util::assure_dir $dstdir
  for f in ca.crt {proxy,kubelet}-$ip.{crt,key}; do
    cp -pf $(pki::pki_srcfile $f) $dstdir
  done
}

