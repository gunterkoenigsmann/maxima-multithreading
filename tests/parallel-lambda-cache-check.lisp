;;; Cache transactions must preserve exact functions under reentry and threads.
(in-package :maxima)

(defvar *lambda-cache-test-hook* nil)
(defmacro lambda-cache-test-expression (body)
  ;; A real compiler callback, without replacing LAMBDA-EXPR-FUN or COERCE.
  (if *lambda-cache-test-hook* (funcall *lambda-cache-test-hook* body) body))

(defun lambda-cache-test-eager-coercion-p ()
  ;; COERCE promises a closure, not eager compilation (CLHS COERCE).
  ;; Keep compiler RNG effects local, including on CLISP.
  (let* ((*random-state* (make-random-state nil))
         (expanded nil)
         (*lambda-cache-test-hook* (lambda (body) (setq expanded t) body)))
    (coerce (list 'lambda nil '(lambda-cache-test-expression 19)) 'function)
    expanded))

(defun lambda-cache-test-thread ()
  #+sb-thread sb-thread:*current-thread*
  #+(and ccl openmcl-native-threads (not sb-thread)) ccl:*current-process*
  #+(and ecl threads (not sb-thread) (not ccl)) mp:*current-process*
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads)) nil)

(defun lambda-cache-test-state (state)
  (let ((copy (make-random-state state)))
    (loop repeat 16 collect (random 65536 copy))))

(defun $lambda_cache_basic (limit)
  (let* ((*lambda-expr-funs* (make-hash-table :test 'eq))
         (*lambda-expr-funs-max* limit)
         (*lambda-expr-funs-random* (make-random-state nil))
         (eager (lambda-cache-test-eager-coercion-p))
         (compiled 0)
         (*lambda-cache-test-hook* (lambda (body) (incf compiled) body))
         (key (list 'lambda '(n) '(lambda-cache-test-expression (+ n 19))))
         (copy (copy-tree key))
         (first (lambda-expr-fun key))
         (after-first compiled)
         (second (lambda-expr-fun key)))
    (and (or (not eager) (plusp after-first))
         (= (funcall first -29) -10) (= (funcall second 37) 56)
         (equal key copy)
         (if (zerop limit)
             (and (or (not eager) (> compiled after-first)) (zerop (hash-table-count *lambda-expr-funs*)))
             (and (or (not eager) (= compiled after-first)) (eq first second)
                  (eq first (gethash key *lambda-expr-funs*))
                  (= (hash-table-count *lambda-expr-funs*) 1)
                  ;; Structurally equal code is still a different EQ key.
                  (progn (lambda-expr-fun copy)
                         (= (hash-table-count *lambda-expr-funs*) (min 2 limit))))))))

(defun $lambda_cache_random ()
  ;; Precompile before observing the caller RNG: CLISP's compiler itself uses
  ;; *RANDOM-STATE*. Coercing these function objects needs no compilation.
  (let* ((functions (loop for index below 16 collect
                     (coerce (list 'lambda '(n) (list '+ 'n index)) 'function)))
         (*lambda-expr-funs* (make-hash-table :test 'eq))
         (*lambda-expr-funs-max* 4)
         (*lambda-expr-funs-random* (make-random-state nil))
         (caller-state (lambda-cache-test-state *random-state*))
         (cache-state (lambda-cache-test-state *lambda-expr-funs-random*)))
    (and (loop for function in functions for index from 0 always
           (and (eq function (lambda-expr-fun function))
                (= (funcall (lambda-expr-fun function) 91) (+ 91 index))))
         (= (hash-table-count *lambda-expr-funs*) 4)
         (equal caller-state (lambda-cache-test-state *random-state*))
         (not (equal cache-state (lambda-cache-test-state *lambda-expr-funs-random*))))))

(defun lambda-cache-test-cases ()
  (loop with state = 563117 repeat 64 collect
    (progn
      (setq state (mod (+ (* state 1664525) 1013904223) (expt 2 32)))
      (let* ((bits (1+ (mod (ash state -3) 257)))
             (negative (logbitp 0 state))
             (coefficient (1- (ash 1 bits)))
             (argument (- (ash state (mod (ash state -12) 257)) 17))
             (offset (- (ash state 7) 100003))
             (expected (- (ash argument bits) argument))
             (form (list 'lambda '(n)
                         (list 'add (list 'mul 'n (if negative (- coefficient) coefficient)) offset))))
        ;; Shift/subtract is independent of the multiplication under test.
        (list form argument (+ (if negative (- expected) expected) offset) (copy-tree form))))))

(defun lambda-cache-test-evaluate (cases)
  (every (lambda (record)
           (and (eql (mapply1 (first record) (list (second record)) '$lambda_cache_test nil)
                     (third record))
                (equal (first record) (fourth record))))
         cases))

(defun $lambda_cache_arithmetic (mode limit)
  (let* ((table (make-hash-table :test 'eq :size 4))
         (random (make-random-state nil))
         (cases (lambda-cache-test-cases))
         (origin (lambda-cache-test-thread))
         (lock (%make-lock "lambda cache arithmetic observations"))
         (seen 0) (sites-correct t)
         (saved (list *live-workers* *peak-workers* *items-run-by-workers*))
         (actual-mode
           #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads)) mode
           #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
           (if (eq mode '$worker) '$fallback mode)))
    (declare (ignorable lock))
    (unwind-protect
         (let ((result
                 (parallel-input-run
                  (lambda ()
                    (%with-lock (lock)
                      (incf seen)
                      (setq sites-correct
                            (and sites-correct
                                 (case actual-mode
                                   ($worker (not (eq origin (lambda-cache-test-thread))))
                                   ($public t)
                                   (otherwise (eq origin (lambda-cache-test-thread)))))))
                    (let ((*lambda-expr-funs* table) (*lambda-expr-funs-max* limit)
                          (*lambda-expr-funs-random* random))
                      (and (lambda-cache-test-evaluate cases)
                           (lambda-cache-test-evaluate (reverse cases)))))
                  actual-mode)))
           (and (= (length cases) 64) sites-correct
                (= seen (if (eq actual-mode '$public) 8 1))
                (if (eq actual-mode '$public) (every #'identity result) result)
                (if (zerop limit) (zerop (hash-table-count table))
                    (<= #+gcl 0 #-gcl 1 (hash-table-count table) limit))))
      (%with-lock (*budget-lock*)
        (setf *live-workers* (first saved)
              *peak-workers* (second saved)
              *items-run-by-workers* (third saved))))))

(defun $lambda_cache_reentrant (cache-depth limit)
  (unless (lambda-cache-test-eager-coercion-p)
    (return-from $lambda_cache_reentrant
      (and ($lambda_cache_basic limit) ($lambda_cache_arithmetic '$serial limit))))
  (let ((*lambda-expr-funs* (make-hash-table :test 'eq))
        (*lambda-expr-funs-max* limit)
        (*lambda-expr-funs-random* (make-random-state nil))
        (seen 0) (functions nil))
    (labels ((compile-level (cache-level)
               (let* ((*lambda-cache-test-hook*
                        (lambda (body)
                          (incf seen)
                          (when (plusp cache-level) (compile-level (1- cache-level)))
                          body))
                      (form (list 'lambda '(n)
                                  (list 'lambda-cache-test-expression (list '+ 'n cache-level))))
                      (function (lambda-expr-fun form)))
                 (push (cons cache-level function) functions)
                 function)))
      (compile-level cache-depth)
      (and (= seen (1+ cache-depth)) (= (length functions) (1+ cache-depth))
           (every (lambda (entry) (= (funcall (cdr entry) 129) (+ 129 (car entry)))) functions)
           (if (zerop limit) (zerop (hash-table-count *lambda-expr-funs*))
               (<= 1 (hash-table-count *lambda-expr-funs*) limit))))))

(defun $lambda_cache_reentrant_same_key ()
  (unless (lambda-cache-test-eager-coercion-p)
    (return-from $lambda_cache_reentrant_same_key ($lambda_cache_basic 4)))
  (let* ((*lambda-expr-funs* (make-hash-table :test 'eq))
         (*lambda-expr-funs-max* 4)
         (*lambda-expr-funs-random* (make-random-state nil))
         (retained (loop for index below 3 collect
                     (let ((form (list 'lambda '(n) (list '+ 'n index))))
                       (cons form (lambda-expr-fun form)))))
         (random (lambda-cache-test-state *lambda-expr-funs-random*))
         (key (list 'lambda nil '(lambda-cache-test-expression 7)))
         (copy (copy-tree key)) (inner nil)
         (*lambda-cache-test-hook*
           (lambda (body)
             (declare (ignore body))
             (let ((*lambda-cache-test-hook*
                     (lambda (form) (declare (ignore form)) 0)))
               (setq inner (lambda-expr-fun key)))
             1))
         (outer (lambda-expr-fun key)))
    (and (= (funcall outer) 1) (= (funcall inner) 0)
         (= (funcall (gethash key *lambda-expr-funs*)) 1)
         (= (hash-table-count *lambda-expr-funs*) 4)
         (every (lambda (entry) (eq (cdr entry) (gethash (car entry) *lambda-expr-funs*))) retained)
         (equal random (lambda-cache-test-state *lambda-expr-funs-random*))
         (equal key copy))))

(defun $lambda_cache_failure ()
  (let* ((*lambda-expr-funs* (make-hash-table :test 'eq))
         (*lambda-expr-funs-max* 1)
         (*lambda-expr-funs-random* (make-random-state nil))
         (key (list 'lambda '(n) '(+ n 7)))
         (function (lambda-expr-fun key))
         (random (lambda-cache-test-state *lambda-expr-funs-random*)))
    (and (handler-case (progn (lambda-expr-fun 17) nil) (error () t))
         (= (hash-table-count *lambda-expr-funs*) 1)
         (eq function (gethash key *lambda-expr-funs*))
         (equal random (lambda-cache-test-state *lambda-expr-funs-random*))
         (= (funcall (lambda-expr-fun key) 11) 18))))

(defun $lambda_cache_values (limit)
  (let ((*lambda-expr-funs* (make-hash-table :test 'eq))
        (*lambda-expr-funs-max* limit)
        (*lambda-expr-funs-random* (make-random-state nil))
        (zero (list 'lambda nil '(values 17 nil -23)))
        (rest (list 'lambda '(a &optional (b 5) &rest tail) '(values (+ a b) tail))))
    (and (equal (multiple-value-list (mapply1 zero nil '$lambda_cache_test nil)) '(17 nil -23))
         (equal (multiple-value-list (mapply1 rest '(7) '$lambda_cache_test nil)) '(12 nil))
         (equal (multiple-value-list (mapply1 rest '(7 11 13 17) '$lambda_cache_test nil)) '(18 (13 17)))
         (handler-case (progn (mapply1 zero '(1) '$lambda_cache_test nil) nil) (error () t))
         (equal (multiple-value-list (mapply1 zero nil '$lambda_cache_test nil)) '(17 nil -23)))))

(defun $lambda_cache_concurrent (kind)
  (declare (ignorable kind))
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (return-from $lambda_cache_concurrent ($lambda_cache_reentrant 3 1))
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (unless (lambda-cache-test-eager-coercion-p)
    ;; The separate stress probe still overlaps native cache accesses.
    (return-from $lambda_cache_concurrent ($lambda_cache_arithmetic '$worker 1)))
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (let* ((table (make-hash-table :test 'eq :size 4)) (random (make-random-state nil))
         (lock (%make-lock "lambda compiler rendezvous"))
         (entered (vector nil nil)) (finished (vector nil nil))
         (threads (vector nil nil)) (results (vector nil nil)) (errors (vector nil nil))
         (key (list 'lambda '(n) '(lambda-cache-test-expression (+ n 13))))
         (keys (list key (if (eq kind '$same_key) key
                            (list 'lambda '(n) '(lambda-cache-test-expression (+ n 29))))))
         (workers nil))
    (labels ((wait-for (predicate)
               (loop with end = (+ (get-internal-real-time) (* 5 internal-time-units-per-second))
                     until (%with-lock (lock) (funcall predicate))
                     do (when (> (get-internal-real-time) end)
                          (error "Lambda compiler rendezvous timed out"))
                        (sleep 0.001)))
             (worker (role)
               (with-thread-local-environment
                 (let ((*lambda-expr-funs* table) (*lambda-expr-funs-max* 1)
                       (*lambda-expr-funs-random* random)
                       (*lambda-cache-test-hook*
                         (lambda (body)
                           (%with-lock (lock)
                             (setf (aref entered role) t
                                   (aref threads role) (lambda-cache-test-thread)))
                           (wait-for (lambda () (every #'identity entered)))
                           (when (= role 1) (wait-for (lambda () (aref finished 0))))
                           ;; Each caller must receive its own coercion result;
                           ;; the last publication remains in the cache.
                           (if (eq kind '$same_key) (list 'list body role) body))))
                   (unwind-protect
                        (handler-case
                            (setf (aref results role)
                                  (funcall (lambda-expr-fun (nth role keys)) 7))
                          (error () (setf (aref errors role) t)))
                     (%with-lock (lock) (setf (aref finished role) t)))))))
      (when (eq kind '$full)
        (let ((*lambda-expr-funs* table) (*lambda-expr-funs-max* 1)
              (*lambda-expr-funs-random* random))
          (lambda-expr-fun '(lambda (n) (- n)))))
      (unwind-protect
           (progn
             (dotimes (role 2)
               (let ((index role))
                 (push (list (%spawn (lambda () (worker index)) "lambda cache regression") nil) workers)))
             (dolist (record workers) (%join (first record)) (setf (second record) t))
             (and (every #'identity entered) (every #'identity finished)
                  (not (eq (aref threads 0) (aref threads 1)))
                  (notany #'identity errors)
                  (equalp results (if (eq kind '$same_key) #((20 0) (20 1)) #(20 36)))
                  (= (hash-table-count table) 1)
                  (let ((cached (gethash (second keys) table)))
                    (and cached (equal (funcall cached 7)
                                       (if (eq kind '$same_key) '(20 1) 36))))))
        ;; CCL joins consume completion notifications. Join each worker once.
        (dolist (record workers) (unless (second record) (%join (first record))))))))

(defun $lambda_cache_stress (limit)
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (return-from $lambda_cache_stress ($lambda_cache_arithmetic '$fallback limit))
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (let* ((table (make-hash-table :test 'eq :size 1)) (random (make-random-state nil))
         (cases (lambda-cache-test-cases)) (workers nil)
         (ready (make-array 4 :initial-element nil))
         (identities (make-array 4 :initial-element nil))
         (results (make-array 4 :initial-element nil))
         (lock (%make-lock "lambda cache stress")))
    (unwind-protect
         (progn
           (dotimes (role 4)
             (let ((index role))
               (push
                (list
                 (%spawn
                  (lambda ()
                    (with-thread-local-environment
                      (handler-case
                          (let ((*lambda-expr-funs* table) (*lambda-expr-funs-max* limit)
                                (*lambda-expr-funs-random* random))
                            (%with-lock (lock)
                              (setf (aref ready index) t
                                    (aref identities index) (lambda-cache-test-thread)))
                            (loop with end = (+ (get-internal-real-time) (* 5 internal-time-units-per-second))
                                  until (%with-lock (lock) (every #'identity ready))
                                  do (when (> (get-internal-real-time) end)
                                       (error "Lambda cache stress workers did not overlap"))
                                     (sleep 0.001))
                            (setf (aref results index)
                                  (loop repeat 4 always (lambda-cache-test-evaluate cases))))
                        (error () (setf (aref results index) nil)))))
                  "lambda cache stress worker") nil)
                workers)))
           (dolist (record workers) (%join (first record)) (setf (second record) t))
           (and (every #'identity ready) (every #'identity results)
                (= (length (remove-duplicates (coerce identities 'list))) 4)
                (<= 1 (hash-table-count table) limit)
                (let ((*lambda-expr-funs* table) (*lambda-expr-funs-max* limit)
                      (*lambda-expr-funs-random* random))
                  (lambda-cache-test-evaluate cases))))
      (dolist (record workers) (unless (second record) (%join (first record)))))))

(defun $lambda_cache_interpreted ()
  #+sbcl
  (let ((sb-ext:*evaluator-mode* :interpret))
    (and (not (lambda-cache-test-eager-coercion-p))
         ($lambda_cache_basic 0) ($lambda_cache_basic 1)
         ($lambda_cache_reentrant 3 1)
         ($lambda_cache_concurrent '$cold)
         ($lambda_cache_arithmetic '$serial 1)
         ($lambda_cache_values 1)))
  #-sbcl
  ($lambda_cache_basic 1))
