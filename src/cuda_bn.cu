#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cuda_runtime.h>
#include <iostream>
#include <stdio.h>
#include <assert.h>
#include "cuda_bn.h"
#include "settings.h"
#include "cuda_functions.h"
#include "polynomial.h"

__constant__ cuyasheint_t CRTPrimesConstant[PRIMES_BUCKET_SIZE];

__constant__ cuyasheint_t M[STD_BNT_WORDS_ALLOC];
__constant__ int M_used;
__constant__ cuyasheint_t u[STD_BNT_WORDS_ALLOC];
__constant__ int u_used;
__constant__ cuyasheint_t Mpis[STD_BNT_WORDS_ALLOC*PRIMES_BUCKET_SIZE];
__constant__ int Mpis_used[PRIMES_BUCKET_SIZE];
__constant__ cuyasheint_t invMpis[PRIMES_BUCKET_SIZE];

////////////////////////
// Auxiliar functions //
////////////////////////

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__host__ __device__ int max_d(int a,int b){
	return (a >= b)*a + (b > a)*b;
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__host__ __device__ int min_d(int a,int b){
	return (a <= b)*a + (b < a)*b;
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__device__ void swap_d(bn_t *a,bn_t *b){
	bn_t tmp = *a;
	*a = *b;
	*b = tmp;
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__device__ int isZero(int x) {
    unsigned zero;
    zero = x;
    zero = 1 ^ ((zero | -zero) >> 31) & 1;
    return zero;    
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__device__ int isNotZero(int x){
	unsigned result = isZero(x);
	return isZero(result);
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__host__ __device__ uint64_t  lessThan(uint64_t x, uint64_t y) {    
    uint64_t less;    
    less = x-y;
    less >>= sizeof(uint64_t)*8-1;    
    return less;        
}

// /**
//  * [max_d description]
//  * @param  a [description]
//  * @param  b [description]
//  * @return   [description]
//  */
// __device__ unsigned greaterOrEqualThan(int x, int y){
// 	return lessThan(y,x);
// }

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__device__ unsigned isEqual(int x, int y) {    
    unsigned equal;    
    equal = x-y; // "equal" turns 0 if x = y    
    equal = 1 ^ ((equal | -equal) >> 31) & 1; // "equal" turns 1 iff enable was 0
    return equal;    
}

/**
 * [max_d description]
 * @param  a [description]
 * @param  b [description]
 * @return   [description]
 */
__host__ __device__ void dv_zero(cuyasheint_t *a, int digits) {
	int i;
 
	// if (digits > DV_DIGS) {
	// 	std::cout << "ERR_NO_VALID" << std::endl;
	// 	exit(1);
	// }	
	for (i = 0; i < digits; i++, a++)
		(*a) = 0;

	return;
}

/**
 * Set a big number struct to zero
 * @param a operand
 */
__host__ __device__ void bn_zero(bn_t *a) {
	a->sign = BN_POS;
	a->used = 0;
	dv_zero(a->dp, a->alloc);
}

__host__ __device__ void bn_zero_non_used(bn_t *a) {
	dv_zero(a->dp+a->used, a->alloc-a->used);
}

__host__ __device__ bool bn_is_zero(const bn_t* a) {
	#ifdef __CUDA_ARCH__
	/**
	 * This version doesn't have branchings, what is good for GPUs
	 */
		return !isEqual( isEqual(a->used,0) + isEqual(a->used,1)*isEqual(a->dp[0],0)
						,false);
	#else
		if (a->used == 0) {
			return true;
		}
		if ((a->used == 1) && (a->dp[0] == 0)) {
			return true;
		}
		return false;
	#endif
}

__global__ void bn_get_deg(int *r, bn_t *coefs, int N){
	/**
	 * This kernel must be executed by a single thread. 
	 */
	
	int index;
	for(index = N-1; index >= 0; index--){
		coefs[index].used = get_used_index(coefs[index].dp,coefs[index].alloc)+1;
		if(!bn_is_zero(&coefs[index]))
			break;
	}
	*r = index;
}

__host__ int callBNGetDeg(bn_t *coefs, int N){
	int *d_value;
	cudaError_t result = cudaMalloc((void**)&d_value,sizeof(int));
	assert(result == cudaSuccess);
	
	bn_get_deg<<<1,1,0>>>(d_value,coefs,N);
	result = cudaGetLastError();
	assert(result == cudaSuccess);

	int h_value;
	result = cudaMemcpy(&h_value,d_value,sizeof(int),cudaMemcpyDeviceToHost);
	assert(result == cudaSuccess);

	return h_value;
}

/**
 * Set a big number to digit
 * @param a     input: big number
 * @param digit input: digit
 */
__host__ __device__ void bn_set_dig(bn_t *a, cuyasheint_t digit) {
	bn_zero(a);	
	a->dp[0] = digit;
	a->used = 1;
	a->sign = BN_POS;
}

__host__ void bn_new(bn_t *a){
  a->used = 0;
  a->alloc = STD_BNT_WORDS_ALLOC;
  a->sign = BN_POS;
  // std::cout << "Will alloc " << (a->alloc*sizeof(cuyasheint_t)) << " bytes" << std::endl;
  a->dp = (cuyasheint_t*) malloc(a->alloc*sizeof(cuyasheint_t));
}

// __device__ void bn_new_d(bn_t *a){
//   a->used = 0;
//   a->alloc = STD_BNT_WORDS_ALLOC;
//   a->sign = BN_POS;
//   cudaMalloc(&a->dp,a->alloc*sizeof(cuyasheint_t));
// }

__host__ void bn_free(bn_t *a){
  if(a->dp != NULL && a->alloc > 0){
	cudaError_t result = cudaFree((a->dp));
	if(result != cudaSuccess){
		std::cout << cudaGetErrorString(result) << std::endl;
		cudaGetLastError();//Reset
	}
  	// assert(result == cudaSuccess);
  }

  a->used = 0;
  a->alloc = 0;  

}

__host__ __device__ int bn_cmpn_low(const cuyasheint_t *a, const cuyasheint_t *b, int size) {
	int i, r;

	a += (size - 1);
	b += (size - 1);

	r = CMP_EQ;
	for (i = 0; i < size; i++, --a, --b) {
		r = 			r				*(!((*a != *b) && r == CMP_EQ)) + 
			((*a > *b)*CMP_GT + (*a <= *b)*CMP_LT)*(*a != *b && r == CMP_EQ);
	}
	return r;
}


__host__ __device__ int bn_cmp_abs(const bn_t *a, const bn_t *b) {
	if(a->used != b-> used)
		return CMP_GT*(a->used > b->used) + CMP_LT*(a->used < b->used); 
	else
		return bn_cmpn_low(a->dp, b->dp, a->used);
}

/**
 * Increase the allocated memory for a bn_t object.
 * @param a        input/output:operand
 * @param new_size input: new_size for dp
 */
__host__ void bn_grow(bn_t *a,const unsigned int new_size){
  // We expect that a->alloc <= new_size
  if((unsigned int)a->alloc > new_size)
  	return;

  std::cout << "Will grow " << (new_size*sizeof(cuyasheint_t)) << " bytes" << std::endl;

  cudaMalloc((void**)(&(a->dp)+a->alloc),new_size*sizeof(cuyasheint_t));
  a->alloc = new_size;

}

__host__ __device__ void bn_2_compl(bn_t *a){
	for(int i = 0; i < a->used; i++)
		a->dp[i] = (a->dp[i]^UINT64_MAX)+1; 
}

////////////////
// Operators //
//////////////

// Mod
__host__ __device__ cuyasheint_t bn_mod1_low(	const uint64_t *a,
												const int size,
												const uint32_t b) {
	// Computes a % b, where b is a one-word number
	
	uint64_t w;
	uint32_t r;
	int i;

	w = 0;
	for (i = size - 1; i >= 0; i--) {
		// Second 32 bits word
		uint32_t hi = uint32_t(a[i] >> 32);
		w = ((w << ((uint64_t)32)) | ((uint64_t)hi))*(hi > 0) + w*(hi == 0);

		r = (uint32_t)(w/b)*(w >= b);
		w -= (((uint64_t)r) * ((uint64_t)b))*(w >= b || hi > 0);
		
		// First 32 bits word
		uint32_t lo = uint32_t(a[i] & 0xFFFFFFFF);
		w = (w << ((uint64_t)32)) | ((uint64_t)lo);

		r = (uint32_t)(w/b)*(w >= b);
		w -= (((uint64_t)r) * ((uint64_t)b))*(w >= b);
		
	}
	return (cuyasheint_t)w;
}

// Multiply 

/**
 * Computes a*digit
 * @param  c     output: result
 * @param  a     input: many-words first operand
 * @param  digit input: one-word second operand
 * @param  size  input: number of words in a
 * @return       output: result's last word
 */
__host__ __device__ cuyasheint_t bn_mul1_low(uint64_t *c,
											const uint64_t *a,
											uint64_t digit,
											int size) {
	int i;
	uint64_t carry;
	carry = 0;
	for (i = 0; i < size; i++, a++, c++) {	
  		#ifdef __CUDA_ARCH__
		////////////
  		// device //
		////////////
  		
		/**
		 * Multiply the digit *a by b and propagate the carry
		 */
		uint64_t lo = (*a)*digit;
		uint64_t hi = __umul64hi(*a,digit) + (lo + carry < lo);
		lo = lo + carry;

		/* Increment the column and assign the result. */
		*c = lo;
		/* Update the carry. */
		carry = hi;
		#else
		//////////
		// host //
		//////////
		__uint128_t r = (((__uint128_t)(*a)) * ((__uint128_t)digit) );
		*c = (r & 0xffffffffffffffffL);
		carry = (r>>64);
		#endif
	}

	#ifdef __CUDA_ARCH__
	__syncthreads();
	#endif

	return carry;
}

/**
 * Computes 64bits a*b mod c
 * @param result       output: result
 * @param a            input: first 64 bits operand
 * @param b            input: second 64 bits operand 
 * @param c 		   input: module
 */
__device__ void bn_64bits_mulmod(cuyasheint_t *result,
									cuyasheint_t a,
									cuyasheint_t b,
									uint32_t m
									){
	/////////
	// Mul //
	/////////
	uint64_t rHi = __umul64hi(a,b);
	uint64_t rLo = a*b;

	/////////
	// Mod //
	/////////
	uint64_t r[] = {	(uint64_t)(rLo & 0xFFFFFFFF),
						(uint64_t)(rLo >> 32),
						(uint64_t)(rHi & 0xFFFFFFFF),
						(uint64_t)(rHi >> 32) 
					};
	*result = bn_mod1_low(r,4,(uint64_t)m);
}

// Add

/**
 * Computes a+b
 * @param  c    output: result
 * @param  a    input: many-words first operand
 * @param  b    input: many-words second operand
 * @param  size input: number of words to add
 * @return      output: result's last word
 */
__host__ __device__ cuyasheint_t bn_addn_low(cuyasheint_t *c,
									cuyasheint_t *a,
									cuyasheint_t *b,
									const int size
									) {
	int i;
	register cuyasheint_t carry, c0, c1, r0, r1;

	carry = 0;
	for (i = 0; i < size; i++, a++, b++, c++) {
		r0 = (*a) + (*b);
		c0 = (r0 < (*a));
		r1 = r0 + carry;
		c1 = (r1 < r0);
		carry = c0 | c1;
		(*c) = r1;
	}
	return carry;
}

/**
 * [bn_add1_low description]
 * @param  c     [description]
 * @param  a     [description]
 * @param  digit [description]
 * @param  size  [description]
 * @return       [description]
 */
__host__ __device__ cuyasheint_t bn_add1_low(cuyasheint_t *c, const cuyasheint_t *a, cuyasheint_t digit, int size) {
	int i;
	register cuyasheint_t carry, r0;

	carry = digit;
	for (i = 0; i < size && carry; i++, a++, c++) {
		r0 = (*a) + carry;
		carry = (r0 < carry);
		(*c) = r0;
	}
	for (; i < size; i++, a++, c++) {
		(*c) = (*a);
	}
	return carry;
}


////////////////////////
// Subtract
////////////////////////
/**
 * bn_subn_low computes a-b. If a < b, returns 1. Else returns 0.
 * @param  c    [description]
 * @param  a    [description]
 * @param  b    [description]
 * @param  size [description]
 * @return      [description]
 */
__host__ __device__ cuyasheint_t bn_subn_low(cuyasheint_t * c, const cuyasheint_t * a,
		const cuyasheint_t * b, int size) {
	int i;
	cuyasheint_t carry, r0, diff;

	/* Zero the carry. */
	carry = 0;
	for (i = 0; i < size; i++, a++, b++, c++) {
		diff = (*a) - (*b);
		r0 = diff - carry;
		carry = ((*a) < (*b)) || (carry && !diff);
		(*c) = r0;
	}
	return carry;
}

/**
 * [bn_sub1_low description]
 * @param  c     [description]
 * @param  a     [description]
 * @param  digit [description]
 * @param  size  [description]
 * @return       [description]
 */
__host__ __device__ cuyasheint_t bn_sub1_low(cuyasheint_t *c, const cuyasheint_t *a, cuyasheint_t digit, int size) {
	int i;
	cuyasheint_t carry, r0;

	carry = digit;
	for (i = 0; i < size && carry; i++, c++, a++) {
		r0 = (*a) - carry;
		carry = (r0 > (*a));
		(*c) = r0;
	}
	for (; i < size; i++, a++, c++) {
		(*c) = (*a);
	}
	return carry;
}

/**
 * Accumulates a double precision digit in a triple register variable.
 *
 * @param[in,out] R2		- most significant word of the triple register.
 * @param[in,out] R1		- middle word of the triple register.
 * @param[in,out] R0		- lowest significant word of the triple register.
 * @param[in] A				- the first digit to multiply.
 * @param[in] B				- the second digit to multiply.
 */
// #ifdef __CUDA_ARCH__	

#define COMBA_STEP_BN_MUL_LOW(R2, R1, R0, A, B)														\
	uint64_t rHi = __umul64hi((uint64_t)(A) , (uint64_t)(B));										\
	uint64_t rLo = (uint64_t)(A) * (uint64_t)(B);													\
	uint64_t _r = (R1);																				\
	(R0) += rLo;																					\
	(R1) += (R0) < rLo;																				\
	(R2) += (R1) < _r;																				\
	(R1) += rHi;																					\
	(R2) += (R1) < rHi;

// #else

// #define COMBA_STEP_BN_MUL_LOW(R2, R1, R0, A, B)														\
// 	__uint128_t r = (__uint128_t)((uint64_t)(A))*(__uint128_t)((uint64_t)(B));						\
// 	uint64_t rHi = (r>>64);																			\
// 	uint64_t rLo = (r&0xffffffffffffffffL);															\
// 	uint64_t _r = (R1);																				\
// 	(R0) += rLo;																					\
// 	(R1) += (R0) < rLo;																				\
// 	(R2) += (R1) < _r;																				\
// 	(R1) += rHi;																					\
// 	(R2) += (R1) < rHi;
// #endif							

/**
 * Accumulates a single precision digit in a triple register variable.
 *
 * @param[in,out] R2		- most significant word of the triple register.
 * @param[in,out] R1		- middle word of the triple register.
 * @param[in,out] R0		- lowest significant word of the triple register.
 * @param[in] A				- the first digit to accumulate.
 */
#define COMBA_ADD(R2, R1, R0, A)											\
	cuyasheint_t __r = (R1);												\
	(R0) += (A);															\
	(R1) += (R0) < (A);														\
	(R2) += (R1) < __r;														\

/**
 * Multiplies two digit vectors of different sizes, with sizea > sizeb. 
 * Computes c = a * b. 
 * 
 * This function outputs as result only the digits between low and high,
 * 	inclusive, with high > sizea and low < sizeb.
 * @param c  [description]
 * @param a  [description]
 * @param sa [description]
 * @param b  [description]
 * @param sb [description]
 * @param l  [description]
 * @param h  [description]
 */
__device__ void bn_muld_low(cuyasheint_t * c, 
							const cuyasheint_t * a, 
							int sa,
							const cuyasheint_t * b, 
							int sb, 
							int l, 
							int h) {
	int i, j, ta;
	const cuyasheint_t *tmpa, *tmpb;
	cuyasheint_t r0, r1, r2;

	c += l;

	r0 = r1 = r2 = 0;
	for (i = l; i < sb; i++, c++) {
		tmpa = a;
		tmpb = b + i;
		for (j = 0; j <= i; j++, tmpa++, tmpb--) {
			COMBA_STEP_BN_MUL_LOW(r2, r1, r0, *tmpa, *tmpb);
		}
		*c = r0;
		r0 = r1;
		r1 = r2;
		r2 = 0;
	}
	ta = 0;
	for (i = sb; i < sa; i++, c++) {
		tmpa = a + ++ta;
		tmpb = b + (sb - 1);
		for (j = 0; j < sb; j++, tmpa++, tmpb--) {
			COMBA_STEP_BN_MUL_LOW(r2, r1, r0, *tmpa, *tmpb);
		}
		*c = r0;
		r0 = r1;
		r1 = r2;
		r2 = 0;
	}
	for (i = sa; i < h; i++, c++) {
		tmpa = a + ++ta;
		tmpb = b + (sb - 1);
		for (j = 0; j < sa - ta; j++, tmpa++, tmpb--) {
			COMBA_STEP_BN_MUL_LOW(r2, r1, r0, *tmpa, *tmpb);
		}
		*c = r0;
		r0 = r1;
		r1 = r2;
		r2 = 0;
	}
}

/**
 * Multiplies two digit vectors of the same size. Computes c = a * b.
 * @param c    [description]
 * @param a    [description]
 * @param b    [description]
 * @param size [description]
 */
__device__ void bn_muln_low(cuyasheint_t *c,
							const cuyasheint_t *a,
							const cuyasheint_t *b,
							int size 
						){
	int i, j;
	const cuyasheint_t *tmpa, *tmpb;
	cuyasheint_t r0, r1, r2;

	r0 = r1 = r2 = 0;
	for (i = 0; i < size; i++, c++) {
		tmpa = a;
		tmpb = b + i;
		for (j = 0; j <= i; j++, tmpa++, tmpb--) {
			COMBA_STEP_BN_MUL_LOW(r2, r1, r0, *tmpa, *tmpb);
		}
		*c = r0;
		r0 = r1;
		r1 = r2;
		r2 = 0;
	}
	for (i = 0; i < size; i++, c++) {
		tmpa = a + i + 1;
		tmpb = b + (size - 1);
		for (j = 0; j < size - (i + 1); j++, tmpa++, tmpb--) {
			COMBA_STEP_BN_MUL_LOW(r2, r1, r0, *tmpa, *tmpb);
		}
		*c = r0;
		r0 = r1;
		r1 = r2;
		r2 = 0;
	}

}

/**
 * [bn_mod_barrt description]
 * @param c  [description]
 * @param a  [description]
 * @param sa [description]
 * @param m  [description]
 * @param sm [description]
 * @param u  [description]
 * @param su [description]
 */

__device__ void bn_mod_barrt(	bn_t *C, const bn_t *A,const int NCoefs,
								const cuyasheint_t * m,  int sm, const cuyasheint_t * u, int su
							) {

	/**
	 * Each thread handles one coefficient
	 */
	
	const int cid = threadIdx.x + blockDim.x*blockIdx.x;

	if(cid < NCoefs){
		cuyasheint_t *a = A[cid].dp;
		int sa = A[cid].used;
		cuyasheint_t *c = C[cid].dp;

		unsigned long mu;
		cuyasheint_t q[2*STD_BNT_WORDS_ALLOC],t[2*STD_BNT_WORDS_ALLOC],carry;
		int sq, st;
		int i;

		mu = sm;
		sq = sa - (mu - 1);
		for (i = 0; i < sq; i++) 
			q[i] = a[i + (mu - 1)];
		
		if (sq > su) {
			bn_muld_low(t, q, sq, u, su, mu, sq + su);
		} else {
			bn_muld_low(t, u, su, q, sq, mu - (su - sq) - 1, sq + su);
		}
		st = sq + su;
		while (st > 0 && t[st - 1] == 0)
			--(st);
		

		sq = st - (mu + 1);
		for (i = 0; i < sq; i++)
			q[i] = t[i + (mu + 1)];

		if (sq > sm) 
			bn_muld_low(t, q, sq, m, sm, 0, sq + 1);
		else 
			bn_muld_low(t, m, sm, q, sq, 0, mu + 1);
		
		st = mu + 1;
		while (st > 0 && t[st - 1] == 0)
			st--;

		sq = mu + 1;
		for (i = 0; i < sq; i++) 
			q[i] = t[i];
		

		st = mu + 1;
		for (i = 0; i < sq; i++)
			t[i] = a[i];

		carry = bn_subn_low(t, t, q, sq);
		while (st > 0 && t[st - 1] == 0)
			st--;
		
		if (carry) {
			sq = (mu + 1);
			for (i = 0; i < sq - 1; i++) {
				q[i] = 0;
			}
			q[sq - 1] = 1;
			bn_subn_low(t, q, t, sq);
		}

		while (bn_cmpn_low(t, m, sm) == 1)
			bn_subn_low(t, t, m, sm);

		for (i = 0; i < st; i++)
			c[i] = t[i];
	}
}

/**
 * [cuModN description]
 * @param c      [description]
 * @param a      [description]
 * @param NCoefs [description]
 * @param m      [description]
 * @param sm     [description]
 * @param u      [description]
 * @param su     [description]
 */
__global__ void cuModN(bn_t * c, const bn_t * a, const int NCoefs,
		const cuyasheint_t * m, int sm, const cuyasheint_t * u, int su){
	/**
	 * This function should be executed with NCoefs threads
	 */
	const unsigned int tid = threadIdx.x + blockIdx.x*blockDim.x;
	if(tid < NCoefs)
		bn_mod_barrt(c,a,NCoefs,m,sm,u,su);
}

/**
 * [callCuModN description]
 * @param c      [description]
 * @param a      [description]
 * @param NCoefs [description]
 * @param m      [description]
 * @param sm     [description]
 * @param u      [description]
 * @param su     [description]
 * @param stream [description]
 */
__host__ void callCuModN(bn_t * c, const bn_t * a,int NCoefs,
		const cuyasheint_t * m, int sm, const cuyasheint_t * u, int su,
		cudaStream_t stream){

	const int size = NCoefs;
	int ADDGRIDXDIM = (size%ADDBLOCKXDIM == 0? 
			size/ADDBLOCKXDIM : 
			size/ADDBLOCKXDIM + 1);
	dim3 gridDim(ADDGRIDXDIM);
	dim3 blockDim(ADDBLOCKXDIM);

	cuModN<<<gridDim,blockDim,0,stream>>>(c,a,NCoefs,m,sm,u,su);
}
/////////
// CRT //
/////////

/**
 * @d_polyCRT - output: array of residual polynomials
 * @x - input: array of coefficients
 * @ N - input: qty of coefficients
 * @NPolis - input: qty of primes/residual polynomials
 */
__global__ void cuCRT(	cuyasheint_t *d_polyCRT,
						const bn_t *x,
						const int used_coefs,
						const unsigned int N,
						const unsigned int NPolis
						){
	/**
	 * This function should be executed with used_coefs*NPolis threads. 
	 * Each thread computes one residue of one coefficient
	 *
	 * x should be an array of N elements
	 * d_polyCRT should be an array of N*NPolis elements
	 */
	
	/**
	 * tid: thread id
	 * cid: coefficient id
	 * rid: residue id
	 */
	const unsigned int tid = threadIdx.x + blockIdx.x*blockDim.x;
	const unsigned int cid = tid % (used_coefs);
	const unsigned int rid = tid / (used_coefs);

	// x can be copied to shared memory!
	// 
	if(tid < used_coefs*NPolis)
		// Computes x mod pi
		d_polyCRT[cid + rid*N] = bn_mod1_low(	x[cid].dp,
												x[cid].used,
												CRTPrimesConstant[rid]
												);

}	

__device__ int get_used_index(cuyasheint_t *u,int alloc){
	int i = 0;
	// int max = 0;


	for(i = alloc-1; i >= 0; i--)
	/*
	 * Profiling shows that the branch is cheaper
	 */ 
		if(u[i] != 0)
			break;
		// max = i*isNotZero(u[i])*isZero(max) + max*isNotZero(max);


	return i;
}

__global__ void cuPreICRT(	cuyasheint_t *inner_results,
							cuyasheint_t *inner_results_used,
							const cuyasheint_t *d_polyCRT,
							const unsigned int N,
							const unsigned int NPolis
						){

	/**
	 * This kernel has a very bad access pattern in inner_results
	 */
	const int tid = threadIdx.x + blockIdx.x*blockDim.x;
	
	if(tid < N*NPolis){
	 	const int cid = tid % N;
	 	const int rid = tid / N;


		// Get a prime
		cuyasheint_t pi = CRTPrimesConstant[rid];

		/**
		 * Inner
		 */
		cuyasheint_t x;		
		bn_64bits_mulmod(	&x,
							invMpis[rid],
							d_polyCRT[cid + rid*N],
							pi);

		// Adjust available words in inner_result
		// assert(inner_result.alloc >= Mpis[rid].used+1);
		// bn_grow_d(&inner_result,1);
		int carry;
		carry = bn_mul1_low(	&inner_results[tid*STD_BNT_WORDS_ALLOC],
						     	&Mpis[rid*STD_BNT_WORDS_ALLOC],
						     	x,
						     	Mpis_used[rid]);

		inner_results_used[tid] = Mpis_used[rid];

		/** 
		 * The frequency of branching at this point is so low that 
		 * doing this is faster than using some non-branch technic
		 */
		if(carry){
			inner_results[tid*STD_BNT_WORDS_ALLOC + Mpis_used[rid]] = carry;	
			inner_results_used[tid] += 1;			
		}
	}
}

/**
 * cuICRT computes ICRT on GPU
 * @param poly      output: An array of coefficients 
 * @param d_polyCRT input: The CRT residues
 * @param N         input: Number of coefficients
 * @param NPolis    input: Number of residues
 */
__global__ void cuICRT(	bn_t *poly,
						const unsigned int N,
						const unsigned int NPolis,
						cuyasheint_t *inner_results,
						cuyasheint_t *inner_results_used
						){
	/**
	 * This function should be executed with N threads.
	 * Each thread j computes a Mpi*( invMpi*(value) % pi) and adds to poly[j]
	 */
	
	/**
	 * tid: thread id
	 * cid: coefficient id
	 * rid: residue id
	 */
	const int tid = threadIdx.x + blockIdx.x*blockDim.x;
	const int cid = tid;
	
	 if(tid < N){
	 	bn_t coef = poly[cid];
	 	bn_zero(&coef); 

	 	for(unsigned int rid = 0; rid < NPolis;rid++){
		 	cuyasheint_t *inner_result = &inner_results[(cid + rid*N)*STD_BNT_WORDS_ALLOC];

			/**
			 * Accumulate
			 */
			int nwords = max_d(coef.used,inner_results_used[(cid + rid*N)]);
			cuyasheint_t carry = bn_addn_low(coef.dp, coef.dp, inner_result,nwords);
			coef.used = nwords;

			/* Equivalent to "If has a carry, add as last word" */
			coef.dp[coef.used] = carry;
			coef.used += (carry > 0);
 		}

		////////////////////////////////////////////////
		// Modular reduction of poly[cid] by M //
		////////////////////////////////////////////////
 	 	/**
 	 	 * At this point a thread i finished the computation of coefficient i
 	 	 */
 		poly[cid] = coef;
		bn_mod_barrt(	poly,
						poly,
						N,
						M,
						M_used,
						u,
						u_used);
    	poly[cid].used = get_used_index(poly[cid].dp,STD_BNT_WORDS_ALLOC)+1;
    	bn_zero_non_used(&poly[cid]);
	 }

}
	
void callCRT(bn_t *coefs,const int used_coefs,cuyasheint_t *d_polyCRT,const int N, const int NPolis,cudaStream_t stream){
	const int size = used_coefs*NPolis;

	if(size <= 0)
		return;
	
	cudaError_t result;
	int blockSize;   // The launch configurator returned block size 
	// int minGridSize; // The minimum grid size needed to achieve the 
           			 // maximum occupancy for a full device launch 
	int gridSize;    // The actual grid size needed, based on input size 

	// cudaOccupancyMaxPotentialBlockSize( &minGridSize, &blockSize, cuCRT, 0, 0); 
	// blockSize = 32; // 0.11 ms
	// blockSize = 64; // 0.07 ms
	// blockSize = 128; // 0.06 ms
	// blockSize = 192; // 0.06 ms
	// blockSize = 256; // 0.06 ms
	blockSize = 512; // 0.07 ms

	gridSize = (size%blockSize == 0? 
			size/blockSize : 
			size/blockSize + 1);
	dim3 gridDim(gridSize);
	dim3 blockDim(blockSize);
	
	cuCRT<<<gridDim,blockDim,0,stream>>>(d_polyCRT,coefs,used_coefs,N,NPolis);
	result = cudaGetLastError();
	assert(result == cudaSuccess);
	// cudaDeviceSynchronize();
	// assert(result == cudaSuccess);

}

void callICRT(bn_t *coefs,cuyasheint_t *d_polyCRT,const int N, const int NPolis,cudaStream_t stream){

	if(N <= 0)
		return;
	int blockSize;   // The launch configurator returned block size 
	// int minGridSize; // The minimum grid size needed to achieve the 
           			 // maximum occupancy for a full device launch 
	int gridSize;    // The actual grid size needed, based on input size 

	// cudaOccupancyMaxPotentialBlockSize( &minGridSize, &blockSize, cuPreICRT, 0, 0); 
	// blockSize = 32; // 0.71 ms
	// blockSize = 64; // 0.58 ms
	// blockSize = 128; // 0.54 ms
	// blockSize = 192; // 0.54 ms
	// blockSize = 256; // 0.54 ms
	blockSize = 512; // 0.54 ms

	gridSize = ( N*NPolis % blockSize == 0? 
						N*NPolis/blockSize : 
						N*NPolis/blockSize + 1);
	cuPreICRT<<<gridSize,blockSize,0,stream>>> (CUDAFunctions::d_inner_results,
												CUDAFunctions::d_inner_results_used,
												d_polyCRT,
												N,
												NPolis
												);
	blockSize = ADDBLOCKXDIM;

	gridSize = ( N % blockSize == 0? 
						N/blockSize : 
						N/blockSize + 1);
	cuICRT<<<gridSize,blockSize,0,stream>>>(coefs,
											N,
											NPolis,
											CUDAFunctions::d_inner_results,
											CUDAFunctions::d_inner_results_used);
	cudaError_t result = cudaGetLastError();
	assert(result == cudaSuccess);
	// cudaDeviceSynchronize();
	// assert(result == cudaSuccess);

}

__host__ void  CUDAFunctions::write_crt_primes(){

  #ifdef VERBOSE
  std::cout << "primes: "<< std::endl;
  for(unsigned int i = 0; i < Polynomial::CRTPrimes.size();i++)
    std::cout << Polynomial::CRTPrimes[i] << " ";
  std::cout << std::endl;
  #endif
  
  // Choose what memory will be used to story CRT Primes
  if(Polynomial::CRTPrimes.size() < MAX_PRIMES_ON_C_MEMORY){
    
    #ifdef VERBOSE
    std::cout << "Writting CRT Primes to GPU's constant memory" << std::endl;
    #endif

    cudaStream_t stream;
    cudaStreamCreate(&stream);

    /////////////////
    // Copy primes //
    /////////////////
    cudaError_t result = cudaMemcpyToSymbolAsync ( CRTPrimesConstant,
                                              &(Polynomial::CRTPrimes[0]),
                                              Polynomial::CRTPrimes.size()*sizeof(cuyasheint_t),
                                              0,
	                                           cudaMemcpyHostToDevice,
                                              stream
                                            );
    assert(result == cudaSuccess);

    ////////////
    // Copy M //
    ////////////
    
    bn_t h_M;
    
    get_words_host(&h_M,Polynomial::CRTProduct);
	assert(h_M.alloc >= STD_BNT_WORDS_ALLOC);
	result = cudaMemcpyToSymbolAsync(M,h_M.dp, h_M.used*sizeof(cuyasheint_t),0,cudaMemcpyHostToDevice,stream);
    assert(result == cudaSuccess);
	result = cudaMemcpyToSymbolAsync(M_used,&h_M.used, sizeof(int),0,cudaMemcpyHostToDevice,stream);
    assert(result == cudaSuccess);
    
    ////////////
    // Copy u //
    ////////////

    cuyasheint_t *h_u;
    bn_t d_u = get_reciprocal(Polynomial::CRTProduct);
    h_u = (cuyasheint_t*)malloc(d_u.alloc*sizeof(cuyasheint_t));
	// assert(d_u.alloc >= STD_BNT_WORDS_ALLOC);
    cudaMemcpyAsync(h_u,d_u.dp,d_u.alloc*sizeof(cuyasheint_t),cudaMemcpyDeviceToHost,stream);
    result = cudaMemcpyToSymbolAsync(u,h_u,d_u.alloc*sizeof(cuyasheint_t),0,cudaMemcpyHostToDevice,stream);
    assert(result == cudaSuccess);
	result = cudaMemcpyToSymbolAsync(u_used,&d_u.used, sizeof(int),0,cudaMemcpyHostToDevice,stream);
    assert(result == cudaSuccess);
    
    //////////////
    // Copy Mpi //
    //////////////    
    bn_t *h_Mpis;
    h_Mpis = (bn_t*) malloc( Polynomial::CRTPrimes.size()*sizeof(bn_t) );
    
    for(unsigned int i = 0; i < Polynomial::CRTPrimes.size();i++){
    	h_Mpis[i].alloc = 0;
    	get_words_host(&h_Mpis[i],Polynomial::CRTMpi[i]);
		result = cudaMemcpyToSymbolAsync(Mpis, h_Mpis[i].dp, STD_BNT_WORDS_ALLOC*sizeof(cuyasheint_t),i*STD_BNT_WORDS_ALLOC*sizeof(cuyasheint_t),cudaMemcpyHostToDevice,stream);
		assert(result == cudaSuccess);
		result = cudaMemcpyToSymbolAsync(Mpis_used,&h_Mpis[i].used, sizeof(int),i*sizeof(int),cudaMemcpyHostToDevice,stream);
		assert(result == cudaSuccess);
    }

    /////////////////
    // Copy InvMpi //
    /////////////////

	result = cudaMemcpyToSymbolAsync(invMpis,
								&Polynomial::CRTInvMpi[0],
								Polynomial::CRTPrimes.size()*sizeof(cuyasheint_t),
								0,
								cudaMemcpyHostToDevice,
								stream
							);
    assert(result == cudaSuccess);

    ////////////////////
    // Release memory //
    ////////////////////
	result = cudaDeviceSynchronize();
    assert(result == cudaSuccess);
    for(unsigned int i = 0; i < Polynomial::CRTPrimes.size();i++)
    	free(h_Mpis[i].dp);

    free(h_Mpis);
    free(h_M.dp);
    cudaFree(d_u.dp);
  }else{
    throw "Too many primes.";
  }
}