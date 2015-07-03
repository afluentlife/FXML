;;; (c) 2005 David Lichteblau <david@lichteblau.com>
;;; License: Lisp-LGPL (See file COPYING for details).
;;;
;;; ystream (for lack of a better name): a rune output "stream"

(in-package :fxml.runes)
(in-readtable :runes)

(defconstant +ystream-bufsize+ 1024)

(defun make-ub8-array (n)
  (make-array n :element-type '(unsigned-byte 8)))

(defun make-ub16-array (n)
  (make-array n :element-type '(unsigned-byte 16)))

(defun make-buffer (&key (element-type '(unsigned-byte 8)))
  (make-array 1
              :element-type element-type
              :adjustable t
              :fill-pointer 0))

(defmacro while (test &body body)
  `(loop while ,test do ,@body))

(defun find-output-encoding (name)
  (when (stringp name)
    (setf name (find-symbol (string-upcase name) :keyword)))
  (cond
    ((null name)
     (warn "Unknown encoding ~A, falling back to UTF-8" name)
     :utf-8)
    ((find name '(:utf-8 :utf_8 :utf8))
     :utf-8)
    (t
     (handler-case
	 (babel-encodings:get-character-encoding name)
       (error ()
	 (warn "Unknown encoding ~A, falling back to UTF-8" name)
	 :utf-8)))))

;;; ystream
;;;  +- encoding-ystream
;;;  |    +- octet-vector-ystream
;;;  |    \- %stream-ystream
;;;  |        +- octet-stream-ystream
;;;  |        \- character-stream-ystream/utf8
;;;  |            \- string-ystream/utf8
;;;  +- rod-ystream
;;;  \-- character-stream-ystream

(defstruct ystream
  (encoding)
  (column 0 :type integer)
  (in-ptr 0 :type fixnum)
  (in-buffer (make-rod +ystream-bufsize+) :type simple-rod))

(defun ystream-unicode-p (ystream)
  (let ((enc (ystream-encoding ystream)))
    (or (eq enc :utf-8)
	(eq (babel-encodings:enc-name enc) :utf-16))))

(defstruct (encoding-ystream
	    (:include ystream)
	    (:conc-name "YSTREAM-"))
  (out-buffer (make-ub8-array (* 6 +ystream-bufsize+))
	      :type (simple-array (unsigned-byte 8) (*))))

(defstruct (%stream-ystream
	     (:include encoding-ystream)
	     (:conc-name "YSTREAM-"))
  (os-stream nil))

;; writes a rune to the buffer.  If the rune is not encodable, an error
;; might be signalled later during flush-ystream.
(definline ystream-write-rune (rune ystream)
  (let ((in (ystream-in-buffer ystream)))
    (when (eql (ystream-in-ptr ystream) (length in))
      (flush-ystream ystream)
      (setf in (ystream-in-buffer ystream)))
    (setf (elt in (ystream-in-ptr ystream)) rune)
    (incf (ystream-in-ptr ystream))
    (setf (ystream-column ystream)
	  (if (eql rune #/U+000A) 0 (1+ (ystream-column ystream))))
    rune))

;; Writes a rod to the buffer.  If a rune in the rod not encodable, an error
;; might be signalled later during flush-ystream.
(defun ystream-write-rod (rod ystream)
  ;;
  ;; OPTIMIZE ME
  ;;
  (loop for rune across rod do (ystream-write-rune rune ystream)))

(defun ystream-write-escapable-rune (rune ystream)
  ;;
  ;; OPTIMIZE ME
  ;;
  (let ((tmp (make-rod 1)))
    (setf (elt tmp 0) rune)
    (ystream-write-escapable-rod tmp ystream)))

;; Writes a rod to the buffer.  If a rune in the rod not encodable, it is
;; replaced by a character reference.
;;
(defun ystream-write-escapable-rod (rod ystream)
  ;;
  ;; TODO OPTIMIZE ME
  ;;
  (if (ystream-unicode-p ystream)
      (ystream-write-rod rod ystream)
      (loop
	 with encoding = (ystream-encoding ystream)
	 for rune across rod
	 do
	   (if (encodablep rune encoding)
	       (ystream-write-rune rune ystream)
	       (let ((cr (string-rod (format nil "&#~D;" (rune-code rune)))))
		 (ystream-write-rod cr ystream))))))

(defun encodablep (character encoding)
  (handler-case
      (babel:string-to-octets (string character) :encoding encoding)
    (babel-encodings:character-encoding-error ()
      nil)))

(defmethod close-ystream :before ((ystream ystream))
  (flush-ystream ystream))


;;;; ENCODING-YSTREAM (abstract)

(defmethod close-ystream ((ystream %stream-ystream))
  (ystream-os-stream ystream))

(defgeneric ystream-device-write (ystream buf nbytes))

(defun encode-runes (out in ptr encoding)
  (case encoding
    (:utf-8
     (runes-to-utf8 out in ptr))
    (t
     ;; by lucky coincidence, babel::unicode-string is the same as simple-rod
     #+nil (coerce string 'babel::unicode-string)
     (let* ((babel::*suppress-character-coding-errors* nil)
	    (mapping (babel::lookup-mapping babel::*string-vector-mappings*
					    encoding)))
       (funcall (babel::encoder mapping) in 0 ptr out 0)
       (funcall (babel::octet-counter mapping) in 0 ptr -1)))))

(defmethod flush-ystream ((ystream encoding-ystream))
  (let ((ptr (ystream-in-ptr ystream)))
    (when (plusp ptr)
      (let* ((in (ystream-in-buffer ystream))
	     (out (ystream-out-buffer ystream))
	     n)
	(when (plusp ptr)
	  (setf n (encode-runes out in ptr (ystream-encoding ystream)))
	  (ystream-device-write ystream out n)
	  (setf (ystream-in-ptr ystream) 0))))))

(defun fast-push (new-element vector)
  (vector-push-extend new-element vector (max 1 (array-dimension vector 0))))

(macrolet ((define-utf8-writer (name (byte &rest aux) result &body body)
	     `(defun ,name (out in n)
		(let (,@aux)
		  (labels
		      ((write0 (,byte)
			 ,@body)
		       (write1 (r)
			 (cond
			   ((<= #x00000000 r #x0000007F) 
			     (write0 r))
			   ((<= #x00000080 r #x000007FF)
			     (write0 (logior #b11000000 (ldb (byte 5 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00000800 r #x0000FFFF)
			     (write0 (logior #b11100000 (ldb (byte 4 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00010000 r #x001FFFFF)
			     (write0 (logior #b11110000 (ldb (byte 3 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x00200000 r #x03FFFFFF)
			     (write0 (logior #b11111000 (ldb (byte 2 24) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))
			   ((<= #x04000000 r #x7FFFFFFF)
			     (write0 (logior #b11111100 (ldb (byte 1 30) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 24) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 18) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 12) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 6) r)))
			     (write0 (logior #b10000000 (ldb (byte 6 0) r))))))
		       (write2 (r)
			 (if (<= #xD800 r #xDFFF)
                             (error
                              "Surrogates not allowed in this configuration")
                             (write1 r))))
		    (dotimes (j n)
		      (write2 (rune-code (elt in j)))))
		  ,result))))
  (define-utf8-writer runes-to-utf8 (x (i 0))
    i
    (setf (elt out i) x)
    (incf i))
  (define-utf8-writer runes-to-utf8/adjustable-string (x)
    nil
    (fast-push (code-char x) out)))


;;;; ROD-YSTREAM

(defstruct (rod-ystream (:include ystream)))

(defmethod flush-ystream ((ystream rod-ystream))
  (let* ((old (ystream-in-buffer ystream))
	 (new (make-rod (* 2 (length old)))))
    (replace new old)
    (setf (ystream-in-buffer ystream) new)))

(defmethod close-ystream ((ystream rod-ystream))
  (subseq (ystream-in-buffer ystream) 0 (ystream-in-ptr ystream)))


;;;; CHARACTER-STREAM-YSTREAM

(defstruct (character-stream-ystream
            (:constructor make-character-stream-ystream (target-stream))
            (:include ystream)
            (:conc-name "YSTREAM-"))
  (target-stream nil))

(defmethod flush-ystream ((ystream character-stream-ystream))
  (write-string (ystream-in-buffer ystream)
                (ystream-target-stream ystream)
                :end (ystream-in-ptr ystream))
  (setf (ystream-in-ptr ystream) 0))

(defmethod close-ystream ((ystream character-stream-ystream))
  (ystream-target-stream ystream))


;;;; OCTET-VECTOR-YSTREAM

(defstruct (octet-vector-ystream
	    (:include encoding-ystream)
	    (:conc-name "YSTREAM-"))
  (result (make-buffer)))

(defmethod ystream-device-write ((ystream octet-vector-ystream) buf nbytes)
  (let* ((result (ystream-result ystream))
	 (start (length result))
	 (size (array-dimension result 0)))
    (while (> (+ start nbytes) size)
      (setf size (* 2 size)))
    (adjust-array result size :fill-pointer (+ start nbytes))
    (replace result buf :start1 start :end2 nbytes)))

(defmethod close-ystream ((ystream octet-vector-ystream))
  (ystream-result ystream))


;;;; OCTET-STREAM-YSTREAM

(defstruct (octet-stream-ystream
	    (:include %stream-ystream)
	    (:constructor make-octet-stream-ystream (os-stream))
	    (:conc-name "YSTREAM-")))

(defmethod ystream-device-write ((ystream octet-stream-ystream) buf nbytes)
  (write-sequence buf (ystream-os-stream ystream) :end nbytes))


;;;; CHARACTER-STREAM-YSTREAM/UTF8

;;;; STRING-YSTREAM/UTF8

;;;; helper functions

(defun rod-to-utf8-string (rod)
  (let ((out (make-buffer :element-type 'character)))
    (runes-to-utf8/adjustable-string out rod (length rod))
    out))

(defun utf8-string-to-rod (str)
  (let* ((bytes (map '(vector (unsigned-byte 8)) #'char-code str))
         (buffer (make-array (length bytes) :element-type 'buffer-byte))
         (n (fxml.runes-encoding:decode-sequence
	     :utf-8 bytes 0 (length bytes) buffer 0 0 nil))
         (result (make-array n :element-type 'rune)))
    (map-into result #'code-rune buffer)
    result))

(defclass octet-input-stream
    (trivial-gray-stream-mixin fundamental-binary-input-stream)
    ((octets :initarg :octets)
     (pos :initform 0)))

(defmethod close ((stream octet-input-stream) &key abort)
  (declare (ignore abort))
  (open-stream-p stream))

(defmethod stream-read-byte ((stream octet-input-stream))
  (with-slots (octets pos) stream
    (if (>= pos (length octets))
        :eof
        (prog1
            (elt octets pos)
          (incf pos)))))

(defmethod stream-read-sequence
    ((stream octet-input-stream) sequence start end &key &allow-other-keys)
  (with-slots (octets pos) stream
    (let* ((length (min (- end start) (- (length octets) pos)))
           (end1 (+ start length))
           (end2 (+ pos length)))
      (replace sequence octets :start1 start :end1 end1 :start2 pos :end2 end2)
      (setf pos end2)
      end1)))

(defun make-octet-input-stream (octets)
  (make-instance 'octet-input-stream :octets octets))