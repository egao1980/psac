(in-package #:psac)

;;;; Differential-test harness: build a graph from a JSON scenario, apply update batches
;;;; incrementally, and emit canonical JSON snapshots. The Lean oracle (model/Main.lean)
;;;; evaluates the same scenario from scratch; outputs must match byte-for-byte.

(defparameter *harness-ops*
  (list (cons "add" #'+)
        (cons "sub" #'-)
        (cons "mul" #'*)
        (cons "max" #'max)
        (cons "min" #'min)))

(defun harness-op (name)
  (or (cdr (assoc name *harness-ops* :test #'string=))
      (error "unknown op: ~a" name)))

(defun snapshot (mods names)
  (loop for name in names
        collect (cons name (mod-value (gethash name mods)))))

(defun render-steps (steps)
  (with-output-to-string (s)
    (write-string "{\"steps\":[" s)
    (loop for step in steps
          for first-step = t then nil
          do (unless first-step (write-string "," s))
             (write-string "{\"values\":{" s)
             (loop for (name . value) in step
                   for first-val = t then nil
                   do (unless first-val (write-string "," s))
                      (format s "\"~a\":~a" name value))
             (write-string "}}" s))
    (write-string "]}" s)))

(defun run-scenario (path &key output-path)
  "Run scenario at PATH; return canonical result JSON (also written to OUTPUT-PATH if given)."
  (reset-graph!)
  (let ((doc (jzon:parse (uiop:read-file-string path)))
        (mods (make-hash-table :test #'equal))
        (names '()))
    (loop for m across (gethash "mods" doc)
          for name = (gethash "name" m)
          do (setf (gethash name mods) (make-mod (gethash "value" m) :name name))
             (push name names))
    (loop for n across (gethash "nodes" doc)
          for op = (harness-op (gethash "op" n))
          for out-name = (gethash "out" n)
          for out = (make-mod nil :name out-name)
          for inputs = (map 'list (lambda (i) (gethash i mods)) (gethash "inputs" n))
          do (setf (gethash out-name mods) out)
             (push out-name names)
             (let ((out out) (op op))
               (register-read inputs
                              (lambda (&rest vals) (write! out (apply op vals)))
                              :name (format nil "~a->~a" (gethash "op" n) out-name))))
    (setf names (sort names #'string<))
    (let ((steps (list (snapshot mods names))))
      (loop for batch across (gethash "updates" doc)
            do (loop for u across batch
                     do (with-principal ((gethash "principal" u "system"))
                          (write! (gethash (gethash "mod" u) mods) (gethash "value" u))))
               (propagate!)
               (push (snapshot mods names) steps))
      (let ((json (format nil "~a~%" (render-steps (nreverse steps)))))
        (when output-path
          (with-open-file (f output-path :direction :output :if-exists :supersede
                                         :external-format :utf-8)
            (write-string json f)))
        json))))
