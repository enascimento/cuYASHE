#include <omp.h>
#include <assert.h>
#include <string.h>
#include "polynomial.h"
#include "integer.h"
#include "settings.h"
#include "common.h"
#include "cuda_bn.h"

ZZ Polynomial::CRTProduct = ZZ(1);
std::vector<cuyasheint_t> Polynomial::CRTPrimes(0);
std::vector<ZZ> Polynomial::CRTMpi;
std::vector<cuyasheint_t> Polynomial::CRTInvMpi;
ZZ Polynomial::global_mod = ZZ(0);
Polynomial *(Polynomial::global_phi) = NULL;
bool Polynomial::phi_set = false;


Polynomial Polynomial::operator+(Polynomial &b){
  return common_addition<Polynomial>(this,&b);
}

Polynomial Polynomial::operator+=(Polynomial &b){
  common_addition_inplace<Polynomial>(this,&b);
  return *this;
}

Polynomial Polynomial::operator*(Polynomial &b){
  return common_multiplication<Polynomial>(this,&b);
}

Polynomial Polynomial::operator*(ZZ b){
      Polynomial p(*this);
      if(!p.get_host_updated()){
        // Operate on device
        Integer I = b;
        return I*p;
        }else{
        //#pragma omp parallel for
        for(int i = 0; i <= p.deg();i++)
          p.set_coeff(i,p.get_coeff(i)*b);
        p.set_device_updated(false);
      }
      return p;
    }

void Polynomial::operator delete(void *ptr){
  Polynomial *p = (Polynomial*)ptr;

  if(p->get_device_crt_residues() != 0x0){
    try
    {
      // std::cout << "Delete: cudaFree" << std::endl;
      cudaError_t result = cudaFree(p->get_device_crt_residues());
      if(result != cudaSuccess)
        throw string( cudaGetErrorString(result));
      
    }catch(string s){
      #ifdef VERBOSE
      std::cout << "Exception at cudaFree: " << s << std::endl;
      #endif 
      cudaGetLastError();//Reset last error
    }
  }

  // free(ptr);
}

void Polynomial::copy_device_crt_residues(Polynomial &b){
  // uint64_t start,end;

  // start = get_cycles();
  if(!b.get_device_updated())
    return;

  // std::cout << "Will copy residues on device memory" << std::endl;


  // Adjusts CRTSPACING
  // Here we don't use update_crt_spacing(). The reason
  // is: speed and context.
  // update_crt_spacing() may not just update the spacing, but
  // also update device data. And in this context, we know
  // that there is no relevant data to update.
  cuyasheint_t *aux;
  this->CRTSPACING = b.get_crt_spacing();

  cudaError_t result = cudaMalloc((void**)&aux,
                      this->get_crt_spacing()*(Polynomial::CRTPrimes.size())*sizeof(cuyasheint_t));
  assert(result == cudaSuccess);
  result = cudaMemcpyAsync(aux,
                      b.get_device_crt_residues(),
                      this->get_crt_spacing()*(Polynomial::CRTPrimes.size())*sizeof(cuyasheint_t),
                      cudaMemcpyDeviceToDevice);      
  assert(result == cudaSuccess);

  this->set_device_crt_residues(aux);
  // end = get_cycles();
  // std::cout << (end-start) << " cycles" << std::endl;
}
/**
 * Initiates a new bn_t object
 * @param a input: operand
 */

////////////////////////
// Auxiliar functions //
////////////////////////
/**
 * get_words converts a NTL big integer
 * in our bn_t format
 * @param b output: word representation
 * @param a input: operand
 */
__host__ void get_words(bn_t *b,ZZ a){
  cudaError_t result = cudaDeviceSynchronize();
  assert(result == cudaSuccess);

  bn_new(b);
  for(ZZ x = a; x > 0; x=(x>>WORD),b->used++){
    if(b->used >= b->alloc)
      bn_grow(b,b->alloc+STD_BNT_ALLOC);
    b->dp[b->used] = conv<uint32_t>(x&UINT32_MAX);
  }
}

/**
 * Convert an array of words into a NTL ZZ
 * @param  a input:array of words
 * @return   output: NTL ZZ
 */
__host__ ZZ get_ZZ(bn_t *a){
  ZZ b = conv<ZZ>(0);
  for(int i = a->used-1; i >= 0;i--)
      b = (b<<WORD) | (a->dp[i]);
    
  return b;
}

void Polynomial::update_device_data(){
  /**
   * This function copy the polynomial to GPU's memory in bn_t format
   */

  if(this->get_device_updated())
    return;


  #if defined(VERBOSE) || defined(VERBOSEMEMORYCOPY) 
  std::cout << "Copying data to GPU." << std::endl;
  #endif


  this->ON_COPY = true;
  // Updated CRTSPACING    
  // Verifica se o espaçamento é válido. Se não for, ajusta.
  if(this->get_crt_spacing() < this->deg()+1){
    const int new_spacing = this->deg()+1;

    // Data on device isn't updated (we check it on begginning)
    // So, update_crt_spacing(int) will only update CRTSpacing and alloc memory
    this->update_crt_spacing(new_spacing);
  }

  if(bn_coefs.size() > 0){
    for(unsigned int i = 0; i < bn_coefs.size();i++){
          bn_free(bn_coefs[i]);
          cudaFree(bn_coefs[i]);
        }
    bn_coefs.clear();
  }
  
  /**
   * Converts ZZs to bn_t
   */
  bn_t *coefs;
  cudaMallocManaged((void**)&coefs,(this->deg()+1)*sizeof(bn_t));
  for(int i = 0; i <= this->deg(); i++){
      get_words(&coefs[i],get_coeff(i));
      bn_coefs.push_back(&coefs[i]);
    }

  /**
  *  CRT
  */
  crt( this->bn_coefs[0],
      this->get_device_crt_residues(),
      this->get_crt_spacing(),
      Polynomial::CRTPrimes.size(),
      this->get_stream()
    );

  cudaError_t result = cudaDeviceSynchronize();
  assert(result == cudaSuccess);

  this->ON_COPY = false;
  this->set_device_updated(true);
}

void Polynomial::update_host_data(){
  
    if(get_host_updated())
      return;
    if(!get_icrt_computed()){
          this->bn_coefs.clear();

          bn_t *coefs;
          cudaMallocManaged((void**)&coefs, this->get_crt_spacing()*sizeof(bn_t));
          cudaError_t result = cudaDeviceSynchronize();
          assert(result == cudaSuccess);
          for(unsigned int i =0; i < this->get_crt_spacing(); i++){

            bn_new(&coefs[i]);
            bn_coefs.push_back(&coefs[i]);
          }
          icrt( this->bn_coefs[0],
                this->get_device_crt_residues(),
                this->get_crt_spacing(),
                Polynomial::CRTPrimes.size(),
                this->get_stream()
              );
        }


    #ifdef VERBOSE
    std::cout << "Copying data to CPU." << std::endl;
    #endif

    assert(Polynomial::CRTPrimes.size() > 0);
    if(this->polyCRT.size() != Polynomial::CRTPrimes.size())
      this->polyCRT.resize(Polynomial::CRTPrimes.size());

    // Prepare this polynomial to receive this->deg()+1 coefficients
    if((int)coefs.size() <= this->deg())
      set_coeffs(this->deg()+1);

    cudaError_t result = cudaDeviceSynchronize();
    assert(result == cudaSuccess);

    /**
     * Convert bn_t to ZZ
     */
    this->set_coeffs(this->deg()+1);
    for(int i = 0; i <= this->deg(); i++){
      // ZZ coef = get_ZZ(bn_coefs[i]);
      ZZ coef = get_ZZ(bn_coefs[i]) % Polynomial::CRTProduct;
      this->set_coeff(i,coef);
    }
    
    this->set_host_updated(true);
}

void Polynomial::DivRem(Polynomial a,Polynomial b,Polynomial &quot,Polynomial &rem){
  // Returns x = a % b

  if(a.get_host_updated() == false && b.get_host_updated() == false){
    // Operates on GPU
    throw "DivRem for GPU not implemented yet";
  }else{
    if(!a.get_host_updated())
        a.update_host_data();

    if(!b.get_host_updated())
        b.update_host_data();
    
    // No need to reduce
    if(a.deg() <= 0)
      return;
    if(check_special_rem_format(b)){
      #ifdef VERBOSE
      std::cout << "Rem in special mode."<<std::endl;
      #endif

      const unsigned int half = b.deg()-1;     

      rem.set_coeffs(half+1);
      #pragma omp parallel for
      for(unsigned int i = 0;i <= half;i++)
        rem.set_coeff(i,a.get_coeff(i)-a.get_coeff(i+half+1));

    }else{
      throw "DivRem: I don't know how to div this!";
    }
  }
}

int isPowerOfTwo (unsigned int x){
  return ((x != 0) && !(x & (x - 1)));
}

void Polynomial::BuildNthCyclotomic(Polynomial *phi,unsigned int n){

  phi->set_coeffs();

  if(isPowerOfTwo(n)){
    #ifdef VERBOSE
    std::cout << n << " is power of 2" << std::endl;
    #endif
    phi->set_coeff(0,1);
    phi->set_coeff(n,1);
    return;
  }else{
    #ifdef VERBOSE
    std::cout << n << " is not power of 2" << std::endl;
    #endif

    std::vector<Polynomial> aux_phi( n+1);

    for (cuyasheint_t i = 1; i <= n; i++) {
       Polynomial t;
       t.set_coeff(0,ZZ(1));

       for (cuyasheint_t j = 1; j <= i-1; j++)
          if (i % j == 0)
             t *= aux_phi[j];

       Polynomial mono;
       mono.set_coeff(i,ZZ(1));
       aux_phi[i] = (mono - 1)/t;

      //  cout << aux_phi[i] << "\n";
    }
    *phi = aux_phi[n];
 }
}

Polynomial Polynomial::get_phi(){
      return *(Polynomial::global_phi);
    }
