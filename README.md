# Maxima multi-threading

Working space for making Maxima safe to run in more than one thread:
issues here, and the branch mirrored here so everyone can reach it.

## Start here

**This branch (`main`) holds only this file.** The code is on
`multithreading-groundwork`, which is the whole Maxima tree and shares no
history with `main`:

```sh
git clone -b multithreading-groundwork \
    git@github.com:gunterkoenigsmann/maxima-multithreading.git maxima
cd maxima
sh bootstrap                       # ./configure is not checked in
./configure --enable-sbcl          # add --enable-ccl64 if you have CCL
make                               # ~15 min; texinfo/makeinfo is required
make check                         # suite + dependency check
```

`makeinfo` is a hard requirement — without it `./configure` aborts.
Building `--disable-build-docs` works but loses `?` help and prints a
warning at every startup, which pollutes every batch capture.

That tree contains **`AGENTS.md`**, Maxima's own instructions for AI
agents: build system, the edit-test loop, test-suite contract, internal
representation, subsystem traps. Read it before changing anything — most
of the ways to waste a day here are in it.

Then read issue #1 and pick an unassigned issue.

## Two repositories, and which one is which

| | |
|---|---|
| **This repo** | Where the work happens. Issues, branches, review. Branch: `multithreading-groundwork` |
| **SourceForge** `git.code.sf.net/p/maxima/code` | Where Maxima actually lives. Nothing is delivered until it lands here |

Not everyone working on this has a SourceForge account, so **push to this
repo**; whoever has SourceForge access syncs across when a piece is ready
and green:

```sh
git remote add gh git@github.com:gunterkoenigsmann/maxima-multithreading.git
git remote add sf ssh://USER@git.code.sf.net/p/maxima/code
git fetch gh
git push sf multithreading-groundwork      # or merged onto master
```

The two are the same history, so this stays a fast-forward as long as
nobody rewrites what is already pushed. Please don't force-push shared
branches.

> **Never push to `github.com/calyau/maxima`.** That is a *different*
> repo: a pure mirror of SourceForge whose commits, branches and PRs are
> overwritten on the next sync. It is not this one.

## Working agreements

- **One issue per piece of work.** Taking one? **Assign it to yourself**
  — that is how the other side knows not to start it. Issue #1 is the
  channel for questions, hand-offs and disagreements.
- **Say whether a claim was measured or read off the source.** Several
  things here behave differently from how they read, in both directions.
- **Check on both SBCL and CCL.** They disagree often enough that a
  result from one is only a hypothesis about the other. `make check`
  runs both.

## What already exists on the branch

- `lisp-utils/thread-safety-survey.lisp` — which global state would leak
  between threads. Static (`who-sets` vs `who-binds` over all 1022
  specials in package `MAXIMA`: 197 assigned-never-bound, 176 both, 649
  neither) plus a dynamic mode that snapshots and reports what a real
  `run_testsuite()` actually disturbs (49 of 957).
- `WITH-THREAD-LOCAL-ENVIRONMENT` (`src/suprv1.lisp`) — binds the 31
  specials a thread must own. Nothing calls it yet, so single-threaded
  Maxima is unchanged by construction.
- `lisp-utils/thread-environment-check.lisp` — re-runnable verification
  that the environment isolates what it claims to, on any lisp.

`make check` is green on both lisps (`sbcl-test`, `ccl64-test`,
`sbcl-depcheck`): 21,496 tests under CCL, 21,465 under SBCL.

## Things that are true and cost time to rediscover

- **Binding is enough — no caller or callee has to change.** A binding
  up-stack catches every `setq` below it, so COMPAR's
  `sign`/`minus`/`odds`/`evens` out-parameter protocol becomes
  thread-safe with the ~50 share files that reach into it untouched.
- **A new thread inherits no dynamic bindings**, only global values. The
  environment must be entered *inside* the thread; wrapping the spawn in
  a `let` does nothing.
- **`DECLARE-TOP` proclaims at load time only in a macro module.** A
  `let` on a variable declared solely that way binds *lexically* and
  silently isolates nothing. `VLIST` was in exactly that state.
- **`fpprec` is six coupled variables.** `$FPPREC` carries an `ASSIGN` of
  `FPPREC1`, so an ordinary `fpprec: 30` rewrites the working precision
  and four bigfloat constants globally, in one go.
- **`LINEARRAY` is shared display scratch**, so concurrent output corrupts
  before a character reaches any stream — and a *recursive* lock does not
  help, because a thread holding one that starts a parallel loop is not
  the thread its workers run in.
- **`read()` reads `*STANDARD-INPUT*` on SBCL and `*QUERY-IO*` on CCL**
  (the `#+(or sbcl cmu)` in `macsys.lisp`), so a worker must bind both.
- **GCL has no threads and CLISP none usable.** Both are supported lisps,
  so anything added here needs a single-threaded fallback.

## Known blind spots

`who-sets` cannot see top-level assignment, in-place mutation
(`ADD2LNC` `nconc`s onto `$PROPS`; the fact database lives on symbol
plists, not in variables), or assignment from Maxima level via `MSET` —
which makes `display2d:false` invisible. **For a user-settable `defmvar`,
a static count of zero is not evidence of anything.**
