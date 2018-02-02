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

# Utility functions for Kubernetes in docker setup and for cni network plugin.

kube::cni::docker_conf() {
  systemctl cat docker | awk 'FNR==1 {print $2}'
}

kube::cni::remove_option() {
  sed -e "s/$1[^[:space:]]*[[:space:]]*//g"
}

kube::cni::add_option() {
  local opt=$1
  local var
  read var
  echo -n $var
  if ! echo $var | grep -qFw $opt; then
    echo " $opt"
  fi
}

kube::cni::restart_docker() {
  systemctl daemon-reload
  systemctl enable docker
  systemctl restart docker
  kube::log::status "Restarted docker with service file modification(s)"
}

kube::cni::place_drop_in() {
  local file=$1

  kube::util::assure_dir $(dirname $file)
  cat > $file.new
  if [[ -f $file && -z $(diff $file $file.new) ]]; then
    # drop-in file already exists and is the same as new, don't restart docker
    rm -f $file.new
  else
    # install new file and restart docker
    mv -f $file.new $file
    restart=true
    kube::log::status "Modified docker drop-in $file"
  fi
}

kube::cni::ensure_docker_settings() {

  if kube::helpers::command_exists systemctl; then
    restart=false
    local conf=$(kube::cni::docker_conf)

    local unit_file=/etc/systemd/system/docker.service
    local drop_in_dir=$unit_file.d

    # get rid of containerd as a separate unit, because of the bug
    # https://github.com/coreos/bugs/issues/1710
    if grep -qw containerd.service $conf; then
      kube::log::status "Docker unit file moved to $unit_file"
      cat $conf | kube::cni::remove_option containerd.service > $unit_file
      systemctl mask containerd
      systemctl stop containerd
      kube::log::status "Containerd unit is masked"
      restart=true
    fi

    local execstart=$(grep '^ExecStart=[^[:space:]]' $conf)
    local new_execstart=$(echo $execstart | \
        kube::cni::remove_option --containerd= | \
        kube::cni::remove_option --mtu= | \
        kube::cni::remove_option --bip= | \
        kube::cni::add_option '$DOCKER_OPTS')
    if [[ $execstart != $new_execstart ]]; then
      kube::cni::place_drop_in $drop_in_dir/execstart.conf <<EOF
[Service]
ExecStart=
$new_execstart
EOF
    fi

    kube::cni::place_drop_in $drop_in_dir/opts.conf <<EOF
[Service]
Environment=DOCKER_OPTS='-H unix:///var/run/docker.sock --ip-forward=true --iptables=true --ip-masq=true'
EOF

    # https://docs.docker.com/engine/userguide/networking/default_network/container-communication/#container-communication-between-hosts
    # In Docker 1.12 and earlier, the default FORWARD chain policy was ACCEPT
    kube::cni::place_drop_in $drop_in_dir/iptables-forward-accept.conf <<EOF
[Service]
ExecStartPost=/sbin/iptables -P FORWARD ACCEPT
EOF

    # Make a drop-in file for shared mounts, as /usr/lib isn't always writeable
    kube::cni::place_drop_in $drop_in_dir/shared-mounts.conf <<EOF
[Service]
MountFlags=
MountFlags=shared
EOF

    # Check if restart needed
    if kube::helpers::is_true $restart; then
      kube::cni::restart_docker
    fi
  fi
}
