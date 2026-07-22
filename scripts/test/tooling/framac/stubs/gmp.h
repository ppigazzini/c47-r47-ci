/* Parse-only GMP stub for Frama-C. Types + prototypes so headers typecheck;
   no semantics. Files whose VALUES flow through GMP are Tier-D (not analysable). */
#ifndef FC_STUB_GMP_H
#define FC_STUB_GMP_H
#include <stddef.h>
#include <stdint.h>
typedef unsigned long mp_limb_t;
typedef unsigned long mp_bitcnt_t;
typedef struct { int _mp_alloc, _mp_size; mp_limb_t *_mp_d; } __mpz_struct;
typedef __mpz_struct mpz_t[1];
typedef __mpz_struct *mpz_ptr;
typedef const __mpz_struct *mpz_srcptr;
void mpz_init(mpz_ptr); void mpz_init2(mpz_ptr, mp_bitcnt_t); void mpz_clear(mpz_ptr);
void mpz_set(mpz_ptr, mpz_srcptr); void mpz_set_si(mpz_ptr, long);
void mpz_set_ui(mpz_ptr, unsigned long); int mpz_set_str(mpz_ptr, const char *, int);
long mpz_get_si(mpz_srcptr); unsigned long mpz_get_ui(mpz_srcptr);
char *mpz_get_str(char *, int, mpz_srcptr);
int mpz_cmp(mpz_srcptr, mpz_srcptr); int mpz_cmp_si(mpz_srcptr, long);
int mpz_cmp_ui(mpz_srcptr, unsigned long); int mpz_sgn(mpz_srcptr);
size_t mpz_sizeinbase(mpz_srcptr, int);
void mpz_add(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_add_ui(mpz_ptr, mpz_srcptr, unsigned long);
void mpz_sub(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_sub_ui(mpz_ptr, mpz_srcptr, unsigned long);
void mpz_mul(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_mul_ui(mpz_ptr, mpz_srcptr, unsigned long);
void mpz_neg(mpz_ptr, mpz_srcptr); void mpz_abs(mpz_ptr, mpz_srcptr);
void mpz_divexact_ui(mpz_ptr, mpz_srcptr, unsigned long);
void mpz_mod(mpz_ptr, mpz_srcptr, mpz_srcptr);
void mpz_gcd(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_lcm(mpz_ptr, mpz_srcptr, mpz_srcptr);
void mpz_fac_ui(mpz_ptr, unsigned long); void mpz_fib_ui(mpz_ptr, unsigned long);
void mpz_bin_uiui(mpz_ptr, unsigned long, unsigned long);
void mpz_setbit(mpz_ptr, mp_bitcnt_t);
int mpz_even_p(mpz_srcptr); int mpz_odd_p(mpz_srcptr);
int mpz_perfect_square_p(mpz_srcptr); int mpz_probab_prime_p(mpz_srcptr, int);
void mpz_nextprime(mpz_ptr, mpz_srcptr); void mpz_sqrt(mpz_ptr, mpz_srcptr);
int mpz_root(mpz_ptr, mpz_srcptr, unsigned long);
void mpz_powm(mpz_ptr, mpz_srcptr, mpz_srcptr, mpz_srcptr);
void mpz_powm_ui(mpz_ptr, mpz_srcptr, unsigned long, mpz_srcptr);
void mpz_tdiv_q(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_tdiv_r(mpz_ptr, mpz_srcptr, mpz_srcptr);
void mpz_tdiv_qr(mpz_ptr, mpz_ptr, mpz_srcptr, mpz_srcptr);
unsigned long mpz_tdiv_q_ui(mpz_ptr, mpz_srcptr, unsigned long);
unsigned long mpz_tdiv_qr_ui(mpz_ptr, mpz_ptr, mpz_srcptr, unsigned long);
void mpz_fdiv_q(mpz_ptr, mpz_srcptr, mpz_srcptr); void mpz_fdiv_r(mpz_ptr, mpz_srcptr, mpz_srcptr);
void mpz_fdiv_q_ui(mpz_ptr, mpz_srcptr, unsigned long);
unsigned long mpz_fdiv_ui(mpz_srcptr, unsigned long);
void mpz_div_2exp(mpz_ptr, mpz_srcptr, mp_bitcnt_t);
void mpz_mul_2exp(mpz_ptr, mpz_srcptr, mp_bitcnt_t);
void mpz_ui_pow_ui(mpz_ptr, unsigned long, unsigned long);
void mpz_pow_ui(mpz_ptr, mpz_srcptr, unsigned long);
int mpz_divisible_p(mpz_srcptr, mpz_srcptr); int mpz_divisible_ui_p(mpz_srcptr, unsigned long);
#endif
