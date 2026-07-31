(in-package #:psac)

;;;; Graph lock ----------------------------------------------------------------
;;;; Defined here (not trace.lisp) so INTERN-PRINCIPAL below can serialize table
;;;; mutation during parallel waves.

;; True inside parallel propagation waves; makes shared-state mutation take *GRAPH-LOCK*.
(defvar *parallel-propagation* nil)
(defvar *graph-lock* (bt:make-lock "psac-graph"))

(defmacro with-graph-lock (&body body)
  "Serialize shared-graph mutation during parallel waves; free in the sequential path."
  `(flet ((body () ,@body))
     (if *parallel-propagation*
         (bt:with-lock-held (*graph-lock*) (body))
         (body))))

;;;; Principals ---------------------------------------------------------------

;; Counters live in one-element boxes so that conveying the binding to lparallel
;; workers shares the cell: a worker's increment is visible to the coordinator
;; instead of dying with the worker's local rebinding.
(defvar *principal-counter* (list -1))
(defvar *principal-ids* (make-hash-table :test #'equal))
(defvar *principal-names* (make-hash-table :test #'eql))

(defun intern-principal (name)
  "Map NAME (string/symbol/integer) to a small integer id; bit (ash 1 id) is used in blame and label masks."
  (etypecase name
    (integer name)
    ((or string symbol)
     (let ((key (string-downcase (string name))))
       (or (gethash key *principal-ids*)
           (with-graph-lock            ; workers may intern concurrently in a wave
             (or (gethash key *principal-ids*)
                 (let ((id (1+ (car *principal-counter*))))
                   ;; blame/label slots are fixnums; overflowing them would silently corrupt masks
                   (unless (typep (ash 1 id) 'fixnum)
                     (error "too many principals: blame masks are fixnums (~a usable bits)"
                            (1- (integer-length most-positive-fixnum))))
                   (setf (car *principal-counter*) id
                         (gethash key *principal-ids*) id
                         (gethash id *principal-names*) key)
                   id))))))))

(defun principal-name (id)
  (or (gethash id *principal-names*) id))

(defvar *current-principal* (intern-principal "system")
  "Id of the acting principal; external writes are blamed on it.")

(defmacro with-principal ((principal) &body body)
  `(let ((*current-principal* (intern-principal ,principal)))
     ,@body))

;;;; Modifiables --------------------------------------------------------------

(defvar *mod-counter* (list 0))   ; boxed; see *principal-counter*
(defvar *enforce-labels* nil
  "When true, write! signals LABEL-FLOW-ERROR if the writing node's pc-label is not below the target's label.")

(defstruct (modref (:constructor %make-modref))
  (name nil)
  (value nil)
  (test #'eql :type function)
  ;; rnode that last wrote this mod; nil for input mods
  (writer nil)
  ;; rnodes currently reading this mod (propagation direction)
  (readers '() :type list)
  (owner 0 :type fixnum)
  (label 0 :type fixnum)
  ;; principals responsible for the value currently propagating through this mod
  (blame 0 :type fixnum)
  ;; 0 = policy stratum (propagates first), 1 = data
  (stratum 1 :type fixnum))

(defun make-mod (value &key name (test #'eql) (owner *current-principal*) (label 0) (stratum 1))
  (%make-modref :name (or name (format nil "m~a" (incf (car *mod-counter*))))
                :value value :test test :owner owner :label label :stratum stratum))

(defun mod-value (mod)
  (modref-value mod))

(defmethod print-object ((m modref) stream)
  (print-unreadable-object (m stream :type t)
    (format stream "~a = ~s" (modref-name m) (modref-value m))))

;;;; Capabilities -------------------------------------------------------------

;; Unforgeable outside this package: constructors are not exported, only GRANT-READ / GRANT-WRITE are.
(defstruct (read-cap (:constructor %make-read-cap)) mod)
(defstruct (write-cap (:constructor %make-write-cap)) mod)

(defun grant-read (mod) (%make-read-cap :mod mod))
(defun grant-write (mod) (%make-write-cap :mod mod))

(defun resolve-readable (thing)
  (etypecase thing
    (modref thing)
    (read-cap (read-cap-mod thing))))

(defun resolve-writable (thing)
  (etypecase thing
    (modref thing)
    (write-cap (write-cap-mod thing))))

;;;; Conditions ---------------------------------------------------------------

(define-condition label-flow-error (error)
  ((node-label :initarg :node-label :reader label-flow-error-node-label)
   (mod :initarg :mod :reader label-flow-error-mod))
  (:report (lambda (c stream)
             (format stream "IFC violation: pc-label ~b does not flow to ~a (label ~b)"
                     (label-flow-error-node-label c)
                     (modref-name (label-flow-error-mod c))
                     (modref-label (label-flow-error-mod c))))))

(define-condition single-writer-error (error)
  ((mod :initarg :mod :reader single-writer-error-mod)
   (writer :initarg :writer :reader single-writer-error-writer)
   (node :initarg :node :reader single-writer-error-node))
  (:report (lambda (c stream)
             (format stream "single-writer violation: ~a already written by live node ~a; ~
node ~a must not write it too (bills, provenance, and parallel waves assume one writer per mod)"
                     (modref-name (single-writer-error-mod c))
                     (single-writer-error-writer c)
                     (single-writer-error-node c)))))

(define-condition height-invariant-error (error)
  ((writer :initarg :writer :reader height-invariant-error-writer)
   (reader :initarg :reader :reader height-invariant-error-reader))
  (:report (lambda (c stream)
             (format stream "height invariant violated: writer ~a dirties same-stratum reader ~a ~
whose height is not greater; propagation would glitch (and mis-bill under parallel waves)"
                     (height-invariant-error-writer c)
                     (height-invariant-error-reader c)))))
