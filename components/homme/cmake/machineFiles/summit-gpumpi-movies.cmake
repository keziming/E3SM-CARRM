#interactive job
#bsub -W 2:00 -nnodes 1 -P cli115 -Is /bin/bash


#SET (HOMMEXX_MPI_ON_DEVICE FALSE CACHE BOOL "")
SET (HOMMEXX_CUDA_MAX_WARP_PER_TEAM "16" CACHE STRING  "")

SET (NETCDF_DIR $ENV{OLCF_NETCDF_FORTRAN_ROOT} CACHE FILEPATH "")
SET (HDF5_DIR $ENV{OLCF_HDF5_ROOT} CACHE FILEPATH "")

#for scorpio
SET (NetCDF_C_PATH $ENV{OLCF_NETCDF_ROOT} CACHE FILEPATH "")

#SET(BUILD_HOMME_WITHOUT_PIOLIBRARY TRUE CACHE BOOL "")

SET(HOMME_FIND_BLASLAPACK TRUE CACHE BOOL "")

SET(WITH_PNETCDF FALSE CACHE FILEPATH "")

SET(USE_QUEUING FALSE CACHE BOOL "")

SET(ENABLE_CUDA FALSE CACHE BOOL "")

SET(BUILD_HOMME_PREQX_KOKKOS TRUE CACHE BOOL "")
SET(BUILD_HOMME_THETA_KOKKOS TRUE CACHE BOOL "")
SET(HOMME_ENABLE_COMPOSE FALSE CACHE BOOL "")

#SET (HOMMEXX_BFB_TESTING TRUE CACHE BOOL "")
SET (AVX_VERSION 0 CACHE STRING "")

SET(USE_TRILINOS OFF CACHE BOOL "")

SET(Kokkos_ENABLE_OPENMP OFF CACHE BOOL "")
SET(Kokkos_ENABLE_CUDA ON CACHE BOOL "")
SET(Kokkos_ENABLE_CUDA_LAMBDA ON CACHE BOOL "")
SET(Kokkos_ARCH_VOLTA70 ON CACHE BOOL "")
SET(Kokkos_ENABLE_EXPLICIT_INSTANTIATION OFF CACHE BOOL "")
SET(Kokkos_ENABLE_CUDA_ARCH_LINKING OFF CACHE BOOL "")

SET(CMAKE_C_COMPILER "mpicc" CACHE STRING "")
SET(CMAKE_Fortran_COMPILER "mpifort" CACHE STRING "")
SET(CMAKE_CXX_COMPILER "/ccs/home/onguba/kokkos/bin/nvcc_wrapper" CACHE STRING "")

set (ENABLE_OPENMP OFF CACHE BOOL "")
set (ENABLE_COLUMN_OPENMP OFF CACHE BOOL "")
set (ENABLE_HORIZ_OPENMP OFF CACHE BOOL "")

set (HOMME_TESTING_PROFILE "dev" CACHE STRING "")

set (USE_NUM_PROCS 4 CACHE STRING "")

#set (OPT_FLAGS "-mcpu=power9 -mtune=power9" CACHE STRING "")

#temp change to have bngry exchange file compile with cuda
#will get rid of this later
set (OPT_FLAGS "--save-temps" CACHE STRING "")

SET (USE_MPI_OPTIONS "--bind-to core" CACHE FILEPATH "")
