#!/usr/bin/env bash
# Clean teardown of the cluster ./up2.sh creates. Re-run ./up2.sh to recreate.
set -euo pipefail
CLUSTER=cluster2
kind delete cluster --name "$CLUSTER"
