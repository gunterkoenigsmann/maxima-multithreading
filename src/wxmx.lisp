;;; -*-  Mode: Lisp; Package: Maxima; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;     wxMaxima worksheets: their input, and their unicode names.      ;;;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;;; A .wxmx file is a .zip container whose member content.xml holds the
;;; whole worksheet: text cells, input cells and the output wxMaxima
;;; last displayed.  wxMaxima writes the mimetype, format.txt and
;;; content.xml members uncompressed and ahead of the images, so the
;;; input cells can be recovered by walking the local file headers of
;;; the archive -- no decompressor and no complete .zip reader needed.
;;; A member that is compressed, or that defers its size to a data
;;; descriptor, is diagnosed rather than guessed at.

(in-package :maxima)
(macsyma-module wxmx)

;; The signature of a .zip local file header, "PK\3\4" read as a
;; little-endian 32 bit integer.
(defconstant +wxmx-local-file-header+ #x04034b50)

(defun wxmx-read-u16 (stream)
  "Read a little-endian 16 bit unsigned integer.  NIL at end of file."
  (let* ((low (read-byte stream nil nil))
         (high (and low (read-byte stream nil nil))))
    (and high (logior low (ash high 8)))))

(defun wxmx-read-u32 (stream)
  "Read a little-endian 32 bit unsigned integer.  NIL at end of file."
  (let* ((low (wxmx-read-u16 stream))
         (high (and low (wxmx-read-u16 stream))))
    (and high (logior low (ash high 16)))))

(defun wxmx-read-octets (stream count)
  "Read COUNT octets.  NIL if the stream does not hold that many -- a
  size a damaged header overstates is not to be allocated first and
  found out about afterwards."
  (let ((length (ignore-errors (file-length stream))))
    (unless (and length (<= count (- length (file-position stream))))
      (return-from wxmx-read-octets nil)))
  (let ((octets (make-array count :element-type '(unsigned-byte 8))))
    (and (eql count (read-sequence octets stream)) octets)))

(defun wxmx-skip (stream count)
  "Move COUNT octets forward in STREAM."
  (or (file-position stream (+ (file-position stream) count))
      (dotimes (i count t)
        (unless (read-byte stream nil nil) (return nil)))))

(defun wxmx-member-name (octets)
  "The name a .zip local file header stores, as a string.  Member names
  are UTF-8 or CP437; the ones we look for are plain ASCII, where the
  two agree."
  (map 'string #'code-char octets))

(defun wxmx-stored-member (stream name filename)
  "Return the contents of the archive member NAME of the .zip file open
  on STREAM as a vector of octets, or NIL if there is no such member.
  FILENAME names the archive in error messages."
  (loop
    (unless (eql (wxmx-read-u32 stream) +wxmx-local-file-header+)
      ;; Either the end of the last member's data, where the central
      ;; directory begins, or a truncated file.  Either way there is no
      ;; further local file header to read.
      (return nil))
    (wxmx-read-u16 stream)                      ; version needed to extract
    (let ((flags (wxmx-read-u16 stream))
          (method (wxmx-read-u16 stream)))
      (wxmx-read-u32 stream)                    ; modification time and date
      (wxmx-read-u32 stream)                    ; CRC-32
      (let* ((compressed-size (wxmx-read-u32 stream))
             (uncompressed-size (wxmx-read-u32 stream))
             (name-length (wxmx-read-u16 stream))
             (extra-length (wxmx-read-u16 stream))
             (member (and extra-length
                          (wxmx-read-octets stream name-length))))
        (declare (ignore uncompressed-size))
        (unless member
          (return nil))
        (wxmx-skip stream extra-length)
        ;; Bit 3 of the flags moves the sizes behind the member's data,
        ;; into a data descriptor, and leaves zeroes here.  Then there
        ;; is nothing to skip the member by.
        (cond ((string= name (wxmx-member-name member))
               (cond ((not (eql method 0))
                      (merror (intl:gettext "Cannot read the .wxmx worksheet ~A: its ~A is stored compressed, which needs a .zip decompressor.")
                              (namestring filename) name))
                     ((logbitp 3 flags)
                      (merror (intl:gettext "Cannot read the .wxmx worksheet ~A: its ~A does not record its size, which needs a full .zip reader.")
                              (namestring filename) name))
                     (t
                      (return (wxmx-read-octets stream compressed-size)))))
              ((logbitp 3 flags)
               (merror (intl:gettext "Cannot read the .wxmx worksheet ~A: the member ~A ahead of ~A does not record its size, which needs a full .zip reader.")
                       (namestring filename) (wxmx-member-name member) name))
              (t
               (wxmx-skip stream compressed-size)))))))

(defun wxmx-code-char (code)
  "The character of code point CODE, or a question mark where this Lisp
  has none."
  (or (and code
           (< code char-code-limit)
           (code-char code))
      #\?))

;; INTL::OCTETS-TO-STRING would do this for a handful of Lisps and fall
;; back to Latin-1 for the rest, so decode UTF-8 here instead: content.xml
;; is UTF-8 whatever Lisp Maxima was built with.
(defun wxmx-utf-8-string (octets)
  "Decode OCTETS, a UTF-8 encoded archive member, into a string.  A
  malformed sequence, and a character this Lisp has no CODE-CHAR for,
  become a question mark."
  (let* ((length (length octets))
         (string (make-array length :element-type 'character
                                    :adjustable t :fill-pointer 0))
         (i 0))
    (loop while (< i length)
          do (let* ((byte (aref octets i))
                    ;; How many continuation bytes the leading byte
                    ;; promises; -1 marks a byte that cannot lead one.
                    (continuations (cond ((< byte #x80) 0)
                                         ((< byte #xc0) -1)
                                         ((< byte #xe0) 1)
                                         ((< byte #xf0) 2)
                                         ((< byte #xf8) 3)
                                         (t -1)))
                    (code (cond ((minusp continuations) nil)
                                ((zerop continuations) byte)
                                (t (logand byte
                                           (ash #x1f (- 1 continuations)))))))
               (incf i)
               (loop repeat (max continuations 0)
                     while code
                     do (let ((continuation (if (< i length)
                                                (aref octets i)
                                                0)))
                          (cond ((eql (logand continuation #xc0) #x80)
                                 (setq code (logior (ash code 6)
                                                    (logand continuation #x3f)))
                                 (incf i))
                                (t
                                 (setq code nil)))))
               (vector-push-extend (wxmx-code-char code) string)))
    (coerce string 'simple-string)))

(defun wxmx-parse-integer (digits radix)
  "The integer DIGITS spells in RADIX, or NIL if it spells none."
  (ignore-errors (parse-integer digits :radix radix)))

(defun wxmx-push-reference (name string)
  "Push the character the XML reference &NAME; stands for onto STRING.
  A reference we do not know is copied through as it was written."
  (let* ((digits (and (> (length name) 1) (char= (char name 0) #\#)))
         (hexadecimal (and digits
                           (> (length name) 2)
                           (member (char name 1) '(#\x #\X))))
         (code (cond ((string= name "lt") 60)
                     ((string= name "gt") 62)
                     ((string= name "amp") 38)
                     ((string= name "quot") 34)
                     ((string= name "apos") 39)
                     (hexadecimal (wxmx-parse-integer (subseq name 2) 16))
                     (digits (wxmx-parse-integer (subseq name 1) 10))
                     (t nil))))
    (cond ((and code (< code char-code-limit) (code-char code))
           (vector-push-extend (code-char code) string))
          (t
           (vector-push-extend #\& string)
           (loop for character across name
                 do (vector-push-extend character string))
           (vector-push-extend #\; string)))))

;; An XML reference is short: &thisisnotareference; in a text cell must
;; not swallow the text that follows it looking for a semicolon.
(defconstant +wxmx-reference-length+ 12)

(defun wxmx-push-text (xml start end string)
  "Push the text XML holds between START and END onto STRING, resolving
  the XML references in it."
  (let ((i start))
    (loop while (< i end)
          do (let* ((limit (min end (+ i +wxmx-reference-length+)))
                    (semicolon (and (char= (char xml i) #\&)
                                    (position #\; xml :start i :end limit))))
               (cond (semicolon
                      (wxmx-push-reference (subseq xml (1+ i) semicolon) string)
                      (setq i (1+ semicolon)))
                     (t
                      (vector-push-extend (char xml i) string)
                      (incf i)))))))

(defun wxmx-push-lines (xml start end string)
  "Push the text of the <line> elements XML holds between START and END
  onto STRING, one line each."
  (let ((i start))
    (loop
      (let ((line (search "<line>" xml :start2 i :end2 end)))
        (unless line
          (return))
        (let ((close (or (search "</line>" xml :start2 line :end2 end) end)))
          (wxmx-push-text xml (+ line 6) close string)
          (vector-push-extend #\Newline string)
          (setq i (min end (+ close 7))))))))

(defun wxmx-content-input (xml)
  "The Maxima input of the worksheet whose content.xml is XML: the text
  of the <line> elements of every <input> element, in the order the
  worksheet has them.  Everything else -- title, section and text cells,
  and the stored output -- is not input and is left behind."
  (let ((string (make-array (length xml) :element-type 'character
                                         :adjustable t :fill-pointer 0))
        (i 0))
    (loop
      (let ((input (search "<input>" xml :start2 i)))
        (unless input
          (return))
        (let ((close (or (search "</input>" xml :start2 input) (length xml))))
          (wxmx-push-lines xml (+ input 7) close string)
          (setq i close))))
    (coerce string 'simple-string)))

(defun wxmx-input-string (filename)
  "The Maxima input stored in the .wxmx worksheet FILENAME."
  (let ((content (with-open-file (stream filename
                                         :element-type '(unsigned-byte 8))
                   (wxmx-stored-member stream "content.xml" filename))))
    (unless content
      (merror (intl:gettext "~A holds no content.xml; it is not a .wxmx worksheet.")
              (namestring filename)))
    (wxmx-content-input (wxmx-utf-8-string content))))

;;; ------------------------------------------------------------------
;;; wxMaxima's unicode names for Maxima names
;;;
;;; wxMaxima's editor offers a few unicode symbols that stand for a Maxima
;;; name -- the greek letter pi for %pi, the n-ary summation sign for sum,
;;; the logical "and" sign for and -- and its .wxm and .wxmx files keep
;;; them as they were typed.  wxMaxima makes them work by defining each one
;;; as an alias at startup (wx-define-unicode-aliases in wxMaxima's
;;; wxMathML.lisp has the same list as below).  It also declares them
;;; alphabetic, so that Maxima reads them as names at all, which makes a
;;; symbol that is no letter part of the names it touches: a, the "and"
;;; sign and b written without spaces would be one name.  So before it
;;; sends a command wxMaxima puts spaces around the symbols that are no
;;; letters (Worksheet::UnicodeToMaxima).
;;;
;;; WITH-WXMAXIMA-ALIASES defines the aliases for as long as a .wxm or .wxmx
;;; file is being read, and WXMAXIMA-INPUT-STRING puts in the spaces, so
;;; that Maxima reads such a file the way wxMaxima reads what is typed into
;;; it -- with or without wxMaxima as the front end.  Without wxMaxima the
;;; symbols need no declaration: the reader reads a character that is no
;;; letter as a name of its own.  It still needs the spaces where a
;;; character is a byte (GCL), since the reader takes every byte above 127
;;; for a letter.

(defparameter *wxmaxima-unicode-aliases*
  '((#x03C0 $%pi t)       ; greek small letter pi
    (#x2148 $%i t)        ; double-struck italic small i
    (#x2147 $%e t)        ; double-struck italic small e
    (#x221E $inf nil)     ; infinity
    (#x2211 $sum nil)     ; n-ary summation
    (#x220F $product nil) ; n-ary product
    (#x222B $integrate nil); integral
    (#x221A $sqrt nil)    ; square root
    (#x22C0 $and nil)     ; n-ary logical and
    (#x22C1 $or nil)      ; n-ary logical or
    (#x22BB $xor nil)     ; xor
    (#x22BC $nand nil)    ; nand
    (#x22BD $nor nil)     ; nor
    (#x21D2 $implies nil) ; rightwards double arrow
    (#x21D4 $equiv nil)   ; left right double arrow
    (#x00AC $not nil))    ; not sign
  "The unicode symbols wxMaxima offers for a Maxima name, as a list of
  (code point, Maxima name, letter) triples.  Letter says whether Unicode
  calls the symbol a letter, which a Lisp whose characters are bytes
  cannot ask ALPHA-CHAR-P.")

(defun wxmaxima-unicode-string (codepoint)
  "The string the character of CODEPOINT is read as.  A Lisp whose
  characters are Unicode reads it as one character; one whose characters
  are bytes (GCL) reads a UTF-8 file as the bytes that encode it."
  (if (> char-code-limit #xFFFF)
      (string (code-char codepoint))
      (map 'string #'code-char
           (cond ((< codepoint #x80) (list codepoint))
                 ((< codepoint #x800)
                  (list (logior #xC0 (ash codepoint -6))
                        (logior #x80 (logand codepoint #x3F))))
                 (t
                  (list (logior #xE0 (ash codepoint -12))
                        (logior #x80 (logand (ash codepoint -6) #x3F))
                        (logior #x80 (logand codepoint #x3F))))))))

(defun wxmaxima-alias-symbol (codepoint)
  "The Maxima name the character of CODEPOINT is read as on its own.
  IMPLODE spells it the way the reader does, which for instance inverts
  the case of an all-lowercase name."
  (implode (coerce (concatenate 'string "$"
                                (wxmaxima-unicode-string codepoint))
                   'list)))

(defun wxmaxima-separate-symbols (text)
  "TEXT, Maxima input, with a space on either side of each of wxMaxima's
  unicode symbols for a Maxima name that is no letter -- outside of
  strings and comments, which are copied as they are, as is a character
  escaped with a backslash."
  (let ((symbols (loop for (codepoint nil letterp) in *wxmaxima-unicode-aliases*
                       unless letterp
                         collect (wxmaxima-unicode-string codepoint)))
        (length (length text))
        (comment-depth 0)
        (i 0))
    (flet ((at (string)
             (let ((end (+ i (length string))))
               (and (<= end length)
                    (string= string text :start2 i :end2 end)))))
      (with-output-to-string (out)
        (loop while (< i length)
              do (let ((character (char text i))
                       (symbol nil))
                   (cond ((at "/*")
                          ;; Maxima's comments nest.
                          (incf comment-depth)
                          (write-string "/*" out)
                          (incf i 2))
                         ((and (plusp comment-depth) (at "*/"))
                          (decf comment-depth)
                          (write-string "*/" out)
                          (incf i 2))
                         ((plusp comment-depth)
                          (write-char character out)
                          (incf i))
                         ((char= character #\\)
                          (write-string text out :start i
                                                 :end (min length (+ i 2)))
                          (incf i 2))
                         ((char= character #\")
                          (let ((end (do ((j (1+ i) (1+ j)))
                                         ((>= j length) length)
                                       (case (char text j)
                                         (#\\ (incf j))
                                         (#\" (return (1+ j)))))))
                            (write-string text out :start i :end end)
                            (setq i end)))
                         ((setq symbol (find-if #'at symbols))
                          (write-char #\Space out)
                          (write-string symbol out)
                          (write-char #\Space out)
                          (incf i (length symbol)))
                         (t
                          (write-char character out)
                          (incf i)))))))))

(defun wxmaxima-input-string (filename)
  "The Maxima input of the wxMaxima .wxm or .wxmx file FILENAME, with
  spaces put around the unicode symbols that need them, as wxMaxima does
  before it sends a command."
  (wxmaxima-separate-symbols
   (if (wxmx-file-p filename)
       (wxmx-input-string filename)
       (with-open-file (stream filename)
         (with-output-to-string (out)
           (loop for line = (read-line stream nil)
                 while line
                 do (write-line line out)))))))

(defun call-with-wxmaxima-aliases (function)
  "Call FUNCTION with wxMaxima's unicode names defined as aliases of the
  Maxima names they stand for, and remove them once it returns or exits
  non-locally.

  Only an alias this function added is removed again, and only if it is
  still as this function left it: a name that already is an alias --
  because wxMaxima is the front end and has defined them all, because
  the user said alias(), or because this is a file loaded from within
  such a file -- is left alone, before and after.

  Unlike alias(), this gives the Maxima name no reversealias property,
  which would make Maxima print it as the unicode symbol from then on."
  (let ((added nil))
    (unwind-protect
         (progn
           (loop for (codepoint old) in *wxmaxima-unicode-aliases*
                 for new = (wxmaxima-alias-symbol codepoint)
                 unless (get new 'alias)
                   do (putprop new old 'alias)
                      (push (cons new old) added))
           (funcall function))
      (loop for (new . old) in added
            when (eq (get new 'alias) old)
              do (remprop new 'alias)))))

(defmacro with-wxmaxima-aliases (&body body)
  "Evaluate BODY with wxMaxima's unicode names defined as aliases.  See
  CALL-WITH-WXMAXIMA-ALIASES."
  `(call-with-wxmaxima-aliases (lambda () ,@body)))
