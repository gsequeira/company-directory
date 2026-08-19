# Caching the build directory in CI

Why `.build` is not cached today, what the obvious fix gets wrong, and the design to use instead.

**Written 2026-08-19**, against issue #30. Nothing here has been implemented; this is the design and
the measurement plan, not a record of a change.

Companion documents: [`CI.md`](CI.md) → *Cached-build corruption* is the short version of the hazard
and *Cost and quota* holds the numbers this would change; [`TOOLCHAIN.md`](TOOLCHAIN.md) explains why
a Swift version number is not a toolchain identity.

---

# Part 1, the problem

Every CI run recompiles the world. From the baseline in `ci.yml`:

| Measurement | Value |
| --- | --- |
| Full run, cold | 12m37s |
| Of which, one compile | 682s |
| Same build locally | 92s |
| Runner | 2 vCPU, private repo standard |

The interesting part is what those 682 seconds are spent on.

| | Count | Size |
| --- | --- | --- |
| Own code (`Sources`, `Tests`) | 16 Swift files | 172 KB |
| Dependency checkouts | 41 packages | 199 MB |

The 41 packages are the whole NIO stack, Vapor, Fluent, PostgresNIO, swift-crypto,
swift-certificates, OpenAPIKit and the OpenAPI generator. Essentially the entire compile is other
people's code, and none of it changes unless `Package.resolved` changes.

That ratio is the argument for caching. It is also, in Part 5, the reason to expect the cache to help
even if the incremental build only partly works.

---

# Part 2, why it is not cached today

`ci.yml` caches `~/.cache/org.swift.swiftpm` and deliberately not `.build`, because a build directory
written by a different compiler produces:

```
compiled module was created by a newer version of the compiler
```

This project has already paid for that once locally, when an Xcode toolchain and a swiftly-managed
toolchain, both reporting 6.3.3, wrote into the same directory. `TOOLCHAIN.md` records it in full.

The decision to skip the cache was correct at the time. Correctness first, then a baseline, then
optimisation. The baseline now exists, so the question is live.

---

# Part 3, four defects in the obvious fix

`CI.md` states the rule as "the cache key must include the toolchain version and not just
`Package.resolved`". That is necessary and it is not sufficient. Doing only that produces a cache that
is unsafe, then useless, and keyed on the wrong thing in two separate ways.

## Defect 1, restore-keys ignore the key

This is the one that reintroduces the exact bug the rule exists to prevent.

```yaml
restore-keys: swiftpm-${{ runner.os }}-
```

`restore-keys` match by **prefix** and discard everything after it. That line says "give me the
newest cache whose key begins with `swiftpm-Linux-`". A toolchain segment placed later in the key is
invisible to the match.

So the failure runs like this. You bump `.swift-version` to 6.4 and update the `container:` tag. The
exact key now misses, because the key contains the toolchain and the toolchain changed. The miss
triggers the fallback. The fallback matches on a prefix that knows nothing about toolchains and
restores a `.build` written by 6.3.3 into a 6.4 job.

The safety net is the delivery mechanism. Every fallback line must terminate **at or after** the
toolchain segment. Not one of them may end before it.

## Defect 2, a key that hits is never refreshed

`actions/cache` saves only when the key missed. The dependency cache gets away with this because its
contents change only when `Package.resolved` changes, so a hit genuinely means the cache is current.

`.build` does not work that way. It tracks the source tree. Keyed on `Package.resolved` alone, it is
written by the first green run and never again: every later run hits, restores, and saves nothing.
The cache freezes at one commit and drifts one commit further from `HEAD` with every merge. Months
later it restores build products for code that no longer exists and recompiles everything that does,
while still costing the full download.

The cache must miss on every run in order to save on every run. That means something per-run in the
key, with `restore-keys` walking back to the previous one.

## Defect 3, the version number is the wrong fingerprint

`TOOLCHAIN.md` already gives the rule: **look at the build identifier, not the version number.**
`swiftlang-6.3.3.1.3` and `swift-6.3.3-RELEASE` are different compilers that emit incompatible
modules and identical version strings.

So `hashFiles('.swift-version')` fingerprints precisely the field that was equal in the failure this
is meant to prevent. Hash the full `swift --version` banner instead, taken from the compiler that is
actually running rather than the file that claims to pin it.

In practice the `container:` tag makes this near-impossible to violate in CI. Use the banner anyway.
It costs one line and it stays correct if the job ever moves off a pinned container.

One caveat if it ever does. The neighbouring drift check extracts the version with
`swift --version | head -1 | awk '{print $3}'`, and that is position-dependent:

```
Swift version 6.3.3 (swift-6.3.3-RELEASE)        → 6.3.3
Apple Swift version 6.3.3 (swift-6.3.3-RELEASE)  → version
```

The Linux banner has three leading fields and the macOS one has four. Correct inside this container,
wrong the moment it leaves. The banner hash is unaffected, because it hashes the whole line.

## Defect 4, the key does not mention the architecture

`runner.os` is `Linux` on both amd64 and arm64, and GitHub now offers arm64 Linux runners. Compiled
objects are not portable between them, so a key built from `runner.os` alone would happily restore an
x86_64 `.build` into an arm64 job.

Hashing only `head -1` does not save you either. The architecture lives on the second line:

```
Swift version 6.3.3 (swift-6.3.3-RELEASE)
Target: x86_64-unknown-linux-gnu
```

Two fixes, and Part 4 takes both. Hash the whole `swift --version` output rather than its first line,
so the target triple is inside the fingerprint. And put `${{ runner.arch }}` in the key as a literal
segment, because a hash is opaque and a key someone can read is a key they are less likely to break.

---

# Part 4, the change

The verify step gains an `id` and one output line. The single cache step becomes two: a restore that
every run performs, and a save that only `main` performs. Part 5 explains why the split is not
optional.

```yaml
      - name: Verify the toolchain matches .swift-version
        id: toolchain
        run: |
          pinned="$(tr -d '[:space:]' < .swift-version)"
          actual="$(swift --version | head -1 | awk '{print $3}')"
          echo "pinned in .swift-version: $pinned"
          echo "running in container:     $actual"
          if [ "$pinned" != "$actual" ]; then
            echo "::error::Toolchain drift. .swift-version pins $pinned but this job runs $actual." \
                 "Update the 'container:' tag in .github/workflows/ci.yml to swift:$pinned."
            exit 1
          fi
          # The whole `swift --version` output, not the version field and not just line 1.
          # Two 6.3.3 toolchains from different builds emit incompatible modules and identical
          # version numbers, which is the failure TOOLCHAIN.md records; and line 2 carries the
          # target triple, which is what separates an amd64 build directory from an arm64 one.
          echo "id=$(swift --version | sha256sum | cut -c1-12)" >> "$GITHUB_OUTPUT"

      - name: Restore SwiftPM dependencies and build products
        id: cache
        uses: actions/cache/restore@v6
        with:
          path: |
            ~/.cache/org.swift.swiftpm
            .build
          # github.sha is here so the key MISSES on every run, which is what lets the save step
          # below write a fresh entry. A key that hits is never refreshed, and a .build keyed on
          # Package.resolved alone freezes at the first run that wrote it.
          key: swift-${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.id }}-${{ hashFiles('Package.resolved') }}-${{ github.sha }}
          # Both fallbacks carry os, arch and toolchain id in the prefix. That is the safety
          # property: restore-keys match by prefix and ignore the rest, so a bare `swift-Linux-`
          # line would restore a 6.2 .build into a 6.3.3 job, or an x86_64 one into arm64.
          # Nothing here can cross a toolchain or architecture boundary. Read these two lines
          # before changing either.
          restore-keys: |
            swift-${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.id }}-${{ hashFiles('Package.resolved') }}-
            swift-${{ runner.os }}-${{ runner.arch }}-${{ steps.toolchain.outputs.id }}-

      # ... Check formatting, Run tests ...

      - name: Save SwiftPM dependencies and build products
        # Only `main` writes; every branch reads. Pull-request caches count against the same
        # 10 GB repository quota, so letting them save evicts the one main cache every new
        # branch restores from. Part 5 has the arithmetic.
        #
        # No `always()`: a run that failed in `Check formatting` never compiled, and saving its
        # near-empty .build under the newest key would leave the first restore-key fallback
        # pointing at a cache worth nothing.
        if: github.ref == 'refs/heads/main'
        uses: actions/cache/save@v6
        with:
          # Repeated rather than shared. GitHub Actions does not support YAML anchors, so the
          # two `path:` lists have to be kept in step by hand.
          path: |
            ~/.cache/org.swift.swiftpm
            .build
          key: ${{ steps.cache.outputs.cache-primary-key }}
```

The fallbacks are ordered most specific first. The first restores a build made with the same compiler
and the same dependency graph, differing only in commit, which is the common case for a PR branched
off a recent `main`. The second accepts a different dependency graph but the same compiler, which is
what you want after a `Package.resolved` bump: most of the 41 packages did not move and their objects
are still valid.

**The prefix rename from `swiftpm-` to `swift-` is deliberate.** It orphans the existing 413 MB cache
so that nothing written under the old scheme can ever be restored under the new one. Do not keep the
old prefix for continuity.

## Branch scoping, which is what makes the split work

Caches written on the default branch are readable from every branch; caches written on a topic branch
are visible only to that branch and its PR. That asymmetry is the whole reason `main` can be the sole
writer without starving anyone: a PR that never saves still restores from `main`'s cache, and gets
exactly the warm start it would have got from saving its own.

With `push` on `main` and `pull_request` everywhere else, every merge repopulates the shared cache.
That is already the trigger configuration in `ci.yml`, so nothing needs to change for this.

What the split costs is the second and third push to a long-lived PR branch: each one restores from
`main` rather than from the push before it, so a PR that sits open across several commits recompiles
its own changes every time. Given that the dependency compile is the 682 seconds and the 16 own-source
files are not, that is close to free. If it ever stops being free, the fix is to relax the `if:` to
also save on `pull_request`, and to accept the eviction pressure that comes with it.

---

# Part 5, what this does not fix

**Your own 16 files will probably recompile every run.** llbuild decides freshness from file stat
metadata, and `actions/checkout` writes the source tree fresh on every run, so `Sources` and `Tests`
are likely to look modified no matter what the cache restored. Dependency sources arrive inside the
cache tarball instead, untouched by checkout, which is the half that matters. This is the main
unverified assumption in the whole design and Part 6 exists to test it.

**Neither restore nor save is free.** A multi-gigabyte cache costs real seconds to download and
extract, and by construction this design writes a fresh one on every `main` run, so the tar and
upload are a recurring cost rather than a one-off. A `.build` is hundreds of thousands of small
files, which is the slow shape for both operations. The claim to make is not "682s becomes zero" but
"682s becomes a restore, plus whatever genuinely rebuilds, plus a save on `main`".

**The quota is what forced the restore/save split, and it nearly killed the whole design.** `CI.md`
currently records a 413 MB cache against a 10 GB per-repository limit and concludes "neither limit is
close". That stops being true the moment `.build` is in the cache and every run writes a new entry.

The arithmetic, assuming the Part 6 measurement comes back around 2.5 GB:

| | Caches that fit in 10 GB |
| --- | --- |
| 2.5 GB entry | 4 |
| 3.5 GB entry | 2 |

Eviction is least-recently-used across the whole repository, and pull-request caches draw on the same
quota as `main`'s. So under a naive single `actions/cache` step, three pushes to one unrelated PR
evict the `main` cache that every new branch restores from. You would then pay the save cost on every
run and still get a cold compile, which is strictly worse than caching nothing.

The failure would also be near-undiagnosable from the logs, because it presents as *runs get slower
over weeks*, the same symptom the troubleshooting table below attributes to defect 2. That is why
Part 4 makes `main` the only writer rather than treating the split as a refinement.

With that in place the repository holds a short history of `main` caches and LRU keeps the newest,
which is exactly the one every branch wants.

**Nothing here helps the 2 vCPU runner.** Caching attacks repeated work. It does not attack the fact
that a cold compile takes 682s here against 92s locally, which is core count and disk speed. Those
are separate levers and this is the free one.

---

# Part 6, how to verify it worked

Measure before implementing. **CI now reports the number on every run**, in the *Measure the build
products* step and in the job summary, so the figure this decision turns on arrives without anyone
running anything:

```
### Build product sizes
N.NG    .build
NNNM    /root/.cache/org.swift.swiftpm
```

The step is guarded with `if: always()` and `continue-on-error`, so it reports on a red run and can
never cause one. `CI.md` → *Part 3, anatomy of the workflow* has the reasoning.

The local equivalent, for anyone who wants the breakdown without waiting for a run, is the recipe
already in `CI.md` → *Reproducing a CI failure locally*, which conveniently writes Linux build
products to a known scratch path:

```bash
docker compose up -d --wait db-test
rm -rf /tmp/company-directory-linux-build
docker run --rm --network company-directory_default \
  -e TEST_DATABASE_HOST=db-test -e TEST_DATABASE_PORT=5432 \
  -v "$PWD":/src -w /src -v /tmp/company-directory-linux-build:/build \
  swift:6.3.3 swift test --scratch-path /build
du -sh /tmp/company-directory-linux-build
```

That single number decides whether this is worth doing. The local macOS `.build` is 5.6 GB, but 2.7
GB of it is `index-build` from SourceKit-LSP, which CI never creates, and 2.3 GB is macOS-specific
objects. The Linux figure is the only one that predicts the cache size.

Compare it against the quota rather than against a feeling. With `main` as the only writer, the
repository needs room for the newest `main` cache plus one or two ancestors, so the test is roughly
**three times the measured size against 10 GB**. Under about 3 GB is comfortable; above it, the
history is one deep and a single toolchain bump evicts everything useful.

Then, once implemented, three checks in order:

1. **Did it restore?** The restore step logs `Cache restored from key: ...`. Read the key it names and
   confirm the toolchain and arch segments match the running compiler.
2. **Did it save?** The save step logs `Cache saved with key: ...`. Expect this on `main` and **not**
   on a pull request; its absence on a PR is the design working, not defect 2 returning. If it is
   missing from a green `main` run, the cache is frozen.
3. **Did it help?** Compare the *Run tests* step duration against the 682s baseline, on a branch cut
   from a `main` that has already saved a cache.

Check 3 is the only one that matters, and under the restore/save split it has to be read on a branch
rather than on a second push to the same one. The first `main` run after the change is by definition
cold.

## The test that proves it is safe

The point of the design is toolchain isolation, so exercise it deliberately rather than waiting for a
real upgrade. On a throwaway branch, change `.swift-version` and the `container:` tag together to a
different Swift release and push. The correct outcome is a full cold compile with no module errors,
because no fallback prefix could reach the old cache. If instead it fails with "compiled module was
created by a newer version of the compiler", a `restore-keys` line is terminating before the
toolchain segment.

**The test only means something if there is something to wrongly restore.** Run it after `main` has
saved at least one cache under the current toolchain, and confirm from the log that the throwaway
branch could see that cache before concluding the isolation held. A branch that restores nothing
proves nothing, and a green cold compile looks identical either way.

---

# Part 7, backing it out

Revert all three steps, and put the single `actions/cache` dependency step back. Do not merely remove
`.build` from the two `path:` lists while keeping the key scheme, because the saved caches remain and
the next reinstatement restores them. If the design is abandoned, change the key prefix as well so
nothing written under it is ever addressable again.

Deleting the entries by hand under repository settings is not a substitute. It clears what exists
today and does nothing about the key that would write them again.

---

# Part 8, what can go wrong

| Symptom | Cause | Fix |
| --- | --- | --- |
| `compiled module was created by a newer version of the compiler` | A `restore-keys` prefix ends before the toolchain segment | Every fallback line must include `${{ steps.toolchain.outputs.id }}` |
| Undefined symbols, or objects for the wrong architecture | The key reached across an architecture boundary | Every key and fallback must carry `${{ runner.arch }}`. See defect 4 |
| Runs get slower over weeks, never faster | Either the key hits so nothing saves, or `main`'s cache is being evicted by pull-request caches | Confirm `github.sha` is still the last key segment, that `Cache saved with key` appears on `main` runs, and that the save step is still gated on `github.ref` |
| No `Cache restored from key` line at all | First run under a new key prefix, or the branch has no ancestor cache on `main` | Expected once. If it persists on `main`, the save step is failing |
| No `Cache saved with key` on a pull request | The save step is gated to `main` | Expected, and not defect 2. Check a `main` run instead |
| Save step fails on upload | The tarball exceeds what the runner can stage, or the repo is at its 10 GB limit | Check *Caches* under repository settings. Consider excluding `.build/repositories` and `.build/checkouts`, both of which duplicate the SwiftPM dependency cache |
| Restore succeeds but everything recompiles anyway | *Part 5, what this does not fix*, first item. llbuild sees a freshly checked-out tree | Compare against the *dependency* compile time rather than the total; if even dependencies rebuild, the design does not pay and should be reverted |
| Green locally, module errors in CI only | A toolchain was bumped in one place and not the other | The verify step should have caught this first. If it did not, the two changed together but the cache outlived them, meaning defect 1 |

---

# Decision status

**Not implemented as of 2026-08-19.** Sequence to follow, cheapest first:

1. Run the measurement in Part 6 and record the Linux `.build` size here.
2. Check it against the quota, not just against 3 GB. Three times the measured size has to fit in
   10 GB, for the reason in Part 5.
3. If it passes, implement Part 4 on a branch against issue #30. The restore/save split is part of
   the design, not a refinement to add later.
4. Run the safety test in Part 6 before merging, not after, and only once `main` holds a cache for it
   to fail against.
5. Update the *Cost and quota* section of `CI.md` with the new cache figures, and its
   *Cached-build corruption* section to point here rather than restate the hazard.

If the measurement comes back much larger, or the verification in Part 6 shows dependencies rebuilding
regardless, the honest conclusion is that this project's 682s is a runner-size problem rather than a
caching problem, and the lever to reach for is more cores rather than a warmer disk.
