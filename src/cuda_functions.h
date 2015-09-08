#ifndef CUDA_FUNCTIONS_H
#define CUDA_FUNCTIONS_H
#include <cuda_runtime.h>
#include <stdint.h>
#include <assert.h>
#include "common.h"
#include <NTL/ZZ.h>
#ifdef CUFFTMUL
#include <cufft.h>
#endif

NTL_CLIENT

class CUDAFunctions{
  public:
  	static int N;
    #ifdef NTTMUL
    static cuyasheint_t wN;
    static cuyasheint_t *d_W;
    static cuyasheint_t *d_WInv;
    #elif defined(CUFFTMUL)
    static cufftHandle plan;
    #endif

    static cuyasheint_t* callPolynomialAddSub(cudaStream_t stream,cuyasheint_t *a,cuyasheint_t *b,int size,int OP);
    static cuyasheint_t* callPolynomialMul(cudaStream_t stream,cuyasheint_t *a,cuyasheint_t *b, int N, int NPolis);
    static void callPolynomialOPInteger(int opcode,cudaStream_t stream,cuyasheint_t *a,cuyasheint_t b,int N,int NPolis);
    static cuyasheint_t* callRealignCRTResidues(cudaStream_t stream,int oldSpacing,int newSpacing, cuyasheint_t *array,int residuesSize,int residuesQty);
    static void init(int N);
  private:
};
#ifdef NTTMUL
__device__ __host__ inline cuyasheint_t s_rem (uint64_t a);
__device__ __host__  uint64_t s_mul(uint64_t a,uint64_t b);
#endif

#endif

