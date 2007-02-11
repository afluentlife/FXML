;;; -*- Mode: Lisp; readtable: runes; -*-
;;;  (c) copyright 2007 David Lichteblau

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

(in-package :cxml)

(defclass cxml-source (klacks:source)
    (;; args to make-source
     (context :initarg :context)
     (validate :initarg :validate)
     (root :initarg :root)
     (dtd :initarg :dtd)
     (error-culprit :initarg :error-culprit)
     ;; current state
     (continuation)
     (current-key :initform nil)
     (current-values)
     (current-attributes)
     (cdata-section-p :reader klacks:current-cdata-section-p)
     ;; extra with-source magic
     (data-behaviour :initform :DTD)
     (namespace-stack :initform (list *initial-namespace-bindings*))
     (temporary-streams :initform nil)
     (scratch-pad :initarg :scratch-pad)
     (scratch-pad-2 :initarg :scratch-pad-2)
     (scratch-pad-3 :initarg :scratch-pad-3)
     (scratch-pad-4 :initarg :scratch-pad-4)))

(defmethod klacks:close-source ((source cxml-source))
  (dolist (xstream (slot-value source 'temporary-streams))
    ;; fixme: error handling?
    (close-xstream xstream)))

(defmacro with-source ((source &rest slots) &body body)
  (let ((s (gensym)))
    `(let* ((,s ,source)
	    (*ctx* (slot-value ,s 'context))
	    (*validate* (slot-value ,s 'validate))
	    (*data-behaviour* (slot-value source 'data-behaviour))
	    (*namespace-bindings* (car (slot-value source 'namespace-stack)))
	    (*scratch-pad* (slot-value source 'scratch-pad))
	    (*scratch-pad-2* (slot-value source 'scratch-pad-2))
	    (*scratch-pad-3* (slot-value source 'scratch-pad-3))
	    (*scratch-pad-4* (slot-value source 'scratch-pad-4)))
       (handler-case
	   (with-slots (,@slots) ,s
	     ,@body)
	 (runes-encoding:encoding-error (c)
	   (wf-error (slot-value ,s 'error-culprit) "~A" c))))))

(defun fill-source (source)
  (with-slots (current-key current-values continuation) source
    (unless current-key
      (setf current-key :bogus)
      (setf continuation (funcall continuation))
      (assert (not (eq current-key :bogus))))))

(defmethod klacks:peek ((source cxml-source))
  (with-source (source current-key current-values)
    (fill-source source)
    (apply #'values current-key current-values)))

(defmethod klacks:peek-value ((source cxml-source))
  (with-source (source current-key current-values)
    (fill-source source)
    (apply #'values current-values)))

(defmethod klacks:consume ((source cxml-source))
  (with-source (source current-key current-values)
    (fill-source source)
    (multiple-value-prog1
	(apply #'values current-key current-values)
      (setf current-key nil))))

(defmethod klacks:map-attributes (fn (source cxml-source))
  (dolist (a (slot-value source 'current-attributes))
    (funcall fn
	     (sax:attribute-namespace-uri a)
	     (sax:attribute-local-name a)
	     (sax:attribute-qname a)
	     (sax:attribute-value a)
	     (sax:attribute-specified-p a))))

(defmethod klacks:list-attributes ((source cxml-source))
  (slot-value source 'current-attributes))

(defun make-source
    (input &rest args
     &key validate dtd root entity-resolver disallow-internal-subset
	  pathname)
  (declare (ignore validate dtd root entity-resolver disallow-internal-subset))
  (etypecase input
    (xstream
      (let ((*ctx* nil))
	(let ((zstream (make-zstream :input-stack (list input))))
	  (peek-rune input)
	  (with-scratch-pads ()
	    (apply #'%make-source
		   zstream
		   (loop
		       for (name value) on args by #'cddr
		       unless (eq name :pathname)
		       append (list name value)))))))
    (stream
      (let ((xstream (make-xstream input)))
	(setf (xstream-name xstream)
	      (make-stream-name
	       :entity-name "main document"
	       :entity-kind :main
	       :uri (pathname-to-uri
		     (merge-pathnames (or pathname (pathname input))))))
	(apply #'make-source xstream args)))
    (pathname
      (let* ((xstream
	      (make-xstream (open input :element-type '(unsigned-byte 8))))
	     (source (apply #'make-source
			    xstream
			    :pathname input
			    args)))
	(push xstream (slot-value source 'temporary-streams))
	source))
    (rod
      (let ((xstream (string->xstream input)))
	(setf (xstream-name xstream)
	      (make-stream-name
	       :entity-name "main document"
	       :entity-kind :main
	       :uri nil))
	(apply #'make-source xstream args)))))

(defun %make-source
    (input &key validate dtd root entity-resolver disallow-internal-subset
		error-culprit)
  ;; check types of user-supplied arguments for better error messages:
  (check-type validate boolean)
  (check-type dtd (or null extid))
  (check-type root (or null rod))
  (check-type entity-resolver (or null function symbol))
  (check-type disallow-internal-subset boolean)
  (let* ((context
	  (make-context :handler nil
			:main-zstream input
			:entity-resolver entity-resolver
			:disallow-internal-subset disallow-internal-subset))
	 (source
	  (make-instance 'cxml-source
	    :context context
	    :validate validate
	    :dtd dtd
	    :root root
	    :error-culprit error-culprit
	    :scratch-pad *scratch-pad*
	    :scratch-pad-2 *scratch-pad-2*
	    :scratch-pad-3 *scratch-pad-3*
	    :scratch-pad-4 *scratch-pad-4*)))
    (setf (slot-value source 'continuation)
	  (lambda () (klacks/xmldecl source input)))
    source))

(defun klacks/xmldecl (source input)
  (with-source (source current-key current-values)
    (let ((hd (p/xmldecl input)))
      (setf current-key :start-document)
      (setf current-values
	    (when hd
	      (list (xml-header-version hd)
		    (xml-header-encoding hd)
		    (xml-header-standalone-p hd))))
      (lambda ()
	(klacks/misc*-2 source input
			(lambda ()
			  (klacks/doctype source input)))))))

(defun klacks/misc*-2 (source input successor)
  (with-source (source current-key current-values)
    (multiple-value-bind (cat sem) (peek-token input)
      (case cat
	(:COMMENT
	  (setf current-key :comment)
	  (setf current-values (list sem))
	  (consume-token input)
	  (lambda () (klacks/misc*-2 source input successor)))
	(:PI
	  (setf current-key :processing-instruction)
	  (setf current-values (list (car sem) (cdr sem)))
	  (consume-token input)
	  (lambda () (klacks/misc*-2 source input successor)))
	(:S
	  (consume-token input)
	  (klacks/misc*-2 source input successor))
	(t
	  (funcall successor))))))

(defun klacks/doctype (source input)
  (with-source (source current-key current-values validate dtd)
    (let ((cont (lambda () (klacks/finish-doctype source input)))
	  ignoreme name extid)
      (prog1
	  (cond
	    ((eq (peek-token input) :<!DOCTYPE)
	      (setf (values ignoreme name extid)
		    (p/doctype-decl input dtd))
	      (lambda () (klacks/misc*-2 source input cont)))
	    (dtd
	      (setf (values ignoreme name extid)
		    (synthesize-doctype dtd input))
	      cont)
	    ((and validate (not dtd))
	      (validity-error "invalid document: no doctype"))
	    (t
	      (return-from klacks/doctype
		(funcall cont))))
	(setf current-key :dtd)
	(setf current-values
	      (list name (extid-public extid) (extid-system extid)))))))

(defun klacks/finish-doctype (source input)
  (with-source (source current-key current-values root data-behaviour)
    (ensure-dtd)
    (when root
      (setf (model-stack *ctx*) (list (make-root-model root))))
    (setf data-behaviour :DOC)
    (setf *data-behaviour* :DOC)
    (fix-seen-< input)
    (let* ((final
	    (lambda ()
	      (klacks/eof source input)))
	   (next
	    (lambda ()
	      (setf data-behaviour :DTD)
	      (setf *data-behaviour* :DTD)
	      (klacks/misc*-2 source input final))))
      (klacks/element source input next))))

(defun klacks/eof (source input)
  (with-source (source current-key current-values)
    (p/eof input)
    (setf current-key :end-document)
    (setf current-values nil)
    (lambda () (klacks/nil source))))

(defun klacks/nil (source)
  (with-source (source current-key current-values)
    (setf current-key nil)
    (setf current-values nil)
    (labels ((klacks/done () #'klacks/done))
      #'klacks/done)))

(defun klacks/element (source input cont)
  (with-source (source current-key current-values current-attributes)
    (multiple-value-bind (cat n-b new-b uri lname qname attrs) (p/sztag input)
      (declare (ignore new-b))
      (setf current-key :start-element)
      (setf current-values (list uri lname qname))
      (setf current-attributes attrs)
      (if (eq cat :stag)
	  (lambda ()
	    (klacks/element-2 source input n-b cont))
	  (lambda ()
	    (klacks/ztag source cont))))))

(defun klacks/ztag (source cont)
  (with-source (source current-key current-values current-attributes)
    (setf current-key :end-element)
    (setf current-attributes nil)
    ;; fixme: (undeclare-namespaces new-b)
    (validate-end-element *ctx* (third current-values))
    cont))

(defun klacks/element-2 (source input n-b cont)
  (with-source (source
		current-key current-values current-attributes namespace-stack)
    (let ((values* current-values))
      (setf current-attributes nil)
      (push n-b namespace-stack)
      (let ((finish
	     (lambda ()
	       (pop namespace-stack)
	       (klacks/element-3 source input values* cont))))
	(klacks/content source input finish)))))

(defun klacks/element-3 (source input tag-values cont)
  (with-source (source current-key current-values current-attributes)
    (setf current-key :end-element)
    (setf current-values tag-values)
    (let ((qname (third tag-values)))
      (p/etag input qname)
      ;; fixme: (undeclare-namespaces new-b)
      (validate-end-element *ctx* qname))
    cont))

(defun klacks/content (source input cont)
  (with-source (source current-key current-values cdata-section-p)
    (let ((recurse (lambda () (klacks/content source input cont))))
      (multiple-value-bind (cat sem) (peek-token input)
	(case cat
	  ((:stag :ztag)
	    (klacks/element source input recurse))
	  ((:CDATA)
	    (process-characters input sem)
	    (setf current-key :characters)
	    (setf current-values (list sem))
	    (setf cdata-section-p nil)
	    recurse)
	  ((:ENTITY-REF)
	    (let ((name sem))
	      (consume-token input)
	      (klacks/entity-reference source input name recurse)))
	  ((:<!\[)
	    (setf current-key :characters)
	    (setf current-values (list (process-cdata-section input sem)))
	    (setf cdata-section-p t)
	    recurse)
	  ((:PI)
	    (setf current-key :processing-instruction)
	    (setf current-values (list (car sem) (cdr sem)))
	    (consume-token input)
	    recurse)
	  ((:COMMENT)
	    (setf current-key :comment)
	    (setf current-values (list sem))
	    (consume-token input)
	    recurse)
	  (otherwise
	    (funcall cont)))))))

(defun klacks/entity-reference (source zstream name cont)
  (assert (not (zstream-token-category zstream)))
  (with-source (source temporary-streams)
    (let ((new-xstream (entity->xstream zstream name :general nil)))
      (push new-xstream temporary-streams)
      (push :stop (zstream-input-stack zstream))
      (zstream-push new-xstream zstream)
      (let ((next
	     (lambda ()
	       (klacks/entity-reference-2 source zstream new-xstream cont))))
	(etypecase (checked-get-entdef name :general)
	  (internal-entdef
	    (klacks/content source zstream next))
	  (external-entdef
	    (klacks/ext-parsed-ent source zstream next)))))))

(defun klacks/entity-reference-2 (source zstream new-xstream cont)
  (with-source (source temporary-streams)
    (unless (eq (peek-token zstream) :eof)
      (wf-error zstream "Trailing garbage. - ~S" (peek-token zstream)))
    (assert (eq (peek-token zstream) :eof))
    (assert (eq (pop (zstream-input-stack zstream)) new-xstream))
    (assert (eq (pop (zstream-input-stack zstream)) :stop))
    (setf (zstream-token-category zstream) nil)
    (setf temporary-streams (remove new-xstream temporary-streams))
    (close-xstream new-xstream)
    (funcall cont)))

(defun klacks/ext-parsed-ent (source input cont)
  (with-source (source)
    (when (eq (peek-token input) :xml-decl)
      (let ((hd (parse-text-decl (cdr (nth-value 1 (peek-token input))))))
	(setup-encoding input hd))
      (consume-token input))
    (set-full-speed input)
    (klacks/content source input cont)))

#+(or)
(trace CXML::KLACKS/DOCTYPE 
       CXML::KLACKS/EXT-PARSED-ENT 
       CXML::KLACKS/MISC*-2 
       CXML::KLACKS/ENTITY-REFERENCE 
       CXML::KLACKS/ENTITY-REFERENCE-2 
       CXML::KLACKS/ELEMENT 
       CXML::KLACKS/ZTAG 
       CXML::KLACKS/XMLDECL 
       CXML::KLACKS/FINISH-DOCTYPE 
       CXML::KLACKS/ELEMENT-3 
       CXML::KLACKS/EOF 
       CXML::KLACKS/ELEMENT-2 
       CXML::KLACKS/CONTENT )