#!/bin/bash
# vim: set sw=2 :

TAG1=${TAG1:-'v1.6.2'}
TAG2=${TAG2:-'v1.6.4'}

KUBERNETES_PATH='../../../../kubernetes'

addons='
  cluster/addons/dashboard                      dashboard-controller.yaml,
  cluster/addons/dashboard                      dashboard-service.yaml,
  cluster/addons/cluster-monitoring/influxdb    grafana-service.yaml,
  cluster/addons/cluster-monitoring/influxdb    heapster-controller.yaml,
  cluster/addons/cluster-monitoring/influxdb    heapster-service.yaml,
  cluster/addons/cluster-monitoring/influxdb    influxdb-grafana-controller.yaml,
  cluster/addons/cluster-monitoring/influxdb    influxdb-service.yaml,
  cluster/images/hyperkube                      kube-proxy-ds.yaml,
  cluster/addons/dns                            kubedns-cm.yaml,
  cluster/addons/dns                            kubedns-controller.yaml,
  cluster/addons/dns                            kubedns-sa.yaml,
  cluster/addons/dns                            kubedns-svc.yaml
'

manifests='
  cluster/images/hyperkube/static-pods          addon-manager-multinode.json,
  cluster/images/hyperkube/static-pod           master-multi.jsons
'

echo "Comparison Kubernetes files between tags $TAG1 $TAG2"
echo
echo $addons, $manifests | awk 'BEGIN { RS="," } {print $1 "/" $2 }' | while read f; do
  ( cd $KUBERNETES_PATH && git --no-pager diff $TAG1 $TAG2 -- $f )
done

