#!/bin/bash
#SBATCH -J clio-netprobe
#SBATCH -p development
#SBATCH -N 2
#SBATCH --ntasks-per-node 1
#SBATCH -t 00:15:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/netprobe-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/netprobe-%j.err

# Diagnostic for the 2-node cluster test:
#  - node list / hostname resolution
#  - InfiniBand interface name + IPoIB address per node
#  - whether compute->compute ssh works within the allocation
set -o pipefail
echo "===== SLURM_JOB_NODELIST=$SLURM_JOB_NODELIST ====="
NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
echo "nodes: ${NODES[*]}"
BOOT=${NODES[0]}; PEER=${NODES[1]}

echo "===== per-node network (srun -N2) ====="
srun -N2 --ntasks-per-node=1 --label bash -c '
    echo "host=$(hostname) hostname-i=$(hostname -i 2>/dev/null)"
    echo "  ib ifaces:"; ip -4 -o addr show 2>/dev/null | awk "\$2 ~ /^ib/ {print \"    \"\$2\" \"\$4}"
    echo "  all ipv4:"; ip -4 -o addr show 2>/dev/null | awk "{print \"    \"\$2\" \"\$4}" | grep -v " lo "
'

echo "===== compute->compute ssh test (BOOT=$BOOT -> PEER=$PEER) ====="
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$PEER" 'echo "ssh OK: I am $(hostname)"' 2>&1 || echo "ssh FAILED"

echo "===== clio_run present in container? ====="
SIF=/work2/11623/hyoklee/frontera/clio-deps-cpu.sif
/opt/apps/tacc-apptainer/1.4.1/bin/apptainer exec \
    --bind /work2/11623/hyoklee:/work2/11623/hyoklee \
    "$SIF" bash -c 'ls -l /work2/11623/hyoklee/frontera/build/clio-core/bin/clio_run && \
        /work2/11623/hyoklee/frontera/build/clio-core/bin/clio_run --help 2>&1 | head -15' 2>&1 | head -25
echo "===== probe done ====="
