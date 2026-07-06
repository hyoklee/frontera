#!/bin/bash
#SBATCH -J clio-cluster4
#SBATCH -p development
#SBATCH -N 4
#SBATCH --ntasks-per-node 1
#SBATCH -t 00:30:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/cluster4-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/cluster4-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Test that N Frontera nodes (submitted with -N 4) form a clio-core cluster
# over the InfiniBand fabric (ib0 / IPoIB). Generalizes the 2-node test:
#  - hostfile lists every node's ib0 address (bootstrap first) so all cluster
#    RPC (ZeroMQ, port 9413) flows over IB, not the em1 management ethernet.
#  - all nodes run `clio_run runtime start` (inside apptainer) symmetrically &
#    simultaneously; wait_for_restart lets them sync. No --induct.
#  - CLIO_RESTART_LOG points at a fresh per-job file (default ~/.clio/
#    restart_log.bin auto-mounts into the container and would replay stale WAL).
# Every node writes its log into the shared $WORK dir so node 0 reads them all.

set -eo pipefail

APPTAINER=/opt/apps/tacc-apptainer/1.4.1/bin/apptainer
SIF=/work2/11623/hyoklee/frontera/clio-deps-cpu.sif
CLIO_RUN=/work2/11623/hyoklee/frontera/build/clio-core/bin/clio_run
WORKROOT=/work2/11623/hyoklee
SHARED=/work2/11623/hyoklee/frontera/build/cluster4-$SLURM_JOB_ID
CONF=$SHARED/clio_config.yaml
HOSTFILE=$SHARED/hostfile
RESTART_LOG=$SHARED/restart_log.bin
PORT=9413
mkdir -p "$SHARED"

NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
N=${#NODES[@]}
BOOT=${NODES[0]}
echo "===== $N nodes: ${NODES[*]}  (bootstrap=$BOOT) ====="

# ib0 IPoIB address of a node (absolute /usr/sbin/ip: ssh PATH omits sbin).
IBCMD="/usr/sbin/ip -4 -o addr show ib0 | awk '{print \$4}' | cut -d/ -f1 | head -1"
declare -A IB
IB[$BOOT]=$(eval "$IBCMD")
for n in "${NODES[@]:1}"; do
    IB[$n]=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$n" "$IBCMD")
done
BOOT_IB=${IB[$BOOT]}
PEER_IPS=(); for n in "${NODES[@]:1}"; do PEER_IPS+=("${IB[$n]}"); done
echo "bootstrap ib0=$BOOT_IB   peers ib0=${PEER_IPS[*]}"
for n in "${NODES[@]}"; do [ -n "${IB[$n]}" ] || { echo "ERROR: no ib0 for $n" >&2; exit 1; }; done

# hostfile (every node's ib0 IP, bootstrap first) + runtime config
: > "$HOSTFILE"; for n in "${NODES[@]}"; do echo "${IB[$n]}" >> "$HOSTFILE"; done
echo "===== hostfile ====="; cat "$HOSTFILE"
cat > "$CONF" <<YAML
networking:
  port: $PORT
  hostfile: $HOSTFILE
  neighborhood_size: 32
  wait_for_restart: 45
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

ENVSET="export CLIO_SERVER_CONF=$CONF CTP_LOG_LEVEL=info CLIO_RESTART_LOG=$RESTART_LOG;"
RUN="$APPTAINER exec --cleanenv --bind $WORKROOT:$WORKROOT $SIF bash -c '$ENVSET exec $CLIO_RUN runtime start'"
STOP="$APPTAINER exec --cleanenv --bind $WORKROOT:$WORKROOT $SIF bash -c '$ENVSET $CLIO_RUN runtime stop'"
CLEAN='rm -f /dev/shm/chi_* 2>/dev/null || true'
BOOT_LOG=$SHARED/log-$BOOT.log
logof() { echo "$SHARED/log-$1.log"; }

cleanup() {
    echo "===== teardown ====="
    eval "$STOP" 2>/dev/null || true
    for n in "${NODES[@]:1}"; do ssh -o BatchMode=yes "$n" "$STOP" 2>/dev/null || true; done
    sleep 2
    kill "$BOOT_PID" 2>/dev/null || true
    pkill -f clio_run 2>/dev/null || true
    for n in "${NODES[@]:1}"; do ssh -o BatchMode=yes "$n" "pkill -f clio_run 2>/dev/null; $CLEAN" 2>/dev/null || true; done
    eval "$CLEAN"
}
trap cleanup EXIT

# Clean slate everywhere.
eval "$CLEAN"; for n in "${NODES[@]:1}"; do ssh -o BatchMode=yes "$n" "$CLEAN" 2>/dev/null || true; done

# --- start ALL runtimes (peers via ssh, then bootstrap local) ----------------
for n in "${NODES[@]:1}"; do
    echo "===== starting peer runtime on $n (${IB[$n]}) ====="
    ssh -o BatchMode=yes "$n" "nohup $RUN > $(logof "$n") 2>&1 < /dev/null &"
done
echo "===== starting bootstrap runtime on $BOOT ($BOOT_IB) ====="
eval "$RUN" > "$BOOT_LOG" 2>&1 &
BOOT_PID=$!

# --- wait until bootstrap has a cluster link to EVERY peer over ib0 ----------
echo "===== waiting for $N-node cluster formation (up to 120s) ====="
formed=0
for i in $(seq 1 120); do
    all=1
    for ip in "${PEER_IPS[@]}"; do
        grep -qE "onnection established to $ip:$PORT" "$BOOT_LOG" 2>/dev/null || { all=0; break; }
    done
    if [ "$all" -eq 1 ]; then formed=1; echo "bootstrap linked to all $((N-1)) peers after ~${i}s"; break; fi
    if ! kill -0 "$BOOT_PID" 2>/dev/null; then echo "ERROR: bootstrap died early"; break; fi
    sleep 1
done

# Stability window, then check liveness + corroborating evidence.
sleep 10
boot_alive=0; kill -0 "$BOOT_PID" 2>/dev/null && boot_alive=1
alive=$boot_alive
for n in "${NODES[@]:1}"; do
    a=$(ssh -o BatchMode=yes "$n" "pgrep -f 'clio_run runtime start' >/dev/null && echo 1 || echo 0" 2>/dev/null)
    [ "$a" = "1" ] && alive=$((alive+1))
done
n_containers=0; grep -qE "with $N containers \(one per node\)" "$BOOT_LOG" 2>/dev/null && n_containers=1
# reciprocal: each peer opened a link back to the bootstrap over ib0
reciprocal=0
for n in "${NODES[@]:1}"; do
    grep -qE "onnection established to $BOOT_IB:$PORT" "$(logof "$n")" 2>/dev/null && reciprocal=$((reciprocal+1))
done

echo ""
echo "===== EVIDENCE: bootstrap $BOOT ($BOOT_IB) ====="
grep -nE "onnection established to|with $N containers|marked as ALIVE|Successfully started local server" "$BOOT_LOG" 2>/dev/null | head -30 || true
for n in "${NODES[@]:1}"; do
    echo "----- peer $n (${IB[$n]}) -----"
    grep -nE "onnection established to|Successfully started local server" "$(logof "$n")" 2>/dev/null | head -6 || true
done

echo ""
echo "formed=$formed  nodes_alive=$alive/$N  peers_linked_back=$reciprocal/$((N-1))  n_containers($N)=$n_containers"
if [ "$formed" -eq 1 ] && [ "$alive" -eq "$N" ] && [ "$n_containers" -eq 1 ] && [ "$reciprocal" -eq "$((N-1))" ]; then
    echo "RESULT: PASS - $N nodes formed a clio-core cluster over ib0 (InfiniBand)."
    echo "        bootstrap=$BOOT_IB  peers=${PEER_IPS[*]}  port=$PORT (ZeroMQ RPC over IPoIB)"
    RC=0
else
    echo "RESULT: FAIL - see logs in $SHARED"
    echo "--- bootstrap log (tail) ---"; tail -25 "$BOOT_LOG" 2>/dev/null
    RC=1
fi
exit $RC
