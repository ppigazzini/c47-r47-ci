# pool-guard.patch - the POOL_GUARD canary, ready to apply

[docs/05-debugging.md](../../../../docs/05-debugging.md) Section 5 owns the
technique and the two rules that make it work; this is that instrumentation
written out, so nobody has to rebuild it from the prose again.

It is **not a lane**. It is a patch applied by hand onto an upstream clone, and
it changes what the allocator hands out, so it is a debugging build and nothing
else.

```bash
cd "$upstream_clone"
git apply "$harness/scripts/test/tooling/poolguard/pool-guard.patch"
meson setup build.guard --buildtype=custom -DRASPBERRY=false -DDECNUMBER_FASTMUL=true \
  -Dc_args="-Wno-deprecated-declarations -DPOOL_GUARD -DT47 -g -rdynamic"
ninja -C build.guard sim src/testSuite/testSuite
```

What it adds, all under `#if defined(POOL_GUARD)`:

- every pool region over-allocated by `POOL_GUARD_BLOCKS` (4 blocks = 16 bytes)
  whose bytes are a hash of their own address - never a constant, or a copy
  overrun carries a matching canary into the target and masks itself;
- all four wrappers inflate identically, because the allocator stores no sizes;
- a check at free/realloc/reduce time, with a `backtrace()` that names the
  culprit (this is the trustworthy half - it fires on the region the caller
  actually holds);
- a registry of live regions swept at exit, for blocks that are never freed -
  and `poolGuardResetRegistry()` called from `doFnReset`, without which the
  sweep reports the reset itself as ~30 overruns of tiny regions.

Read the two baselines in 05-debugging Section 5.3 before believing a sweep
count: a corpus run ends on 30 sweep-time violations that are a property of the
tree, not of any one change.

Audit basis: applies to upstream c43 at `199477075` (MR !1631 branch, based on
`3c84890a1`). It touches `memory.c`, `memory.h` and `config.c`; upstream edits
to any of those three will need the hunks re-fitted.
