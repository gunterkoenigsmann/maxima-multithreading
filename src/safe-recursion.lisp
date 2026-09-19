;;; safe-recursion.lisp
;;;
;;; This is intended as a simple way to allow code to bounce around the (large
;;; and confusing) Maxima system without having to worry so much about stack
;;; overflows from unbounded recursion.
;;;
;;; An "unsafe recursion" is defined as one that comes back to the same call
;;; site with an argument that is either equal to or contains one we've seen
;;; before. In that case, we assume that we're either stuck in a recursive loop
;;; or we're diverging and we should raise an error.
;;;
;;; Obviously, this doesn't catch every sort of unbounded recursion (for
;;; example, FOO could recurse to itself, incrementing its argument each call),
;;; but it should catch the silliest examples.

(in-package :maxima)

(define-condition unsafe-recursion (error)
  ((name     :initarg :name :reader ur-name)
   (existing :initarg :existing :reader ur-existing)
   (arg      :initarg :arg :reader ur-arg))
  (:report
   (lambda (err stream)
     (format stream "Unsafe recursion at site ~A. ~
                     Known args ~S contain ~S as a subtree"
             (ur-name err) (ur-existing err) (ur-arg err)))))

;;; The calls in progress, as an alist from the name of a call site to the
;;; arguments of the calls through it, innermost first.  It is bound, never
;;; assigned, so the record belongs to one thread's call stack: a call at the
;;; same site in another thread is not a recursion, and unwinding restores
;;; the record exactly.  A new thread, a parallel worker included, starts
;;; with none.
(defvar *current-recursion-args* nil)

;;; CALL-WITH-SAFE-RECURSION
;;;
;;; Call (FUNCALL THUNK), but record the call in *CURRENT-RECURSION-ARGS*
;;; under NAME. FUN may recurse through this call site again, but only if the
;;; new argument isn't a cons containing ARG as a subtree.
;;;
;;; If a recursion is spotted, raise an UNSAFE-RECURSION error.
(defun call-with-safe-recursion (name arg thunk)
  (let ((known-args (cdr (assoc name *current-recursion-args*))))
    (when (find-if (lambda (known)
                     (if (consp known)
                         (appears-in arg known)
                         (equal arg known)))
                   known-args)
      (error 'unsafe-recursion :name name :existing known-args :arg arg))

    (let ((*current-recursion-args*
            (acons name (cons arg known-args) *current-recursion-args*)))
      (funcall thunk))))

(defmacro with-safe-recursion (name arg &body body)
  `(call-with-safe-recursion ',name ,arg (lambda () ,@body)))
