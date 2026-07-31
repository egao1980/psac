(in-package #:psac)

;;;; Level-synchronous parallel change propagation (phase 7).
;;;;
;;;; By the height invariant, a node's height is strictly greater than the heights of the
;;;; writers of everything it reads, so all dirty nodes at the same (stratum, height) are
;;;; mutually independent: they never read each other's outputs. Propagation therefore
;;;; runs level by level; each level's nodes execute as one parallel wave (lparallel),
;;;; with a barrier before the next level is computed.
;;;;
;;;; Graph bookkeeping (reader registration, dirty marking, billing) is guarded by
;;;; *GRAPH-LOCK*, taken only while *PARALLEL-PROPAGATION* is true. User thunks run
;;;; unlocked. Children spawned mid-wave land at higher levels; if a wave peer writes a
;;;; mod such a child already read, the child is simply dirtied and re-runs next level,
;;;; so the wave stays convergent.
;;;;
;;;; Assumed (as everywhere in psac): single-writer discipline per mod.

(defvar *default-workers* 4)

(defun ensure-kernel (&optional workers)
  "Create the lparallel kernel on first use. Worker count: WORKERS, else $PSAC_WORKERS, else 4."
  (unless lparallel:*kernel*
    (setf lparallel:*kernel*
          (lparallel:make-kernel
           (or workers
               (let ((env (uiop:getenv "PSAC_WORKERS")))
                 (and env (parse-integer env :junk-allowed t)))
               *default-workers*)
           :name "psac")))
  lparallel:*kernel*)

(defun next-dirty-level ()
  "Remove and return all dirty live nodes at the minimal (stratum, height)."
  (loop for key = (min-dirty-key)
        while key
        do (let ((level (remove-if (lambda (n) (or (rnode-dead-p n) (not (rnode-dirty-p n))))
                                   (gethash key *dirty-buckets*))))
             (remhash key *dirty-buckets*)
             (when level (return level)))))

(defun run-level-task (node blame bill)
  "Executed on a worker: re-run NODE, return the execution log of this task."
  (let ((*propagation-bill* bill)
        (*propagation-blame* blame)
        (*propagation-log* '())
        (*parallel-propagation* t))
    (run-rnode node)
    (record-execution node blame)
    (setf (rnode-blame node) 0)
    *propagation-log*))

(defun propagate-parallel! (&key workers)
  "Parallel PROPAGATE!: drain dirty nodes in (stratum, height) waves, each wave in
parallel on the lparallel kernel. Returns the bill. Within a wave, execution (and
therefore log) order is arbitrary; bills are deterministic regardless."
  (ensure-kernel workers)
  (let ((bill (make-hash-table :test #'eql))
        (log '()))
    (loop
      (let ((level (next-dirty-level)))
        (unless level (return))
        ;; Sequential pre-pass: capture blame, mark clean, detach stale subtrees.
        (let ((prepared (loop for node in level
                              collect (cons node (rnode-blame node))
                              do (setf (rnode-dirty-p node) nil)
                                 (kill-subtree node))))
          ;; convey the coordinator's dynamic state to workers: lparallel futures/tasks
          ;; see global bindings otherwise, which would break WITH-FRESH-STATE
          (let* ((effective-bill (if *billing-suspended* nil bill))
                 (buckets *dirty-buckets*)
                 (enforce *enforce-labels*)
                 (task (lambda (pair)
                         (let ((*dirty-buckets* buckets)
                               (*enforce-labels* enforce))
                           (run-level-task (car pair) (cdr pair) effective-bill))))
                 (logs (if (null (cdr prepared))
                           (list (funcall task (first prepared)))
                           (lparallel:pmap 'list task prepared))))
            (dolist (l logs)
              (setf log (append l log)))))))
    (unless *billing-suspended*
      (setf *last-update-log* (nreverse log)
            *last-bill* bill))
    bill))

;;;; Fork-join inside computations (phase 7b, RSP-lite) -------------------------
;;;;
;;;; PAR evaluates two branches of a thunk, possibly in parallel via lparallel futures
;;;; (lparallel's kernel does work stealing internally), joining before the thunk
;;;; continues. So a single R-node's (re-)execution can be internally parallel, and
;;;; ADAPTIVE-READs created in the branches are recorded with :par context -- the trace
;;;; carries S/P structure (RSP-lite; full timestamped RSP trees remain future work).
;;;;
;;;; Dynamic state (bill, blame, labels, scenario, dirty buckets, lock flag) is conveyed to workers explicitly:
;;;; lparallel futures do not transfer special bindings. Granularity control is
;;;; defpun-style: beyond ceil(log2 workers)+2 nested PARs the branches just run
;;;; sequentially in the caller (override the cutoff with *PAR-MAX-DEPTH*).

(defvar *par-depth* 0)
(defvar *par-max-depth* nil
  "Deepest PAR nesting that still spawns a future; NIL = ceil(log2 workers)+2, 0 = never spawn.")

(defun par-max-depth ()
  (or *par-max-depth*
      (+ 2 (integer-length (1- (lparallel:kernel-worker-count))))))

(defun call-par (left right)
  "Run thunks LEFT and RIGHT (RIGHT possibly on a worker), return both values."
  (if (or (null lparallel:*kernel*)
          (>= *par-depth* (par-max-depth)))
      (values (funcall left) (funcall right))
      (let ((rnode *current-rnode*)
            (bill *propagation-bill*)
            (blame *propagation-blame*)
            (suspended *billing-suspended*)
            (enforce *enforce-labels*)
            (principal *current-principal*)
            (scenario *current-scenario*)
            (buckets *dirty-buckets*)
            (depth (1+ *par-depth*)))
        (let ((fut (lparallel:future
                     (let ((*current-rnode* rnode)
                           (*propagation-bill* bill)
                           (*propagation-blame* blame)
                           (*billing-suspended* suspended)
                           (*enforce-labels* enforce)
                           (*current-principal* principal)
                           (*current-scenario* scenario)
                           (*dirty-buckets* buckets)
                           (*propagation-log* '())
                           (*parallel-propagation* t)
                           (*par-context* t)
                           (*par-depth* depth))
                       (cons (funcall right) *propagation-log*))))
              (left-value (let ((*parallel-propagation* t)
                                (*par-context* t)
                                (*par-depth* depth))
                            (funcall left))))
          (destructuring-bind (right-value . right-log) (lparallel:force fut)
            ;; fold the worker's task-local execution log into ours
            (setf *propagation-log* (append right-log *propagation-log*))
            (values left-value right-value))))))

(defmacro par (form-a form-b)
  "Fork-join: evaluate FORM-A and FORM-B, possibly in parallel; return both values.
Safe inside ADAPTIVE-READ thunks: nested reads, writes, and billing in either branch
are lock-protected and joined before PAR returns."
  `(call-par (lambda () ,form-a) (lambda () ,form-b)))

(defun par-map (fn list)
  "Map FN over LIST by fork-join divide and conquer (spawning bounded by PAR's depth cutoff)."
  (labels ((rec (l len)
             (if (<= len 1)
                 (mapcar fn l)
                 (let ((half (floor len 2)))
                   (multiple-value-bind (a b)
                       (call-par (lambda () (rec (subseq l 0 half) half))
                                 (lambda () (rec (subseq l half) (- len half))))
                     (append a b))))))
    (rec list (length list))))
