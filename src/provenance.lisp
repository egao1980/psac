(in-package #:psac)

;;;; Provenance: the trace *is* the derivation DAG, so explanation is a read-only walk.
;;;;
;;;; Access control: EXPLAIN takes a :READABLE predicate and truncates the walk at the
;;;; first mod the caller may not read, collapsing hidden branches into a single
;;;; (:redacted t) entry -- no names, values, or branch counts leak. SUPPORT and the
;;;; portfolio's DERIVATION-SLICE walk the full graph unconditionally: they are
;;;; trusted-context APIs (billing, reports); expose them to principals only through a
;;;; policy gate such as EXPLAIN-VIEW (portfolio.lisp).

(defun node-deps (node &optional (selective t))
  "Mods NODE's result depends on: its own read set plus the read sets of all ancestors
\(control dependence — nested thunks close over ancestor bindings)."
  (let ((deps '()))
    (loop for n = node then (rnode-parent n)
          while n
          do (setf deps (append (if selective (rnode-determined n) (rnode-mods-read n)) deps)))
    (remove-duplicates deps :test #'eq)))

(defun support (mod &key (selective t))
  "Input mods (those never written by a node) that MOD's current value depends on.
With SELECTIVE, ops that declared :provenance are sliced to their determining inputs."
  (let ((visited (make-hash-table :test #'eq))
        (acc '()))
    (labels ((walk (m)
               (unless (gethash m visited)
                 (setf (gethash m visited) t)
                 (let ((w (modref-writer m)))
                   (if (null w)
                       (push m acc)
                       (mapc #'walk (node-deps w selective)))))))
      (walk mod))
    acc))

(defun explain (mod &key (depth 3) (selective t) readable)
  "Nested plist explaining MOD's value: (:mod name :value v :via node :from (...)).
With READABLE (a predicate over mods), the walk descends only while every mod on the
path is readable: an unreadable MOD answers (:redacted t) outright, and a node's
unreadable dependencies collapse into one (:redacted t) entry -- the caller sees the
derivation down to the deepest layer entirely within their rights, and nothing below."
  (labels ((collapse (kids)
             (let ((visible (remove-if (lambda (k) (getf k :redacted)) kids)))
               (if (< (length visible) (length kids))
                   (append visible (list (list :redacted t)))
                   visible)))
           (walk (m d)
             (if (and readable (not (funcall readable m)))
                 (list :redacted t)
                 (let ((w (modref-writer m)))
                   (append (list :mod (modref-name m) :value (modref-value m))
                           (cond ((null w) (list :input t))
                                 ((zerop d) (list :via (node-name w) :pruned t))
                                 (t (list :via (node-name w)
                                          :from (collapse
                                                 (mapcar (lambda (x) (walk x (1- d)))
                                                         (node-deps w selective)))))))))))
    (walk mod depth)))

(defun explain-record (r)
  (list :node (node-name (update-record-node r))
        :blame (blame-principals (update-record-blame r))
        :cost (update-record-cost r)
        :wrote (mapcar #'modref-name (update-record-writes r))))

(defun explain-update ()
  "Causal chain of the last propagation, in execution order: which nodes re-ran, on whose
blame, at what cost, writing which mods."
  (mapcar #'explain-record *last-update-log*))

(defun probe (mod value output)
  "Counterfactual: the value OUTPUT would take if MOD were VALUE.
Runs one incremental propagation forward and one back; billing and logs are untouched."
  (let ((*billing-suspended* t)
        (old (modref-value mod)))
    (unwind-protect
         (progn
           (write! mod value)
           (propagate!)
           (mod-value output))
      (write! mod old)
      (propagate!))))
