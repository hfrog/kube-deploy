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
    kube::log::fatal "Will not create PKI on worker node"
  fi

  if [[ ! -v initialized ]]; then
    pki::init
  fi

  [[ -d $CA_DIR ]] || rm -f $CA_DIR && mkdir -p $CA_DIR \
        && chmod 700 $CA_DIR

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
      ./easyrsa init-pki
    )
  fi
  easyrsa_created=1
}

pki::create_ca() {
  if [[ $MASTER_IP != $IP_ADDRESS ]]; then
    kube::log::fatal "Will not create new CA on worker node"
  fi

  if [[ ! -v easyrsa_created ]]; then
    pki::create_easyrsa
  fi

  if [[ ! -f $easyrsa_dir/pki/ca.crt ]]; then
    (
      kube::log::status "PKI creating new CA"
      cd $easyrsa_dir
      ./easyrsa --batch "--req-cn=${MASTER_IP}@`date +%s`" build-ca nopass
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
                build-client-full $name nopass
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
    kube::log::fatal "Can't create certs on worker node"
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
        ./easyrsa --subject-alt-name=$sans build-server-full $name nopass
      )
    fi
  done

  pki::create_client_cert kubecfg
  pki::create_client_cert addon-manager
  master_certs_created=1

  pki::create_worker_certs $MASTER_IP
}

pki::place_tls_cert_bundle() {
  # make bundle for HTTPS
  local tls_cert_bundle=$K8S_CERTS_DIR/kubernetes-master-bundle.pem
  if [[ ! -f $tls_cert_bundle ]]; then
    openssl x509 -outform PEM < $K8S_CERTS_DIR/kubernetes-master.crt > $tls_cert_bundle
    cat $K8S_CERTS_DIR/ca.crt >> $tls_cert_bundle
    chmod 444 $tls_cert_bundle
  fi
}

pki::copy_file() {
  local file=$1
  
  if [[ ! -v initialized ]]; then
    pki::init
  fi

  # create dst dirs
  [[ -d $K8S_CERTS_DIR ]] || rm -f $K8S_CERTS_DIR \
        && mkdir -p $K8S_CERTS_DIR
  [[ -d $K8S_KEYS_DIR ]] || rm -f $K8S_KEYS_DIR \
        && mkdir -p $K8S_KEYS_DIR

  # set pki_src here, dst and modes
  local pki_srcfile dstfile mode
  if [[ $file =~ \.crt$ ]]; then
    if [[ $file == ca.crt ]]; then
      pki_srcfile=$easyrsa_dir/pki/$file
    else
      pki_srcfile=$easyrsa_dir/pki/issued/$file
    fi
    dstfile=$K8S_CERTS_DIR/$file
    mode=444
  elif [[ $file =~ \.key$ ]]; then
    pki_srcfile=$easyrsa_dir/pki/private/$file
    dstfile=$K8S_KEYS_DIR/$file
    mode=400
  else
    kube::log::fatal "Don't know how to handle $file"
  fi

  local srcfile
  if [[ ! -f $dstfile ]]; then
    # there is no dst cert/key file, try to copy it from SRC_CERTS_DIR
    srcfile=$SRC_CERTS_DIR/$file
    if [[ -f $srcfile ]]; then
      # check source mixing
      if [[ ! -v source ]]; then
        source=$SRC_CERTS_DIR
        kube::log::status "PKI source: pre-created $source"
      else
        if [[ $source != $SRC_CERTS_DIR ]]; then
          kube::log::fatal "PKI source mixing, was $source, now $SRC_CERTS_DIR"
        fi
      fi

      cp -f $srcfile $dstfile
      chmod $mode $dstfile
    else
      # try to copy file from PKI
      if [[ -f $pki_srcfile ]]; then
        # check source mixing
        if [[ ! -v source ]]; then
          source=$easyrsa_dir
          kube::log::status "PKI source: easyrsa CA $source"
        else
          if [[ $source != $easyrsa_dir ]]; then
            kube::log::fatal "PKI source mixing, was $source, now $easyrsa_dir"
          fi
        fi

        cp -f $pki_srcfile $dstfile
        chmod $mode $dstfile
      else
        return 1
      fi
    fi
  fi

  if [[ $file == kubernetes-master.crt ]]; then
    pki::place_tls_cert_bundle
  fi

  # verify certs and keys
  if [[ $file =~ \.crt$ ]]; then
    # verify crt issuer
    if ! openssl verify -CAfile $K8S_CERTS_DIR/ca.crt $dstfile >/dev/null; then
      kube::log::fatal "openssl verify $dstfile failed"
    fi
  elif [[ $file =~ \.key$ ]]; then
    # verify key consistency
    if ! openssl rsa -check -noout -in $dstfile >/dev/null; then
      kube::log::fatal "openssl rsa check $dstfile failed"
    fi

    # verify crt and key match togeter
    local crt_file=$K8S_CERTS_DIR/${file/%key/crt}
    local crt_modulus=$(openssl x509 -noout -modulus -in $crt_file)
    local key_modulus=$(openssl rsa -noout -modulus -in $dstfile)
    if [[ $crt_modulus != $key_modulus ]]; then
      kube::log::fatal "keys $crt_file $dstfile don't match"
    fi
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
    local tls_cert_bundle=$K8S_CERTS_DIR/tls_cert_bundle_from_network.pem
    if [[ ! -v got_tls_bundle || ! -f $tls_cert_bundle ]]; then
      # get tls cert bundle from the https cerver
      if ! openssl s_client -connect $MASTER_IP:443 -showcerts </dev/null 2>/dev/null > $tls_cert_bundle; then
        kube::log::fatal "openssl can't connect to master $MASTER_IP:443"
      fi
      got_tls_bundle=1
    fi

    local dstfile=$K8S_CERTS_DIR/$file
    if ! openssl verify -CAfile $tls_cert_bundle $dstfile >/dev/null; then
      kube::log::fatal "openssl verify $dstfile with TLS CA cert failed"
    fi
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

