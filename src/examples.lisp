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
  "Maximum over MODS, with selective provenance: only the argmax determines the result."
  (let ((out (make-mod nil :name (format nil "~a-out" name))))
    (register-read mods
                   (lambda (&rest vals)
                     (let ((m (reduce #'max vals)))
                       (write! out m)
                       m))
                   :name "max-node"
                   :provenance (lambda (result vals mods-read)
                                 (list (nth (position result vals) mods-read))))
    out))

(defun adaptive-avg (mods &key (name "avg"))
  "Exact (rational) average over MODS."
  (let ((out (make-mod nil :name (format nil "~a-out" name))))
    (register-read mods
                   (lambda (&rest vals)
                     (write! out (/ (reduce #'+ vals) (length vals))))
                   :name "avg-node")
    out))
