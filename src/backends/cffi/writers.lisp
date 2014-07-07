(in-package :verrazano)

(defmethod process-gccxml-node :around ((backend simple-backend) (node gccxml:node-with-name))
  ;; KLUDGE: ignore STL nodes
  (bind ((name (gccxml:name-of node)))
    (unless (find #\< name)
      (call-next-method))))

(defmethod process-gccxml-node :around ((backend cffi-backend) (node gccxml:gcc_xml))
  (with-open-file (*standard-output* (output-filename-of backend)
                                     :direction :output :if-exists :supersede)
    (bind ((package-name (package-name-of backend))
           (*package* (eval `(defpackage package-name (:use :cffi))))
           (body (with-output-to-string (*standard-output*)
                   (call-next-method))))
      (write-formatted-text ";;; Generated by Verrazano ~A~%" (asdf:component-version
                                                               (asdf:find-system :verrazano)))
      (write-formatted-text ";;; WARNING: This is a generated file, editing it is unwise!~%~%")
      (write-form '(cl:in-package :cl-user))
      ;;(write-form '(asdf:operate 'asdf:load-op :verrazano-runtime))
      (write-form `(defpackage
                       ,package-name
                     (:use :cffi)
                     ,(list* :nicknames (package-nicknames-of backend))
                     ,(list* :export (mapcar #'string-upcase
                                             (hash-table-keys (exported-symbols-of backend))))))
      (write-form `(in-package ,(package-name-of backend)))
      (write-form '(cl:defun vtable-lookup (pobj indx coff)
                    (cl:let ((vptr (cffi:mem-ref pobj :pointer coff)))
                      (cffi:mem-aref vptr :pointer (- indx 2)))))
      (write-form '(cl:defmacro virtual-funcall (pobj indx coff &body body)
                    `(cffi:foreign-funcall-pointer (vtable-lookup ,pobj ,indx ,coff) nil ,@body)))
      (write-string body))))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:struct))
  (write-composite-cffi-type backend node :struct))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:class))
  (write-composite-cffi-type backend node :class))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:union))
  (write-composite-cffi-type backend node :union))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:macro))
  (assert (body-of node))
  (assert (typep (body-of node) '(or string number)))
  (write-form `(cl:defconstant ,(symbolify
                                 (enqueue-for-export
                                  (transform-name (name-of node) :constant)))
                 ,(body-of node))))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:typedef))
  (bind ((type (type-of node)))
    (if (and (typep type '(or gccxml:struct gccxml:class gccxml:union gccxml:enumeration))
             (string= (name-of type) (name-of node)))
        ;; it's an instance of the "deftype struct foo {} foo;" pattern, write the struct/union instead
        (process-gccxml-node backend type)
        (progn
          #+nil
          (when (string-equal (name-of node) "JSAccessMode")
            (break "here: ~A" node))
          (process-gccxml-node backend type)
          (assert (null (find-node-by-name (name-of node) 'gccxml:struct *parser* :otherwise nil)))
          (process-gccxml-node backend type)
          (format t "~%(cffi::defctype ~A " (enqueue-for-export
                                             (transform-name (name-of node) :type)))
          (write-cffi-type type)
          (format t ")~%")))))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:enumeration))
  (format t "~%(cffi:defcenum ~A~%" (enqueue-for-export
                                     (transform-name (name-of node) :enum)))
  (pprint-logical-block (*standard-output* nil :per-line-prefix "  ")
    (iter (for enum-value :in-sequence (flexml:children-of node))
          (unless (first-time-p)
            (pprint-newline :mandatory))
          (assert (typep enum-value 'gccxml:enumvalue))
          (format t "(~A ~A)"
                  (concatenate 'string ":" (enqueue-for-export
                                            (transform-name (name-of enum-value)
                                                            :enum-value)))
                  (slot-value enum-value 'gccxml::init))))
  (format t ")~%"))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:constructor))
  (write-cffi-function backend node)
  (write-form `(cl:defun ,(symbolify
                           (enqueue-for-export
                            (transform-name (concatenate 'string (name-of node) "-new") :function))) ()
                 (cl:let ((instance (cffi:foreign-alloc ',(symbolify (transform-name (name-of (context-of node)) :class)))))
                   (,(symbolify (transform-name (function-name-of node) :function)) instance)
                   instance))))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:function))
  (write-cffi-function backend node))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:variable))
  (bind ((type (type-of node)))
    (if (and (typep type 'gccxml:cvqualifiedtype)
             (const? type))
        (write-form `(cl:defconstant ,(symbolify
                                       (enqueue-for-export
                                        (transform-name (name-of node) :constant)))
                       ,(c-literal-to-lisp-literal (slot-value node 'gccxml:init))))
        (progn
          (process-gccxml-node backend type)
          (format t "~%(cffi:defcvar (~S ~A) "
                  (or (mangled-of node) (name-of node))
                  (enqueue-for-export
                   (transform-name (name-of node) :function)))
          (write-cffi-type type)
          (format t ")~%")))))

(defmethod process-gccxml-node ((backend cffi-backend) (node gccxml:node-with-type))
  (process-gccxml-node backend (type-of node)))

(defgeneric write-cffi-type (type))

(defmethod write-cffi-type ((node t))
  (error "Don't know how to write ~A as a CFFI type" node))

(macrolet ((define (&rest entries)
             `(progn
                ,@(iter (for (type kind) :in entries)
                        (collect `(defmethod write-cffi-type ((node ,type))
                                    (if (name-of node)
                                        (write-string (enqueue-for-export
                                                       (transform-name (name-of node) ,kind)))
                                        (warn-and-write-as-comment "Skipping anonymous type ~A" node))))))))
  (define
    (gccxml:struct :struct)
    (gccxml:class :class)
    (gccxml:union :union)
    (gccxml:typedef :type)
    (gccxml:enumeration :enum)))

(defmethod write-cffi-type ((node gccxml:pointertype))
  (bind ((target-type (type-of node)))
    (if (typep target-type 'gccxml:fundamentaltype)
        (progn
          (write-string "(:pointer ")
          (write-cffi-type target-type)
          (write-string ")"))
        (write-string ":pointer"))))

(defmethod write-cffi-type ((node gccxml:functiontype))
  ;; TODO FIXME KLUDGE
  (write-string ":pointer"))

(defmethod write-cffi-type ((node gccxml:arraytype))
  (write-cffi-type (type-of node))
  (bind ((max (slot-value node 'gccxml:max)))
    (when (ends-with #\u max)
      (setf max (subseq max 0 (1- (length max)))))
    (unless (equal "" max)
    (bind ((count (1+ (parse-integer max))))
        (format t " :count ~A" count)))))

(defmethod write-cffi-type ((node gccxml:referencetype))
  (write-cffi-type (type-of node)))

(defmethod write-cffi-type ((node gccxml:cvqualifiedtype))
  (write-cffi-type (type-of node)))

(defmethod write-cffi-type ((node gccxml:fundamentaltype))
  (bind ((gccxml-type (name-of node))
         (cffi-type (cdr (assoc gccxml-type *gccxml-fundamental-type->cffi-type* :test #'string=))))
    (if cffi-type
        (write-keyword cffi-type)
        (warn-and-write-as-comment "No entry found for gccxml type ~S in *GCCXML-FUNDAMENTAL-TYPE->CFFI-TYPE*" gccxml-type))))

(defun write-composite-cffi-type (backend node type)
  (if (name-of node)
      (bind ((definer (ecase type
                        (:struct "cffi:defcstruct")
                        (:class "cffi:defcstruct")
                        (:union "cffi:defcunion"))))
        (do-fields-of-composite-type (field node)
          (process-gccxml-node backend (type-of field)))
        (format t "~%(~A ~A~%" definer (enqueue-for-export
                                        (transform-name (name-of node) type)))
        (pprint-logical-block (*standard-output* nil :per-line-prefix "  ")
          (bind ((bits 0))
            (do-fields-of-composite-type (field node)
              (unless (first-time-p)
                (pprint-newline :mandatory))
              (if (bits-of field)
                  (progn
                    ;; FIXME
                    ;; KLUDGE try to generate sensible output
                    (warn-and-write-as-comment
                     "Skipping field ~A in ~A because it has a bitfield type which is not yet supported by CFFI! Check the layout manually!"
                     field (context-of field))
                    (incf bits (bits-of field))
                    (cond ((= bits 32)
                           (format t "~%(~A :int) ;; generated to pad 32 bits of skipped bitfield typed fields" ;
                                   (generate-unique-name "padding"))
                           (setf bits 0))
        ((= bits 64)
         (format t "~%(~A :long) ;; generated to pad 64 bits of skipped bitfield typed fields"
                 (generate-unique-name "padding"))
         (setf bits 0))))
  (progn
    (unless (zerop bits)
      (setf bits 0)
      ;; FIXME
      (warn-and-write-as-comment
       "Encountered a field while the previous bitfield typed fields do not add up to 32 or 64 bits. The fields offsets will be wrong in ~A!"
       node))
    (bind ((type (type-of field))
           (offset-in-bits (offset-of field))
           ((:values offset-in-bytes remainder) (truncate offset-in-bits 8)))
      (declare (ignore offset-in-bytes))
      (if (zerop remainder)
          (progn
            (format t "(~A " (enqueue-for-export
                              (transform-name (name-of field) :field)))
            (write-cffi-type type)
            ;; Unfortunately this would be problematic due to the varying size of the pointer type on 32/64 bit platforms
            ;; (format t " :offset ~A" offset-in-bytes)
            (format t ")"))
          (warn-and-write-as-comment
           "The offset of the field ~A in struct ~A is not at byte boundary; skipping it!"
           field (context-of field)))))))))
        (format t ")~%"))
      (warn-and-write-as-comment "Skipping anonymous composite type ~A" node)))

(defun write-composite-cffi-type-field (field)
  (if (bits-of field)
      (warn-and-write-as-comment
       "The field ~A in ~A has a bitfield type which is not yet supported by CFFI; skipping it!"
       field (context-of field))
      (bind ((type (type-of field))
             (offset-in-bits (offset-of field))
             ((:values offset-in-bytes remainder) (truncate offset-in-bits 8)))
        (declare (ignore offset-in-bytes))
        (if (zerop remainder)
            (progn
              (format t "(~A " (enqueue-for-export
                                (transform-name (name-of field) :field)))
              (write-cffi-type type)
              ;; This is problematic due to the varying size of the pointer type
              ;; (format t " :offset ~A" offset-in-bytes)
              (format t ")"))
            (warn-and-write-as-comment
             "The offset of the field ~A in struct ~A is not at byte boundary; skipping it!"
             field (context-of field))))))

(defun remove-internal-suffix (name)
  (bind ((suffix " *INTERNAL* "))
    (if (ends-with-subseq suffix name)
        (subseq name 0 (- (length name) (length suffix)))
        name)))

(defgeneric function-name-of (node)
  (:method ((node gccxml:function))
    (name-of node))

  (:method ((node gccxml:operatormethod))
    (concatenate 'string (name-of (context-of node)) "-operator-" (name-of node)))

  (:method ((node gccxml:operatorfunction))
    (concatenate 'string "operator-" (name-of node)))

  (:method ((node gccxml:constructor))
    (concatenate 'string (name-of node) "-constructor")))

(defun write-cffi-function (backend node)
  (bind ((returns
          (unless (typep node 'gccxml:constructor)
            (returns-of node))))
    (when returns
      (process-gccxml-node backend returns))
    (do-arguments-of-function (argument node :skip-ellipsis t)
      (process-gccxml-node backend (type-of argument)))
    (format t "~%(cffi:defcfun (~S ~A) "
            (or (awhen (mangled-of node)
                  (remove-internal-suffix it))
                (name-of node))
            (enqueue-for-export
             (transform-name (function-name-of node) :function)))
    (if returns
        (write-cffi-type returns)
        (format t ":void"))
    (pprint-logical-block (*standard-output* nil)
      (bind ((index 0))
        (when (typep node '(or gccxml:constructor gccxml:method gccxml:operatormethod))
          (format t " (this :pointer)"))
        (do-arguments-of-function (argument node)
          (incf index)
          (if (typep argument 'gccxml:ellipsis)
              (write-string "common-lisp:&rest")
              (bind ((argument-name (aif (name-of argument)
                                         (transform-name it :variable)
                                         (format nil "arg~A" index)))
                     (argument-type (type-of argument)))
                (pprint-newline :fill)
                (format t " (~A " argument-name)
                (write-cffi-type argument-type)
                (format t ")"))))))
    (format t ")~%")))

;; TODO move them
(defun warn-and-write-as-comment (message &rest args)
  (apply #'warn message args)
  (format t ";;; ")
  (apply #'format t message args)
  (terpri))

(defun write-keyword (keyword)
  (assert (keywordp keyword))
  (write-char #\:)
  (write-string (string-downcase keyword)))

(defun write-form (form)
  (bind ((*print-pprint-dispatch* (copy-pprint-dispatch)))
    (set-pprint-dispatch 'symbol
                         (lambda (stream symbol)
                           (bind ((package (symbol-package symbol))
                                  (flag (nth-value 1 (find-symbol (symbol-name symbol) package))))
                             (write-string
                              (string-downcase
                               (cond ((and (string= "VERRAZANO" (package-name package))
                                           (eq :internal flag))
                                      (symbol-name symbol))
                                     ((eq package *package*)
                                      (symbol-name symbol))
                                     ((eq package (find-package :keyword))
                                      (concatenate 'string
                                                   ":"
                                                   (symbol-name symbol)))
                                 
                                     (t
                                      (concatenate 'string
                                                   (or (first (package-nicknames package))
                                                       (package-name package))
                                                   (if (eq :external flag)
                                                       ":"
                                                       "::")
                                                   (symbol-name symbol)))))
                              stream))))
    (format t "~%~S~%" form)))

(defun write-formatted-text (format &rest args)
  (apply 'format t format args))

(defun symbolify (name)
  (intern (string-upcase name)))
