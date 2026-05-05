CPU:
slurm command for resouce allocation: salloc --partition=project_l --nodes=1 --tasks-per-node=96 --mem=256G --gres=gpu:1

module load nvhpc-openmpi4

mkdir build_cpu
cd build_cpu
cmake -DPARTHENON_DISABLE_HDF5=ON  -DPARTHENON_ENABLE_PYTHON_MODULE_CHECK=OFF -DCMAKE_CXX_FLAGS="--diag_suppress=code_is_unreachable" DREGRESSION_GOLD_STANDARD_SYNC=OFF  -DPARTHENON_ENABLE_TESTING=OFF -DCMAKE_BUILD_TYPE=Release ../
make -j
mpirun -np 96 build_cpu/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx{1,2,3}=128 parthenon/meshblock/nx{1,2,3}=16 parthenon/time/nlim=250 parthenon/mesh/numlevel=3

not sure about this command (probably works) - vtune: 

mpirun -np 96 vtune -collect hotspots -target-duration-type=medium -trace-mpi -r vtuneresults96_1_128_16_3 -- mpirun -n 96 ./buildwithcpu/benchmarks/burgers/burgers-benchmark   -i benchmarks/burgers/burgers.pin   parthenon/mesh/nx1=128   parthenon/mesh/nx2=128   parthenon/mesh/nx3=128   parthenon/meshblock/nx1=16   parthenon/meshblock/nx2=16   parthenon/meshblock/nx3=16   parthenon/time/nlim=250   parthenon/mesh/numlevel=3

--------------------


1 GPU example - you can only run with a gpu

salloc --partition=project_l --nodes=1 --mem=256G --ntasks=16 --cpus-per-task=1 --gres=gpu:1

git clone --recursive https://github.com/parthenon-hpc-lab/parthenon.git
cd parthenon
mkdir build_gpu
cd build_gpu/
cmake -DKokkos_ENABLE_CUDA=ON -DPARTHENON_DISABLE_HDF5=ON ../
make -j
cd ..

ml gcc/10.3.0 openmpi/4.1.6-cuda

mpirun -n 1 ./buildwithgpu2/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx1=128 parthenon/mesh/nx2=128 parthenon/mesh/nx3=128 parthenon/meshblock/nx1=16 parthenon/meshblock/nx2=16 parthenon/meshblock/nx3=16 parthenon/time/nlim=20 parthenon/mesh/numlevel=3

Using MPS:

nvidia-cuda-mps-control -d

mpirun -n 16 --map-by ppr:16:node:pe=1 ./buildwithgpu2/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx1=128 parthenon/mesh/nx2=128 parthenon/mesh/nx3=128 parthenon/meshblock/nx1=16 parthenon/meshblock/nx2=16 parthenon/meshblock/nx3=16 parthenon/time/nlim=20 parthenon/mesh/numlevel=3

Using vtune with GPUs
module load vtune
mpirun -n 1 vtune -collect hotspots -target-duration-type=medium -trace-mpi -r vtuneresults1_16_128_16_3 -- ./build_gpu/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx1=128 parthenon/mesh/nx2=128 parthenon/mesh/nx3=128 parthenon/meshblock/nx1=16 parthenon/meshblock/nx2=16 parthenon/meshblock/nx3=16 parthenon/time/nlim=250 parthenon/mesh/numlevel=3

--------------------

2 GPUs:

salloc --partition=project_l --nodes=1 --tasks-per-node=2 --mem=512G --gres=gpu:2

mpirun -n 2 ./build_gpu/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx{1,2,3}=128 parthenon/meshblock/nx{1,2,3}=16 parthenon/time/nlim=250 parthenon/mesh/numlevel=3

MPS is used to run with more ranks per GPU (ranks per GPU is the number of cores managing a GPU)

--------------------
MultiGPU, MultiRank:

nvidia-cuda-mps-control -d

mpirun -n 24 --map-by ppr:24:node -x CUDA_VISIBLE_DEVICES=0,1,2,3 ./build_gpu/benchmarks/burgers/burgers-benchmark -i benchmarks/burgers/burgers.pin parthenon/mesh/nx{1,2,3}=128 parthenon/meshblock/nx{1,2,3}=16 parthenon/time/nlim=250 parthenon/mesh/numlevel=3

--------------------

These are the major functions - read BACKGROUND section in the Parthenon_Characterised.pdf paper by Akash Poptani.
UpdateMeshBlockTree, RedistributeAndRefineMeshBlocks, SetBounds, SendBoundBufs, ReceiveBoundBufs
Burgers functions: WeightedSumData, CalculateFluxes, FillDerived

--------------------

Lighthouse server (Intel Sapphire Rapids and H100s):

Slurm server (Umich Lighthouse) with 16 nodes with 8 H100s and 96 Sapphire Rapid cores in each of them. But its shared so I hardly get access to the nodes.

Always run to see what resources are available:

for node in $(sinfo -p ramanvr -N -h -o "%N"); do echo "--- $node ---"; scontrol show node $node | grep -E "CfgTRES|AllocTRES"; done 

--------------------

Using Kokkos-tools - kokkos-tools:

KOKKOS_PROFILE_LIBRARY=/home/akashpt/kokkos-tools/install/lib64/--.so mpirun -n <num_procs> ./your_parthenon_executable [your_arguments]

../kokkos-tools/install/bin/kp_reader lh1801.arc-ts.umich.edu-4031272.dat

--------------------

Using nvprof

--------------------

vTune

--------------------

nvidia-smi

--------------------

Memory requirements  - top or htop 

--------------------

nsys - using nvidia NSIght compute and nvidia Nsight systems - profiling_tools/

--------------------

Whatever changes the agent is making in this directory "Parthenon_Project" - they have be recorded in RECORD.md