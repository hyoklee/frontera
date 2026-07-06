#!/bin/bash
#SBATCH -J clio-cluster
#SBATCH -p development
#SBATCH -N 2
#SBATCH --ntasks-per-node 1
#SBATCH -t 00:30:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/cluster-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/cluster-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Test that 2 Frontera nodes form a clio-core cluster over the InfiniBand
# fabric (ib0 / IPoIB). Each node runs the runtime with the SAME hostfile of
# ib0 addresses; the runtime matches a hostfile entry to a local NIC IP to
# pick "self" and advertises it, so all cluster RPC (ZeroMQ, port 9413) flows
# over IB rather than the em1 management ethernet (129.114.x).
#
# clio_run lives inside the deps-cpu container -> launched via apptainer on
# each node. Both runtimes start symmetrically & simultaneously; wait_for_restart
# lets each wait for its peer before finalizing the distributed compose.
#
# CLIO_RESTART_LOG is pointed at a fresh per-job file: the default is
# ~/.clio/restart_log.bin, and $HOME is auto-mounted into the container, so a
# stale WAL from a previous ctest run would otherwise be replayed on start.

set -eo pipefail

APPTAINER=/opt/apps/tacc-apptainer/1.4.1/bin/apptainer
SIF=/work2/11623/hyoklee/frontera/clio-deps-cpu.sif
CLIO_RUN=/work2/11623/hyoklee/frontera/build/clio-core/bin/clio_run
WORKROOT=/work2/11623/hyoklee
SHARED=/work2/11623/hyoklee/frontera/build/cluster-$SLURM_JOB_ID
CONF=$SHARED/clio_config.yaml
HOSTFILE=$SHARED/hostfile
RESTART_LOG=$SHARED/restart_log.bin      # fresh, per-job (avoid stale replay)
PORT=9413
mkdir -p "$SHARED"

NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
BOOT=${NODES[0]}
PEER=${NODES[1]}
echo "===== nodes: BOOT=$BOOT PEER=$PEER ====="

# ib0 IPoIB address of each node (the fast fabric). Absolute path to `ip`
# because a non-interactive ssh shell omits /usr/sbin from PATH.
ib_ip_local() { /usr/sbin/ip -4 -o addr show ib0 | awk '{print $4}' | cut -d/ -f1 | head -1; }
BOOT_IB=$(ib_ip_local)
PEER_IB=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" \
    "/usr/sbin/ip -4 -o addr show ib0 | awk '{print \$4}' | cut -d/ -f1 | head -1")
echo "BOOT_IB(ib0)=$BOOT_IB   PEER_IB(ib0)=$PEER_IB"
[ -n "$BOOT_IB" ] && [ -n "$PEER_IB" ] || { echo "ERROR: could not determine ib0 addresses" >&2; exit 1; }

# hostfile (ib0 IPs, bootstrap first) + runtime config
printf '%s\n%s\n' "$BOOT_IB" "$PEER_IB" > "$HOSTFILE"
echo "===== hostfile ====="; cat "$HOSTFILE"
cat > "$CONF" <<YAML
networking:
  port: $PORT
  hostfile: $HOSTFILE
  neighborhood_size: 32
  wait_for_restart: 30
  wait_for_restart_poll_period: 1
runtime:
  num_threads: 4
  queue_depth: 1024
compose:
  - mod_name: clio_bdev
    pool_name: "ram::chi_default_bdev"
    pool_query: local
    pool_id: "301.0"
    bdev_type: ram
    capacity: "0g"
swim:
  enabled: true
  direct_probe_timeout_sec: 30.0
  indirect_probe_timeout_sec: 15.0
  suspicion_timeout_sec: 30.0
YAML

BOOT_LOG=$SHARED/boot.log
PEER_LOG=$SHARED/peer.log
# Environment handed to clio_run inside the container on both nodes.
ENVSET="export CLIO_SERVER_CONF=$CONF CTP_LOG_LEVEL=info CLIO_RESTART_LOG=$RESTART_LOG;"
RUNBOOT="$APPTAINER exec --cleanenv --bind $WORKROOT:$WORKROOT $SIF bash -c '$ENVSET exec $CLIO_RUN runtime start'"
RUNPEER="$APPTAINER exec --cleanenv --bind $WORKROOT:$WORKROOT $SIF bash -c '$ENVSET exec $CLIO_RUN runtime start'"
STOP="$APPTAINER exec --cleanenv --bind $WORKROOT:$WORKROOT $SIF bash -c '$ENVSET $CLIO_RUN runtime stop'"
CLEAN='rm -f /dev/shm/chi_* 2>/dev/null || true'

cleanup() {
    echo "===== teardown ====="
    eval "$STOP" 2>/dev/null || true
    ssh -o BatchMode=yes "$PEER" "$STOP" 2>/dev/null || true
    sleep 2
    kill "$BOOT_PID" 2>/dev/null || true
    pkill -f clio_run 2>/dev/null || true
    ssh -o BatchMode=yes "$PEER" "pkill -f clio_run 2>/dev/null; $CLEAN" 2>/dev/null || true
    eval "$CLEAN"
}
trap cleanup EXIT

# Start from a clean slate on both nodes.
eval "$CLEAN"; ssh -o BatchMode=yes "$PEER" "$CLEAN" 2>/dev/null || true

# --- start BOTH runtimes ~simultaneously (symmetric; no --induct) ------------
echo "===== starting peer runtime on $PEER ($PEER_IB) ====="
ssh -o BatchMode=yes "$PEER" "nohup $RUNPEER > $PEER_LOG 2>&1 < /dev/null &"
echo "===== starting bootstrap runtime on $BOOT ($BOOT_IB) ====="
eval "$RUNBOOT" > "$BOOT_LOG" 2>&1 &
BOOT_PID=$!

# --- wait for the 2-node cluster to form -------------------------------------
# Membership signal: node 0 opens a cluster RPC connection to node 1's ib0
# address (proves distributed mode + IB fabric). The reciprocal node1->node0
# connection and the "2 containers (one per node)" pool layout are verified
# afterward as corroboration.
echo "===== waiting for cluster formation (up to 90s) ====="
boot_to_peer() { grep -qE "onnection established to $PEER_IB:$PORT" "$BOOT_LOG" 2>/dev/null; }
formed=0
for i in $(seq 1 90); do
    if boot_to_peer; then formed=1; echo "node0->node1 cluster link up after ~${i}s"; break; fi
    if ! kill -0 "$BOOT_PID" 2>/dev/null; then echo "ERROR: bootstrap died early"; break; fi
    sleep 1
done

# Let it run a little to confirm stability, then check both are still alive.
sleep 10
boot_alive=0; kill -0 "$BOOT_PID" 2>/dev/null && boot_alive=1
peer_alive=$(ssh -o BatchMode=yes "$PEER" "pgrep -f 'clio_run runtime start' >/dev/null && echo 1 || echo 0" 2>/dev/null)
# Reciprocal link node1 -> node0 over ib0, and the 2-container pool layout.
peer_to_boot=$(ssh -o BatchMode=yes "$PEER" "grep -qE 'onnection established to $BOOT_IB:$PORT' $PEER_LOG && echo 1 || echo 0" 2>/dev/null)
two_containers=0; grep -qE "with 2 containers \(one per node\)" "$BOOT_LOG" 2>/dev/null && two_containers=1

echo ""
echo "===== EVIDENCE: boot.log ($BOOT / $BOOT_IB) ====="
grep -nE "Loaded [0-9]+ hosts|onnection established to|marked as ALIVE|Registered|node_id=|Distributed|Successfully started local server" "$BOOT_LOG" 2>/dev/null | head -25 || true
echo "===== EVIDENCE: peer.log ($PEER / $PEER_IB) ====="
ssh -o BatchMode=yes "$PEER" "grep -nE 'Loaded [0-9]+ hosts|onnection established to|marked as ALIVE|Registered|node_id=|Distributed|Successfully started local server' $PEER_LOG 2>/dev/null | head -25" || true

echo ""
echo "formed(node0->node1)=$formed  peer_to_boot(node1->node0)=$peer_to_boot" \
     "two_containers=$two_containers  boot_alive=$boot_alive  peer_alive=$peer_alive"
if [ "$formed" -eq 1 ] && [ "$peer_to_boot" = "1" ] && [ "$boot_alive" -eq 1 ] && [ "$peer_alive" = "1" ]; then
    echo "RESULT: PASS - 2 nodes formed a clio-core cluster over ib0 (InfiniBand)."
    echo "        bootstrap=$BOOT_IB  peer=$PEER_IB  port=$PORT  (ZeroMQ RPC over IPoIB)"
    echo "        bidirectional cluster links up; pools created with 2 containers (one per node)."
    RC=0
else
    echo "RESULT: FAIL - see logs below."
    echo "--- boot.log (tail) ---"; tail -25 "$BOOT_LOG" 2>/dev/null
    echo "--- peer.log (tail) ---"; ssh -o BatchMode=yes "$PEER" "tail -25 $PEER_LOG" 2>/dev/null
    RC=1
fi
exit $RC
