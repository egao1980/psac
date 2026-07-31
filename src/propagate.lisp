(in-package #:psac)

;;;; Change propagation: drain dirty R-nodes in (stratum, height) order.
;;;;
;;;; Stratum 0 (policy) quiesces before stratum 1 (data), so access decisions during a
;;;; propagation are consistent with the latest policy. Height order makes propagation
;;;; glitch-free for DAGs (writers always run before their readers).
;;;;
;;;; v1 limitation: heights are computed at node creation; pathological dynamic graphs
;;;; that invert writer/reader heights mid-flight are not re-leveled. RSP-tree timestamps
;;;; replace this in the parallel phase.

(defun min-dirty-key ()
  "Minimal (stratum . height) key with a non-empty bucket, discarding stale heap
entries for drained buckets. O(log #levels) amortized (DIRTY-KEY< and the heap live
in trace.lisp)."
  (loop for key = (dirty-heap-peek *dirty-heap*)
        while key
        do (if (gethash key *dirty-buckets*)
               (return key)
               (progn (dirty-heap-pop *dirty-heap*)
                      (remhash key *dirty-buckets*)))))

(defun pop-min-dirty ()
  "Remove and return a live dirty node at the minimal (stratum, height), or NIL."
  (loop for key = (min-dirty-key)
        while key
        do (loop for node = (pop (gethash key *dirty-buckets*))
                 while node
                 when (and (not (rnode-dead-p node)) (rnode-dirty-p node))
                   do (return-from pop-min-dirty node))
           (remhash key *dirty-buckets*)))

(defun propagate! ()
  "Re-run dirty computations until quiescent. Returns the bill: hash principal-id -> cost."
  (let* ((bill (make-hash-table :test #'eql))
         (*propagation-bill* (if *billing-suspended* nil bill))
         (*propagation-log* '()))
    (loop
      (let ((node (pop-min-dirty)))
        (unless node (return))
        (setf (rnode-dirty-p node) nil)
        (let* ((blame (rnode-blame node))
               (*propagation-blame* blame)
               (completed nil))
          (unwind-protect
               (progn
                 (kill-subtree node)
                 (run-rnode node)
                 (when *propagation-bill*
                   (record-execution node blame))
                 (setf (rnode-blame node) 0)
                 (setf completed t))
            ;; a signaling thunk must not leave the node silently clean: re-enqueue it
            ;; (blame intact) so the next PROPAGATE! retries instead of no-opping
            (unless completed
              (enqueue-dirty! node))))))
    (unless *billing-suspended*
      (setf *last-update-log* (nreverse *propagation-log*)
            *last-bill* bill))
    bill))
