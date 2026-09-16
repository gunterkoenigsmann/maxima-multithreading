;;; Exact generated-parameter identities and their mathematical independence.
(in-package :maxima)

(defun parameter-check-thread ()
  #+sb-thread sb-thread:*current-thread*
  #+(and ccl openmcl-native-threads (not sb-thread)) ccl:*current-process*
  #+(and ecl threads (not sb-thread) (not ccl)) mp:*current-process*
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads)) nil)

(defun parameter-check-number (parameter)
  (and (symbolp parameter)
       (> (length (symbol-name parameter)) 3)
       (string= "$%R" (symbol-name parameter) :end2 3)
       (parse-integer (symbol-name parameter) :start 3 :radix 10)))

(defun $parameter_identity_serial (parameter-start parameter-count)
  (let* (($%rnum parameter-start)
         ($%rnum_list (list '(mlist) '$parameter_identity_sentinel))
         (parameter-prefix $%rnum_list)
         (parameter-values (loop repeat parameter-count collect (make-param))))
    (and (= $%rnum (+ parameter-start parameter-count))
         (eq parameter-prefix $%rnum_list)
         (eq (second $%rnum_list) '$parameter_identity_sentinel)
         (equal (cddr $%rnum_list) parameter-values)
         (loop for parameter in parameter-values for offset from 1
               always (= (parameter-check-number parameter) (+ parameter-start offset)))
         (= (length (remove-duplicates parameter-values)) parameter-count))))

(defun $parameter_identity_reset ()
  (let (($%rnum 0) ($%rnum_list (list '(mlist))))
    (let ((parameter-first (make-param)))
      (setq $%rnum 0)
      (let ((parameter-second (make-param)))
        (and (eq parameter-first '$%r1) (eq parameter-first parameter-second)
             (= $%rnum 1)
             (equal (cdr $%rnum_list) (list parameter-first parameter-first)))))))

(defun $parameter_identity_errors ()
  (let (($%rnum :invalid) ($%rnum_list (list '(mlist))))
    (and (handler-case (progn (make-param) nil) (error () t))
         (eq $%rnum :invalid) (equal $%rnum_list '((mlist)))
         (progn (setq $%rnum 41) (eq (make-param) '$%r42))
         (progn (setq $%rnum_list 17)
                (handler-case (progn (make-param) nil) (error () t)))
         (= $%rnum 43)
         (progn (setq $%rnum_list (list '(mlist))) (eq (make-param) '$%r44))
         (equal $%rnum_list '((mlist) $%r44)))))

(defun parameter-check-solve (parameter-rhs)
  (let (($%rnum_list (list '(mlist))))
    (let* ((parameter-answer
             (mfuncall '$solve
                       (list '(mlist) (list '(mequal) (add '$parameter_check_x '$parameter_check_y)
                                            parameter-rhs))
                       '((mlist) $parameter_check_x $parameter_check_y)))
           (parameter-equations (cdr (second parameter-answer)))
           (parameter-x (third (find '$parameter_check_x parameter-equations :key #'second)))
           (parameter-y (third (find '$parameter_check_y parameter-equations :key #'second)))
           (parameter-symbol (second $%rnum_list)))
      (list (and (= (length parameter-answer) 2)
                 (= (length parameter-equations) 2)
                 (= (length $%rnum_list) 2)
                 (= (add parameter-x parameter-y) parameter-rhs)
                 (or (not (freeof parameter-symbol parameter-x))
                     (not (freeof parameter-symbol parameter-y))))
            parameter-symbol (parameter-check-thread)))))

(defun parameter-check-family (parameter-rhs)
  ;; Construct independent solutions x = rhs - r, y = r. Concurrent SOLVE
  ;; has a separate baseline failure; this exercises parameter independence
  ;; without making a claim about the rest of the solver's shared scratch.
  (let* (($%rnum_list (list '(mlist)))
         (parameter-symbol (make-param))
         (parameter-x (sub parameter-rhs parameter-symbol)))
    (list (and (equal $%rnum_list (list '(mlist) parameter-symbol))
               (= (add parameter-x parameter-symbol) parameter-rhs)
               (not (freeof parameter-symbol parameter-x)))
          parameter-symbol (parameter-check-thread))))

(defun parameter-check-solutions (parameter-records parameter-origin parameter-mode)
  (and (every #'first parameter-records)
       (= (length (remove-duplicates (mapcar #'second parameter-records))) (length parameter-records))
       (every (lambda (record) (parameter-check-number (second record))) parameter-records)
       (case parameter-mode
         ($worker (every (lambda (record) (and (third record) (not (eq parameter-origin (third record)))))
                         parameter-records))
         (($serial $caller $fallback) (every (lambda (record) (eq parameter-origin (third record))) parameter-records))
         (otherwise t))))

(defun parameter-check-run (parameter-mode parameter-rhs parameter-solve-p)
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (when (eq parameter-mode '$worker) (setq parameter-mode '$fallback))
  (let ((parameter-saved $%rnum)
        (parameter-origin (parameter-check-thread))
        (parameter-stats (list *live-workers* *peak-workers* *items-run-by-workers*)))
    (unwind-protect
         (progn
           (setq $%rnum 2000000)
           (let* ((parameter-result
                    (parallel-input-run
                     (lambda ()
                       (if parameter-solve-p (parameter-check-solve parameter-rhs)
                           (parameter-check-family parameter-rhs)))
                     parameter-mode))
                  (parameter-records (if (eq parameter-mode '$public) parameter-result (list parameter-result))))
             (and (= (length parameter-records) (if (eq parameter-mode '$public) 8 1))
                  (= $%rnum (+ 2000000 (length parameter-records)))
                  (parameter-check-solutions parameter-records parameter-origin parameter-mode))))
      (setq $%rnum parameter-saved)
      (%with-lock (*budget-lock*)
        (setf *live-workers* (first parameter-stats)
              *peak-workers* (second parameter-stats)
              *items-run-by-workers* (third parameter-stats))))))

(defun $parameter_identity_solver (parameter-mode parameter-rhs)
  (parameter-check-run parameter-mode parameter-rhs t))

(defun $parameter_identity_families (parameter-mode parameter-rhs)
  (parameter-check-run parameter-mode parameter-rhs nil))

(defun $parameter_identity_nested ()
  (let ((parameter-saved $%rnum)
        (parameter-stats (list *live-workers* *peak-workers* *items-run-by-workers*)))
    (unwind-protect
         (progn
           (setq $%rnum 3000000)
           (let* (($parallel_threads 4)
                  (parameter-results
                    (call-in-parallel
                     (loop for parameter-index from 1 to 3 collect
                       (let ((parameter-rhs (ash parameter-index 140)))
                         (lambda ()
                           (call-in-parallel
                            (loop repeat 4 collect (lambda () (parameter-check-family parameter-rhs)))))))))
                  (parameter-records (apply #'append parameter-results)))
             (and (= (length parameter-records) 12) (= $%rnum 3000012)
                  (parameter-check-solutions parameter-records nil '$public))))
      (setq $%rnum parameter-saved)
      (%with-lock (*budget-lock*)
        (setf *live-workers* (first parameter-stats)
              *peak-workers* (second parameter-stats)
              *items-run-by-workers* (third parameter-stats))))))

(defun $parameter_identity_native (parameter-workers parameter-count parameter-start)
  #-(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (return-from $parameter_identity_native
    ($parameter_identity_serial parameter-start (min 32 (* parameter-workers parameter-count))))
  #+(or sb-thread (and ccl openmcl-native-threads) (and ecl threads))
  (let* ((parameter-saved $%rnum)
         (parameter-origin (parameter-check-thread))
         (parameter-guard (%make-lock "parameter identity regression"))
         (parameter-ready 0) (parameter-go nil) (parameter-threads nil)
         (parameter-results (make-array parameter-workers :initial-element nil))
         (parameter-errors (make-array parameter-workers :initial-element nil)))
    (unwind-protect
         (progn
           (setq $%rnum parameter-start)
           (unwind-protect
                (progn
                  (dotimes (parameter-index parameter-workers)
                    (let ((parameter-slot parameter-index))
                      (push
                       (%spawn
                        (lambda ()
                          (let ((*package* (find-package :maxima))
                                ($%rnum_list nil))
                            (handler-case
                                (progn
                                  (%with-lock (parameter-guard) (incf parameter-ready))
                                  (loop until (%with-lock (parameter-guard) parameter-go) do (sleep 0.001))
                                  (let ((parameter-values (make-array parameter-count)))
                                    (dotimes (parameter-n parameter-count)
                                      (setq $%rnum_list (list '(mlist)))
                                      (setf (aref parameter-values parameter-n) (make-param))
                                      (unless (equal $%rnum_list (list '(mlist) (aref parameter-values parameter-n)))
                                        (error "Incorrect per-call parameter list")))
                                    (setf (aref parameter-results parameter-slot)
                                          (cons (parameter-check-thread) parameter-values))))
                              (error (condition) (setf (aref parameter-errors parameter-slot) condition)))))
                        "parameter identity regression") parameter-threads)))
                  (loop with parameter-deadline = (+ (get-internal-real-time) (* 5 internal-time-units-per-second))
                        until (%with-lock (parameter-guard) (= parameter-ready parameter-workers))
                        do (when (> (get-internal-real-time) parameter-deadline)
                             (error "Parameter workers did not start"))
                           (sleep 0.001)))
             (%with-lock (parameter-guard) (setq parameter-go t))
             (dolist (parameter-thread parameter-threads) (%join parameter-thread)))
           (let ((parameter-unique (make-hash-table :test 'eq)))
             (and (every #'null parameter-errors)
                  (every #'identity parameter-results)
                  (= (length (remove-duplicates (map 'list #'car parameter-results))) parameter-workers)
                  (every (lambda (record) (not (eq (car record) parameter-origin))) parameter-results)
                  (= $%rnum (+ parameter-start (* parameter-workers parameter-count)))
                  (every (lambda (record)
                           (every (lambda (parameter)
                                    (let ((parameter-number (parameter-check-number parameter)))
                                      (prog1 (and parameter-number
                                                  (< parameter-start parameter-number)
                                                  (<= parameter-number $%rnum)
                                                  (not (gethash parameter parameter-unique)))
                                        (setf (gethash parameter parameter-unique) t))))
                                  (cdr record)))
                         parameter-results)
                  (= (hash-table-count parameter-unique) (* parameter-workers parameter-count)))))
      (setq $%rnum parameter-saved))))

(defun $parameter_identity_properties ()
  ;; Deterministic cases, without consuming the caller's random state.
  (loop with parameter-state = 570197
        repeat 64 always
        (progn
          (setq parameter-state (mod (+ (* parameter-state 1664525) 1013904223) (ash 1 32)))
          (let* ((parameter-magnitude (ash (1+ parameter-state) (mod parameter-state 226)))
                 (parameter-start (if (oddp parameter-state) parameter-magnitude (- parameter-magnitude))))
            ($parameter_identity_serial parameter-start (mod parameter-state 33))))))
