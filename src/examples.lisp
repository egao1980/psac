(in-package #:psac)

;;;; Example adaptive combinators over lists of mods.

(defun adaptive-map (fn input-mods &key (name "map"))
  "One output mod per input; each updates independently in O(1)."
  (loop for m in input-mods
        for i from 0
        collect (let ((out (make-mod nil :name (format nil "~a[~a]" name i)))
                      (m m))
                  (register-read (list m)
                                 (lambda (v) (write! out (funcall fn v)))
                                 :name (format nil "~a-node[~a]" name i))
                  out)))

(defun adaptive-reduce (fn mods &key (name "reduce"))
  "Balanced binary reduction tree: a single input update re-runs O(log n) nodes."
  (cond ((null mods) (error "adaptive-reduce: empty input"))
        ((null (cdr mods)) (first mods))
        (t
         (let* ((mid (floor (length mods) 2))
                (left (adaptive-reduce fn (subseq mods 0 mid) :name name))
                (right (adaptive-reduce fn (subseq mods mid) :name name))
                (out (make-mod nil :name (format nil "~a-out~a" name (incf *mod-counter*)))))
           (register-read (list left right)
                          (lambda (a b) (write! out (funcall fn a b)))
                          :name name)
           out))))

(defun adaptive-filter (pred mods &key (name "filter"))
  "Output mod holding the list of current values satisfying PRED."
  (let ((wrapped (adaptive-map (lambda (v) (if (funcall pred v) (list v) '())) mods
                               :name (format nil "~a-wrap" name))))
    (adaptive-reduce #'append wrapped :name name)))

(defun adaptive-max (mods &key (name "max"))
  "Maximum over MODS, with selective provenance: the argmax positions (all of them, under
ties) explain the result. Selective slices explain the current value; only the full
\(non-selective) support bounds influence."
  (let ((out (make-mod nil :name (format nil "~a-out" name))))
    (register-read mods
                   (lambda (&rest vals)
                     (let ((m (reduce #'max vals)))
                       (write! out m)
                       m))
                   :name "max-node"
                   :provenance (lambda (result vals mods-read)
                                 (loop for v in vals
                                       for m in mods-read
                                       when (= v result) collect m)))
    out))

(defun adaptive-avg (mods &key (name "avg"))
  "Exact (rational) average over MODS."
  (let ((out (make-mod nil :name (format nil "~a-out" name))))
    (register-read mods
                   (lambda (&rest vals)
                     (write! out (/ (reduce #'+ vals) (length vals))))
                   :name "avg-node")
    out))

;;;; Parallel benchmark -------------------------------------------------------

(defun heavy-work (v)
  "Deliberately expensive pure function (multiplicative LCG churn) for benchmarks."
  (let ((acc (abs v)))
    (dotimes (i 300000 acc)
      (setf acc (ldb (byte 61 0) (+ (* acc 6364136223846793005) 1442695040888963407 i))))))

(defun bench-parallel (&key (n 32) (rounds 3) workers)
  "Compare sequential vs parallel propagation over N heavy map nodes feeding a reduce
tree. Prints and returns (values seq-ms par-ms speedup)."
  (flet ((build ()
           (reset-graph!)
           (loop for i below n collect (make-mod i)))
         (elapsed-ms (start) (/ (- (get-internal-real-time) start)
                                (/ internal-time-units-per-second 1000))))
    (let (seq-ms par-ms)
      (let ((inputs (build)))
        (adaptive-reduce #'logxor (adaptive-map #'heavy-work inputs :name "heavy") :name "xor")
        (let ((start (get-internal-real-time)))
          (dotimes (r rounds)
            (dolist (m inputs) (write! m (+ (mod-value m) r 1)))
            (propagate!))
          (setf seq-ms (elapsed-ms start))))
      (let ((inputs (build)))
        (adaptive-reduce #'logxor (adaptive-map #'heavy-work inputs :name "heavy") :name "xor")
        (ensure-kernel workers)
        (let ((start (get-internal-real-time)))
          (dotimes (r rounds)
            (dolist (m inputs) (write! m (+ (mod-value m) r 1)))
            (propagate-parallel!))
          (setf par-ms (elapsed-ms start))))
      (let ((speedup (if (zerop par-ms) 0.0 (float (/ seq-ms par-ms)))))
        (format t "~&bench-parallel: n=~a rounds=~a  sequential=~,1fms  parallel=~,1fms  speedup=~,2fx~%"
                n rounds (float seq-ms) (float par-ms) speedup)
        (values seq-ms par-ms speedup)))))

(defun bench-par-within (&key (n 64) (rounds 3) workers)
  "Fork-join speedup *inside one node*: a single R-node whose thunk PAR-MAPs heavy work
over N items. Level parallelism can't help here (one dirty node per wave); only PAR can.
Prints and returns (values seq-ms par-ms speedup)."
  (ensure-kernel workers)
  (reset-graph!)
  (let ((in (make-mod 0 :name "in"))
        (out (make-mod nil :name "out")))
    (register-read (list in)
                   (lambda (v)
                     (write! out (reduce #'logxor
                                         (par-map (lambda (i) (heavy-work (+ v i)))
                                                  (alexandria:iota n)))))
                   :name "par-within")
    (flet ((run-rounds (start-at)
             (let ((start (get-internal-real-time)))
               (dotimes (r rounds)
                 (write! in (+ start-at r 1))
                 (propagate!))
               (/ (- (get-internal-real-time) start)
                  (/ internal-time-units-per-second 1000)))))
      (let* ((seq-ms (let ((*par-max-depth* 0)) (run-rounds 0)))
             (par-ms (run-rounds 1000))
             (speedup (if (zerop par-ms) 0.0 (float (/ seq-ms par-ms)))))
        (format t "~&bench-par-within: n=~a rounds=~a  sequential=~,1fms  par=~,1fms  speedup=~,2fx~%"
                n rounds (float seq-ms) (float par-ms) speedup)
        (values seq-ms par-ms speedup)))))
