#include <iostream>
#include <stdio.h>
#include <assert.h>
#include "cuda_functions.h"
#include "settings.h"
#include "polynomial.h"

int main(){
  #ifdef NTTMUL
  // Plan settings
  const int N = 8;
  const int batch = 2;

  CUDAFunctions::init(2*N);
  
  // Memory alloc
  cuyasheint_t *h_a;
  cuyasheint_t *h_b;
  cuyasheint_t *d_a1;
  cuyasheint_t *aux;
  cuyasheint_t *d_a2;

  h_a = (cuyasheint_t*)malloc(2*N*batch*sizeof(cuyasheint_t));
  h_b = (cuyasheint_t*)malloc(2*N*batch*sizeof(cuyasheint_t));

  cudaError_t result = cudaMalloc((void**)&d_a1,2*N*batch*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);
  result = cudaMalloc((void**)&d_a2,2*N*batch*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);
  result = cudaMalloc((void**)&aux,2*N*batch*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);

  // Data load
  std::cout << "a: "<< std::endl;
  for(unsigned int pol = 0; pol < batch;pol++)
    for(unsigned int coeff = 0; coeff < 2*N; coeff++){
      std::cout << "a"<<pol<<"[" << coeff << "] = ";     
      if(coeff < N)
        h_a[pol*(2*N) + coeff] = 42*(pol+1);
      else
        h_a[pol*(2*N) + coeff] = 0;
      std::cout << h_a[pol*N + coeff] << std::endl;
    }
  // Memcpy
  result = cudaMemcpy(d_a1,h_a,2*N*batch*sizeof(cuyasheint_t),cudaMemcpyHostToDevice);
  assert(result == cudaSuccess);

  // NTT
  result = cudaMemset((void*)aux,0,(2*N)*batch*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);
  CUDAFunctions::callNTT(2*N, batch, d_a1, aux,FORWARD);

  result = cudaMemcpy(d_a2,d_a1,2*N*batch*sizeof(cuyasheint_t),cudaMemcpyDeviceToDevice);
  assert(result == cudaSuccess);

  // Check 
  // Memcpy
  result = cudaMemcpy(h_b,d_a2,2*N*batch*sizeof(cuyasheint_t),cudaMemcpyDeviceToHost);
  for(unsigned int pol = 0; pol < batch;pol++){
    std::cout << "Check! " << pol << std::endl;
    for(unsigned int coeff = 0; coeff < 2*N; coeff++)
      std::cout << "h_b[" << coeff <<"]: " << h_b[pol*N + coeff] << std::endl;;
  }
  std::cout << "============"<<std::endl;

  result = cudaMemset((void*)aux,0,(2*N)*batch*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);
  CUDAFunctions::callNTT(2*N, batch,d_a2,aux,INVERSE);

  // Memcpy
  result = cudaMemcpy(h_b,d_a2,2*N*batch*sizeof(cuyasheint_t),cudaMemcpyDeviceToHost);

  for(unsigned int pol = 0; pol < batch;pol++){
    std::cout << "residue " << pol << std::endl;
    for(unsigned int coeff = 0; coeff < 2*N; coeff++)
      std::cout << "h_a" << pol << "[" << coeff <<"]: " << h_a[pol*N + coeff] << " == " << "h_b[" << coeff <<"]: " << h_b[pol*N + coeff]/(2*N) << std::endl;;
  }

  free(h_a);
  cudaFree(d_a1);
  cudaFree(d_a2);
  cudaFree(aux);
  #endif
}
