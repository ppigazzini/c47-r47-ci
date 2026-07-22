/* M3 WP proof - the register-number bijection regKStoC / regCtoKS (defines.h:
 * 1414/1422). Constants inlined from defines.h (audit basis ccafdfe51):
 *   NUMBER_OF_LOCAL_REGISTERS = 99 ; local offset 7000-112 = 6888
 *   C  stat/spare 112..125, local 7000..7098 ; KS stat/spare 211..224, local 112..210.
 * The (uint8_t) cast in regCtoKS is decomposed: on the valid domain the pre-cast
 * value is in [0,224] (proved by cast_is_identity_*), so the mask is a no-op and
 * the round-trip is pure linear arithmetic Z3 closes at once.
 * Prove:  frama-c -wp -wp-prover z3 -wp-rte regnum_bijection.c                  */

/* (b) the regCtoKS result, before the uint8_t cast, always lands in [0,224]. */
/*@ requires (0 <= c <= 125) || (7000 <= c <= 7098);
    assigns \nothing;
    ensures 0 <= \result <= 224;
*/
int ctoks_precast(int c) {
  return c + (112 <= c && c <= 125) * 99 - (7000 <= c && c <= 7098) * 6888;
}

/* (a) C -> KS -> C is the identity (cast dropped: identity on [0,224] by (b)). */
/*@ requires (0 <= c <= 125) || (7000 <= c <= 7098);
    assigns \nothing;
    ensures \result == c;
*/
int roundtrip_C_KS_C(int c) {
  int ks = c + (112 <= c && c <= 125) * 99 - (7000 <= c && c <= 7098) * 6888;
  return ks - (211 <= ks && ks <= 224) * 99 + (112 <= ks && ks <= 210) * 6888;
}

/* KS -> C -> KS is the identity over every valid keystroke register code. */
/*@ requires 0 <= k <= 224;
    assigns \nothing;
    ensures \result == k;
*/
int roundtrip_KS_C_KS(int k) {
  int c = k - (211 <= k && k <= 224) * 99 + (112 <= k && k <= 210) * 6888;
  return c + (112 <= c && c <= 125) * 99 - (7000 <= c && c <= 7098) * 6888;
}
