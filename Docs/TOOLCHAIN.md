# Swift toolchain

Which Swift compiles this project, how that is pinned, and what to do when it changes.

**Decision, 2026-08-14:** this project builds with the **swift.org release toolchain managed by
swiftly**, pinned to **6.3.3** by the `.swift-version` file in the repository root. This project does
not use Xcode.

Written after a real failure. See [Appendix, the error that prompted this](#appendix-the-error-that-prompted-this).

## The problem this solves

A macOS machine with Xcode installed has **at least two Swift compilers**, and they are not
interchangeable:

| Path | Build identifier | Origin |
| --- | --- | --- |
| `/usr/bin/swift` | `swiftlang-6.3.3.1.3 clang-2100.1.1.101` | `xcode-select` shim into Xcode's toolchain |
| `~/.swiftly/bin/swift` | `swift-6.3.3-RELEASE` | swift.org release, managed by swiftly |

Same version number. Different builds. `.swiftmodule` files are **not portable between compiler
builds**, so one compiler rejects what the other wrote.

`/usr/bin/swift` exists whenever the Xcode command line tools are installed, regardless of whether
you ever open Xcode. It cannot be removed, and in a non-interactive shell it often wins on `PATH`.
So "I don't use Xcode" does not by itself prevent the mix-up. The pin does.

Check which one you are actually getting:

```bash
which -a swift             # PATH order — the first one wins
swift --version            # look at the build identifier, not the version number
swiftly use                # what swiftly resolves here, honouring .swift-version
```

## Why swift.org rather than Xcode's

Xcode's toolchain is a fork with its own module format and its own release cadence. The swift.org
releases are the same lineage as the official `swift:*` Docker images, so a local build and a
`docker run --rm swift:6.3 swift build` compare like with like. That matters now that CI exists,
because a discrepancy should mean a real problem rather than a toolchain difference.

## How the pin works

`.swift-version` in the repository root contains a single line:

```
6.3.3
```

swiftly resolves the toolchain from the current working directory, and `.swift-version` takes
precedence over the global default. From `swiftly use --help`:

```
-g, --global-default    Set the global default toolchain that is used when
                        there are no .swift-version files.
```

Three consequences worth knowing:

- **`swiftly use 6.4.0` in another project does not affect this one.** Without the file it would,
  and you would rediscover a toolchain error here with no obvious connection to what you changed.
- **`swiftly use <version>` run *in this directory* rewrites `.swift-version`.** The upgrade is a
  one-line diff you review and commit, not an ambient change to your machine.
- **`swiftly install` with no argument installs whatever `.swift-version` names.** That is the
  one-line onboarding command, and the same line CI runs.

## Upgrading

Nothing updates automatically. swiftly has no background updater, and installing is not switching,
because `--use` is opt-in:

```
swiftly install [<version>] [--use] ...
```

So `swiftly install 6.4.0` sits alongside the existing toolchains and changes nothing.

When you do decide to move:

```bash
git switch -c toolchain-6.4.0
swiftly install 6.4.0
swiftly use 6.4.0        # rewrites .swift-version, since we are in the project directory
swift package clean      # do not skip: .build was compiled by the old compiler
swift build
swift test
```

Own branch, own commit, nothing else in the diff. A change that touches every compiled artifact
should never share a commit with a change that means something. That is the same rule that governed
the `swift-format --in-place` run in #6.

### What can actually go wrong

| Risk | Notes |
| --- | --- |
| New or stricter diagnostics | Warnings that did not exist before. Swift 6 language mode is already enabled, so the large concurrency migration is behind us |
| Dependencies not yet compatible | May need a `swift package update` and, occasionally, waiting for an upstream release |
| **`swift-tools-version` asymmetry** | A 6.4 toolchain builds a `swift-tools-version: 6.3` manifest fine. The reverse is **not** true. Bumping the manifest to 6.4 means anything pinned to 6.3, including a CI container, can no longer build the package at all |

Upgrade the toolchain freely. Treat bumping `swift-tools-version` in `Package.swift` as a separate,
deliberate decision that breaks far more if it is wrong.

`platforms: [.macOS(.v26)]` and `swiftLanguageModes: [.v6]` survive a toolchain bump in either
direction.

## A beta macOS SDK can outrun the pin

The pin fixes the *compiler*. It does not fix the SDK that compiler builds against, and on a machine
running a beta macOS the SDK can arrive months ahead of the pinned release. Seen 2026-08-16 on a Mac
running beta macOS 27 with beta Xcode 27, where `swift run CompanyDirectory serve` failed inside a
*dependency*:

```
.build/checkouts/swift-crypto/Sources/CryptoExtras/Digests/SHA512256Digest.swift:18:15:
error: type 'SHA512256Digest' does not conform to protocol 'ContiguousBytes'
note: protocol requires function 'withBytes' with type '<R, E> ((RawSpan) throws(E) -> R) throws(E) -> R'
```

That SDK's Foundation added a `withBytes` requirement to `ContiguousBytes`, gated at macOS 27 and
carrying an `@_alwaysEmitIntoClient` default implementation. Swift 6.3.3 does not take that default
as the witness, so every `Digest` type in swift-crypto reads as non-conforming and nothing depending
on Vapor compiles. Xcode 27 beta's Swift 6.4 compiles it.

Note what this is *not*. It is not the two-compilers problem above, since only one compiler is
involved, and it is not a `.build` hazard, since `swift package clean` changes nothing here. It is
the pinned compiler meeting a standard library newer than itself.

Three fixes that look right and are not:

| Tempting | Why not |
| --- | --- |
| Bump the swift-crypto pin | 4.5.1 has byte-identical sources. There is no released fix to move to |
| `-Xswiftc -target arm64-apple-macos27.0` | The `@available(macOS 10.15)` on the conforming type is what blocks the witness, not the deployment target. Gets further into the build, fails the same way |
| Point `.swift-version` at `xcode` or a snapshot | Drags every other machine and CI along to satisfy one beta install, and breaks the *Verify the toolchain* step, since there is no `swift:xcode` image |

The last row is the one worth resisting hardest, and it is the same argument as
[*Upgrading*](#upgrading) in reverse. The pin's value is that it reads the same everywhere. A beta OS
is the one machine allowed to be wrong, so **the answer is to build on a machine with a shipping
SDK**, not to move the pin. Decided that way on 2026-08-16, and the pin stayed at 6.3.3.

**Resolved 2026-08-17** by returning that machine to the shipping macOS release. The pin never moved,
and nothing in the project changed. Recorded because the failure recurs with every beta cycle, and
the three rows above are what stops someone re-diagnosing it each time.

If a build is genuinely needed on such a machine, override locally and leave the file alone:

```bash
swiftly run swift build +xcode                # swiftly lists `xcode` as a system toolchain
xcrun swift build                             # equivalent, bypassing swiftly
```

Both invoke a *different compiler build* than the pin names, so give them their own scratch
directory. Otherwise this is exactly the mixed-`.build` corruption in the appendix below:

```bash
xcrun swift build --scratch-path /tmp/company-directory-xcode-build
```

**CI cannot see any of this**, which is the point of running it in `swift:6.3.3` on Linux. No macOS
SDK is involved, so the failure cannot reach it. See [`CI.md`](CI.md) → *Green in CI, will not build
on your Mac* for the same event read from the other side.

## The split reaches the bundled tools too

The two toolchains do not just differ in compiler build. They ship **different versions of the tools
bundled with them**, and `swift-format` is the one this project meets first:

| Invocation | Toolchain | swift-format |
| --- | --- | --- |
| `swift format` (bare) | Xcode | **6.3.0** |
| `~/.swiftly/bin/swift format` | swift.org 6.3.3 | **6.3.3** |
| CI, inside `swift:6.3.3` | swift.org 6.3.3 | **6.3.3** |

Note the direction is the reverse of what you might guess. Xcode's is the *older* one.

**This does not carry the `.build` hazard.** `swift format` reads and writes source files; it runs no
build. I timestamped `.build`, linted a file, and nothing inside `.build` changed. The corruption in
the appendix below came from `swift build`, not from the bundled tools.

**And on this codebase the two versions currently agree**, which is worth knowing rather than
fearing. Run over all tracked `.swift` files with the project's intended settings, 6.3.0 and 6.3.3
produce byte-identical output and the same 42 findings.

The reason to use the swiftly path anyway is the failure mode *if* a future pair diverges, which is
unusually hard to read: you format locally, CI lints with a different version and goes red, you
re-run the formatter, it re-applies the same output, and nothing changes. The rule is therefore the
same one that already applies to `swift build`, which is to invoke the toolchain by path, and it now
has two reasons behind it rather than one.

See issue #6 for the formatting work itself.

## Moving the project directory invalidates the module cache

Renaming the working directory on 2026-08-16 broke the build, and the message names the cause
exactly:

```
error: precompiled file '.../company-directory/.build/.../ModuleCache/..._Builtin_stdbool.pcm'
       was compiled with module cache path '/Users/glenn/Developer/Vapor/foobar/.build/...'
       but the path is currently '/Users/glenn/Developer/Vapor/company-directory/.build/...'
```

**Precompiled modules record the absolute path they were built under.** `.build` moves with the
directory, so every `.pcm` in it now disagrees with where it sits. The failure surfaces as
`fatal error: could not build module '_DarwinFoundation1'`, which reads like a broken toolchain
rather than a moved folder.

The fix is narrow. Delete only the module cache, not the whole build directory:

```bash
find .build -maxdepth 3 -type d -name ModuleCache -exec rm -rf {} +
```

That cost seconds and kept the rest of the 5.6 GB build tree. `rm -rf .build` also works and costs a
full cold rebuild for no extra benefit.

Same family as the corruption described above. `.build` holds absolute paths and compiler-specific
artefacts, so anything that changes the path or the compiler can invalidate it while leaving it
looking intact.

## Relationship to CI

`.swift-version` is the contract between a development machine and the runner. CI's Swift version has
to agree with this file, so an upgrade is a single commit that moves both together and gets validated
on a branch rather than discovered mid-task locally. See [`POSTGRES.md`](POSTGRES.md) for the Linux
build check, which uses the matching `swift:6.3` image.

## Appendix, the error that prompted this

While swapping the SQLite driver for PostgreSQL (step 2 of [`POSTGRES.md`](POSTGRES.md)), a build
that should have failed with a plain "no such module" produced this instead:

```
Sources/CompanyDirectory/Database.swift:2:8: error: compiled module was created by a newer version
of the compiler: .build/arm64-apple-macosx/debug/Modules/FluentSQLiteDriver.swiftmodule
```

The message is misleading. Nothing was newer. Inspecting the modules showed two compilers had written
into the same `.build`:

```
FluentSQLiteDriver.swiftmodule    Aug 13 11:19   swiftlang-6.3.3.1.3     ← Xcode
FluentPostgresDriver.swiftmodule  Aug 14 19:15   swift-6.3.3-RELEASE     ← swiftly
```

`strings <module> | grep "Swift version"` is what shows this. The version number alone hides it.

Two conditions had to coincide. The toolchain differed, **and** `fluent-sqlite-driver` had just left
the dependency graph, so `swift package resolve` deleted its checkout while leaving the compiled
module orphaned in `.build`. Nothing rebuilt it, because it was no longer in the graph; nothing
deleted it either; and the still-present `import FluentSQLiteDriver` found it on the search path
anyway.

**Do not over-learn from this.** An ordinary toolchain change rebuilds every module in the graph and
is harmless. It was the orphan that made it strange.

The fix is `swift package clean`, which discards compiled products while keeping `.build/checkouts`,
so no dependency is re-fetched.

**The tell for this whole family of problems** is an error about a module you did not change, naming
a path inside `.build`. Reach for `swift package clean` before debugging the source.
