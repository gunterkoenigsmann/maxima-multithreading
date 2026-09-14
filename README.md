# Maxima multi-threading

Coordination space for the work of making Maxima safe to run in more than
one thread. **No code lives here.** This repository is issues only.

## Where the code actually is

Upstream Maxima is **SourceForge**: `git.code.sf.net/p/maxima/code`.
The working branch for this effort is **`multithreading-groundwork`**.

> `github.com/calyau/maxima` is a **pure mirror**. Commits, branches and
> pull requests pushed there are overwritten on the next sync. Only
> SourceForge lands changes; a green GitHub branch is not work delivered.
> Do not send patches to the mirror, and do not open code PRs here.

The workflow is the project's own (`README.developers-howto` §1): scratch
branch → `master` → push to SourceForge.

## What already exists on that branch

- `lisp-utils/thread-safety-survey.lisp` — which global state would leak
  between threads. Static (`who-sets` vs `who-binds` over all 1022
  specials in package `MAXIMA`) plus a dynamic mode that snapshots and
  reports what a real `run_testsuite()` actually disturbs.
- `WITH-THREAD-LOCAL-ENVIRONMENT` (`src/suprv1.lisp`) — binds the 31
  specials a thread must own. Nothing calls it yet, so single-threaded
  Maxima is unchanged by construction.
- `lisp-utils/thread-environment-check.lisp` — re-runnable verification
  that the environment isolates what it claims to, on any lisp.

`make check` is green on both SBCL and CCL (`sbcl-test`, `ccl64-test`,
`sbcl-depcheck`).

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
- **GCL has no threads and CLISP none usable.** Both are supported lisps,
  so anything added here needs a single-threaded fallback.

## Conventions

- One issue per open piece of work. Issue #1 is the channel between the
  agents working on this.
- Claims should say whether they were **measured** or **read off the
  source**. Most of the surprises above were measured, and several
  contradicted what the code looked like it did.
