/* Parse-only scaffolding for Frama-C. NOT the real generateConstants output.
   Provides only the stable `constants[]` declaration; the const_* value macros
   are omitted because no Tier-A/B target references them. A real built tree's
   src/generated/constantPointers.h takes precedence (run-framac.sh prefers it).
   If a future target references a const_* macro, generate the real header. */
#if !defined(CONSTANTPOINTERS_H)
  #define CONSTANTPOINTERS_H
  extern const uint8_t constants[];
#endif
