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
  (setf *dirty-queue*
        (delete-if (lambda (n) (or (rnode-dead-p n) (not (rnode-dirty-p n)))) *dirty-queue*))
  (when *dirty-queue*
    (let* ((stratum (reduce #'min *dirty-queue* :key #'rnode-stratum))
           (in-stratum (remove-if-not (lambda (n) (= (rnode-stratum n) stratum)) *dirty-queue*))
           (height (reduce #'min in-stratum :key #'rnode-height))
           (level (remove-if-not (lambda (n) (= (rnode-height n) height)) in-stratum)))
      (setf *dirty-queue* (set-difference *dirty-queue* level :test #'eq))
      level)))

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
          (let* ((effective-bill (if *billing-suspended* nil bill))
                 (task (lambda (pair) (run-level-task (car pair) (cdr pair) effective-bill)))
                 (logs (if (null (cdr prepared))
                           (list (funcall task (first prepared)))
                           (lparallel:pmap 'list task prepared))))
            (dolist (l logs)
              (setf log (append l log)))))))
    (unless *billing-suspended*
      (setf *last-update-log* (nreverse log)
            *last-bill* bill))
    bill))
