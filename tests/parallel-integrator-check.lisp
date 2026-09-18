;;; Concurrent checks for the integrator's working state in src/sin.lisp:
;;; SUPEREXPT's BASE, POW and EXPTFLAG and SUBST41's ROOTFORM, ROOTVAR
;;; and OLDVAR, which every thread must have to itself.
(in-package :maxima)

(defun integrator-test-subst41-case (c)
  "SUBST41's arguments as RATROOT passes them for x*((2*x+C)/(x+3))^(1/2),
with a root form that differs for each C: a runner that substitutes
another runner's root form gives a visibly different result."
  (let* ((ratroot2 (div (add (mul 2 '$x) c) (add '$x 3)))
         (new-var (make-symbol "RATROOT"))
         (rootform (add (power new-var 2) c)))
    (list (mul '$x (power ratroot2 '((rat simp) 1 2)))
          rootform new-var 2 ratroot2 '$x)))

(defun integrator-test-native (tests)
  "Run each function of TESTS as one item of a parallel job on its own
native worker, all released together, and return true when every one
returned true.  Real workers, not the public scheduler, so ECL's native
threads are exercised too.  Without native threads there is nothing to
race and the result is true."
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (progn tests t)
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (let* ((count (length tests))
         (gate (%make-lock "integrator test gate"))
         (ready 0) (threads nil)
         (deadline (+ (get-internal-real-time)
                      (* 20 internal-time-units-per-second)))
         (job
          (make-parallel-job
           :thunks
           (coerce
            (loop for test in tests
                  collect (let ((test test))
                            (lambda ()
                              ;; No worker starts before all are inside.
                              (%with-lock (gate) (incf ready))
                              (loop until (%with-lock (gate) (= ready count))
                                    do (when (>= (get-internal-real-time)
                                                 deadline)
                                         (error "integrator test rendezvous ~
                                                 timed out"))
                                       (sleep 0.001))
                              (funcall test))))
            'vector)
           :results (make-array count :initial-element nil)
           :errors (make-array count :initial-element nil)
           :count count
           :lock (%make-lock "integrator test job")
           :captured (capture-bindings (specials-to-bind nil)))))
    (unwind-protect
         (progn
           (dotimes (index count)
             (push (%spawn (run-worker job) "integrator test worker")
                   threads))
           (dolist (thread threads) (%join thread))
           (setq threads nil)
           (and (= ready count) (every #'null (job-errors job))
                (every (lambda (value) (eq value t)) (job-results job))))
      (dolist (thread threads) (ignore-errors (%join thread))))))

(defun $parallel_subst41_check ()
  "Four workers substitute with four different root forms at once, 300
times each; every result must equal the one computed serially."
  (let ((groups
         (loop for g below 4
               collect (loop for c from (+ 1 (* 10 g)) to (+ 5 (* 10 g))
                             for args = (integrator-test-subst41-case c)
                             collect (cons args (apply #'subst41 args))))))
    (integrator-test-native
     (loop for group in groups
           collect (let ((group group))
                     (lambda ()
                       (loop repeat 60
                             always (loop for (args . expected) in group
                                          always (alike1 (apply #'subst41 args)
                                                         expected)))))))))

(defun $parallel_superexpt_check ()
  "Four workers integrate %e^(c*%e^(%i*x)), which SUPEREXPT transforms,
for different c at once; every result must equal the serial one."
  (let ((groups
         (loop for g below 4
               collect (loop for c from (+ 1 (* 3 g)) to (+ 3 (* 3 g))
                             for e = (power '$%e
                                            (mul c (power '$%e (mul '$%i '$x))))
                             collect (cons e ($integrate e '$x))))))
    (integrator-test-native
     (loop for group in groups
           collect (let ((group group))
                     (lambda ()
                       (loop repeat 5
                             always (loop for (e . expected) in group
                                          always (alike1 ($integrate e '$x)
                                                         expected)))))))))
