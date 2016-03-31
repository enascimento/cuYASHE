
#include "yashe.h"
#include "settings.h"
int Yashe::d = 0;
Polynomial Yashe::phi = Polynomial();
ZZ Yashe::q = ZZ(0);
bn_t Yashe::qDiv2;
Integer Yashe::t = 0;
Integer Yashe::delta = 0;
ZZ Yashe::w = ZZ(0);
int Yashe::lwq = 0;
Polynomial Yashe::h = Polynomial();
std::vector<Polynomial> Yashe::gamma;
Polynomial Yashe::f = Polynomial();
Polynomial Yashe::ff = Polynomial();
ZZ Yashe::WDMasking = ZZ(0);
std::vector<Polynomial> Yashe::P;


void Yashe::generate_keys(){
  #ifdef DEBUG
  std::cout << "generate_keys:" << std::endl;
  std::cout << "d: " << d << std::endl;
  std::cout << "phi: " << phi.to_string() << std::endl;
  std::cout << "q: " << Polynomial::global_mod << std::endl;
  std::cout << "t: " << t.get_value() << std::endl;
  std::cout << "w: " << w << std::endl;
  std::cout << "R: " << Polynomial::global_mod << std::endl;
  #endif

  Polynomial g = this->xkey.get_sample(phi.deg()-1);
  #ifdef DEBUG
  std::cout << "g = " << g.to_string() << std::endl;
  #endif

  // Computes a polynomial f with inverse
  Polynomial fInv;
  while(1==1){
    Polynomial fl = xkey.get_sample(phi.deg()-1);

    f = t*fl + 1;
    f.reduce();

    #ifdef DEBUG
    std::cout << "fl: " << fl.to_string() << std::endl;
    std::cout << "f: " << f.to_string() << std::endl;
    #endif
    try{
      // fInv = Polynomial::InvMod(f,phi);
      // fInv.normalize();
      fInv = f;

      break;
    } catch (exception& e)
    {
      #ifdef VERBOSE
      std::cout << "f has no modular inverse. " << e.what() << std::endl;
      #endif
    }
  }

  // Pre-computed value
  ff = f*f;
  ff.reduce();

  h = t*fInv*g;
  h.reduce();
  h.update_device_data();

  gamma.resize(lwq);
  for(int k = 0 ; k < lwq; k ++){
    gamma[k] = Polynomial(f);//Copy

    for(int j = 0; j < k;j ++){
      gamma[k] *= w;
    }

    Polynomial e = xerr.get_sample(phi.deg()-1);
    Polynomial s = xerr.get_sample(phi.deg()-1);

    Polynomial hs = h*s;
    hs.reduce();
    gamma[k] += e;
    gamma[k] += hs;
    gamma[k].reduce();
    gamma[k].update_crt_spacing(2*(phi.deg()-1));
    gamma[k].update_device_data();

    #ifdef DEBUG
    std::cout << "e = " << e.to_string() << std::endl;
    std::cout << "s = " << s.to_string() << std::endl;
    std::cout << "gamma[" << k << "] = " << gamma[k].to_string() << std::endl;
    #endif
  }

  // Word decomp mask
  WDMasking = NTL::LeftShift(ZZ(1),NumBits(Yashe::w))-1;

  //////////////////////////////////
  // Init static variables
  Yashe::ps.update_crt_spacing(2*phi.deg()-1);
  Yashe::e.update_crt_spacing(phi.deg()-1);
  //////////////////////////////////
  get_words(&qDiv2,q/2);
  //////////////////////////////////
  delta = (q/t.get_value()); // q/t
  //////////////////////////////////
  bn_t *d_P;
  const int N = 2*Polynomial::global_phi->deg()-1;
  const int size = N*lwq;

  P.clear();
  P.resize(lwq,N);
  cudaError_t result = cudaMalloc((void**)&d_P,size*sizeof(bn_t));
  assert(result == cudaSuccess);

  bn_t *h_P;
  h_P = (bn_t*)malloc(size*sizeof(bn_t));

  // #pragma omp parallel for
  for(int i = 0; i < size; i++)
    get_words(&h_P[i],to_ZZ(0));

  result = cudaMemcpy(d_P,h_P,size*sizeof(bn_t),cudaMemcpyHostToDevice);
  assert(result == cudaSuccess);

  for(int i = 0; i < lwq;i++){
    // cudaFree(P[i].d_bn_coefs);
    P[i].d_bn_coefs = d_P + i*N;
  }
  free(h_P);
  /////
  #ifdef VERBOSE
  std::cout << "Keys generated." << std::endl;
  #endif
}

Ciphertext Yashe::encrypt(Polynomial m){

  #ifdef DEBUG
  std::cout << "delta: "<< delta.get_value() <<std::endl;
  #endif
  /** 
   * ps will be used in a D degree multiplication, resulting in a 2*D degree polynomial
   * e will be used in a 2*D degree addition
   */
  xerr.get_sample(&ps,phi.deg()-1);
  xerr.get_sample(&e,phi.deg()-1);

  #ifdef DEBUG
  std::cout << "ps: "<< ps.to_string() <<std::endl;
  std::cout << "e: "<< e.to_string() <<std::endl;
  #endif
  
  Polynomial mdelta = delta*m;
  // ps *= h;
  // e += mdelta;
  // e += ps;
  assert(ps.get_crt_spacing() == h.get_crt_spacing());
  CUDAFunctions::callPolynomialMul( ps.get_device_crt_residues(),
                                    ps.get_device_crt_residues(),
                                    h.get_device_crt_residues(),
                                    (int)(ps.get_crt_spacing())*Polynomial::CRTPrimes.size(),
                                    ps.get_stream()
                                    );
  mdelta.update_crt_spacing(e.get_crt_spacing());
  assert(e.get_crt_spacing() == mdelta.get_crt_spacing());
  CUDAFunctions::callPolynomialAddSub(e.get_device_crt_residues(),
                                      e.get_device_crt_residues(),
                                      mdelta.get_device_crt_residues(),
                                      (int)(e.get_crt_spacing()*Polynomial::CRTPrimes.size()),
                                      ADD,
                                      e.get_stream());
  assert(e.get_crt_spacing() == ps.get_crt_spacing());
  CUDAFunctions::callPolynomialAddSub(e.get_device_crt_residues(),
                                      e.get_device_crt_residues(),
                                      ps.get_device_crt_residues(),
                                      (int)(e.get_crt_spacing()*Polynomial::CRTPrimes.size()),
                                      ADD,
                                      e.get_stream());
  e.reduce(); // Bad bad performance

  Ciphertext c = e;
  return c;
}

Polynomial Yashe::decrypt(Ciphertext c){
  #ifdef VERBOSE
  std::cout << "Yashe decrypt" << std::endl;
  #endif
  // std::cout << "f " << f.to_string() << std::endl;
  // std::cout << "c " << c.to_string() << std::endl;
  // uint64_t start,end;

  Polynomial m;

  if(c.aftermul){
    #ifdef VERBOSE
    std::cout << "aftermul" << std::endl;
    #endif
    m = ff*c;    
    // std::cout << "f*f:" << g.to_string() << std::endl;
    // std::cout << "f*f*c:" << g.to_string() << std::endl;

  }else{
    #ifdef VERBOSE
    std::cout << "not  aftermul" << std::endl;
    #endif
    // f.set_crt_residues_computed(false);
    m = f*c;
  }
  m.reduce();

  m.set_device_crt_residues( 
    CUDAFunctions::callPolynomialOPInteger( MUL,
      m.get_stream(),
      m.get_device_crt_residues(),
      Yashe::t.get_device_crt_residues(),
      m.get_crt_spacing(),
      Polynomial::CRTPrimes.size()
    )
  );
  m.icrt();
  callMersenneDiv(  m.d_bn_coefs, 
                    Yashe::q, 
                    m.get_crt_spacing(), 
                    m.get_stream());
  m.set_transf_computed(false);
  m.set_itransf_computed(false);
  m.set_crt_computed(false);
  m.set_icrt_computed(true);
  m.set_host_updated(false);
  return m;
}