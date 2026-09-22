;; Fichier util.lsp

;       ***************************************************************
;       *                    MODULE SYM                               *
;       *       MANIPULATIONS DE FONCTIONS SYMETRIQUES                *
;       *        (version01: Commonlisp pour Maxima)                 *
;       *                                                             *
;       *                ----------------------                       *
;       *                  Annick VALIBOUZE                           *
;       *                    GDR MEDICIS                              *
;       *  (Mathe'matiques Effectives, De'veloppements Informatiques, *
;       *           Calculs et Ingenierie, Syste`mes)                 *
;       *             LITP (Equipe Calcul Formel)                     *
;       *                 Universite' Paris 6,                        *
;       *        4 place Jussieu, 75252 Paris cedex 05.               *
;       *              e-mail : avb@sysal.ibp.fr                      *
;       ***************************************************************

(in-package :maxima)
(macsyma-module util macros)
;---------------------------------------------------------------------------
;                     DECLARATION DES MACROS
; pour le type 2 des polynomes partitionnes avec en tete de chaque
; terme partitionne sa longueur
;---------------------------------------------------------------------------

;----------------------------------------------------------------------------
;                       LES UTILITAIRES 
;----------------------------------------------------------------------------
;                 On a des coefficients dans k[y1, ...,yn]
; p=(t1 t2 ... tn)  t1 > t2 > ...
; t = (longueur coe . partition)

(progn (defvar d) (defvar lvar) (defvar permut))

(progn)
(progn)


(defun $estpartition (l)
   (apply '>= (cdr l)))

;--------------------------------------------------------------------------
;              MERGE PHYSIQUE AVEC SOMME SUR LES GRANDS ENTIERS
; ON UTILISE LE PREDICAT SUR LES TERMES ET NON SUR LES MONOMES(comme merge)
;---------------------------------------------------------------------------
(defun somme (l1 l2 pr)
  (cond
    ((null l1) l2)
    ((null l2) l1)
    (t (let ((t1 (termi l1)) (t2 (termi l2)))
         (cond
           ((equal (tmon t1) (tmon t2))
            (chcoeterm t1 ($add_sym (tcoe t1) (tcoe t2)))
            (cond
	      ((and (numberp (tcoe t1))
		    (zerop (tcoe t1)))
	       (somme (cdr l1) (cdr l2) pr))
	      (t
	       (somme2 (cdr l2) l1 pr) l1)))
           ((funcall pr t1 t2) (somme2 l2 l1 pr) l1)
           (t (somme2 l1 l2 pr) l2))))))

(defun somme2 (l2 l1 pr)
  (do ((l1 l1) (l2 l2) (ll2 nil) (t1 (termi (cdr l1)) (termi (cdr l1)))
       (t2 (termi l2)))
      ((or (null l2) (and (null (cdr l1)) (nconc l1 l2))))
    (cond
      ((equal (tmon t1) (tmon t2))
       (chcoeterm t1 ($add_sym (tcoe t1) (tcoe t2))) (setq l2 (cdr l2))
       (setq t2 (termi l2))
       (if (and (numberp (tcoe t1)) (zerop (tcoe t1)))
           (setq l1 (rplacd l1 (cddr l1)))
           (setq l1 (cdr l1))))
      ((funcall pr t1 t2) (setq l1 (cdr l1)))
      (t (setq ll2 (cdr l1)) (setq l1 (cdr (rplacd l1 l2)))
         (setq l2 ll2) (setq t2 (termi l2))))))

;======================================================================
;         CREATION D'UNE LISTE LISP DE nb VARIABLES GENERIQUES :
;               ($x1 ... $x(nb))
; (lvar 2 '(r)) = ; ($X1 $X2 R)
;======================================================================

(defun lvar (nb lvar)
  (cond
    ((eql 0 nb) lvar)
    (t (lvar (1- nb)
             (cons (flet ((franz.concat (&rest args)
                              "equivalent to Franz Lisp 'concat'."
                              (values (intern
                                       (format nil "~{~A~}" args) :maxima))))
                     (franz.concat '$x nb))
                   lvar)))))

;(lvar_lettre 2 '(r) 'x)
; (X1 X2 R)

(defun lvar_lettre (nb lvar lettre)
  (cond
    ((eql 0 nb) lvar)
    (t (lvar_lettre (1- nb)
           (cons (flet ((franz.concat (&rest args)
                            "equivalent to Franz Lisp 'concat'."
                            (values (intern (format nil "~{~A~}" args) :maxima))))
                   (franz.concat lettre nb))
                 lvar)
           lettre))))

;===========================================================================
;             Calcul du degre d'un polynome symetrique 
; avec REP([pol]) = [lppart](2)

(defun $degrep (pol)
  (let ((d 0))
    (mapc #'(lambda (di)
             (and (< d di)
                  (setq d di)))
          (mapcar #'(lambda (mon) ($degre (cddr mon))) pol ))
    d))

; Calcul du degre d'une forme monomiale avec REP([forme mon])=[partition](2)
; mon = (lgI coeI . I)

(defun $degre (mon)
  (if (or (constantp mon) (null mon)) 0
      (+  (* (car mon) (cadr mon))
          ($degre (cddr mon)))))

;---------------------------------------------------------------------------
; TESTE SI ON A AFFAIRE A UNE CONSTANTE APRES LE LECTEUR
; termpart = REP([somme orbitale])

; avec [somme orbitale] = (coe.[partition])

(defun constante (termpart)
  (or (null (cdr termpart))
      (eval (cons 'and
                  (mapcar #'(lambda (exposant) (eql 0 exposant))
                           (cdr termpart))))))

; avec [somme orbitale] = (longueur coe.[partition])
; il suffit de tester si la longueur est nulle

(defun lconstante (ltermpart) (eql 0 (car ltermpart)))

; Calcul des longueurs de chaque partition contenue dans la liste listparts
; sous forme [partition](2)

(defun lgparts (ppart)
  (mapcar #'(lambda (mon) (cons ($calculvar (cdr mon)) mon)) ppart))

; Calcul de la longueur d'une partition I.
; Pour [partition](1)

(defun longueur (i)
  (if (or (null i) (eql 0 (car i))) 0
        (1+ (longueur (cdr i)))))

; Pour [partition](2), pouvant se terminer par des 0.

(defun $calculvar (i)
  (if (or (null i) (eql 0 (car i))) 0
        (+ (cadr i) ($calculvar (cddr i)))))

;**************************************************************************
;                      PREDICATS
;-------------------------------------------------------------------------
;term est un [partition](2) c'est a dire sous la forme :
; dans la forme (a1 m1 a2 m2...) ou mi est la multiplicite' de ai (> a(i+1)) 
;-------------------------------------------------------------------------
;(2 1 ...) < (2 2 ...) < (3 1 2 1 ...) < (3 1 2 2 ...)

(defun $lex (term1 term2)
  (cond
    ((null term1) t)
    ((null term2) nil)
    (t (let ((pui1 (car term1)) (nb1 (cadr term1)) (rest1 (cddr term1))
             (pui2 (car term2)) (nb2 (cadr term2))
             (rest2 (cddr term2)))
         (cond
           ((or (< pui1 pui2)
                (and (eql pui1 pui2)
                     (< nb1 nb2)))
            t)
           ((or (< pui2 pui1)
                (< nb2 nb1))
            nil)
           (t ($lex rest1 rest2)))))))

; q inferieur a p pour l'ordre des longueurs ou p et q sont des
; sommes orbitales represente'es par des [terme partionne](2) avec
; la longueur en plus en tete

(defun orlongsup (p q)
  (cond
    ((equal (cddr p) (cddr q)) nil)
    ((> (car p) (car q)))
    ((eql (car p) (car q)) ($lex (cddr q) (cddr p)))
    (t nil)))
;----------------------------------------------------
; le vrai ordre des longueurs q inferieur a p pour cet ordre : ;  p { q

;(orlongsup '(2 a 2 1 3 1) '(1 a 4 1))
;T

;>(orlong '(2 a 2 1 3 1) '(1 a 4 1))
;NIL
;----------------------------------------------------

(defun orlong (p q)
  (cond
    ((equal (cddr p) (cddr q)) nil)
    ((< (car p) (car q)))
    ((eql (car p) (car q)) ($lex (cddr p) (cddr q)))
    (t nil)))

(defun $orlong_cst (p q)
  (cond
    ((lconstante p))
    ((lconstante q) nil)
    (t (orlong p q))))

; p > q

(defun $e_lexinv_cst (mon1 mon2)
  (cond
    ((constante mon1))
    ((constante mon2) nil)
    (t ($e_lexinv mon1 mon2))))

; p=(lg(I) coeI .I)

(defun $e_lexinv (p q)
  (and (not (equal (cddr p) (cddr q))) ($lex (cddr q) (cddr p))))

; p < q
; les constantes sont les + petites

(defun $e_lex_cst (p q)
  (cond
    ((constante p))
    ((constante q) nil)
    (t ($e_lex p q))))
  
(defun $e_lex (p q)
  (and (not (equal (cddr p) (cddr q))) ($lex (cddr p) (cddr q))))

; teste sur deux monomes en representation distribuee (i1 i2 ...)

(defun lex_term (term1 term2)
    (lex_mon (cdr term1) (cdr term2)))

(defun lex_mon (m1 m2)
  (and (not (equal m1 m2))
       (catch 'trouve
               (mapc #'(lambda (e1 e2)

                      (or (eql e1 e2)
                          (cond
                            ((> e1 e2)
                             (throw 'trouve t))
                             (t (throw 'trouve nil)))))
                   m1 m2))))

;***************************************************************************
;                           INTERFACE 


; Le lecteur utilise la fonction $distri_lect qui appelle distri_lecteur

(defun lect ($pol $lvar) 
         (mapcar 'cdr 
                (cdr (meval (list '($distri_lect) $pol $lvar)))))

;--------------------------------------------------------------------------
;                    [ppart](i) lisp ==> [ppart](i) macsyma

(defun macsy_list (llist)
  (cons '(mlist) (mapcar #'(lambda (list) (cons '(mlist) list)) llist)))

; sa recipropque :

(defun mac2lisp (list) (mapcar 'cdr (cdr list)))
;--------------------------------------------------------------------------
;                    [ppart](i)  == > polynome macsyma

; Si REP([pol]) =[ppart](1)
; Pour une liste de polynomes. 
; Mais attention! Si on veut l'utiliser sous Macsyma, il faut
; rajouter (MLIST SIMP) en car de la liste resultat.
;--------------------------------------------------------------------------

(defun ecrit_listpol (listpol lvar)
  (mapcar #'(lambda (pol) (ecrit_pol pol lvar)) listpol))

;--------------------------------------------------------------------------
; Pour un polynome de plusieurs groupes de variables 
; en representation distribuee :
; (c m1 m2 ... mp) ou mi est un monome en X^(i) . 
; Par exemple : mi=(3 4 1) represente U^3*V^4*W si X^(i)=(U,V,W).
; llvar = (X^(1), ..., X^(p)) est une liste de listes de variables
;--------------------------------------------------------------------------

(defun multi_ecrit (pol llvar)
  (cond
    ((null (cdr pol))
     (multi_ecrit_mon (caar pol) (cdr (car pol)) llvar))
    (t ($fadd_sym
              (mapcar #'(lambda (terme)
                         (multi_ecrit_mon (car terme) (cdr terme)
                             llvar))
                      pol)))))

(defun multi_ecrit_mon (coe llexposants llvar)
  (cond
    ((null llvar) coe)
    (t (mapc #'(lambda (lexposants lvar)
                (setq coe (ecrit_mon lexposants lvar coe)))
             llexposants llvar)
       coe)))
;--------------------------------------------------------------------------
; Pour un polynome a un groupe de variables dont le representaion
; partitionnee est de type 1, on considere que le polynome
; est sous forme distribue'e et on se sert de l'ecrivain de polynomes
; destine' a ce cas afin d'obtenir un polyn\^ome maxima.
; la fonction au niveau maxima est $distri_ecrit. Mais c'est ennnuyeux
; de mettre de mlist pour les retirer ensuite, alors j'appelle
; directement
; la fonction interne : $ecrivain_sym
;--------------------------------------------------------------------------

(defun ecrit_pol (ppart lvar) 
         (meval (list '($distri_ecrit)  
                             (macsy_list ppart) (cons '(mlist) lvar))))

;--------------------------------------------------------------------------
;    Si REP([pol]) = [ppart](2) on se ramene au cas precedent
;--------------------------------------------------------------------------

(defun 2ecrit (ppart lvar) (ecrit_pol (ch1repol ppart) lvar))

;**************************************************************************
;                CHANGEMENTS DES REPRESENTATIONS DE PARTITIONS
;-----------------------------------------------------------------------
; Fonction passant de [partition](1) a [partition](2)

(defun ch2rep (partition1)
  (and partition1 (not (eql 0 (car partition1)))
       (ch2rep2 (cdr partition1) (list 1 (car partition1)))))

(defun ch2rep2 (partition1 partition2)
  (if (or (null partition1) (eql 0 (car partition1)))
      (nreverse partition2)
      (if (eql (car partition1) (cadr partition2))
          (ch2rep2 (cdr partition1)
                   (rplaca partition2
                           (1+ (car partition2))))
          (ch2rep2 (cdr partition1)
                   (cons 1 (cons (car partition1) partition2))))))

; Passer d'un polynome partitionne avec [partition](1) a [partition](2)

(defun ch2repol (ppart)
  (mapcar #'(lambda (tpart) (cons (car tpart) (ch2rep (cdr tpart))))
          ppart))

; PASSAGE DE [partition](2) a [partition](1)

(defun ch1rep (partition2)
  (and partition2
       (ch1rep2 (cddr partition2)
                (make-list (cadr partition2) 
                           :initial-element (car partition2)))))

(defun ch1rep2 (partition2 partition1)
  (cond
    ((null partition2) (nreverse partition1))
    (t (ch1rep2 (cddr partition2)
                (nconc (make-list (cadr partition2) 
                                  :initial-element (car partition2))
                       partition1)))))

; Maintenant passer d'un polynome partitionne avec [partition](2)
; a un polynome partitionne avec [partition](1)

(defun ch1repol (ppart)
  (mapcar #'(lambda (tpart) (cons (car tpart) (ch1rep (cdr tpart))))
          ppart))

;------- Seconde methode  
; Passage de la premiere represensentation des partitions a la seconde
; on ramene les cst sans partition associee

; listM =(i1 i2 i3 ...ip) avec 0< i1 <= i2 <= ... <=ip

(defun part (listm)
  ($part2 (cdr listm) (cons (car listm) (cons 1 nil))))

(defun $part2 (listm lpartm)
  (if (null listm) lpartm
      ($part2 (cdr listm)
              (if (eql (car listm) (car lpartm))
                  (progn
                    (rplaca (cdr lpartm)
                            (1+ (cadr lpartm)))
                    lpartm)
                  (cons (car listm) (cons 1 lpartm))))))

(defun $cherchepui (mmon) (if (atom mmon) 1 (car (last mmon))))

;=========================================================================
;            CALCUL DU CARDINAL DE L' ORBITE D'UN MONOME
;            DONT LA LISTE DES EXPOSANTS EST DONNE PAR UNE
;       PARTITION DONT LA REPRESENTATION EST  [partition](2)=(a1 m1 a2 m2...)
; qui est n!/(m0!m1!...) ou n=somme_{i=0} mi
; Ou du coefficient multinomial associe a une partition type [partition](1)
; qui est |I|!/(i1!i2!....)
;---------------------------------------------------------------------------
(defun $card_orbit ($partition $card)
  (card_orbit (cdr $partition) $card))

(defun card_orbit (partition card)
  (nbperm0 card
           (- card ($calculvar partition)); le nombre a la puissance 0
           partition))

(defun $multinomial (poids $partition) 
  (multinomial (nbperm2 1 poids 1 (cadr $partition)) (cddr $partition)))

(defun multinomial (prec_multinomial partition) 
  (cond
    ((or (null partition) (= 0 (car partition))) (car prec_multinomial))
    (t (multinomial
           (nbperm2 (car prec_multinomial) (cadr prec_multinomial) 1
                    (car partition))
           (cdr partition)))))

(defun nbperm0 (card m0 part) (nbperm (nbperm2 1 card 1 m0) part))

(defun nbperm (lpermn part)
  (if (null part) (car lpermn)
      (nbperm (nbperm2 (car lpermn) (cadr lpermn) 1 (cadr part))
              (cddr part))))

(defun nbperm2 (perm n i mi)
  (if (< mi i)
      (list perm n)
      (nbperm2 (/ (mult perm n) i)
               (1- n)
               (1+ i)
               mi)))

;------------------------------------------------------------------------
;            Calcul du cardinal du stabilisateur d'une liste ordonnee
; de paires ou de nombres dans l'ordre lexicographique croissant.

(defmfun $card_stab ($part $egal) ($card_stab_init $part $egal))

(mdefprop $card_stab
    ((lambda ()) ((mlist) $part $egal)
     ((mprog) (($operation)) (($card_stab_init) $part $egal)))
    mexpr)
(add2lnc '(($card_stab) $part $egal) $functions)
;------------------------------------------------------------------------

(defun $card_stab_init ($part $egal)
  (card_stab (cdr $part)
             (find-symbol (string $egal))))

(defun card_stab (s egal)
  (let ((lmultip (sort (multiplicites s egal) '<)))
       (prod_factor lmultip)))

(defun multiplicites (s egal)
  (multiplicites2 (cdr s) (car s) 1 nil egal))

(defun multiplicites2 (s ai mi lmultip egal)
  (cond
    ((null s) (cons mi lmultip))
    ((funcall egal (car s) ai)
     (multiplicites2 (cdr s) ai
           (1+ mi)
         lmultip egal))
    (t (multiplicites2 (cdr s) (car s) 1 (cons mi lmultip) egal))))

; l = (m1 m2 ... mp) croissante , on veut m1!m2!...mp!

(defun prod_factor (l)
  (apply '* (list_factor l (list (factorielle (car l))))))
; l = (mi m(i+1) ... mp) et lfactor = (mi!, ..., m2!, m1!)

(defun list_factor (l lfactor)
  (cond
    ((null (cdr l)) lfactor)
    (t (list_factor (cdr l)
           (cons (fact_recur (car l) (cadr l) (car lfactor)) lfactor)))))

(defun fact_recur (m1 m2 factm1)
  (cond
    ((eql m1 m2) factm1)
    (t (* (finfact (1+ m1)
                   m2
                   (1+ m1))
          factm1))))

(defun finfact (i m2 finfactm2)
  (cond
    ((eql i m2) finfactm2)
    (t (finfact (1+ i)
                m2
                (* (1+ i)
                   finfactm2)))))

(defun factorielle (n)
  (cond
    ((eql 0 n) 1)
    (t (* n  (factorielle (1- n))))))

;________________________________________________________________________  

;           OBTENIR TOUTES LES PERMUTATIONS D'UN NUPLET D'ENTIER
;       (Philippe Esperet) remarque : 
;        VOIR FONCTIONS permutations et permutations_lex de MAXIMA
;---------------------------------------------------------------------------

(defun $lpermut (nuplet)
  (cons '(mlist)
        (mapcar #'(lambda (permu) (cons '(mlist) permu))
                (permut (cdr nuplet)))))

;======================================================================
;                      EXPRESSION D'UN POLYNOME
;             DONT ON CONNAIT LES FONCTIONS SYMETRIQUES
;                      ELEMENTAIRES DES RACINES
; $fct_elem =[cardinal, e_1,e_2,...,e_cardinal,...]
;======================================================================

(defun $ele2polynome ($fct_elem $z)
   (ele2polynome (cdr $fct_elem) $z))

(defun ele2polynome (l_degre_$elem $z)
  (genpoly2
      (1- (car l_degre_$elem))
      -1 ($exp_sym $z (car l_degre_$elem)) (cdr l_degre_$elem) $z))

(defun genpoly2 (exp sign $pol l_$elem $z)
  (cond
    ((null l_$elem)  $pol $pol)
    (t (genpoly2
           (1- exp)
           (* -1 sign)
           ($add_sym  $pol
               ($mult_sym ($mult_sym sign (car l_$elem))
                   ($exp_sym  $z exp)))
           (cdr l_$elem) $z))))
;=========================================================================
;      OBTENIR UN POLYNOME A PARTIR DES FONCTIONS PUISSANCES
;                     DE SES RACINES

; fct_pui = (card p1 p2 ...)
;=========================================================================

(defun $pui2polynome ($var $fct_pui)
    (pui2polynome $var (cdr $fct_pui)))

(defun pui2polynome (variable fct_pui)
   (let (($pui2ele '$girard))
         (ele2polynome (cdr (meval (list '($pui2ele) (car fct_pui)
                                 (cons '(mlist)  fct_pui))))
             variable)))
         
;=========================================================================
;               CALCUL DES FONCTIONS SYMETRIQUES ELEMENTAIRES
;                     DES RACINES D'UN POLYNOME 
; entrees : $p un polynome en la variable $var 
; sortie  :  [d , e1, ...,ed] ou d est le degre du polynome
;==========================================================================
(defun $polynome2ele ($p $var)
   (cons '(mlist) (polynome2ele $p $var)))

(defun polynome2ele ($p $var)
   (let* ((alt -1)
        (n (meval (list '($HIPOW) $p $var)))
         (an (meval (list '($COEFF) $p $var n))))
        (do ((alt alt (* -1 alt ))
             (i 1 (1+ i))
            (elem nil (cons ($divi_sym ($mult_sym alt
                                             (meval (list '($COEFF)
						   $P $var (- n i))))
                                             an)
                             elem)))
            ((= (1+ n) i) (cons n (nreverse elem))))))


; Obtenir tout les coefficients, meme les nuls, 
; (cn c(n-1)...c0) ou ci coefficient de x**i.
(defun lcoe2 (precedexp p lcoe)
  (if (null p)
      (or (eql 0 precedexp) 
          (rplacd lcoe (make-list precedexp :initial-element 0)))
      (let ((exp (car p)) (coe (cadr p)))
        (if (eql precedexp
                 (1+ exp))
            (lcoe2 exp (cddr p) (cdr (rplacd lcoe (list coe))))
            (lcoe2 exp (cddr p)
                   (last (rplacd lcoe
                                 (append 
                                    (make-list (- precedexp
                                                 (1+ exp))
                                                :initial-element 0)
                                        (list coe)))))))))

;======================================================================

(defun binomial (n p)
      (meval (list '(%binomial) n p)))

;======================================================================

; la fonction maxote est commune a : treillis.lsp , resolvante.lsp, kak.lsp
; voir dans util.lsp

; ici difference avec le common-lisp de macsyma : 
;      / a la place de /! pour la division

(defun maxote (a b)
  (and (plusp b)
       (if (eql 1 b) 0
           (if (eql 0 (rem a b))
                (- a (div a b))
                (- a (1+ (/ a b)))))))
