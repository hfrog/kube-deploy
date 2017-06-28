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

initialized=0

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
    cd $easyrsa_dir
    ./easyrsa init-pki
  fi
}

pki::create_ca() {
  if [[ ! -f $easyrsa_dir/pki/ca.crt ]]; then
    cd $easyrsa_dir
    ./easyrsa --batch "--req-cn=${MASTER_IP}@`date +%s`" build-ca nopass
  fi
}

pki::create_client_cert() {
  name=$1
  if [[ ! -f $easyrsa_dir/pki/issued/$name.crt ]]; then
    cd $easyrsa_dir
    # Make a superuser client cert with subject "O=system:masters, CN=kubecfg"
    ./easyrsa --dn-mode=org \
        --req-cn=$name --req-org=system:masters \
        --req-c= --req-st= --req-city= --req-email= --req-ou= \
        build-client-full $name nopass
  fi
}

pki::create_worker_certs() {
  ip=$1
  pki::create_client_cert kubelet-$ip
  pki::create_client_cert proxy-$ip
}

pki::create_master_certs() {
  extra_sans=${1:-}
  sans=IP:$MASTER_IP
  if [[ -n $extra_sans ]]; then
    sans="$sans,$extra_sans"
  fi

  name=kubernetes-master
  if [[ ! -f $easyrsa_dir/pki/issued/$name.crt ]]; then
    cd $easyrsa_dir
    ./easyrsa --subject-alt-name=$sans build-server-full $name nopass
  fi

  pki::create_client_cert kubecfg
  pki::create_client_cert addon-manager
  pki::create_worker_certs $MASTER_IP
}

pki::copy_file() {
  file=$1
  
  if [[ $initialized == 0 ]]; then
    pki::init
  fi

  # create dst dirs
  [[ -d $K8S_CERTS_DIR ]] || rm -f $K8S_CERTS_DIR \
        && mkdir -p $K8S_CERTS_DIR
  [[ -d $K8S_KEYS_DIR ]] || rm -f $K8S_KEYS_DIR \
        && mkdir -p $K8S_KEYS_DIR

  # set pki_src here, dst and modes
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
      # try to copy file from pki
      if [[ -f $pki_srcfile ]]; then
        # check source mixing
        if [[ ! -v source ]]; then
          source=$easyrsa_dir
          kube::log::status "PKI source: easyrsa ca $source"
        else
          if [[ $source != $easyrsa_dir ]]; then
            kube::log::fatal "PKI source mixing, was $source, now $easyrsa_dir"
          fi
        fi

        cp -f $pki_srcfile $dstfile
        chmod $mode $dstfile
      else
        return 0
      fi
    fi
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
    crt_file=$K8S_CERTS_DIR/${file/%key/crt}
    crt_modulus=$(openssl x509 -noout -modulus -in $crt_file)
    key_modulus=$(openssl rsa -noout -modulus -in $dstfile)
    if [[ $crt_modulus != $key_modulus ]]; then
      kube::log::fatal "keys $crt_file $dstfile don't match"
    fi
  fi
}

pki::place_worker_file() {
  file=$1
  if ! pki::copy_file $file; then
    # create file and try to copy it again
    kube::log::fatal "There is no src file $file, please fix it"
  fi
}

pki::place_master_file() {
  file=$1
  if ! pki::copy_file $file; then
    # create file and try to copy it again
    kube::log::fatal "There is no src file $file, please fix it"
  fi
}

