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

kube::cni::restart_docker() {
  systemctl daemon-reload
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

    # Clear mtu and bip when previously started in docker-bootstrap mode
    if [[ ! -z $(grep "mtu=" $conf) && ! -z $(grep "bip=" $conf) ]]; then
      sed -i 's/--mtu=.* --bip=.*//g' $conf
      restart=true
      kube::log::status "The mtu and bip parameters removed"
    fi

    local drop_in_dir=/etc/systemd/system/docker.service.d

    local execstart=$(grep '^ExecStart=[^[:space:]]' $conf \
        | sed 's/\(dockerd[[:space:]]\).*$/\1/')
    kube::cni::place_drop_in $drop_in_dir/execstart.conf <<EOF
[Service]
ExecStart=
$execstart --host=fd:// -H unix:///var/run/docker.sock -H tcp://127.0.0.1:4243 --ip-forward=true --iptables=true --raw-logs --ip-masq=true --selinux-enabled
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
    if [[ $restart == true ]]; then
      kube::cni::restart_docker
    fi
  fi
}
