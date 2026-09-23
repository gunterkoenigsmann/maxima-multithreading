# Shared mutable state in Maxima

An inventory of the state two computations would share if Maxima ever ran
them at the same time, checked against the source rather than collected
from memory.

It is worth having whether or not Maxima ever grows threads. Most of what
is below is also the answer to "why did that global change under me", and
several entries are latent bugs in the single-threaded code -- a cache
that can exceed its own documented limit, an unwinding loop that depends
on a variable nobody thinks of as shared.

## How to read this

Every claim is marked **measured** or **read**. "Read" means it was
worked out from the source and not run; the two disagree often enough in
this codebase that the distinction is worth the words. Rates like "2 of
200" come from running the case that many times on four cores.

Locations are file plus construct name, never line numbers.

Entries are grouped by the **kind** of state, because the kind decides
what could fix it. A variable that merely holds the state of one
computation can be bound per thread and needs nothing else; a counter on
a property list cannot be bound at all.

## 1. Specials holding the state of one computation

The easy case, and the one the existing groundwork addresses. These hold
something belonging to a single evaluation, so a binding at the point a
thread starts makes every assignment below it land in that thread's own
binding, and no caller or callee has to change.

| state | where | note |
|---|---|---|
| `SIGN`, `MINUS`, `ODDS`, `EVENS` | `src/compar.lisp` | one answer in four variables, set together |
| `WIDTH`, `HEIGHT`, `DEPTH` | `src/displa.lisp` | box dimensions |
| `VARLIST`, `GENVAR`, `VLIST` | `src/rat3*.lisp` | CRE's variables and their ordering |
| `TSTACK`, `*LOCAL-SIGNS*`, `$MULTIPLICITIES`, `$%RNUM_LIST`, `$ERROR`, `$ERROR_SYMS`, `$LINENUM`, `$GENSUMNUM`, `$INTEGRATION_CONSTANT_COUNTER` | various | state of one line of computation |
| `$PIECE` | `src/globals.lisp` | the part the last `part()`/`inpart()` selected; read right afterwards by `trgsmp.mac` and other share packages (issue #66) |
| `SN*`, `SD*` | `src/csimp2.lisp` | numerator and denominator factors `PRODND` hands back to `COMDENOM` (`xthru`); bound by `COMDENOM` itself (issue #70) |

`WITH-THREAD-LOCAL-ENVIRONMENT` (`src/suprv1.lisp`) binds these.
**Measured** by the groundwork on a `SIGN`-shaped protocol raced between
two threads: 1797 wrong answers in 4000 unbound, 0 bound.

## 2. Specials that are one half of a pair

The trap in the first category. Some of these variables are bookkeeping
for state that lives somewhere a binding cannot reach, and binding one
without the other is worse than leaving both alone.

**`$FPPREC` and the bigfloat constants.** `$FPPREC` carries an `ASSIGN`
property of `FPPREC1`, so an ordinary `fpprec: 30` rewrites the working
precision `FPPREC` and rebuilds `*BIGFLOATONE*`, `*BIGFLOATZERO*`,
`*BFHALF*` and `*BFMHALF*` from it, globally, in one go. Binding a subset
leaves a thread whose precision disagrees with its own constants. (read)

**`CURRENT` and the `CMARK` counts.** `CURRENT` (`src/db.lisp`) records
which context the fact database has marked. `CONTEXTMARK` does nothing
when it already equals `CONTEXT`, so sharing it is why a parallel region
nested inside a parallel body cannot see the facts of the body that
started it. But binding it is worse: the other half of the pair is the
`CMARK` counts on the context symbols' plists (sec. 6), which no binding
can reach, so a thread with its own `CURRENT` unmarks its caller's chain,
marks its own, and then loses the binding on the way out while the counts
it changed stay changed. **Measured**: binding `CURRENT` alone took a
plain inherited `assume()` from 0 wrong in 200 to **200 wrong in 200**.

> The rule this gives: before binding anything here, ask what else moves
> when it moves. The pair goes together or not at all.

## 3. Symbol value cells written through a generic setter

Maxima binds a user variable by **saving the symbol's value, `MSET`ting
it, and putting the old value back** -- `MBIND-DOIT` and `MUNBIND` in
`src/mlisp.lisp`. That writes the one global value cell every thread
shares, and because the write goes through `MSET` rather than a `SETQ`
naming the variable, a cross-reference search for assignments finds
nothing at all.

**Measured**: a parallel `makelist` whose body was no more than `i^2`
returned a wrong list **2 times in 200**, an element having been computed
with another element's index. Giving each runner its own binding of the
loop variable: 0 in 200.

This is also the shape the observation half of
`lisp-utils/thread-safety-survey.lisp` is blind to: a save-and-restore
leaves no net change, so watching value cells over a `run_testsuite()`
cannot see it either. Both halves of that tool miss this, and it sits in
the evaluator's most central mechanism.

## 4. Shared stacks

`BINDLIST` and `MSPECLIST` (`src/mlisp.lisp`) are the stacks `MBIND`
pushes saved values onto; `LOCLIST` (`src/globals.lisp`) is `MLOCAL`'s.

They are not merely accounting. `ERRCATCH` (`src/errset.lisp`) saves
`(cons bindlist loclist)`, and `ERRLFUN1` (`src/suprv1.lisp`) unwinds by
calling `MUNLOCAL` until `LOCLIST` is `EQ` to the cons it saved. Shared
between threads, that cons is no longer anywhere in the unwinding
thread's chain, so the loop pops an already-empty `LOCLIST` for ever.

**Measured**: an error raised in one element of a parallel `makelist`
left the whole run spinning at full CPU with its workers already gone, on
about **half** of the runs of the error test and **one full suite run in
five**. With `LOCLIST` bound per runner: 0 of 30, and 0 of 12.

Note `MUNLOCAL` also pops `MPROPLIST` and `FACTLIST`, which `MLOCAL`
pushes alongside `LOCLIST`. What a `local()` inside a parallel body does
to those has not been measured. (read)

## 5. Lists mutated by read, modify, write

**`$CONTEXTS`.** `$SUPCONTEXT` (`src/compar.lisp`) registers a new
context with `(setq $contexts (mcons name $contexts))` -- a read, a cons
and a write of one shared list. Two runners doing it at once lose one of
the two names, and the runner whose name went missing then dies with
`supcontext: no such context ctxt<n>`.

**Measured**: `parallel_makelist(integrate(x^i, x), i, 1, 8)` failed
**30 times out of 30**, and a scratch context was left behind in the
user-visible `contexts` list. `integrate()` reaches this constantly
through `WITH-NEW-CONTEXT` (`src/maxmac.lisp`), which makes a gensym
context, works in it and kills it again. With the context variables bound
per runner: 0 of 30, nothing left behind.

**`$PROPS`, `$VALUES`, `$FUNCTIONS`, `$RULES`, `$ARRAYS`, `$LABELS`,
`$STRUCTURES`.** Same family. `ADD2LNC` extends `$PROPS` with
`(nconc llist (ncons item))`, mutating the list in place and never
assigning the variable, so a cross-reference search sees nothing here
either. (read)

## 6. Counters on property lists

Which facts are visible is decided by `CONTEXTMARK` (`src/db.lisp`),
which keeps a **count on each context symbol's plist** and walks the
chain incrementing and decrementing it:

```lisp
(defun cmark (con)
  (let ((cm (zl-get con 'cmark)))
    (putprop con (if cm (1+ cm) 1) 'cmark)
    (mapc #'cmark (zl-get con 'subc))))
```

A read, an add and a write, on state every thread shares. Concurrent
runners lose each other's updates and the count on a context holding real
assumptions drifts to zero, after which its facts are invisible.

**Measured**: with each runner given its own context (an attempt at
scoping a body's facts to the body), a plain inherited `assume()` went
from right every time to **wrong 157 times in 200**, getting worse the
longer the session ran, against **0 in 200** on the serial path -- which
creates and kills exactly the same contexts. The scoping was therefore
sound and concurrency alone broke it. It is written down and switched off
in `src/parallel.lisp`.

> **A lock here is not enough, and this is the entry most likely to be
> got wrong.** Serialising the counter walk stops updates being lost and
> is still incorrect, because the count is a count: two runners' chains
> end up marked at the same time and each can then see the other's facts.
> Marking has to become per thread, which means these counts have to stop
> living on shared plists.

## 7. The fact database

The assumptions themselves do not live in variables. They live on
**symbol plists** -- `src/db.lisp` writes them with `putprop`, and a
symbol's facts hang off its `data` property. There is no variable to
bind, so no dynamic binding can make the database per thread; it wants
either a lock or a real per-thread store.

The interning tables in front of it are shared in the ordinary way as
well: `DINTERN` (`src/db.lisp`) extends `DOBJECTS` with
`(setq dobjects (cons (dbnode x) dobjects))`, and numbers go into
`*NOBJECTS*` the same way -- read, cons, write, as in sec. 5. So two
threads mentioning an expression the database has not seen before race
before either of them has asserted anything. (read)

**Measured**, with the context variables bound per runner and nothing
else: a body's own assumption was invisible to its own `sign()`
**2 times in 200** with threads, **0 times in 200** on the serial path.

Two lifetimes share the one store, which complicates any scheme: `assume`
facts survive between inputs, while `asksign` facts are cleared between
them by `CLEARSIGN` (defined in `src/compar.lisp`, called from
`src/suprv1.lisp`).

## 8. In-place mutation a cross-reference search cannot see

**`LINEARRAY`** (`src/displa.lisp`) is the clearest example in the tree:
it is **never assigned anywhere**. It is `defvar`'d once and thereafter
mutated with `(setf (aref linearray i) ...)` and `(fill linearray nil)`.
A search for assignments to it returns nothing, and it appears in the
survey's classification only because somebody read the code. It is
`DISPLA`'s layout scratch, so two threads displaying at once corrupt each
other's output before a character reaches any stream -- and a lock around
the *writing* would not help, since the corruption is in the buffer.

For a user-settable option variable, **a static count of zero is not
evidence of anything**.

## 9. Global hash tables

`src/` has 35 `make-hash-table` calls, one of them commented out. 16 are
top-level, in a `defvar` or `defparameter`; the rest are locals inside a
function or a macro expansion and belong to one call.

This section was originally written from the call sites. It has since
been **measured**, by `lisp-utils/hash-table-survey.lisp`, which watches
every symbol in the image whose value is a hash table -- rather than a
list of names, so a table nobody has thought of shows up by itself --
records each table's key set and the value under each key, runs a
workload twice and reports what moved. Keys and not counts, because
replacing the value under a key already present leaves the count where
it was.

Two controls, because two unrelated faults both produce an empty report.
Every workload form is checked for having evaluated: a workload that
threw on its first line would watch a table nobody touched and call all
of them clean. And `*OPR-TABLE*`, which the workload writes by calling
`infix()`, must appear in the result, so a snapshot looking in the wrong
place says so instead of passing.

The image holds **28** global hash tables, which is more than `src/`
creates: `defsystem`, `cl-info`, `intl` and `f2cl-lib` contribute the
rest.

### Written while a computation runs

**Measured**, on SBCL, by the survey:

| table | where | written by |
|---|---|---|
| `*OPR-TABLE*` | `src/opr-util.lisp` | `PUTOPR`, reached from `infix()` and friends |
| `*DIRECTORY-CACHE*` | `src/mload.lisp` | every path search; also `REMHASH` on eviction |
| `*TEMP-FILES-LIST*` | `src/globals.lisp` | `PLOT-TEMP-FILE0`, on every plot |
| `*LAMBDA-EXPR-FUNS*` | `src/mlisp.lisp` | `LAMBDA-EXPR-FUN`, on every miss |
| `CL-INFO::*INFO-TABLES*` | `src/cl-info.lisp` | `ENSURE-INFO-TABLES`, when a documentation index loads |

This **corrects** an earlier reading of this section, which listed
`*OPR-TABLE*` among the tables "filled once and read thereafter".
`infix()` is a Maxima-level command, so it writes the table whenever a
user calls it.

`CL-INFO::*INFO-TABLES*` was not in the first inventory at all. Loading
a share package does not touch it, but loading a documentation index
does: **measured**, `load("logic-index")` took it from 1 entry to 2.
`describe()` maps over the same table, so this is the iterate-while-
insert case and not merely a lost entry.

### Written only as files load

`*VARIABLE-INITIAL-VALUES*`, `*FLONUM-OP*`, `*BIG-FLOAT-OP*`,
`*RUNNING-ERROR-OP*`, `*COLOR-TABLE*`,
`*ATAN2-EXTENDED-REAL-HASHTABLE*`, `*BUILTIN-SYMBOL-PROPS*`,
`*BUILTIN-SYMBOL-VALUES*`, `CL-INFO::*HTML-INDEX*`, the `intl` tables
and `defsystem`'s own.

**Measured** unchanged -- same key set, same value under every key --
across two passes of a workload of integration, factoring, solving,
Taylor series, bigfloat arithmetic, assume/sign/forget, matrix
arithmetic, `makelist`, `parallel_makelist` and `describe`.

That is a **conditional** answer, not a clean bill of health, and the
condition is that nothing loads a file from a worker, which is #41.
**Measured**: `load("f90")` adds an entry to `*VARIABLE-INITIAL-VALUES*`
at run time, because a share file full of `defmvar` forms writes one per
variable. So the cost of allowing `load()` inside a parallel body is not
only the loader; it is every table any loaded file fills, at once.

### Per-call locals

`factor.lisp`, `numth.lisp` (twice), `mload.lisp` (twice),
`clmacs.lisp`, `float.lisp` inside a macro expansion, `sublis.lisp`
bound to a special that is always `LET`-bound. **Measured** absent from
the survey's roll, which is what a table with no global value cell looks
like, and consistent with reading them.

### What a synchronized table buys

`clmacs.lisp` defines `%MAKE-HASH-TABLE`, which adds `:SYNCHRONIZED` on
SBCL and nothing at all anywhere else.

**SBCL is the only lisp on that list, and that is a measured result
rather than the starting assumption.** Each of the others was tried and
each failed differently, which is the most useful thing this section
has to report:

| lisp | what happened |
|---|---|
| SBCL 2.2.9 | works; 160000 of 160000 kept, repeatedly |
| CLISP 2.49.93 | rejects `:SYNCHRONIZED` outright |
| CCL 1.12 | accepts `:SHARED`, and it buys nothing -- see below |
| ECL 24.5.10 | accepts `:SYNCHRONIZED`, then cannot build Maxima with it |

ECL fails while loading `init-cl`, which is where
`*BUILTIN-SYMBOL-PROPS*` and `*VARIABLE-INITIAL-VALUES*` are filled,
with `When acting on lock #<rwlock ...>, got an unexpected error`. ECL
21.2.1 performs the same operations -- put, get, a nested lookup inside
a write, and `MAPHASH` while writing -- without complaint, so this is a
property of that release rather than of the code above it. Until
somebody works out which, ECL gets a plain table.

So **there is no portable synchronized hash table across the lisps
Maxima supports.** A table two threads must write wants a lock, and this
constructor is an optimisation on SBCL rather than the general answer.
That is the finding to carry into any further threading work, and it is
worth more than the constructor is.

`%MAKE-HASH-TABLE` is in `clmacs.lisp` and not beside
`%MAKE-LOCK` in `parallel.lisp` for a load-order reason: `globals.lisp`
and `opr-util.lisp` create their tables in top-level `defvar`s, and both
load long before `parallel.lisp`.

It matters. **Measured** on SBCL 2.2.9, eight threads inserting 20000
entries each into one `EQUAL` table:

| table | entries kept of 160000 | threads that errored |
|---|---|---|
| plain, trial 1 | 869 | 8 of 8 |
| plain, trial 2 | 218 | 8 of 8 |
| plain, trial 3 | 328 | 8 of 8 |
| synchronized, 3 trials | 160000 each | none |

The error is `Unsafe concurrent operations on #<HASH-TABLE ...>
detected`, so on SBCL this is loud. Do not read that as a guarantee.
The same experiment on **CCL 1.12** kept 159998 of 160000 and raised
nothing: two entries gone, no error, no warning. A lisp that does not
police its own tables loses data quietly, and quietly is worse.

### CCL has no synchronized table, and that is the larger finding

CCL accepts `:SHARED`, so the first version of this work took it and the
check passed. It passed by luck; run again, it failed. The measurement
underneath says why -- eight threads, 20000 `EQUAL` inserts each,
CCL 1.12, entries **lost** of 160000:

| table | trials |
|---|---|
| plain | 2, 4 |
| `:shared t` | 4, 2 |
| `:lock-free t` | 5, 5 |
| `:shared t :lock-free t` | 1, 7 |
| plain, **lock held around the write** | 0, 0 |
| `:shared t`, **lock held around the write** | 0, 0, 0 |

Checked by looking up all 160000 keys afterwards and by walking the
table, not by `HASH-TABLE-COUNT` alone -- the entries really are gone,
and nothing is signalled for any of them. So on CCL no table option
buys safety and only a lock does, and `%MAKE-HASH-TABLE` returns a
plain table there: a table that needs a lock must not be made to look
like one that does not.

Two things follow. Maxima's shared tables are unprotected on CCL
whatever this section does, so CCL wants a lock per table rather than a
constructor. And the loss is small and silent -- single digits in
160000, no condition raised -- which is precisely the shape that
survives a test suite and reaches a user as one wrong answer.

`CHECK-SYNCHRONIZED-HASH-TABLE` in
`lisp-utils/thread-environment-check.lisp` runs that experiment under
`make check` on every lisp that has threads, because the constructor
probes only that the keyword was *accepted* and not that it was acted
on. Its own controls: the same inserts run serially must all survive, so
a loss belongs to the concurrency and not to the counting; and the
workers meet at a barrier before the first insert, so a scheduler free
to run them one after another cannot produce a false pass. The plain
table is written the same way and reported but never asserted on,
because how badly it breaks is a property of the lisp. **Measured** on
the same experiment under `make check`: SBCL 2.2.9 kept 11201 of 160000
and signalled in all eight threads; **CCL 1.12 kept 159998 and signalled
nothing**. CCL is the warning here, not the reassurance -- it lost two
entries in silence, which is the failure mode that reaches a user as a
wrong answer rather than as a crash. An assertion that the control must
lose entries would be answered by those two, which is too close to none
to depend on.

### What it does not buy, and what the cost is

Two things it does not buy:

- Synchronization is per operation, not per iteration. A table mapped
  over while another thread inserts -- `WITH-HASH-TABLE-ITERATOR`, the
  eviction pattern in `MAPPLY1`, the searches in `cl-info` -- is still
  undefined. Those want a lock over both halves, as `*TEMP-FILES-LIST*`
  has in `plot.lisp`, or a table per thread, as `*LAMBDA-EXPR-FUNS*`
  has.
- It is not a substitute for asking which bucket a table is in. A
  synchronized table full of state two threads disagree about is a
  correct data structure holding a wrong answer.

What it does **not** cost is speed. **Measured** on SBCL 2.2.9: a
synchronized `gethash` is about five times a plain one, 10ns against
51ns over 10^7 lookups, and `puthash` 16ns against 48ns. But Maxima does
not spend its time in hash lookups. `*FLONUM-OP*` is the hottest global
table and is consulted once per float function evaluation, so
`makelist(sin(float(i))+cos(float(i)), i, 1, 60000)` does some 120000
lookups: 41ns each is 5ms against a 320ms workload, 1.5%.

Below the noise, and the control is what says so. A/B in one image over
15 interleaved trials, swapping the table the global points at:

| arm | min | median |
|---|---|---|
| plain A | 0.320s | 0.328s |
| plain B (control) | 0.304s | 0.348s |
| synchronized | 0.312s | 0.360s |

The control -- two identical plain tables raced against each other --
moves by -5.0% on the minimum and +6.1% on the median. The synchronized
arm moves by -2.5% and +9.8%. The effect is inside the noise floor of
the machine, and on the minimum estimator the synchronized table was the
faster of the two.

A 320ms workload has a +/- 6% noise floor, which is too coarse to see a
1.5% effect either way, so the same question was put to the benchmark
the Maxima team uses: a full `run_testsuite()`, 17671 tests and roughly
98 seconds a run. Four rounds, ordered base / converted / base, so the
two base runs measure the noise at that scale:

| arm | n | min | median | mean |
|---|---|---|---|---|
| base A | 4 | 96.43s | 98.59s | 99.27s |
| base B (control) | 4 | 97.21s | 98.07s | 98.14s |
| converted | 4 | 96.95s | 98.33s | 98.04s |

The control moves by +0.8% on the minimum and -0.5% on the median --
two builds of identical source. The converted tree moves by +0.5% and
+0.0% against all eight base runs. The difference is smaller than the
spread between two runs of the same code, at a scale where 1.5% would
have been visible.

All twelve runs reported **1 test failed out of 17671**, the same
`rtest3` problem 222 in every arm, base included. So the conversion is
behaviour-neutral across the suite as well as free.

One benchmark on one lisp: a table read in a genuinely tight inner loop
would show the difference, and Maxima has none.

So every global table in `src/` that two threads could reach now goes
through `%MAKE-HASH-TABLE`, rather than only the ones measured moving
today. `*LAMBDA-EXPR-FUNS*` and `*TEMP-FILES-LIST*` stay plain on
purpose: the first is rebound per thread by
`WITH-THREAD-LOCAL-ENVIRONMENT` and the second is guarded by a lock that
also covers the iteration, and in both cases a synchronized table would
cover strictly less. `intl`'s tables stay plain because `intl.lisp`
loads before `clmacs.lisp`.

**`*LAMBDA-EXPR-FUNS*` is worth fixing regardless of threads.** It
memoises compiled functions for the Lisp lambda expressions applied by
`MAPPLY1`, and its eviction branch runs `WITH-HASH-TABLE-ITERATOR`,
`RANDOM` on one shared random state, and `REMHASH` -- a combination the
standard does not define under concurrent modification.

**Measured**, four threads each applying 400 distinct expressions:

| run | worker threads that died | final size (limit 128) |
|---|---|---|
| 1 | 4 of 4 | 14 |
| 2 | 2 of 4 | **129** |
| 3 | 1 of 4 | **135** |

The deaths are SBCL's own internal assertion,
`failed AVER: (= SB-IMPL::HWM (HASH-TABLE-SIZE TABLE))` -- the table's
internal structure corrupted, not merely a wrong answer. And the cache
exceeded the limit its own docstring says it must not grow past.

**Reachability**: `MAPPLY1` uses this branch only for a **Lisp** lambda;
Maxima's own `lambda([x], ...)` is `((lambda) ...)` and goes to
`MLAMBDA` instead. So this is a real defect on a path ordinary Maxima
code does not currently reach -- latent rather than live. A table per
thread fixes both halves of it, and is what the groundwork does.

## 10. Streams

A new thread inherits no dynamic bindings, only global values, so a
thread that reads `*STANDARD-OUTPUT*` for itself gets the session-wide
stream and not whatever its caller had bound.

This is not theoretical: `RUN_TESTSUITE` rebinds `*STANDARD-OUTPUT*`
around each problem to capture what it prints (`TEST-BATCH`,
`src/mload.lisp`). **Measured**: a message printed by a worker walked
past the harness into the log while the same message printed by the
calling thread was caught, so the suite's own output changed from run to
run according to which runner took the failing element -- found by
diffing three whole-suite runs against each other rather than comparing
their headline results. Capturing the streams in the thread that starts
the workers: 0 of 8 runs.

Also per-lisp: `read()` takes `*STANDARD-INPUT*` under SBCL and CMUCL and
`*QUERY-IO*` elsewhere (the `#+(or sbcl cmu)` in `src/macsys.lisp`), so a
worker must bind both. (measured by the groundwork)

## 11. Working arrays reached through a symbol

Gaussian elimination (`TFGELI` and `TFGELI1`, `src/mat.lisp`) is handed
its matrix as a **symbol** and reaches the array through that symbol's
value (`GET-ARRAY-POINTER`). The functions that build the array store it
with `(setf (symbol-value name) ...)`: `FORMX` for `SOLVEX`
(`src/solve.lisp`, symbol `XA*`), and `MTOA` for the matrix functions
(`src/matrix.lisp`, `*MAT*`) and for the Risch integrator's `LSA`
(`src/risch.lisp`, `*JM*`). `TFGELI1` assigns its row and column
permutations `*ROW*`, `*COL*` and `*COLINV*` in the same way. No owner
bound its variable, so every call wrote one global value cell. For
`XA*`, `*MAT*` and `*JM*` a search for assignments finds nothing, because
the write goes through `SYMBOL-VALUE` and not a `SETQ`.

**Measured** on SBCL, 48 parallel items and three workers, five runs
each. Every run of `solve`, `linsolve`, `determinant` (`ratmx:true`),
`rank`, `echelon`, `triangularize` and `invert_by_gausselim` failed,
either with a Lisp error or by hanging until the time limit. Binding only
`XA*` turned three of five `solve` runs into **wrong solutions with no
error at all**. Four threads calling `LSA` directly hung without the
`*JM*` binding. With each owner binding its own variable (issue #58), the
same runs all return the serial answers.

> The rule this gives: a symbol handed to a function as the **name of its
> data** is a variable, and whoever builds the data must bind it.

The same shape remains, not yet changed, in `src/linnew.lisp` (`tmlinsolve`
and friends) and in the sparse determinant (`src/sprdet.lisp`,
`src/newinv.lisp`), each with globals of its own. **Measured**: even a
serial `determinant` under `sparse:true` still assigns the global `*ROW*`
and `*COL*`, because `SPRDET` reaches `TMLATTICE` in `src/linnew.lisp`.

The same shape occurs without a symbol handed around. `$ALLROOTS` and
`$BFALLROOTS` (`src/cpoly.lisp`) `SETQ` ten work arrays declared only by
a `DECLARE-TOP` (`*PR-SL*`, `*PI-SL*`, `*SHR-SL*`, ...), fill them in
`CPOLY-SL`/`RPOLY-SL`, and read the roots back out of them. **Measured**
on SBCL, 48 parallel calls per run: 14 to 21 errors, plus 7 to 18 results
that differed from serial **without an error**. Some were partial
factorizations with complex coefficients for a real polynomial; others
were roots whose residual reached 223475. The scalars of the same files
were already bound: after calls exercising the real, complex, bigfloat
and `polyfactor` paths, only the ten arrays had global values. Each call
now binds them (issue #65).

## 12. State in closures over a top-level LET

```lisp
(let ((base nil) (pow nil) (exptflag nil))
  (defun superexpt ...)
  (defun elemxpt ...))
```

This looks private, and in one thread it behaves like private state. But
the `LET` runs once, when the file is loaded, so every thread's calls
share its **one** set of cells. Unlike a special, no binding can give a
thread its own copy. Neither a search for specials nor the survey's
observation of value cells can see these cells.

`src/sin.lisp` had three such blocks: `SUPEREXPT`'s base, power and
failure flag, which `ELEMXPT` reads and sets; `SUBST41`'s root form and
variables, which `SUBST4` reads; and `POWERL`, set by `INTFORM` and read by
`INTEGRATOR`.

**Measured** on SBCL, 48 items with three workers: parallel
`integrate(%e^(i*%e^(%i*x)), x)` differed from serial in 4 runs of 4. With
a factor `%e^(%i*x)`, 3 runs of 4 failed outright, because a worker took
a method the serial computation never reaches and hit the guard against
loading a package in a parallel body. Replaying real `SUBST41` arguments
from four threads gave 349 and 420 wrong results in 1600 calls, and 0 in
400 from one thread. No failure was reproduced for `POWERL` (0 of 6
mixed runs).

Each name now stands, through `SYMBOL-MACROLET`, for a special that
`WITH-THREAD-LOCAL-ENVIRONMENT` binds to `NIL` in every thread (issue
#63). The function bodies are unchanged. Each cell is written before it
is read, and one thread still has one set of cells, so a single thread
computes exactly what it did before, recursion included. Binding per call
instead would have changed what a nested call leaves behind for its
caller.

The same shape remains in `src/irinte.lisp` (`CHECKSIGNTM`'s
`ZEROSIGNTEST` and `PRODUCTCASE`, also used by `src/hyp.lisp`). Replaying
its real arguments from four threads gave no wrong result in 13,600 calls,
so it is left alone until something shows it matters. (measured)

## 13. Variables of share packages written in Maxima

A Maxima function that assigns a variable it has not made a `block`
local writes that variable's global value cell, which every thread shares.
Only bindings go through `MBIND`, and only those are private to a runner
(sec. 3). Share packages written in Maxima do this on purpose to pass
state between their functions. Some even declare the variables globally
first, as `share/algebra/nusum.mac` does with `dva(%r); dva(p); dva(%cf);`.

**Measured**: 48 parallel `nusum(k^2 + i, k, 1, n)` differed from serial
in 4 runs of 4 on SBCL, in one run 46 of 48 items. For `i = 1` a correct
`(n*(2*n^2+3*n+7))/6` became a rational function carrying a free
parameter `%r50`. `nusuml` assigned `%r` (the term ratio) and `%cf` (the
coefficients) as globals. Binding those two per runner as a probe made 4
runs of 4 match serial, while binding `$RATVARS` (which `nusuml` also sets
globally) changed nothing. The fix makes them locals of `nusuml`'s `block`
(issue #66).

`trigsimp` failed for a core reason instead: `trgsmp.mac` reads `piece`
right after `inpart()`, and `$PIECE` was shared. It is now bound per
thread (sec. 1). **Measured**: 48 parallel `trigsimp()` calls failed in 4
runs of 4 before, and matched serial in 4 of 4 with the binding. `lsquares_estimates_exact`
(`share/lsquares/lsquares.mac`) kept the stationary points from `solve()`
in the global `solutions`. **Measured**: 7 to 18 of 48 parallel exact fits
fell back to numerical approximations, e.g. `a = 3.00085` for `a = 3`.
`solutions` is now a `block` local.

`simplify_sum` (`share/solve_rec/simplify_sum.mac`) had both kinds of
problem: variables it forgot to make locals (`polypart`, `support`, `dif`,
`ni_coeffs`, `quolim`), and **contexts named by recursion depth alone**
(`ss_context1`, `ss_context`, `sum_by_integral1`), killing any existing
context of that name first. Concurrent sums therefore killed and re-created
each other's contexts. **Measured**: 24 parallel sums differed from serial
in 3 runs of 3 on SBCL. On CCL they raised `supcontext: no such context`,
overflowed the value stack, or ended a `run_testsuite()` session silently
(7 of 30 runs), against 0 of 20 once every call worked in a context of its
own. The same name clash crashes Maxima even serially: with a user context
`ss_context1` current, the old code killed it and re-created it beneath
itself, and CLISP died with "Program stack overflow". The same issue lists
`eigenvalues`,
`eigenvectors` and `trigrat` as failing in parallel, with their causes not
yet established.

## What this adds up to

Three of these can be fixed by binding, and are: the per-computation
specials (sec. 1), the stacks (sec. 4), the streams (sec. 10). One is
fixed by binding but only if the whole pair moves (sec. 2, sec. 5).

Two cannot be fixed by binding at all, because the state is not in a
variable: the `CMARK` counts (sec. 6) and the fact database itself
(sec. 7). Those two are the real decision, and the ordering between them
is forced -- the counts have to become per-thread before any scheme for
the database can be evaluated, because until then every experiment on the
database is measuring the counts instead.

One is a plain bug worth fixing on its own account (sec. 9).

## Method, and two things that cost time

**Every measurement needs a control.** A first attempt to observe what a
`makelist` body disturbs reported 0 of 958 variables moved, which read as
a clean result. It was not: every body had errored on a bad parse call and
the workload never ran. What exposed it was asserting that `$LINENUM`
must move, since it moves for any input that runs at all.

The control that separated design from implementation throughout this
document is **the serial path**: running the same code with the thread
limit set to 1 exercises identical machinery without concurrency. Where
serial is clean and threaded is not, the design is sound and the sharing
is the problem -- which is how sec. 6 was diagnosed.

**Say whether a claim was measured or read.** Two things in this document
were believed, written down, and then turned out to be wrong when run:
that the CRE `GENVAR` renumbering was corrupting parallel rational
arithmetic (it was the loop variable, sec. 3), and that scoping a body's
facts to its own context would work (sec. 6).
