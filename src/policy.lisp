(in-package #:psac)

;;;; Access rights expressed as SAC.
;;;;
;;;; Policy state is normalized to per-fact mods at stratum 0: member?(p,g) and
;;;; grants(g,class). Effective rights are derived mods maintained by ordinary R-nodes,
;;;; so revocation is just change propagation: flipping member?(p,g) re-runs exactly the
;;;; computations whose authority depended on it, before any data-stratum work.

(defvar *member-mods* (make-hash-table :test #'equal))
(defvar *grant-mods* (make-hash-table :test #'equal))
(defvar *allowed-mods* (make-hash-table :test #'equal))

(defun member-mod (principal group)
  "Per-fact policy mod: is PRINCIPAL a member of GROUP?"
  (let ((key (cons (intern-principal principal) group)))
    (or (gethash key *member-mods*)
        (setf (gethash key *member-mods*)
              (make-mod nil :name (format nil "member?(~a,~a)" (principal-name (car key)) group)
                            :stratum 0)))))

(defun grant-mod (group class)
  "Per-fact policy mod: does GROUP grant access to resource CLASS?"
  (let ((key (cons group class)))
    (or (gethash key *grant-mods*)
        (setf (gethash key *grant-mods*)
              (make-mod nil :name (format nil "grants(~a,~a)" group class) :stratum 0)))))

(defun admit! (principal group)
  (write! (member-mod principal group) t)
  (propagate!))

(defun revoke! (principal group)
  (write! (member-mod principal group) nil)
  (propagate!))

(defun grant-class! (group class &optional (granted t))
  (write! (grant-mod group class) granted)
  (propagate!))

(defun allowed-mod (principal class &key groups)
  "Derived stratum-0 mod: PRINCIPAL may access CLASS iff some g in GROUPS has
member?(p,g) and grants(g,class). Built once per (principal, class, group-set) --
the group set is part of the cache key, so different group sets never share a
cached decision."
  (let* ((id (intern-principal principal))
         (key (list id class (sort (copy-list groups) #'string< :key #'string))))
    (or (gethash key *allowed-mods*)
        (let* ((out (make-mod nil :name (format nil "allowed?(~a,~a)" (principal-name id) class)
                                  :stratum 0))
               (member-mods (mapcar (lambda (g) (member-mod principal g)) groups))
               (grant-mods (mapcar (lambda (g) (grant-mod g class)) groups))
               (n (length groups)))
          (register-read (append member-mods grant-mods)
                         (lambda (&rest vals)
                           (let ((members (subseq vals 0 n))
                                 (grants (subseq vals n)))
                             ;; multi-sequence SOME is an SBCL extension; LOOP is ANSI CL
                             (write! out (and (loop for m in members
                                                    for g in grants
                                                    thereis (and m g))
                                              t))))
                         :name (format nil "allowed-node(~a,~a)" (principal-name id) class))
          (setf (gethash key *allowed-mods*) out)))))

(defmacro guarded-read ((var data-mod allowed-mod) &body body)
  "Run BODY with VAR bound to DATA-MOD's value while ALLOWED-MOD is true, else :DENIED.
Revocation re-runs BODY through ordinary change propagation."
  `(register-read (list ,allowed-mod ,data-mod)
                  (lambda (ok val)
                    (let ((,var (if ok val :denied)))
                      ,@body))
                  :name "guarded-read"))

(defun release-gated (source out &key (min-distinct-owners 2))
  "Differencing-resistant release gate: copy SOURCE to OUT only once writes from at least
MIN-DISTINCT-OWNERS distinct principals have accumulated since the last release. A single
principal's update can never be recovered by differencing consecutive releases.
Caveat: the accumulated-owner state lives in this closure, so if the gate node is nested
under another R-node and gets killed/rebuilt by a parent re-run, the pending mask resets
\(and the rebuild releases the current value). Register gates at top level."
  (let ((pending 0)
        (first-run t))
    (register-read (list source)
                   (lambda (v)
                     (cond (first-run
                            (setf first-run nil)
                            (write! out v))
                           (t
                            (setf pending (logior pending (rnode-blame *current-rnode*)))
                            (when (>= (logcount pending) min-distinct-owners)
                              (setf pending 0)
                              (write! out v)))))
                   :name "release-gate"))
  out)

(defun reset-policy! ()
  "Forget all policy mods (used by tests)."
  (clrhash *member-mods*)
  (clrhash *grant-mods*)
  (clrhash *allowed-mods*)
  (values))

(defun reset-all! ()
  "Full reset for tests and demos: graph, policy, scenarios, principals, counters.
Makes principal ids (and therefore blame-split remainders) deterministic per session.
For isolation without touching global state, see WITH-FRESH-STATE."
  (reset-graph!)
  (reset-policy!)
  (clrhash *scenarios*)
  (clrhash *principal-ids*)
  (clrhash *principal-names*)
  (setf *principal-counter* (list -1)
        *current-principal* (intern-principal "system")
        *mod-counter* (list 0)
        *rnode-counter* (list 0))
  (values))

(defmacro with-fresh-state (&body body)
  "Run BODY with every piece of mutable psac state rebound to fresh objects: graph queue,
bills, logs, scenarios, policy and principal tables, counters. The dynamic-extent
counterpart of RESET-ALL!: globals are untouched, bindings nest, and each thread that
wraps its work in WITH-FRESH-STATE gets a fully isolated world -- independent universes
may then compute concurrently. Parallel waves and PAR convey the coordinator's bindings
to lparallel workers via *CONVEYED-STATE*; other threads spawned inside BODY do not
inherit them. Any new stateful defvar readable from worker code must be added here,
to RESET-ALL!, and to *CONVEYED-STATE*."
  `(let* ((*dirty-buckets* (make-hash-table :test #'equal))
          (*current-rnode* nil)
          (*last-bill* nil)
          (*last-update-log* '())
          (*current-scenario* nil)
          (*scenarios* (make-hash-table :test #'equal))
          (*member-mods* (make-hash-table :test #'equal))
          (*grant-mods* (make-hash-table :test #'equal))
          (*allowed-mods* (make-hash-table :test #'equal))
          (*principal-ids* (make-hash-table :test #'equal))
          (*principal-names* (make-hash-table :test #'eql))
          (*principal-counter* (list -1))
          (*mod-counter* (list 0))
          (*rnode-counter* (list 0))
          ;; last: interned into the fresh tables bound above
          (*current-principal* (intern-principal "system")))
     ,@body))
