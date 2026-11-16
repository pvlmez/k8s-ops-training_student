# Lab 10: a shortcut for talking to Redis. Load it into your shell with
#
#   source labs/files/lab-10/redis-cli.sh
#
# (again in every new terminal). You then have:
#
#   rcli <pod> <redis command>     runs redis-cli inside that pod, logged in.
#                                  Example:  rcli redis-0 info replication
#
# The password never appears on your screen: inside the pod, the script
# /scripts/password.sh reads it from the file that the Vault agent wrote.
# shellcheck shell=bash

rcli() {
  local pod=${1:?give a pod name first, for example: rcli redis-0 ping}
  shift
  # shellcheck disable=SC2016
  kubectl -n redis exec "$pod" -c redis -- sh -c '. /scripts/password.sh; exec redis-cli "$@"' redis-cli "$@"
}

echo "Loaded: rcli. Try:  rcli redis-0 ping"
