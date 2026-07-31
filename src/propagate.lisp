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

(defun pop-min-dirty ()
  (let ((best nil))
    (dolist (n *dirty-queue*)
      (when (or (null best)
                (< (rnode-stratum n) (rnode-stratum best))
                (and (= (rnode-stratum n) (rnode-stratum best))
                     (< (rnode-height n) (rnode-height best))))
        (setf best n)))
    (when best
      (setf *dirty-queue* (delete best *dirty-queue* :count 1)))
    best))

(defun propagate! ()
  "Re-run dirty computations until quiescent. Returns the bill: hash principal-id -> cost."
  (let* ((bill (make-hash-table :test #'eql))
         (*propagation-bill* (if *billing-suspended* nil bill))
         (*propagation-log* '()))
    (loop
      (setf *dirty-queue*
            (delete-if (lambda (n) (or (rnode-dead-p n) (not (rnode-dirty-p n))))
                       *dirty-queue*))
      (let ((node (pop-min-dirty)))
        (unless node (return))
        (setf (rnode-dirty-p node) nil)
        (let* ((blame (rnode-blame node))
               (*propagation-blame* blame))
          (kill-subtree node)
          (run-rnode node)
          (when *propagation-bill*
            (record-execution node blame))
          (setf (rnode-blame node) 0))))
    (unless *billing-suspended*
      (setf *last-update-log* (nreverse *propagation-log*)
            *last-bill* bill))
    bill))
