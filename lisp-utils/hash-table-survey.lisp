;;;; hash-table-survey.lisp -- which global hash tables a computation writes
;;;;
;;;; src/ creates 35 hash tables and synchronizes none of them (#131).
;;;; Most are believed to be filled once as the files load and only read
;;;; afterwards, which costs nothing to share between threads.  The ones
;;;; that are written while a computation runs are races the moment two
;;;; computations run at once.  Which table is in which group was read
;;;; off the call sites; this runs the experiment instead.
;;;;
;;;; It watches every symbol in the image whose value is a hash table --
;;;; not a hand-written list of names -- so a table nobody has thought
;;;; about yet, or one a share file creates as it loads, appears by
;;;; itself.
;;;;
;;;;     ./maxima-local --very-quiet --no-init
;;;;     :lisp (load "lisp-utils/hash-table-survey.lisp")
;;;;     :lisp (maxima-hash-survey:survey)
;;;;
;;;; WHAT IS COMPARED.  Counting entries is not enough: replacing the
;;;; value under a key that is already there leaves the count where it
;;;; was, and that is exactly the shape a re-run DEFMVAR has in
;;;; *VARIABLE-INITIAL-VALUES*.  So each table is snapshotted as its key
;;;; set plus the value under each key, and the report separates keys
;;;; added, keys removed, and keys whose value moved.
;;;;
;;;; A table with more than *DETAIL-LIMIT* entries is snapshotted by
;;;; count alone, because the snapshot holds a reference to every key and
;;;; value it records and would otherwise pin an unbounded amount of what
;;;; the workload allocates.  Those rows say so, and a change they report
;;;; is a floor rather than a measurement.
;;;;
;;;; THE CONTROLS.  Two, because two different things can make this
;;;; report an empty page.
;;;;
;;;;   - Every workload form is checked for having evaluated without an
;;;;     error.  A workload that quietly threw on its first line would
;;;;     observe a table nobody touched and report every one of them
;;;;     unchanged, which reads exactly like good news.
;;;;
;;;;   - *OPR-TABLE* is asserted to have grown.  The workload calls
;;;;     infix("@@"), which writes it through PUTOPR, so a run in which
;;;;     that table is reported unchanged means the snapshot is not
;;;;     looking where it thinks it is.
;;;;
;;;; The workload runs twice, from three snapshots, because "written at
;;;; runtime" and "written once and then reused" want different fixes.  A
;;;; table that grows in the first pass and not in the second is a cache
;;;; filling up; one that grows in both is written per call.

(defpackage #:maxima-hash-survey
  (:use #:common-lisp)
  (:export #:tables #:snapshot #:diff #:survey #:*workload*))

(in-package #:maxima-hash-survey)

;;; ------------------------------------------------------------------
;;; Finding the tables

(defparameter *ignored-package-prefixes*
  '("SB-" "SB!" "COMMON-LISP" "KEYWORD" "MAXIMA-HASH-SURVEY"
    "MAXIMA-THREAD-SURVEY")
  "Packages whose tables are the implementation's business, not ours.
Everything else is surveyed, including packages a share file creates as
it loads, so the list of tables grows by itself rather than by hand.")

(defun ignored-package-p (package)
  (let ((name (package-name package)))
    (some (lambda (prefix)
            (and (<= (length prefix) (length name))
                 (string= prefix name :end2 (length prefix))))
          *ignored-package-prefixes*)))

(defun surveyed-packages ()
  (remove-if #'ignored-package-p (list-all-packages)))

(defun tables ()
  "Every (SYMBOL . TABLE) pair reachable through a global value cell."
  (let ((seen (make-hash-table :test #'eq))
        (out '()))
    (dolist (package (surveyed-packages))
      (do-symbols (symbol package)
        (unless (gethash symbol seen)
          (setf (gethash symbol seen) t)
          (when (and (boundp symbol)
                     (hash-table-p (symbol-value symbol)))
            (push (cons symbol (symbol-value symbol)) out)))))
    (sort out #'string< :key (lambda (row) (symbol-name (car row))))))

;;; ------------------------------------------------------------------
;;; Snapshots

(defparameter *detail-limit* 5000
  "Above this many entries a table is recorded by count alone.")

(defstruct (snap (:constructor make-snap (table count entries truncated)))
  table          ; the table object, to notice the value cell being replaced
  count
  entries        ; key -> value, or NIL when TRUNCATED
  truncated)

(defun snapshot-table (table)
  (let ((count (hash-table-count table)))
    (if (> count *detail-limit*)
        (make-snap table count nil t)
        (let ((entries (make-hash-table :test (hash-table-test table))))
          (maphash (lambda (key value) (setf (gethash key entries) value))
                   table)
          (make-snap table count entries nil)))))

(defun snapshot ()
  "Record every global hash table as it stands now."
  (let ((out (make-hash-table :test #'eq)))
    (dolist (row (tables))
      (setf (gethash (car row) out) (snapshot-table (cdr row))))
    out))

;;; ------------------------------------------------------------------
;;; Diffing

(defstruct (change (:constructor make-change (symbol status before after
                                              added removed altered)))
  symbol
  status         ; :grew :shrank :altered :replaced :gone :new :same
  before after   ; entry counts
  added removed altered)   ; lists of keys, or NIL when truncated

(defun diff-table (symbol before after)
  "Compare two SNAPs of the same symbol and say what moved."
  (cond
    ((null after) (make-change symbol :gone (snap-count before) 0 nil nil nil))
    ((null before)
     (make-change symbol :new 0 (snap-count after) nil nil nil))
    ((not (eq (snap-table before) (snap-table after)))
     (make-change symbol :replaced (snap-count before) (snap-count after)
                  nil nil nil))
    ((or (snap-truncated before) (snap-truncated after))
     (make-change symbol
                  (cond ((> (snap-count after) (snap-count before)) :grew)
                        ((< (snap-count after) (snap-count before)) :shrank)
                        (t :same))
                  (snap-count before) (snap-count after) nil nil nil))
    (t
     (let ((added '()) (removed '()) (altered '())
           (old (snap-entries before))
           (new (snap-entries after)))
       (maphash (lambda (key value)
                  (multiple-value-bind (was present) (gethash key old)
                    (cond ((not present) (push key added))
                          ((not (eql was value)) (push key altered)))))
                new)
       (maphash (lambda (key value)
                  (declare (ignore value))
                  (unless (nth-value 1 (gethash key new))
                    (push key removed)))
                old)
       (make-change symbol
                    (cond ((and (null added) (null removed) (null altered))
                           :same)
                          (added :grew)
                          (removed :shrank)
                          (t :altered))
                    (snap-count before) (snap-count after)
                    added removed altered)))))

(defun diff (before after)
  "Rows for every table that moved between two SNAPSHOT results."
  (let ((rows '()))
    (maphash (lambda (symbol snap)
               (push (diff-table symbol snap (gethash symbol after)) rows))
             before)
    (maphash (lambda (symbol snap)
               (declare (ignore snap))
               (unless (nth-value 1 (gethash symbol before))
                 (push (diff-table symbol nil (gethash symbol after)) rows)))
             after)
    (sort (remove-if (lambda (row) (eq (change-status row) :same)) rows)
          #'string< :key (lambda (row) (symbol-name (change-symbol row))))))

;;; ------------------------------------------------------------------
;;; The workload

(defparameter *workload*
  '("f : sin(x)/x$"
    "integrate(f, x)$"
    "diff(sin(x)^3, x, 2)$"
    "factor(x^10 - 1)$"
    "solve(x^2 + 3*x + 1 = 0, x)$"
    "taylor(exp(x), x, 0, 8)$"
    "float(sqrt(2)) + float(%pi)$"
    "fpprec : 60$"
    "bfloat(sqrt(2)) * bfloat(%e)$"
    "fpprec : 16$"
    "atan2(inf, 1)$"
    "assume(aa > 0)$"
    "sign(aa)$"
    "forget(aa > 0)$"
    ;; Writes *OPR-TABLE* through PUTOPR.  This is the positive control:
    ;; if the report says that table did not move, the survey is broken.
    "infix(\"@@\")$"
    "1 @@ 2$"
    "random(1000)$"
    "makelist(i^2, i, 1, 50)$"
    "parallel_makelist(i^2, i, 1, 50)$"
    "matrix([1, 2], [3, 4]) . matrix([5, 6], [7, 8])$"
    "string(rat(x^2 - 1))$"
    ;; Reaches *LAMBDA-EXPR-FUNS*, the table SUPRV1 already rebinds per
    ;; thread.  It is in the workload so the inventory can show that.
    "map(lambda([u], u^2 + 1), [1, 2, 3, 4, 5])$"
    ;; Reaches *INFO-TABLES* through the documentation index.
    "describe(\"sin\", exact)$")
  "Ordinary work, every form terminated with $ so MACSYMA-READ-STRING
does not have to extend the string it was handed.")

(defparameter *loading-workload*
  ;; f90 is a Lisp share file with DEFMVAR forms in it, so loading it
  ;; writes *VARIABLE-INITIAL-VALUES* -- a table this survey otherwise
  ;; reports as load-time-only.  eigen is a .mac file and exercises the
  ;; other half, the path search.
  '("load(\"f90\")$"
    "load(\"eigen\")$"
    ;; A documentation index, which is what reaches ENSURE-INFO-TABLES
    ;; and so writes CL-INFO::*INFO-TABLES* -- the table describe()
    ;; iterates.  Loading the share package alone does not do it; the
    ;; index file has to be loaded, so name it outright.
    "load(\"logic-index\")$")
  "Kept apart because it is the case #41 is about: loading from a worker
turns every load-time table write into a runtime one.  Measuring it
separately keeps that out of the ordinary-work numbers.")

(defparameter *plot-workload*
  ;; PLOT-TEMP-FILE0 writes *TEMP-FILES-LIST* before gnuplot is invoked,
  ;; so this measures the table write whether or not gnuplot exists here.
  ;; The form is expected to error on a machine without gnuplot; the
  ;; control for this block is that *TEMP-FILES-LIST* grew, not that the
  ;; form succeeded.
  '("plot2d(x, [x, -1, 1], [gnuplot_term, dumb])$")
  "Plotting, kept apart because it errors where gnuplot is absent.")

(defun eval-maxima (string)
  "Evaluate one Maxima input string, returning T when it did not error.

WITH-$ERROR and WITH-ERRCATCH-TAG-$ERRORS are what errcatch() uses:
without them a Maxima-level error throws to MACSYMA-QUIT and unwinds
straight past HANDLER-CASE, taking the rest of the workload with it and
leaving the failure uncounted."
  (handler-case
      (progn
        (maxima::with-$error
          (maxima::with-errcatch-tag-$errors
            (maxima::meval (maxima::macsyma-read-string string))))
        t)
    (error (condition)
      (format *debug-io* "~&hash-table-survey: ~A errored: ~A~%"
              string condition)
      nil)))

(defun run-workload (forms)
  "Evaluate FORMS with their output thrown away.  Returns how many ran."
  (let ((sink (make-broadcast-stream))
        (ok 0))
    (let* ((*standard-output* sink)
           (*trace-output* sink)
           (*error-output* sink)
           (maxima::$display2d nil))
      (dolist (form forms)
        (when (eval-maxima form) (incf ok))))
    ok))

;;; ------------------------------------------------------------------
;;; Reporting

(defun home-package-name (symbol)
  (let ((package (symbol-package symbol)))
    (if package (package-name package) "#:")))

(defun sample (keys n)
  (let ((shown (subseq keys 0 (min n (length keys)))))
    (format nil "~{~S~^ ~}~:[~; ...~]"
            shown (> (length keys) n))))

(defun report-rows (rows stream label)
  (format stream "~&~%~A: ~D table~:P moved~%" label (length rows))
  (when rows
    (format stream "~&  ~34A ~8A ~7A ~6A ~5A ~5A ~5A~%"
            "TABLE" "PACKAGE" "STATUS" "BEFORE" "AFTER" "+ADD" "~CHG")
    (dolist (row rows)
      (format stream "  ~34A ~8A ~7A ~6D ~5D ~5D ~5D~%"
              (symbol-name (change-symbol row))
              (home-package-name (change-symbol row))
              (string-downcase (symbol-name (change-status row)))
              (change-before row) (change-after row)
              (length (change-added row)) (length (change-altered row))))
    (format stream "~&~%  keys added or altered:~%")
    (dolist (row rows)
      (when (change-added row)
        (format stream "    ~A + ~A~%" (change-symbol row)
                (sample (change-added row) 4)))
      (when (change-altered row)
        (format stream "    ~A ~~ ~A~%" (change-symbol row)
                (sample (change-altered row) 4)))
      (when (change-removed row)
        (format stream "    ~A - ~A~%" (change-symbol row)
                (sample (change-removed row) 4))))))

(defun report-coverage (snapshot stream)
  "List every table being watched, so a missing one is visible.

A table this survey never sees is not a table that does not move: a
LET-bound table inside a function, and a table reachable only through a
structure slot or a closure, both have no global value cell to watch.
Printing the roll makes the gap between this list and the
make-hash-table sites in src/ something a reader can check."
  (let ((rows '()))
    (maphash (lambda (symbol snap)
               (push (list symbol (snap-count snap)) rows))
             snapshot)
    (setf rows (sort rows #'string<
                     :key (lambda (row) (symbol-name (first row)))))
    (format stream "~&~%watched tables (~D):~%" (length rows))
    (format stream "~&  ~38A ~10A ~A~%" "TABLE" "PACKAGE" "ENTRIES")
    (dolist (row rows)
      (format stream "  ~38A ~10A ~D~%"
              (symbol-name (first row))
              (home-package-name (first row))
              (second row)))))

(defun control-ok-p (rows)
  "Did the table the workload is known to write actually move?"
  (let ((opr (find-symbol "*OPR-TABLE*" "MAXIMA")))
    (and opr (find opr rows :key #'change-symbol))))

(defun survey (&key (stream *standard-output*))
  "Measure which global hash tables ordinary work writes.

Runs the workload twice: a table that grows only in the first pass is a
cache filling, one that grows in both is written per call."
  (let* ((before (snapshot))
         (ran-1 (run-workload *workload*))
         (middle (snapshot))
         (ran-2 (run-workload *workload*))
         (after (snapshot))
         (pass-1 (diff before middle))
         (pass-2 (diff middle after)))
    (format stream "~&hash-table-survey: ~D global hash table~:P watched~%"
            (hash-table-count before))
    (format stream "~&  workload: ~D of ~D forms ran in pass 1, ~
~D of ~D in pass 2~%"
            ran-1 (length *workload*) ran-2 (length *workload*))
    (unless (and (= ran-1 (length *workload*))
                 (= ran-2 (length *workload*)))
      (format stream "~&  CONTROL FAILED: a workload form errored, so ~
every unchanged~%    table below is unmeasured rather than clean.~%"))
    (if (control-ok-p pass-1)
        (format stream "~&  control ok: *OPR-TABLE* moved, so the ~
snapshot sees writes.~%")
        (format stream "~&  CONTROL FAILED: *OPR-TABLE* did not move, ~
though infix() wrote it.~%"))
    (report-rows pass-1 stream "pass 1 (cold)")
    (report-rows pass-2 stream "pass 2 (warm)")
    (let* ((load-before (snapshot))
           (ran-3 (run-workload *loading-workload*))
           (load-after (snapshot)))
      (format stream "~&~%load(): ~D of ~D forms ran~%"
              ran-3 (length *loading-workload*))
      (report-rows (diff load-before load-after) stream
                   "loading a share package"))
    (let* ((plot-before (snapshot))
           (ran-4 (run-workload *plot-workload*))
           (plot-rows (diff plot-before (snapshot))))
      (format stream "~&~%plot2d(): ~D of ~D forms ran ~
(an error here is expected without gnuplot)~%"
              ran-4 (length *plot-workload*))
      (let ((temp (find-symbol "*TEMP-FILES-LIST*" "MAXIMA")))
        (if (and temp (find temp plot-rows :key #'change-symbol))
            (format stream "~&  control ok: *TEMP-FILES-LIST* moved.~%")
            (format stream "~&  CONTROL FAILED: *TEMP-FILES-LIST* did ~
not move, so this block~%    measured nothing.~%")))
      (report-rows plot-rows stream "plotting"))
    (report-coverage (snapshot) stream)
    (values)))
