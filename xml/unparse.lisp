;;; -*- Mode: Lisp; Syntax: Common-Lisp; Package: FXML; readtable: runes; Encoding: utf-8; -*-
;;; ---------------------------------------------------------------------------
;;;     Title: Unparse XML
;;;     Title: (including support for canonic XML according to J.Clark)
;;;   Created: 1999-09-09
;;;    Author: Gilbert Baumann <unk6@rz.uni-karlsruhe.de>
;;;    Author: David Lichteblau <david@lichteblau.com>
;;;    Author: Paul M. Rodriguez <pmr@ruricolist.com>
;;;   License: Lisp-LGPL (See file COPYING for details).
;;; ---------------------------------------------------------------------------
;;;  (c) copyright 1999 by Gilbert Baumann
;;;  (c) copyright 2004 by knowledgeTools Int. GmbH
;;;  (c) copyright 2004 by David Lichteblau (for headcraft.de)
;;;  (c) copyright 2005-2008 by David Lichteblau
;;;  (c) copyright 2014 by Paul M. Rodriguez

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;;; Boston, MA  02111-1307  USA.

(in-package :fxml)
(in-readtable :runes)

;;
;; | Canonical XML
;; | =============
;; |
;; | This document defines a subset of XML called canonical XML. The
;; | intended use of canonical XML is in testing XML processors, as a
;; | representation of the result of parsing an XML document.
;; |
;; | Every well-formed XML document has a unique structurally equivalent
;; | canonical XML document. Two structurally equivalent XML documents have
;; | a byte-for-byte identical canonical XML document. Canonicalizing an
;; | XML document requires only information that an XML processor is
;; | required to make available to an application.
;; |
;; | A canonical XML document conforms to the following grammar:
;; |
;; |    CanonXML    ::= Pi* element Pi*
;; |    element     ::= Stag (Datachar | Pi | element)* Etag
;; |    Stag        ::= '<'  Name Atts '>'
;; |    Etag        ::= '</' Name '>'
;; |    Pi          ::= '<?' Name ' ' (((Char - S) Char*)? - (Char* '?>' Char*)) '?>'
;; |    Atts        ::= (' ' Name '=' '"' Datachar* '"')*
;; |    Datachar    ::= '&amp;' | '&lt;' | '&gt;' | '&quot;'
;; |                     | '&#9;'| '&#10;'| '&#13;'
;; |                     | (Char - ('&' | '<' | '>' | '"' | #x9 | #xA | #xD))
;; |    Name        ::= (see XML spec)
;; |    Char        ::= (see XML spec)
;; |    S           ::= (see XML spec)
;; |
;; | Attributes are in lexicographical order (in Unicode bit order).
;; |
;; | A canonical XML document is encoded in UTF-8.
;; |
;; | Ignorable white space is considered significant and is treated
;; | equivalently to data.
;;
;; -- James Clark (jjc@jclark.com)


(eval-when (:compile-toplevel :load-toplevel)
  (defvar *basic-keywords*
    '(canonical indentation text-indentation encoding omit-xml-declaration standalone)))

;;;; SINK: an xml output sink

(defclass sink (fxml.sax:content-handler)
  ((ystream :initarg :ystream :accessor sink-ystream)
   (width :initform 79 :initarg :width :accessor width)
   (canonical :initform nil :initarg :canonical :accessor canonical)
   (indentation :initform nil :initarg :indentation :accessor indentation)
   (text-indentation :initform nil :initarg :text-indentation :accessor text-indentation)
   (current-indentation :initform 0 :accessor current-indentation)
   (notations :initform (make-buffer :element-type t) :accessor notations)
   (name-for-dtd :accessor name-for-dtd)
   (previous-notation :initform nil :accessor previous-notation)
   (have-doctype :initform nil :accessor have-doctype)
   (have-internal-subset :initform nil :accessor have-internal-subset)
   (stack :initform nil :accessor stack)
   (sink-omit-xml-declaration-p :initform nil
                                :initarg :omit-xml-declaration
                                :initarg :omit-xml-declaration-p
                                :accessor sink-omit-xml-declaration-p)
   (sink-standalone-p :initform nil
                      :initarg :standalone
                      :initarg :standalone-p
                      :accessor sink-standalone-p)
   (encoding :initarg :encoding :reader sink-encoding)))

(defmethod initialize-instance :after ((instance sink) &key)
  (when (eq (canonical instance) t)
    (setf (canonical instance) 1))
  (unless (member (canonical instance) '(nil 1 2))
    (error "Invalid canonical form: ~A" (canonical instance)))
  (when (and (canonical instance) (indentation instance))
    (error "Cannot indent XML in canonical mode"))
  (when (and (canonical instance)
             (not (eq (ystream-encoding (sink-ystream instance)) :utf-8)))
    (error "Cannot use non-UTF-8 encoding in canonical mode"))
  (when (let ((encoding (ystream-encoding (sink-ystream instance))))
          (and (not (symbolp encoding))
               (eq (babel-encodings:enc-name encoding) :utf-16)))
    (sink-write-rune #/U+FEFF instance)))

(defun make-buffer (&key (element-type '(unsigned-byte 8)))
  (make-array 1
              :element-type element-type
              :adjustable t
              :fill-pointer 0))

;; bisschen unschoen hier die ganze api zu duplizieren, aber die
;; ystreams sind noch undokumentiert
(macrolet ((define-maker (make-sink make-ystream &rest args)
             `(defun ,make-sink (,@args &rest initargs &key ,@*basic-keywords*)
                (declare (ignore ,@(remove 'encoding *basic-keywords*)))
                (let* ((encoding (or encoding "UTF-8"))
                       (ystream (,make-ystream ,@args)))
                  (setf (ystream-encoding ystream)
                        (fxml.runes:find-output-encoding encoding))
                  (apply #'make-instance
                         'sink
                         :ystream ystream
                         :encoding encoding
                         initargs)))))
  (define-maker make-octet-vector-sink make-octet-vector-ystream)
  (define-maker make-octet-stream-sink make-octet-stream-ystream stream)
  (define-maker make-rod-sink make-rod-ystream)
  
  (define-maker make-character-stream-sink make-character-stream-ystream stream))

(defun make-string-sink #.`(&rest args &key ,@*basic-keywords*)
  "@return{A serialization sink, i.e. a @class{SAX handler}}

   Returns a handler that writes processes SAX events by writing an
   equivalent XML document to a newly allocated string of unicode
   characters.

   The sink will return the string as a result from
   @fun{fxml.sax:end-document}.

   All sink creation functions share the same keyword arguments.
   Refer to @fun{make-octet-vector-sink} for details on keyword
   arguments."
  (declare #.`(ignorable ,@*basic-keywords*))
  (apply #'make-rod-sink args))


(defmethod fxml.sax:end-document ((sink sink))
  (close-ystream (sink-ystream sink)))


(setf (documentation #'make-octet-vector-sink 'function)
      "@arg[canonical]{canonical form, one of NIL, T, 1, 2.  If specified,
         serialization in canonical form is enabled.  The two canonical
         forms are useful to allow comparisons of XML documents and their
         content model by character-by-character comparisons of
         their serialized representation.}
       @arg[indentation]{indentation level.  An integer or nil.  If
         specified, a pretty-printing indentation mode is enabled.  Note
         that indentation as implemented currently changes the content model
         unconditionally, and is usually helpful only for debugging purposes.}
       @arg[encoding]{the character encoding to use.  A string or
         keyword.  Values are interpreted by Babel.  nil is also allowed
         and means UTF-8.}
       @arg[omit-xml-declaration]{Boolean.  If true, no XML declaration
         is written.}
       @arg[standalone]{Boolean.  If true, the xml-declaration will include
         `standalone='yes'`
       @return{A serialization sink, i.e. a @class{SAX handler}}

       Returns a handler that writes processes SAX events by writing an
       equivalent XML document to a newly allocated vector of
       @code{(unsigned-byte 8)}.

       The following values for @code{canonical} are allowed:

       @begin{itemize}
       @item{t or 1: Canonical XML}
       @item{2: Second Canonical Form}
       @item{NIL: Use a more readable non-canonical representation.}
       @end{itemize}

       The sink will return the vector as a result from
       @fun{fxml.sax:end-document}.

       An internal subset will be included in the result regardless of the
       canonical setting. It is the responsibility of the caller to not
       report an internal subset for canonical <= 1, or only notations as
       required for canonical = 2. For example, the include-doctype argument
       to fxml.dom:map-document should be set to nil for the former behaviour and
       :canonical-notations for the latter. ")

(setf (documentation #'make-octet-stream-sink 'function)
      "@arg[stream]{An (unsigned-byte 8) stream.}
       @return{A serialization sink, i.e. a @class{SAX handler}}

       Returns a handler that writes processes SAX events by writing an
       equivalent XML document to @var{stream}.

       The sink will return @var{stream} as a result from
       @fun{fxml.sax:end-document}.

       All sink creation functions share the same keyword arguments.
       Refer to @fun{make-octet-vector-sink} for details on keyword
       arguments.")

(setf (documentation #'make-rod-sink 'function)
      "@return{A serialization sink, i.e. a @class{SAX handler}}

       Returns a handler that writes processes SAX events by writing an
       equivalent XML document to a newly allocated string of unicode
       characters (or on implementations without unicode support: a rod).

       The sink will return the string (or rod) as a result from
       @fun{fxml.sax:end-document}.

       All sink creation functions share the same keyword arguments.
       Refer to @fun{make-octet-vector-sink} for details on keyword
       arguments.")

(setf (documentation #'make-character-stream-sink 'function)
      "@arg[stream]{A character stream.}
       @return{A serialization sink, i.e. a @class{SAX handler}}

       Returns a handler that writes processes SAX events by writing an
       equivalent XML document to @var{stream}.

       The sink will return @var{stream} as a result from
       @fun{fxml.sax:end-document}.

       All sink creation functions share the same keyword arguments.
       Refer to @fun{make-octet-vector-sink} for details on keyword
       arguments.")


;;;; doctype and notations

(defmethod fxml.sax:start-document ((sink sink))
  (unless (or (canonical sink)
              (sink-omit-xml-declaration-p sink))
    (sink-write-rod #"<?xml version=\"1.0\" encoding=\"" sink)
    (sink-write-rod (rod (sink-encoding sink)) sink)
    (sink-write-rod #"\"" sink)
    (when (sink-standalone-p sink)
      (sink-write-rod #" standalone=\"yes\"" sink))
    (sink-write-rod #"?>" sink)
    (sink-write-rune #/U+000A sink)))

(defmethod fxml.sax:start-dtd ((sink sink) name public-id system-id)
  (setf (name-for-dtd sink) name)
  (unless (canonical sink)
    (ensure-doctype sink public-id system-id)))

(defun ensure-doctype (sink &optional public-id system-id)
  (unless (have-doctype sink)
    (setf (have-doctype sink) t)
    (sink-write-rod #"<!DOCTYPE " sink)
    (sink-write-rod (name-for-dtd sink) sink)
    (cond
      ((not (zerop (length public-id)))
       (sink-write-rod #" PUBLIC \"" sink)
       (sink-write-escapable-rod public-id sink)
       (sink-write-rod #"\" \"" sink)
       (sink-write-escapable-rod system-id sink)
       (sink-write-rod #"\"" sink))
      ((not (zerop (length system-id)))
       (sink-write-rod #" SYSTEM \"" sink)
       (sink-write-escapable-rod system-id sink)
       (sink-write-rod #"\"" sink)))))

(defmethod fxml.sax:start-internal-subset ((sink sink))
  (when (have-internal-subset sink)
    (error "duplicate internal subset"))
  (setf (have-internal-subset sink) t)
  (ensure-doctype sink)
  (sink-write-rod #" [" sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:end-internal-subset ((sink sink))
  (ensure-doctype sink)
  (sink-write-rod #"]" sink))

(defmethod fxml.sax:unparsed-internal-subset ((sink sink) str)
  (when (have-internal-subset sink)
    (error "duplicate internal subset"))
  (setf (have-internal-subset sink) t)
  (ensure-doctype sink)
  (sink-write-rod #" [" sink)
  (sink-write-rune #/U+000A sink)
  (sink-write-rod str sink)
  (sink-write-rod #"]" sink))

;; for the benefit of the XML test suite, prefer ' over "
(defun write-quoted-rod (x sink)
  (let ((q (if (find #/' x) #/" #/'
               ;; '" (thanks you Emacs indentation, the if ends here)
                     )))
    (sink-write-rune q sink)
    (sink-write-rod x sink)
    (sink-write-rune q sink)))

(defmethod fxml.sax:notation-declaration ((sink sink) name public-id system-id)
  (let ((prev (previous-notation sink)))
    (when (and (and (canonical sink) (>= (canonical sink) 2))
               prev
               (not (rod< prev name)))
      (error "misordered notations; cannot unparse canonically"))
    (setf (previous-notation sink) name))
  (sink-write-rod #"<!NOTATION " sink)
  (sink-write-rod name sink)
  (cond
    ((zerop (length public-id))
     (sink-write-rod #" SYSTEM " sink)
     (write-quoted-rod system-id sink))
    ((zerop (length system-id))
     (sink-write-rod #" PUBLIC " sink)
     (write-quoted-rod public-id sink))
    (t
     (sink-write-rod #" PUBLIC " sink)
     (write-quoted-rod public-id sink)
     (sink-write-rod #" " sink)
     (write-quoted-rod system-id sink)))
  (sink-write-rune #/> sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:unparsed-entity-declaration
    ((sink sink) name public-id system-id notation-name)
  (unless (and (canonical sink) (< (canonical sink) 3))
    (sink-write-rod #"<!ENTITY " sink)
    (sink-write-rod name sink)
    (cond
      ((zerop (length public-id))
       (sink-write-rod #" SYSTEM " sink)
       (write-quoted-rod system-id sink))
      ((zerop (length system-id))
       (sink-write-rod #" PUBLIC " sink)
       (write-quoted-rod public-id sink))
      (t
       (sink-write-rod #" PUBLIC " sink)
       (write-quoted-rod public-id sink)
       (sink-write-rod #" " sink)
       (write-quoted-rod system-id sink)))
    (sink-write-rod #" NDATA " sink)
    (sink-write-rod notation-name sink)
    (sink-write-rune #/> sink)
    (sink-write-rune #/U+000A sink)))

(defmethod fxml.sax:external-entity-declaration
    ((sink sink) kind name public-id system-id)
  (when (canonical sink)
    (error "cannot serialize parsed entities in canonical mode"))
  (sink-write-rod #"<!ENTITY " sink)
  (when (eq kind :parameter)
    (sink-write-rod #" % " sink))
  (sink-write-rod name sink)
  (cond
    ((zerop (length public-id))
     (sink-write-rod #" SYSTEM " sink)
     (write-quoted-rod system-id sink))
    ((zerop (length system-id))
     (sink-write-rod #" PUBLIC " sink)
     (write-quoted-rod public-id sink))
    (t
     (sink-write-rod #" PUBLIC " sink)
     (write-quoted-rod public-id sink)
     (sink-write-rod #" " sink)
     (write-quoted-rod system-id sink)))
  (sink-write-rune #/> sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:internal-entity-declaration ((sink sink) kind name value)
  (when (canonical sink)
    (error "cannot serialize parsed entities in canonical mode"))
  (sink-write-rod #"<!ENTITY " sink)
  (when (eq kind :parameter)
    (sink-write-rod #" % " sink))
  (sink-write-rod name sink)
  (sink-write-rune #/U+0020 sink)
  (sink-write-rune #/\" sink)
  (sink-write-escapable-rod/dtd value sink)
  (sink-write-rune #/\" sink)
  (sink-write-rune #/> sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:element-declaration ((sink sink) name model)
  (when (canonical sink)
    (error "cannot serialize element type declarations in canonical mode"))
  (sink-write-rod #"<!ELEMENT " sink)
  (sink-write-rod name sink)
  (sink-write-rune #/U+0020 sink)
  (labels ((walk (m)
             (cond
               ((eq m :EMPTY)
                (sink-write-rod "EMPTY" sink))
               ((eq m :PCDATA)
                (sink-write-rod "#PCDATA" sink))
               ((eq m :ANY)
                (sink-write-rod "ANY" sink))
               ((atom m)
                (sink-write-escapable-rod m sink))
               (t
                (ecase (car m)
                  (and
                   (sink-write-rune #/\( sink)
                   (loop for (n . rest) on (cdr m) do
                     (walk n)
                     (when rest
                       (sink-write-rune #\, sink)))
                   (sink-write-rune #/\) sink))
                  (or
                   (sink-write-rune #/\( sink)
                   (loop for (n . rest) on (cdr m) do
                     (walk n)
                     (when rest
                       (sink-write-rune #\| sink)))
                   (sink-write-rune #/\) sink))
                  (*
                   (walk (second m))
                   (sink-write-rune #/* sink))
                  (+
                   (walk (second m))
                   (sink-write-rune #/+ sink))
                  (?
                   (walk (second m))
                   (sink-write-rune #/? sink)))))))
    (walk model))
  (sink-write-rune #/> sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:attribute-declaration ((sink sink) ename aname type default)
  (when (canonical sink)
    (error "cannot serialize attribute type declarations in canonical mode"))
  (sink-write-rod #"<!ATTLIST " sink)
  (sink-write-rod ename sink)
  (sink-write-rune #/U+0020 sink)
  (sink-write-rod aname sink)
  (sink-write-rune #/U+0020 sink)
  (cond
    ((atom type)
      (sink-write-rod (rod (string-upcase (symbol-name type))) sink))
    (t
      (when (eq :NOTATION (car type))
        (sink-write-rod #"NOTATION " sink))
      (sink-write-rune #/\( sink)
      (loop for (n . rest) on (cdr type) do
            (sink-write-rod n sink)
            (when rest
              (sink-write-rune #\| sink)))
      (sink-write-rune #/\) sink)))
  (sink-write-rune #/U+0020 sink)
  (cond
    ((atom default)
      (sink-write-rune #/# sink)
      (sink-write-rod (rod (string-upcase (symbol-name default))) sink))
    (t
      (when (eq :FIXED (car default))
        (sink-write-rod #"#FIXED " sink))
      (sink-write-rune #/\" sink)
      (sink-write-escapable-rod (second default) sink)
      (sink-write-rune #/\" sink)))
  (sink-write-rune #/> sink)
  (sink-write-rune #/U+000A sink))

(defmethod fxml.sax:end-dtd ((sink sink))
  (when (have-doctype sink)
    (sink-write-rod #">" sink)
    (sink-write-rune #/U+000A sink)))


;;;; elements

(defstruct (tag (:constructor make-tag (name)))
  name
  (n-children 0)
  (have-gt nil))

(defun sink-fresh-line (sink)
  (unless (zerop (ystream-column (sink-ystream sink)))
    (sink-write-rune #/U+000A sink)		;newline
    (indent sink)))

(defun maybe-close-tag (sink)
  (let ((tag (car (stack sink))))
    (when (and (tag-p tag) (not (tag-have-gt tag)))
      (setf (tag-have-gt tag) t)
      (sink-write-rune #/> sink))))

(defmethod fxml.sax:start-element
    ((sink sink) namespace-uri local-name qname attributes)
  (declare (ignore namespace-uri local-name))
  (maybe-close-tag sink)
  (when (stack sink)
    (incf (tag-n-children (first (stack sink)))))
  (push (make-tag qname) (stack sink))
  (when (indentation sink)
    (sink-fresh-line sink)
    (start-indentation-block sink))
  (sink-write-rune #/< sink)
  (sink-write-rod qname sink)
  (dolist (a (if (canonical sink)
                 (sort (copy-list attributes)
                       #'rod<
                       :key #'fxml.sax:attribute-qname)
                 attributes))
    (sink-write-rune #/space sink)
    (sink-write-rod (fxml.sax:attribute-qname a) sink)
    (sink-write-rune #/= sink)
    (sink-write-rune #/\" sink)
    (if (canonical sink)
        (sink-write-escapable-rod/canonical (fxml.sax:attribute-value a) sink)
        (sink-write-escapable-rod/attribute (fxml.sax:attribute-value a) sink))
    (sink-write-rune #/\" sink))
  (when (canonical sink)
    (maybe-close-tag sink)))

(defmethod fxml.sax:end-element
    ((sink sink) namespace-uri local-name qname)
  (declare (ignore namespace-uri local-name))
  (let ((tag (pop (stack sink))))
    (unless (tag-p tag)
      (error "output does not nest: not in an element"))
    (unless (rod= (tag-name tag) qname)
      (error "output does not nest: expected ~A but got ~A"
             (rod qname) (rod (tag-name tag))))
    (when (indentation sink)
      (end-indentation-block sink)
      (unless (zerop (tag-n-children tag))
        (sink-fresh-line sink)))
    (cond
      ((tag-have-gt tag)
       (sink-write-rod '#.(string-rod "</") sink)
       (sink-write-rod qname sink)
       (sink-write-rod '#.(string-rod ">") sink))
      (t
       (sink-write-rod #"/>" sink)))))

(defmethod fxml.sax:processing-instruction ((sink sink) target data)
  (maybe-close-tag sink)
  (unless (rod-equal target '#.(string-rod "xml"))
    (sink-write-rod '#.(string-rod "<?") sink)
    (sink-write-rod target sink)
    (cond
      ((plusp (length data))
       (sink-write-rune #/space sink)
       (sink-write-rod data sink))
      ((canonical sink)
       (sink-write-rune #/space sink)))
    (sink-write-rod '#.(string-rod "?>") sink)))

(defmethod fxml.sax:start-cdata ((sink sink))
  (maybe-close-tag sink)
  (push :cdata (stack sink)))

(defmethod fxml.sax:characters ((sink sink) data)
  (maybe-close-tag sink)
  (cond
    ((and (eq (car (stack sink)) :cdata)
          (not (canonical sink))
          (not (search #"]]" data)))
      (when (indentation sink)
        (sink-fresh-line sink))
      (sink-write-rod #"<![CDATA[" sink)
      ;; XXX signal error if body is unprintable?
      ;; zzz no, in that case, split into multiple CDATA sections
      (map nil (lambda (c) (sink-write-rune c sink)) data)
      (sink-write-rod #"]]>" sink))
    (t
      (if (text-indentation sink)
          (unparse-indented-text data sink)
          (if (canonical sink)
              (sink-write-escapable-rod/canonical data sink)
              (sink-write-escapable-rod data sink))))))

(defmethod fxml.sax:unescaped ((sink sink) data)
  (maybe-close-tag sink)
  (sink-write-rod data sink))

(defmethod fxml.sax:comment ((sink sink) data)
  (maybe-close-tag sink)
  (unless (canonical sink)
    ;; XXX signal error if body is unprintable?
    (sink-write-rod #"<!--" sink)
    (map nil (lambda (c) (sink-write-rune c sink)) data)
    (sink-write-rod #"-->" sink)))

(defmethod fxml.sax:end-cdata ((sink sink))
  (unless (eq (pop (stack sink)) :cdata)
    (error "output does not nest: not in a cdata section")))

(defun indent (sink)
  (loop repeat (current-indentation sink) do
    (sink-write-rune #/U+0020 sink)))

(defun start-indentation-block (sink)
  (incf (current-indentation sink) (indentation sink)))

(defun end-indentation-block (sink)
  (decf (current-indentation sink) (indentation sink)))

(defun unparse-indented-text (data sink)
  (flet ((whitespacep (x)
           (or (rune= x #/U+000A) (rune= x #/U+0020))))
    (let* ((n (length data))
           (pos (position-if-not #'whitespacep data))
           (need-whitespace-p nil))
      (cond
        ((zerop n))
        (pos
          (sink-fresh-line sink)
          (while (< pos n)
            (let* ((w (or (position-if #'whitespacep data :start (1+ pos)) n))
                   (next (or (position-if-not #'whitespacep data :start w) n)))
              (when need-whitespace-p
                (if (< (+ (ystream-column (sink-ystream sink)) w (- pos))
                       (width sink))
                    (sink-write-rune #/U+0020 sink)
                    (sink-fresh-line sink)))
              (sink-write-escapable-rod data sink :start pos :end w)
              (setf need-whitespace-p (< w n))
              (setf pos next))))
        (t
         (sink-write-rune #/U+0020 sink))))))

(defun sink-write-escapable-aux (rod sink start end escape-fn)
  (check-type escape-fn function)
  (let ((y (sink-ystream sink))
        esc)
    (flet ((needs-escape? (c)
             (setq esc (funcall escape-fn c))))
      (serapeum:do-splits ((l r rune?) (rod #'needs-escape? :start start :end end))
        (unless (= l r)
          (ystream-write-escapable-rod rod y :start l :end r))
        (when rune?
          (ystream-write-escapable-rod esc y))))))

(defun sink-write-escapable-rod (rod sink &key (start 0) (end (length rod)))
  (sink-write-escapable-aux
   rod sink start end
   (lambda (c)
     (case c
       (#/& #.(string-rod "&amp;"))
       (#/< #.(string-rod "&lt;"))
       ;; there's no need to escape > per se, but we're supposed to
       ;; escape -->, which is harder to check for
       (#/> #.(string-rod "&gt;"))
       (#/U+000D #.(string-rod "&#13;"))))))

(defun sink-write-escapable-rod/attribute
    (rod sink &key (start 0) (end (length rod)))
  (sink-write-escapable-aux
   rod sink start end
   (lambda (c) 
     (case c
       (#/& #.(string-rod "&amp;"))
       (#/< #.(string-rod "&lt;"))
       ;; there's no need to escape > per se, but we're supposed to
       ;; escape -->, which is harder to check for
       (#/> #.(string-rod "&gt;"))
       (#/\" #.(string-rod "&quot;"))
       (#/U+0009 #.(string-rod "&#9;"))
       (#/U+000A #.(string-rod "&#10;"))
       (#/U+000D #.(string-rod "&#13;"))))))

(defun sink-write-escapable-rod/canonical
    (rod sink &key (start 0) (end (length rod)))
  (sink-write-escapable-aux
   rod sink start end
   (lambda (c)
     (case c
       (#/& #.(string-rod "&amp;"))
       (#/< #.(string-rod "&lt;"))
       (#/> #.(string-rod "&gt;"))
       (#/\" #.(string-rod "&quot;"))
       (#/U+0009 #.(string-rod "&#9;"))
       (#/U+000A #.(string-rod "&#10;"))
       (#/U+000D #.(string-rod "&#13;"))))))

(defun sink-write-escapable-rod/dtd
    (rod sink &key (start 0) (end (length rod)))
  (sink-write-escapable-aux
   rod sink start end
   (lambda (c)
     (case c
       (#/% #.(string-rod "&#37;"))
       (#/& #.(string-rod "&amp;"))
       (#/< #.(string-rod "&lt;"))
       (#/> #.(string-rod "&gt;"))
       (#/\" #.(string-rod "&quot;"))
       (#/U+0009 #.(string-rod "&#9;"))
       (#/U+000A #.(string-rod "&#10;"))
       (#/U+000D #.(string-rod "&#13;"))))))

(defun sink-write-rune (c sink)
  (ystream-write-rune c (sink-ystream sink)))

(defun sink-write-rod (r sink)
  (ystream-write-rod r (sink-ystream sink)))


;;;; convenience functions for DOMless XML serialization

(defvar *current-element*)
(defvar *sink*)
(defvar *unparse-namespace-bindings*)
(defvar *current-namespace-bindings*)

(defmacro with-xml-output (sink &body body)
  "@arg[sink]{A @class{SAX handler}, evaluated}
   @arg[body]{forms}
   @return{The result of calling @code{fxml.sax:end-document} on @code{sink}.}

   Evaluates sink and establishes it as the current output sink for
   the following \"convenience serialization\" macros and functions:
   @fun{with-element}, @fun{with-namespace}, @fun{doctype},
   @fun{with-element*}, @fun{attribute}, @fun{attribute*}, @fun{text}
   @fun{comment}, @fun{processing-instruction}, @fun{unescaped}.

   Before @code{body} is evaluated, @fun{fxml.sax:start-document} is signalled
   to the @code{sink}.  Afterwards, @fun{fxml.sax:end-document} is signalled.

   Note that convenience serialization delays some serialization events.
   For example, @fun{with-element} delays signalling an opening tag
   using @fun{fxml.sax:start-element} until it has information about all
   possible attributes of the element.  Because of this delay, it is
   not usually safe to signal SAX events to the sink during the extent
   of @code{with-xml-output}.  However, @fun{with-output-sink} can be
   used to force output of delayed events, allowing direct use of the
   sink.

   Example:
   @pre{(with-xml-output (make-octet-stream-sink stream)
  (with-element \"foo\"
    (attribute \"xyz\" \"abc\")
    (with-element \"bar\"
      (attribute \"blub\" \"bla\"))
    (text \"Hi there.\")))}"
  `(invoke-with-xml-output (lambda () ,@body) ,sink))

(defmacro with-output-sink ((var) &body body)
  "@arg[var]{A symbol, not evaluated.}
   @arg[body]{forms, an implicit progn}
   @return{The result of @code{body}.}

   Allows safe use of manual calls to SAX functions during the extent
   of @fun{with-xml-output},

   Determines the current output sink established by @fun{with-xml-output},
   as used by convenience serialization functions.  Writes delayed
   serialization events to the sink. Binds local variable @code{var} to the
   sink and evaluates @code{body} as an implicit progn.

   The consequences are undefined if this macro is used outside of the
   extent of a call to @fun{with-xml-output}.

   See @fun{with-xml-output} for details on delayed events."
  `(invoke-with-output-sink (lambda (,var) ,@body)))

(defun invoke-with-xml-output (fn sink)
  (let ((*sink* sink)
        (*current-element* nil)
        (*unparse-namespace-bindings* *initial-namespace-bindings*)
        (*current-namespace-bindings* nil))
    (fxml.sax:with-document-events (sink)
      (funcall fn))))

(defun invoke-with-output-sink (fn)
  (maybe-emit-start-tag)
  (funcall fn *sink*))

(defmacro with-element (qname &body body)
  "@arg[qname]{A string, evaluated.}
   @arg[body]{forms, an implicit progn}
   @return{The result of @code{body}.}

   Writes an element to the current output sink.

   This macro is a convenience wrapper around @fun{with-element*}.

   @var{qname} is parsed to determine the element's namespace prefix
   and local name.  Then @fun{with-element*} is called on @var{body} using
   the resulting values."
  `(invoke-with-element (lambda () ,@body) ,qname))

(defmacro with-element* ((prefix lname) &body body)
  "@arg[prefix]{Namespace prefix, a string (evaluated).}
   @arg[lname]{Local name, a string (evaluated).}
   @arg[body]{forms, an implicit progn}
   @return{The result of @code{body}.}

   Writes an element to the current output sink.

   First, @var{prefix} is resolved to a namespace URI using the bindings
   established by @fun{with-namespace}.

   Next, body is evaluated as an implicit progn.  During this time,
   attributes for the element can be specified using @fun{attribute}.

   Once information on the start tag is complete, @fun{start-element}
   on the current output sink, using the specified namespace prefix and
   local name specified by the arguments, the namespace URI computed as
   described above,and including all attributes collected so far.

   Information on the start tag is considered complete once the first of
   the following situations occurs:
   @begin{itemize}
   @item{Before any child node of the element is written, e.g. using an
     inner call of @fun{with-element},}
   @item{Before the body of @fun{with-ouptut-sink} is evaluated.}
   @item{After the end of @var{body} has been reached.}
   @end{itemize}

   Finally, fxml.sax:end-element is used to write an end tag, using the same
   qualified name and namespace information as above."
  `(invoke-with-element* (lambda () ,@body) ,prefix ,lname))

(defmacro with-namespace ((prefix uri) &body body)
  "@arg[prefix]{Namespace prefix, a string (evaluated).}
   @arg[uri]{Namespace URI, a string (evaluated).}
   @arg[body]{forms, an implicit progn}
   @return{The result of @code{body}.}

   Registers @code{prefix} as a name for the namespace URI @code{uri}
   for the extent of body.

   Namespace bindings established by @code{with-namespace} are used by
   @fun{with-element} and @fun{with-element*} as well as @fun{attribute}
   and @fun{attribute*}."
  `(invoke-with-namespace (lambda () ,@body) ,prefix ,uri))

(defun doctype (name public-id system-id &optional internal-subset &aux (sink *sink*))
  "@arg[name]{Element name, a string.}
   @arg[public-id]{String}
   @arg[system-id]{A system ID as a @class{quri:uri}.}
   @arg[internal-subset]{nil or a string}
   @return{undocumented}

   Writes a doctype declaration to the current output sink, using the
   specified name, public ID, system ID, and optionally an internal subset."
  (fxml.sax:start-dtd sink name public-id system-id)
  (when internal-subset
    (fxml.sax:unparsed-internal-subset sink internal-subset))
  (fxml.sax:end-dtd sink))

(defun maybe-emit-start-tag (&aux (current-element *current-element*))
  (when current-element
    ;; starting child node, need to emit opening tag of parent first:
    (destructuring-bind ((uri lname qname) &rest attributes) current-element
      (fxml.sax:start-element *sink* uri lname qname (nreverse attributes)))
    (setf *current-element* nil)))

(defun invoke-with-namespace (fn prefix uri &aux (sink *sink*))
  (let ((*unparse-namespace-bindings*
         (acons prefix uri *unparse-namespace-bindings*))
        (*current-namespace-bindings*
         (acons prefix uri *current-namespace-bindings*)))
    (fxml.sax:start-prefix-mapping sink prefix uri)
    (multiple-value-prog1
        (funcall fn)
      (fxml.sax:end-prefix-mapping sink prefix))))

(defun invoke-with-element (fn qname)
  (setf qname (rod qname))
  (multiple-value-bind (prefix lname)
      (split-qname qname)
    (invoke-with-element* fn prefix lname qname)))

(defun find-unparse-namespace (prefix)
  (cdr (assoc prefix *unparse-namespace-bindings* :test 'equal)))

(defun invoke-with-element* (fn prefix lname &optional qname)
  (setf prefix (when prefix (rod prefix)))
  (setf lname (rod lname))
  (maybe-emit-start-tag)
  (let* ((qname (or qname
                    (if prefix (concatenate 'rod prefix #":" lname) lname)))
         (uri (find-unparse-namespace (or prefix #"")))
         (*current-element*
          (cons (list uri lname qname)
                (mapcar (lambda (x)
                          (destructuring-bind (prefix &rest uri) x
                            (fxml.sax:make-attribute
                             :namespace-uri #"http://www.w3.org/2000/xmlns/"
                             :local-name prefix
                             :qname (if (zerop (length prefix))
                                        #"xmlns"
                                        (concatenate 'rod #"xmlns:" prefix))
                             :value uri)))
                        *current-namespace-bindings*))))
    (multiple-value-prog1
        (let ((*current-namespace-bindings* nil))
          (funcall fn))
      (maybe-emit-start-tag)
      (fxml.sax:end-element *sink* uri lname qname))))

(defgeneric unparse-attribute (value))
(defmethod unparse-attribute ((value string)) value)
(defmethod unparse-attribute ((value null)) nil)
(defmethod unparse-attribute ((value integer)) (write-to-string value))

(defun attribute (qname value)
  "@arg[qname]{Qualified name, a string.}
   @arg[value]{Any value understood by @fun{unparse-attribute}, in particular
     strings.}
   @return{undocumented}

   Collects an attribute for the start tag that is currently being written.

   This function may only be called during the extent of a use of
   @fun{with-element} or @fun{with-element*}, and only before the first
   child node has been written.

   An attribute for the current element is recorded using the namespace prefix
   and local name specified by @var{qname}.  The attribute's namespace prefix
    is resolved to a namespace URI using the bindings established by
   @fun{with-namespace},and that namespace URI is used for the attribute."
  (setf qname (rod qname))
  (multiple-value-bind (prefix lname)
      (split-qname qname)
    (attribute* prefix lname value qname)))

(defun attribute* (prefix lname value &optional qname)
  "@arg[prefix]{Namespace prefix, a string.}
   @arg[lname]{Local name, a string.}
   @arg[value]{Any value understood by @fun{unparse-attribute}, in particular
     strings.}
   @return{undocumented}

   Collects an attribute for the start tag that is currently being written.

   This function may only be called during the extent of a use of
   @fun{with-element} or @fun{with-element*}, and only before the first
   child node has been written.

   An attribute for the current element is recorded using the namespace prefix
   and local name specified by arguments.  @var{prefix} is resolved to a
   namespace URI using the bindings established by @fun{with-namespace},
   and that namespace URI is used for the attribute."
  (setf value (unparse-attribute value))
  (when value
    (setf prefix (when prefix (rod prefix)))
    (setf lname (rod lname))
    (push (fxml.sax:make-attribute
           :namespace-uri (find-unparse-namespace prefix)
           :local-name lname
           :qname (or qname
                      (if prefix (concatenate 'rod prefix #":" lname) lname))
           :value (rod value)
           :specified-p t)
          (cdr *current-element*))))

(defun cdata (data &aux (sink *sink*))
  "@arg[data]{String.}
   @return{undocumented}

   Writes a CDATA section to the current output sink, using @code{data} as
   its contents.

   Note: It is currently the caller's responsibily to ensure that the CDATA
   section will not contain forbidden character sequences."
  (maybe-emit-start-tag)
  (fxml.sax:start-cdata sink)
  (fxml.sax:characters sink (rod data))
  (fxml.sax:end-cdata sink)
  data)

(defun text (data)
  "@arg[data]{String.}
   @return{undocumented}

   Writes a text node to the current output sink, using @code{data} as
   its contents.

   Note: It is currently the caller's responsibily to ensure that @code{data}
   does not contain characters forbidden for character data."
  (maybe-emit-start-tag)
  (fxml.sax:characters *sink* (rod data))
  data)

(defun comment (data)
  "@arg[data]{String.}
   @return{undocumented}

   Writes a comment to the current output sink, using @code{data} as
   its contents.

   Note: It is currently the caller's responsibily to ensure that @code{data}
   does not contain character sequences forbidden for comments."
  (maybe-emit-start-tag)
  (fxml.sax:comment *sink* (rod data))
  data)

(defun processing-instruction (target data)
  "@arg[target]{String.}
   @arg[data]{String.}
   @return{undocumented}

   Writes a processing instruction to the current output sink, using
   @code{target} and @code{data} as its contents.

   Note: It is currently the caller's responsibily to ensure that
   @code{target} and @code{data} do not contain character sequences
   forbidden for processing instruction contents."
  (maybe-emit-start-tag)
  (fxml.sax:processing-instruction *sink* (rod target) (rod data))
  data)

(defun unescaped (str)
  "@arg[data]{String.}
   @return{undocumented}

   If supported by the current output sink, writes character data directly
   to the sink's target.

   Use of this function is often an indicator of bad design.  Avoid it
   if you can. (Implementation note: This function is supported because
   XSLT's XML output method requires it.)"
  (maybe-emit-start-tag)
  (fxml.sax:unescaped *sink* (rod str)))
