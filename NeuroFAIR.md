Create a new slurm job that runs MiV simulation case 6.
Save slurm job scripts and other shell scripts into `bin/` directory.
All necessary repos such as clio-core, neuroh5, NeuroFAIR, MiV-Simulator, and MiV-Simulator-Cases for simulation are available under `/work2/11623/hyoklee/`
Always use the latest `dev` branch for `clio-core`.
If things don't work, make patches on new branches for each repo.
Place all build directories under `/work2/11623/hyoklee/frontier/`.
Test actual simulation case 6 in MiV-Simulator-Cases
using MiV-Simulator, neuroh5, and clio-core by submitting a slurm job.
Use Apptainer for simulation job by updating '/work2/11623/hyoklee/frontera/clio-deps-cpu.sif' with required modules.
Place large simulation input & output HDF5 files under either `/scratch2/11623/hyoklee` or `/scratch3/11623/hyoklee`.
Summarize simulation performance results in an .md file.
Update `NeuroFAIR/wiki` based on the test results.
If Python is necessary, use miniconda3 under $HOME/miniconda3.
Use envs under dependency download and linking.
