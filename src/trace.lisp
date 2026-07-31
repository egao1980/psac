(in-package #:psac)

;;;; The dependency trace: R-nodes, read/write edges, dirty marking.
;;;;
;;;; Every ADAPTIVE-READ creates an R-node holding a re-runnable thunk over a static
;;;; read set. Nested reads become children; re-running a node kills and rebuilds its
;;;; subtree. Edges are bidirectional: mod -> readers (propagation) and node -> mods-read
;;;; (provenance slicing).

(defvar *rnode-counter* 0)
(defvar *current-rnode* nil)
(defvar *dirty-queue* '())
(defvar *last-update-log* '())
;; Bound by PROPAGATE! so that nodes (re)executed during propagation are charged and logged.
(defvar *propagation-bill* nil)
(defvar *propagation-blame* 0)
(defvar *propagation-log* '())
(defvar *billing-suspended* nil)
;; True inside parallel propagation waves; makes graph bookkeeping take *GRAPH-LOCK*.
(defvar *parallel-propagation* nil)
(defvar *graph-lock* (bt:make-lock "psac-graph"))

(defmacro with-graph-lock (&body body)
  "Serialize shared-graph mutation during parallel waves; free in the sequential path."
  `(flet ((body () ,@body))
     (if *parallel-propagation*
         (bt:with-lock-held (*graph-lock*) (body))
         (body))))

(defstruct (rnode (:print-object print-rnode))
  (id (incf *rnode-counter*) :type fixnum)
  (name nil)
  (thunk nil :type (or null function))
  ;; static read set (bindings of the adaptive-read); nested reads live in children
  (mods-read '() :type list)
  ;; selective provenance: subset of mods-read that actually determined the last result
  (determined '() :type list)
  (provenance-fn nil)
  (writes '() :type list)
  (children '() :type list)
  (parent nil)
  (height 0 :type fixnum)
  (stratum 1 :type fixnum)
  ;; pc-label: join of labels of everything readable in scope
  (label 0 :type fixnum)
  (cost 1 :type fixnum)
  (blame 0 :type fixnum)
  (dirty-p nil)
  (dead-p nil))

(defun print-rnode (node stream)
  (print-unreadable-object (node stream :type t)
    (format stream "~a h~a~@[ dirty~]~@[ dead~]"
            (node-name node) (rnode-height node) (rnode-dirty-p node) (rnode-dead-p node))))

(defun node-name (node)
  (or (rnode-name node) (format nil "rnode-~a" (rnode-id node))))

(defstruct update-record
  node
  (blame 0 :type fixnum)
  (cost 0 :type fixnum)
  (writes '() :type list))

(defun last-update-log ()
  *last-update-log*)

(defun reset-graph! ()
  "Clear global propagation state (queue, logs, bills). Mods and nodes are owned by callers."
  (setf *dirty-queue* '()
        *last-update-log* '()
        *last-bill* nil
        *current-rnode* nil)
  (values))

;;;; Node construction and execution ------------------------------------------

(defun compute-node-height (mods parent)
  (let ((h 0))
    (dolist (m mods)
      (let ((w (modref-writer m)))
        (when w (setf h (max h (rnode-height w))))))
    (when parent
      (setf h (max h (rnode-height parent))))
    (1+ h)))

(defun register-read (readables thunk &key (cost 1) provenance name)
  "Create an R-node reading READABLES (mods or read-caps), run THUNK on their values.
THUNK re-runs whenever any of the mods changes. Returns the node."
  (let* ((mods (mapcar #'resolve-readable readables))
         (parent *current-rnode*)
         (node (make-rnode
                :thunk thunk :mods-read mods :cost cost :provenance-fn provenance
                :parent parent :name name
                :stratum (reduce #'max mods :key #'modref-stratum
                                 :initial-value (if parent (rnode-stratum parent) 0))
                :label (reduce #'logior mods :key #'modref-label
                               :initial-value (if parent (rnode-label parent) 0))
                :height (compute-node-height mods parent))))
    (with-graph-lock
      (dolist (m mods)
        (push node (modref-readers m)))
      (when parent
        (push node (rnode-children parent))))
    (run-rnode node)
    ;; nodes born during propagation are part of the update's cost
    (when *propagation-bill*
      (record-execution node *propagation-blame*))
    node))

(defmacro adaptive-read ((&rest bindings) &body body)
  "BINDINGS: (var mod-or-read-cap)*. Optional leading options form (:cost N :provenance FN :name S).
BODY runs with vars bound to current values and re-runs on changes; writes inside propagate onward."
  (let* ((opts (when (and (consp (car body)) (keywordp (caar body)))
                 (pop body)))
         (vars (mapcar #'first bindings))
         (exprs (mapcar #'second bindings)))
    `(register-read (list ,@exprs)
                    (lambda ,vars ,@body)
                    ,@opts)))

(defun run-rnode (node)
  (let* ((*current-rnode* node)
         (vals (mapcar #'modref-value (rnode-mods-read node))))
    (setf (rnode-writes node) '()
          (rnode-children node) '())
    (let ((result (apply (rnode-thunk node) vals)))
      (setf (rnode-determined node)
            (if (rnode-provenance-fn node)
                (funcall (rnode-provenance-fn node) result vals (rnode-mods-read node))
                (rnode-mods-read node)))
      result)))

(defun record-execution (node blame)
  (with-graph-lock
    (charge! *propagation-bill* blame (rnode-cost node)))
  ;; *PROPAGATION-LOG* is coordinator- or task-local; no lock needed.
  (push (make-update-record :node node :blame blame :cost (rnode-cost node)
                            :writes (copy-list (rnode-writes node)))
        *propagation-log*))

;;;; Subtree replacement ------------------------------------------------------

(defun kill-subtree (node)
  "Detach NODE's descendants: they are rebuilt when NODE's thunk re-runs."
  (dolist (child (rnode-children node))
    (kill-node child))
  (setf (rnode-children node) '()))

(defun kill-node (node)
  (setf (rnode-dead-p node) t
        (rnode-dirty-p node) nil)
  (dolist (m (rnode-mods-read node))
    (setf (modref-readers m) (delete node (modref-readers m))))
  (dolist (m (rnode-writes node))
    (when (eq (modref-writer m) node)
      (setf (modref-writer m) nil)))
  (kill-subtree node))

;;;; Writes and dirty marking -------------------------------------------------

(defun write! (target value)
  "Write VALUE into TARGET (mod or write-cap). Equality cutoff via the mod's :test.
Inside an R-node this is an internal write (blame flows from the node); outside it is
an external update blamed on *CURRENT-PRINCIPAL*. Returns T if the value changed."
  (let ((mod (resolve-writable target))
        (node *current-rnode*))
    (when (and *enforce-labels* node
               (not (zerop (logandc2 (rnode-label node) (modref-label mod)))))
      (error 'label-flow-error :node-label (rnode-label node) :mod mod))
    (when node
      (pushnew mod (rnode-writes node))
      (setf (modref-writer mod) node))
    (with-graph-lock
      (let ((old (modref-value mod)))
        (cond ((funcall (modref-test mod) old value)
               nil)
              (t
               (setf (modref-value mod) value
                     (modref-blame mod) (if node
                                            (logior (rnode-blame node) *propagation-blame*)
                                            (ash 1 *current-principal*)))
               (dirty-readers! mod)
               t))))))

(defun dirty-readers! (mod)
  (dolist (r (modref-readers mod))
    (unless (rnode-dead-p r)
      (setf (rnode-blame r) (logior (rnode-blame r) (modref-blame mod)))
      (unless (rnode-dirty-p r)
        (setf (rnode-dirty-p r) t)
        (push r *dirty-queue*)))))
