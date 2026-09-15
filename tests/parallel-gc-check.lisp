;;; Managed roots and exact arithmetic across observed collections.
(in-package :maxima)

(defun gc-test-supported-p ()
  #+(or sbcl ccl clisp ecl) t
  #-(or sbcl ccl clisp ecl) nil)

(defun gc-test-collect ()
  ($garbage_collect))

(defun gc-test-stamp ()
  #+sbcl sb-kernel::*gc-epoch*
  #+ccl (nth-value 0 (ccl::gccounts))
  #+clisp (let ((*standard-output* (make-broadcast-stream)))
            (nth-value 3 (room nil)))
  #+ecl (nth-value 1 (si:gc-stats t))
  #-(or sbcl ccl clisp ecl) nil)

(defun gc-test-with-observer (thunk)
  #+ecl
  (multiple-value-bind (bytes count old-status) (si:gc-stats t)
    (declare (ignore bytes count))
    (unwind-protect (funcall thunk) (si:gc-stats old-status)))
  #-ecl (funcall thunk))

(defun gc-test-observed-collection (lock)
  (declare (ignorable lock))
  ;; Serialize instrumentation, including ECL's global statistics reader.
  ;; This lock never spans mathematics, worker creation or joining.
  (%with-lock (lock)
    (let ((before (gc-test-stamp)))
      (and (eq (gc-test-collect) t)
           #+sbcl (not (eq before (gc-test-stamp)))
           #-sbcl (> (gc-test-stamp) before)))))

(defstruct gc-test-root
  seed token ring aliases table closure bytes integer mate expression variable
  bigfloat bigfloat-snapshot rational digits)

(defun gc-test-bigfloat-snapshot (value)
  ;; Preserve every mantissa bit independently of the original bignum, plus
  ;; header flags, precision and exponent. No Lisp printer runs during GC.
  (let* ((mantissa (second value))
         (bits (make-array (1+ (integer-length mantissa)) :element-type 'bit)))
    (dotimes (index (length bits))
      (setf (sbit bits index) (if (logbitp index mantissa) 1 0)))
    (list (copy-list (car value)) bits (third value))))

(defun gc-test-make-root (seed)
  (let* ((bits (1+ (mod seed 4096)))
         (integer (1- (ash 1 bits)))
         (mate (1+ (ash 1 bits)))
         (token (gensym "GC-TOKEN-"))
         (shared (list token integer mate))
         (ring (cons token nil))
         (aliases (vector shared shared))
         (table (make-hash-table :test 'eq))
         (bytes (make-array 257 :element-type '(unsigned-byte 8)))
         (variable (gensym "GC-VARIABLE-"))
         (digits (+ 17 (mod seed 111)))
         (rational (/ (- (mod seed 20001) 10000)
                      (+ 3 (mod (ash seed -8) 997)))))
    (setf (cdr ring) ring (gethash token table) shared)
    (dotimes (index (length bytes))
      (setf (aref bytes index) (mod (+ seed index) 256)))
    (mset '$fpprec digits)
    (let ((bigfloat ($bfloat (cl-rat-to-maxima rational))))
      (make-gc-test-root
       :seed seed :token token :ring ring :aliases aliases :table table
       :closure (lambda () (values shared token)) :bytes bytes
       :integer integer :mate mate :variable variable
       :expression (add (mul integer variable) 7)
       :bigfloat bigfloat :bigfloat-snapshot (gc-test-bigfloat-snapshot bigfloat)
       :rational rational :digits digits))))

(defun gc-test-valid-root-p (root seed)
  (let* ((bits (1+ (mod seed 4096)))
         (token (gc-test-root-token root))
         (ring (gc-test-root-ring root))
         (aliases (gc-test-root-aliases root))
         (bytes (gc-test-root-bytes root))
         (integer (gc-test-root-integer root))
         (mate (gc-test-root-mate root))
         (bigfloat (gc-test-root-bigfloat root))
         (rational (/ (- (mod seed 20001) 10000)
                      (+ 3 (mod (ash seed -8) 997)))))
    (and (= (gc-test-root-seed root) seed)
         (= integer (1- (ash 1 bits))) (= mate (1+ (ash 1 bits)))
         (= (mul integer mate) (1- (ash 1 (* 2 bits))))
         (= (maxima-substitute 3 (gc-test-root-variable root)
                      (gc-test-root-expression root))
            (+ (ash integer 1) integer 7))
         (eq (cdr ring) ring) (eq (car ring) token)
         (= (length aliases) 2) (eq (aref aliases 0) (aref aliases 1))
         (eq (car (aref aliases 0)) token)
         (= (hash-table-count (gc-test-root-table root)) 1)
         (eq (gethash token (gc-test-root-table root)) (aref aliases 0))
         (equal (cdr (aref aliases 0)) (list integer mate))
         (multiple-value-bind (shared closed-token) (funcall (gc-test-root-closure root))
           (and (eq shared (aref aliases 0)) (eq closed-token token)))
         (= (length bytes) 257)
         (loop for byte across bytes for index from 0
               always (= byte (mod (+ seed index) 256)))
         (= rational (gc-test-root-rational root))
         (= (gc-test-root-digits root) (+ 17 (mod seed 111)))
         ($bfloatp bigfloat)
         (equal (gc-test-bigfloat-snapshot bigfloat)
                  (gc-test-root-bigfloat-snapshot root))
         (< (/ (abs (- (parallel-precision-test-rational bigfloat) rational))
               (max 1 (abs rational)))
            (expt 10 (- 3 (gc-test-root-digits root)))))))

(defun gc-test-seeds (seed)
  (loop repeat 16
        do (setq seed (mod (+ (* seed 1664525) 1013904223) (expt 2 32)))
        collect seed))

(defun gc-test-valid-roots-p (roots seeds)
  (and (= (length roots) 16) (= (length seeds) 16)
       (every #'gc-test-valid-root-p roots seeds)))

(defun gc-test-run-body (seed collect-p lock)
  (let* ((seeds (gc-test-seeds seed))
         (roots (mapcar #'gc-test-make-root seeds)))
    (and (gc-test-valid-roots-p roots seeds)
         (loop repeat 3 always
               (and (or (not collect-p) (gc-test-observed-collection lock))
                    (gc-test-valid-roots-p roots seeds))))))

(defun gc-test-mode (mode)
  (if (and (eq mode '$worker) (not (parallel-threads-p))) '$fallback mode))

(defun $parallel_gc_site (mode collect-p)
  (when (and collect-p (not (gc-test-supported-p)))
    (return-from $parallel_gc_site ($parallel_gc_site mode nil)))
  (gc-test-with-observer
   (lambda ()
     (call-with-captured-bindings
      (capture-bindings (specials-to-bind nil))
      (lambda ()
        (let* ((lock (%make-lock "observed garbage collection"))
               (result (parallel-input-run
                        (lambda () (gc-test-run-body 48173 collect-p lock))
                        (gc-test-mode mode))))
          (if (eq mode '$public) (every #'identity result) result)))))))

(defun $parallel_gc_nested (outer-mode inner-mode)
  (parallel-input-run
   (lambda () ($parallel_gc_site inner-mode t))
   (gc-test-mode outer-mode)))

(defun $parallel_gc_observer_check (exit-kind)
  (labels ((exercise ()
             (let ((observed nil)
                   (result
                     (catch 'gc-test-exit
                       (handler-case
                           (multiple-value-list
                            (gc-test-with-observer
                             (lambda ()
                               (case exit-kind
                                 ($error (error "Expected GC observer error."))
                                 ($throw (throw 'gc-test-exit :thrown))
                                 (otherwise (values nil 37))))))
                         (error () :error)))))
               (setq observed
                     (case exit-kind
                       ($error (eq result :error))
                       ($throw (eq result :thrown))
                       (otherwise (equal result '(nil 37)))))
               observed)))
    #+ecl
    (multiple-value-bind (bytes count original) (si:gc-stats t)
      (declare (ignore bytes count))
      (unwind-protect
           (loop for setting in '(nil t :full) always
                 (progn
                   (si:gc-stats setting)
                   (and (exercise)
                        (eq setting (nth-value 2 (si:gc-stats setting))))))
        (si:gc-stats original)))
    #-ecl (exercise)))

(defun $parallel_gc_native (busy-p)
  (declare (ignorable busy-p))
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (return-from $parallel_gc_native ($parallel_gc_site '$fallback t))
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (when (parallel-threads-p)
    (gc-test-with-observer
     (lambda ()
       (let* ((lock (%make-lock "GC rendezvous"))
              (collector-lock (%make-lock "GC observation"))
              (progress (vector 0 0)) (released 0) (cancelled nil)
              (threads nil) (jobs nil) (collected t))
         (labels
             ((await-state (predicate)
                (let ((deadline (+ (get-internal-real-time)
                                   (* 15 internal-time-units-per-second))))
                  (loop
                    (when (%with-lock (lock) (funcall predicate)) (return t))
                    (when (or (%with-lock (lock) cancelled)
                              (> (get-internal-real-time) deadline))
                      (return nil))
                    (sleep 0.001))))
              (work (role)
                ;; These roots are created inside the worker. The controller
                ;; receives only the final boolean, never the object graph.
                (let* ((seeds (gc-test-seeds (+ 48173 role)))
                       (roots (mapcar #'gc-test-make-root seeds)))
                  (and
                   (gc-test-valid-roots-p roots seeds)
                   (if busy-p
                       (loop
                         (when (%with-lock (lock) cancelled)
                           (return (gc-test-valid-roots-p roots seeds)))
                         ;; Bound work if a controller fails to release us.
                         (when (%with-lock (lock) (>= (aref progress role) 4096))
                           (return nil))
                         (unless (gc-test-valid-roots-p roots seeds) (return nil))
                         (%with-lock (lock) (incf (aref progress role))))
                       (loop for round from 1 to 3 always
                             (progn
                               (%with-lock (lock) (setf (aref progress role) round))
                               (and (await-state (lambda () (>= released round)))
                                    (gc-test-valid-roots-p roots seeds))))))))
              (make-job (role)
                (make-parallel-job
                 :thunks (vector (lambda () (work role)))
                 :results (vector nil) :errors (vector nil) :count 1
                 :lock (%make-lock "GC worker job")
                 :captured (capture-bindings (specials-to-bind nil)))))
           (unwind-protect
                (progn
                  (dotimes (role 2)
                    (let ((job (make-job role)))
                      (push job jobs)
                      (push (%spawn (run-worker job) "GC root worker") threads)))
                  (let ((distinct (not (eq (first threads) (second threads)))))
                    (loop for round from 1 to 3
                          do (unless (await-state
                                      (lambda ()
                                        (every (lambda (count) (>= count round)) progress)))
                               (setq collected nil) (return))
                             (let ((before (%with-lock (lock) (copy-seq progress))))
                               (unless (gc-test-observed-collection collector-lock)
                                 (setq collected nil))
                               (if busy-p
                                   (unless (await-state
                                            (lambda () (every #'> progress before)))
                                     (setq collected nil) (return))
                                   (%with-lock (lock) (setq released round)))))
                    ;; Parked workers must consume the final release before
                    ;; cancellation: their wait checks readiness and abort
                    ;; separately. Busy workers need a stop signal to finish.
                    (when (or busy-p (not collected))
                      (%with-lock (lock) (setq cancelled t)))
                    (dolist (thread threads) (%join thread))
                    (setq threads nil)
                    (and collected distinct
                         (every (lambda (count) (>= count 3)) progress)
                         (every (lambda (job)
                                  (and (equalp (job-results job) #(t))
                                       (not (aref (job-errors job) 0)))) jobs))))
             (%with-lock (lock) (setq cancelled t))
             (dolist (thread threads) (%join thread)))))))))
