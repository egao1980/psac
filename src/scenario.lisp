(in-package #:psac)

;;;; Tagged ephemeral (as-if) updates: private scenario universes.
;;;;
;;;; A scenario is a named batch of hypothetical writes applied to the live graph,
;;;; propagated, observed, and rolled back on exit (normal or non-local). It is
;;;;   * tagged  -- registered under its tag in *SCENARIOS* with its writes, bill and log;
;;;;   * private -- the base universe, *LAST-BILL* and *LAST-UPDATE-LOG* are untouched,
;;;;     and hypothetical recompute cost is captured on the scenario's own bill, blamed
;;;;     on the scenario owner (rollback propagation is unbilled);
;;;;   * as-if  -- inside the body, MOD-VALUE reads the hypothetical world incrementally.
;;;;
;;;; Scenarios nest LIFO. PROBE remains the single-write anonymous special case.
;;;; Lean counterparts: scenario_observe / scenario_roundtrip / scenario_private
;;;; in model/PsacModel/Scenario.lean.

;; *CURRENT-SCENARIO* is defined in trace.lisp so PAR can convey it to workers.
(defvar *scenarios* (make-hash-table :test #'equal)
  "Completed scenarios by tag; a reused tag keeps the most recent run.")

(defstruct (scenario (:print-object print-scenario))
  tag
  (owner 0 :type fixnum)
  ;; (mod . value-before-scenario-write) undo stack, newest first
  (undo '() :type list)
  bill
  (log '() :type list)
  (live-p t))

(defun print-scenario (sc stream)
  (print-unreadable-object (sc stream :type t)
    (format stream "~s~:[~; live~] owner ~a, ~a writes, cost ~a"
            (scenario-tag sc) (scenario-live-p sc)
            (principal-name (scenario-owner sc))
            (length (scenario-undo sc))
            (bill-total (scenario-bill sc)))))

(defun find-scenario (tag)
  (gethash tag *scenarios*))

(defun resolve-scenario (scenario-or-tag)
  (etypecase scenario-or-tag
    (scenario scenario-or-tag)
    (t (or (find-scenario scenario-or-tag)
           (error "no scenario tagged ~s" scenario-or-tag)))))

(defun call-with-scenario (tag owner thunk)
  (let ((sc (make-scenario :tag tag :owner (intern-principal owner)
                           :bill (make-hash-table :test #'eql))))
    (unwind-protect
         (let ((*current-scenario* sc))
           (funcall thunk))
      ;; roll back newest-first, unbilled; base bill/log stay untouched
      (let ((*billing-suspended* t))
        (loop for (mod . old) in (scenario-undo sc)
              do (write! mod old))
        (propagate!))
      (setf (scenario-live-p sc) nil
            (gethash tag *scenarios*) sc))
    sc))

(defmacro with-scenario ((tag &key (owner '*current-principal*)) &body body)
  "Run BODY in an ephemeral universe named TAG, owned by OWNER. Inside, SCENARIO-WRITE!
applies as-if updates and SCENARIO-PROPAGATE! recomputes; MOD-VALUE then reads the
hypothetical world. On exit -- normal or non-local -- every write is rolled back and the
base universe, its *LAST-BILL* and *LAST-UPDATE-LOG* are exactly as before; the scenario
keeps its own bill (blamed on OWNER) and causal log, registered under TAG. Returns the
scenario object."
  `(call-with-scenario ,tag ,owner (lambda () ,@body)))

(defun scenario-write! (target value)
  "Ephemeral write inside WITH-SCENARIO, undone at scenario exit. Blame (and therefore
the scenario bill) goes to the scenario owner."
  (let ((sc (or *current-scenario*
                (error "SCENARIO-WRITE! outside WITH-SCENARIO")))
        (mod (resolve-writable target)))
    (push (cons mod (modref-value mod)) (scenario-undo sc))
    (let ((*current-principal* (scenario-owner sc)))
      (write! mod value))))

(defun scenario-propagate! (&optional (sc *current-scenario*))
  "Propagate inside a scenario: recompute cost accumulates on the scenario's own bill
and log, leaving the base universe's *LAST-BILL* / *LAST-UPDATE-LOG* untouched."
  (unless sc (error "SCENARIO-PROPAGATE! outside WITH-SCENARIO"))
  (let ((saved-bill *last-bill*)
        (saved-log *last-update-log*))
    (let ((bill (propagate!)))
      (maphash (lambda (k v) (incf (gethash k (scenario-bill sc) 0) v)) bill)
      (setf (scenario-log sc) (append (scenario-log sc) *last-update-log*)
            *last-bill* saved-bill
            *last-update-log* saved-log)
      bill)))

(defun scenario-explain (scenario-or-tag)
  "Causal chain of SCENARIO's propagations, in execution order (see EXPLAIN-UPDATE)."
  (mapcar #'explain-record (scenario-log (resolve-scenario scenario-or-tag))))

(defun scenario-bill-alist (scenario-or-tag)
  (bill-alist (scenario-bill (resolve-scenario scenario-or-tag))))

(defun what-if (writes outputs &key (tag "what-if") (owner *current-principal*))
  "Tagged multi-write PROBE: apply WRITES ((mod . value) ...) in an ephemeral universe
TAG owned by OWNER, propagate, and return (values output-values scenario) where
OUTPUT-VALUES are the hypothetical values of OUTPUTS. The base universe is untouched."
  (let ((vals nil))
    (let ((sc (with-scenario (tag :owner owner)
                (loop for (mod . value) in writes
                      do (scenario-write! mod value))
                (scenario-propagate!)
                (setf vals (mapcar #'mod-value outputs)))))
      (values vals sc))))
