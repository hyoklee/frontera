#!/bin/bash
#SBATCH -J miv-sif-build
#SBATCH -p normal
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 03:00:00
#SBATCH -A IBN22011
#SBATCH -o /work2/11623/hyoklee/frontera/build/miv-sif-%j.out
#SBATCH -e /work2/11623/hyoklee/frontera/build/miv-sif-%j.err
#SBATCH --mail-type=end,fail
#SBATCH --mail-user=hyoklee@hdfgroup.org
#
# Build the MiV-Simulator case-6 stack SIF on top of clio-deps-cpu.sif.
# Apptainer is blocked on Frontera login nodes, so this runs as a batch job;
# %post needs network (apt/pip/git) which Frontera compute nodes have.

set -eo pipefail
module load tacc-apptainer/1.4.1

DEF=/work2/11623/hyoklee/frontera.hyoklee/bin/miv-stack.def
SIF=/work2/11623/hyoklee/frontera/miv-stack.sif
export APPTAINER_CACHEDIR=$SCRATCH/apptainer-cache
export APPTAINER_TMPDIR=$SCRATCH/apptainer-tmp
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

echo "===== building $SIF from $DEF @ $(date) on $(hostname) ====="
# Unprivileged (proot) build; ran apt/pip in %post fine on the prior attempt.
apptainer build --force "$SIF" "$DEF"
echo "BUILD_OK"
echo "===== done @ $(date) ====="
ls -lh "$SIF"
