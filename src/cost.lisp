(in-package #:psac)

;;;; Cost attribution.
;;;; Costs are split among the principals in the blame bitmask by integer division,
;;;; remainder charged to the lowest principal id. Deterministic and exactly conserved
;;;; (mirrored by charge_conserves in model/PsacModel/Cost.lean).

(defvar *last-bill* nil)

(defun charge! (bill blame cost)
  (if (zerop blame)
      (incf (gethash :system bill 0) cost)
      (multiple-value-bind (share rem) (floor cost (logcount blame))
        (let ((first-charged nil))
          (dotimes (i (integer-length blame))
            (when (logbitp i blame)
              (incf (gethash i bill 0) (if first-charged share (+ share rem)))
              (setf first-charged t)))))))

(defun bill-total (&optional (bill *last-bill*))
  (let ((total 0))
    (when bill
      (maphash (lambda (k v) (declare (ignore k)) (incf total v)) bill))
    total))

(defun principal< (a b)
  (cond ((eq a :system) nil)
        ((eq b :system) t)
        (t (< a b))))

(defun bill-alist (&optional (bill *last-bill*))
  "((principal-id . cost) ...) sorted by principal id, :system last."
  (let ((entries '()))
    (when bill
      (maphash (lambda (k v) (push (cons k v) entries)) bill))
    (sort entries #'principal< :key #'car)))

(defun last-bill ()
  *last-bill*)

(defun blame-principals (blame)
  "List of principal names present in the BLAME bitmask."
  (loop for i below (integer-length blame)
        when (logbitp i blame)
          collect (principal-name i)))
