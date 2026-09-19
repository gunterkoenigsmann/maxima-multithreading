;;; -*-  Mode: Lisp; Package: Maxima; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;     The data in this file contains enhancements.                   ;;;;;
;;;                                                                    ;;;;;
;;;  Copyright (c) 1984,1987 by William Schelter,University of Texas   ;;;;;
;;;     All rights reserved                                            ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; SUBLIS: A Macsyma flavor of Lisp's SUBLIS...
;;;
;;; ** (c) Copyright 1980 Massachusetts Institute of Technology **

(in-package :maxima)

(macsyma-module sublis)

(defmvar $sublis_apply_lambda t
  "a flag which controls whether LAMBDA's substituted are applied in
   simplification after the SUBLIS or whether you have to do an
   EV to get things to apply. A value of TRUE means perform the application.")

(declare-top (special *msublis-table*))

;;; SUBLIS([sym1=form1,sym2=form2,...],expression)$
;;;
;;;  This should change all occurrences of sym1 in expression to form1,
;;;  all occurrences of sym2 to form2, etc. The replacement is done in
;;;  parallel, so having occurrences of sym1 in form2, etc. will have
;;;  the `desired' (non-interfering) effect.

(defmfun $sublis (substitutions form)
  (cond (($listp substitutions)
	 (do ((l (cdr substitutions) (cdr l))
	      (nl ())
	      (temp))
	     ((null l) (setq substitutions nl))
	   (setq temp (car l))
	   (cond ((and (not (atom temp))
		       (not (atom (car temp)))
		       (eq (caar temp) 'mequal)
		       (symbolp (car (pop temp))))
		  (push (cons (pop temp) (pop temp)) nl))
		 (t (merror (intl:gettext "sublis: expected an equation with left-hand side a symbol; found: ~M") temp)))))
	(t
	 (merror (intl:gettext "sublis: first argument must a list; found: ~M") substitutions)))
  (msublis substitutions form))

;; The substitutions are kept in a table of this call's own, not on the
;; property lists of the symbols: those are shared by every thread, and
;; concurrent calls substituting for the same symbol would find each
;; other's entries.
(defun msublis (s y)
  (let ((*msublis-table* (make-hash-table :test #'eq)))
    (msublis-setup s)
    (msublis-subst y t)))

;; S holds the equations in reverse order, so for a symbol given twice the
;; earlier equation is stored last and wins.
(defun msublis-setup (s)
  (do ((x s (cdr x)) (temp) (temp1)) ((null x))
    (cond ((not (symbolp (setq temp (caar x))))
	   (merror (intl:gettext "sublis: left-hand side of equation must be a symbol; found: ~M") temp)))
    (setf (gethash temp *msublis-table*) (cdar x))
    (cond ((not (eq temp (setq temp1 (getopr temp))))
	   (setf (gethash temp1 *msublis-table*) (cdar x))))))

(defun msublis-subst (form flag)
  (cond ((atom form)
	 (cond ((and (null form) (not flag)) nil) ;preserve trailing NILs
	       ((symbolp form)
		(multiple-value-bind (value found) (gethash form *msublis-table*)
		  (if found value form)))
	       (t form)))
	(flag
	 (cond (($ratp form)
		(let* ((disrep ($ratdisrep form))
		       (sub    (msublis-subst disrep t)))
		  (cond ((eq disrep sub) form)
			(t ($rat sub)))))
	       ((atom (car form))
		;; NOTE TO TRANSLATORS: "CAR" = FIRST ELEMENT OF LISP CONS
		(merror (intl:gettext "sublis: malformed expression (atomic car).")))
	       (t
		(let ((cdr-value (msublis-subst (cdr form) nil))
		      (caar-value (msublis-subst (caar form) t)))
		  (cond ((and (eq cdr-value (cdr form))
			      (eq (caar form) caar-value))
			 form)
			((and $sublis_apply_lambda
			      (eq (caar form) 'mqapply)
			      (eq caar-value 'mqapply)
			      (atom (cadr form))
			      (not (atom (car cdr-value)))
			      (eq (caar (car cdr-value)) 'lambda))
			 (cons (cons (car cdr-value)
				     (cond ((member 'array (car form) :test #'eq)
					    '(array))
					   (t nil)))
			       (cdr cdr-value)))
			((and (not (atom caar-value))
			      (or (not (or (eq (car caar-value) 'lambda)
					   (eq (caar caar-value) 'lambda)))
				  (not $sublis_apply_lambda)))
			 (list* (cons 'mqapply
				      (cond ((member 'array (car form) :test #'eq)
					     '(array))
					    (t nil)))
				caar-value
				cdr-value))
			(t (cons (cons caar-value
				       (cond ((member 'array (car form) :test #'eq)
					      '(array))
					     (t nil)))
				 cdr-value)))))))
	(t
	 (let ((car-value (msublis-subst (car form) t))
	       (cdr-value (msublis-subst (cdr form) nil)))
	   (cond ((and (eq (car form) car-value)
		       (eq (cdr form) cdr-value))
		  form)
		 (t
		  (cons car-value cdr-value)))))))
