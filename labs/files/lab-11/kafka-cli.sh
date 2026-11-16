# Lab 11: a shortcut for Kafka's own command line tools. Load it with
#
#   source labs/files/lab-11/kafka-cli.sh
#
# (again in every new terminal). You then have:
#
#   kt <tool> <arguments>     runs bin/kafka-<tool>.sh inside a broker pod,
#                             already pointed at the cluster.
#
#   kt topics --list
#   kt topics --describe --topic orders
#   kt consumer-groups --describe --group <group>
#   kt console-producer --topic <topic>            (reads lines from its input)
#   kt console-consumer --topic <topic> --from-beginning --max-messages 10
#   kt metadata-quorum describe --status
#
# The tools run in the pod platform-dual-role-0. To use another broker:
#   KAFKA_POD=platform-dual-role-1 kt topics --list
# shellcheck shell=bash

kt() {
  local tool=${1:?give a tool name first, for example: kt topics --list}
  shift
  kubectl -n kafka exec -i "${KAFKA_POD:-platform-dual-role-0}" -c kafka -- \
    "bin/kafka-$tool.sh" --bootstrap-server localhost:9092 "$@"
}

echo "Loaded: kt. Try:  kt topics --list"
