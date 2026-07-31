(defpackage #:psac/tests
  (:use #:cl #:rove #:psac))
(in-package #:psac/tests)

(deftest core-propagation
  (testing "chain propagation and cutoff"
    (reset-graph!)
    (let ((x (make-mod 1 :name "x"))
          (y (make-mod nil :name "y"))
          (z (make-mod nil :name "z")))
      (adaptive-read ((v x)) (write! y (* v 10)))
      (adaptive-read ((v y)) (write! z (1+ v)))
      (ok (= (mod-value z) 11))
      (write! x 2)
      (propagate!)
      (ok (= (mod-value z) 21))
      ;; equality cutoff: rewriting the same value re-runs nothing
      (write! x 2)
      (propagate!)
      (ok (null (last-update-log))))))

(deftest reduce-tree
  (testing "balanced reduction updates in O(log n)"
    (reset-graph!)
    (let* ((inputs (loop for i below 8 collect (make-mod (1+ i) :name (format nil "x~a" i))))
           (total (adaptive-reduce #'+ inputs)))
      (ok (= (mod-value total) 36))
      (with-principal ("alice")
        (write! (first inputs) 100))
      (propagate!)
      (ok (= (mod-value total) 135))
      ;; only the leaf-to-root path re-ran: log2(8) = 3 nodes
      (ok (= (length (last-update-log)) 3))
      (ok (= (mod-value total) (reduce #'+ (mapcar #'mod-value inputs)))))))

(deftest randomized-consistency
  (testing "incremental result equals from-scratch after random updates"
    (reset-graph!)
    (let* ((n 16)
           (inputs (loop for i below n collect (make-mod i)))
           (total (adaptive-reduce #'+ inputs))
           (mx (adaptive-max inputs))
           (evens (adaptive-filter #'evenp inputs)))
      (dotimes (round 25)
        (write! (nth (random n) inputs) (- (random 200) 100))
        (propagate!)
        (let ((vals (mapcar #'mod-value inputs)))
          (ok (= (mod-value total) (reduce #'+ vals)))
          (ok (= (mod-value mx) (reduce #'max vals)))
          (ok (equal (mod-value evens) (remove-if-not #'evenp vals))))))))

(deftest cost-attribution
  (testing "bills are conserved and split deterministically"
    (reset-graph!)
    (let* ((inputs (loop for i below 4 collect (make-mod (1+ i))))
           (total (adaptive-reduce #'+ inputs))
           (alice (intern-principal "alice"))
           (bob (intern-principal "bob")))
      (declare (ignore total))
      ;; single principal: whole path billed to alice
      (with-principal ("alice")
        (write! (first inputs) 10))
      (let ((bill (propagate!)))
        (ok (= (bill-total bill) 2))
        (ok (= (gethash alice bill 0) 2)))
      ;; batched two-principal update: shared root cost 1 split 0/0 + remainder to lower id
      (with-principal ("alice")
        (write! (first inputs) 20))
      (with-principal ("bob")
        (write! (third inputs) 30))
      (let ((bill (propagate!)))
        (ok (= (bill-total bill) (length (last-update-log))))
        (ok (= (bill-total bill) 3))
        (ok (= (gethash alice bill 0) 2))
        (ok (= (gethash bob bill 0) 1))))))

(deftest provenance
  (testing "support, selective provenance, counterfactual probes"
    (reset-graph!)
    (let* ((inputs (loop for i below 4 collect (make-mod (* 10 (1+ i)) :name (format nil "p~a" i))))
           (total (adaptive-reduce #'+ inputs))
           (mx (adaptive-max inputs)))
      (ok (= (length (support total)) 4))
      ;; max is determined by its argmax alone
      (ok (equal (support mx) (list (fourth inputs))))
      (write! (first inputs) 11)
      (propagate!)
      (ok (consp (explain-update)))
      (let ((bill-before (bill-total)))
        (ok (= (probe (first inputs) 1000 total) (+ 1000 20 30 40)))
        ;; probe restored the world: value, bill
        (ok (= (mod-value total) (+ 11 20 30 40)))
        (ok (= (bill-total) bill-before))))))

(deftest policy-revocation
  (testing "revocation and re-admission are change propagation"
    (reset-graph!)
    (reset-policy!)
    (let ((salary (make-mod 50000 :name "salary"))
          (out (make-mod nil :name "alice-view")))
      (admit! "alice" :eng)
      (grant-class! :eng :salaries)
      (let ((allowed (allowed-mod "alice" :salaries :groups '(:eng))))
        (guarded-read (v salary allowed)
          (write! out v))
        (ok (= (mod-value out) 50000))
        (revoke! "alice" :eng)
        (ok (eq (mod-value out) :denied))
        (admit! "alice" :eng)
        (ok (= (mod-value out) 50000))
        (write! salary 60000)
        (propagate!)
        (ok (= (mod-value out) 60000))))))

(deftest label-enforcement
  (testing "pc-label must flow to the written mod"
    (reset-graph!)
    (let ((*enforce-labels* t))
      (let ((secret (make-mod 42 :label 1))
            (public (make-mod nil :label 0))
            (sink (make-mod nil :label 1)))
        (ok (signals (adaptive-read ((v secret)) (write! public v)) 'label-flow-error))
        (adaptive-read ((v secret)) (write! sink v))
        (ok (= (mod-value sink) 42))))))

(deftest release-gate-differencing
  (testing "aggregate release gate blocks single-owner differencing"
    (reset-graph!)
    (let* ((salaries (loop for name in '("s-alice" "s-bob" "s-carol" "s-dave")
                           for v in '(40 60 80 100)
                           collect (make-mod v :name name)))
           (avg (adaptive-avg salaries))
           (released (make-mod nil :name "released")))
      (release-gated avg released :min-distinct-owners 2)
      (ok (= (mod-value released) 70))
      ;; one owner's update moves the raw aggregate but not the released view
      (with-principal ("alice")
        (write! (first salaries) 44))
      (propagate!)
      (ok (= (mod-value avg) 71))
      (ok (= (mod-value released) 70))
      ;; a second distinct owner opens the gate
      (with-principal ("bob")
        (write! (second salaries) 64))
      (propagate!)
      (ok (= (mod-value released) 72)))))

(deftest parallel-propagation
  (testing "parallel waves match from-scratch; bills conserved"
    (reset-graph!)
    (let* ((n 64)
           (inputs (loop for i below n collect (make-mod i)))
           (squares (adaptive-map (lambda (v) (* v v)) inputs :name "sq"))
           (total (adaptive-reduce #'+ squares))
           (mx (adaptive-max squares)))
      (dotimes (round 10)
        (with-principal ("alice")
          (dotimes (k 8) (write! (nth (random n) inputs) (- (random 100) 50))))
        (with-principal ("bob")
          (dotimes (k 8) (write! (nth (random n) inputs) (- (random 100) 50))))
        (let ((bill (propagate-parallel!)))
          (ok (= (bill-total bill) (length (last-update-log)))))
        (let ((sq (mapcar (lambda (m) (* (mod-value m) (mod-value m))) inputs)))
          (ok (= (mod-value total) (reduce #'+ sq)))
          (ok (= (mod-value mx) (reduce #'max sq))))))))

(deftest parallel-nested
  (testing "nested reads rebuild correctly under parallel propagation"
    (reset-graph!)
    (let ((x (make-mod 2))
          (y (make-mod 3))
          (out (make-mod nil)))
      (adaptive-read ((v x))
        (adaptive-read ((w y))
          (write! out (* v w))))
      (ok (= (mod-value out) 6))
      (write! x 5)
      (propagate-parallel!)
      (ok (= (mod-value out) 15))
      (write! y 10)
      (propagate-parallel!)
      (ok (= (mod-value out) 50)))))

(deftest parallel-stratified
  (testing "policy stratum quiesces before data even in parallel waves"
    (reset-graph!)
    (reset-policy!)
    (let ((salary (make-mod 100 :name "salary2"))
          (out (make-mod nil)))
      (admit! "carol" :hr)
      (grant-class! :hr :payroll)
      (let ((allowed (allowed-mod "carol" :payroll :groups '(:hr))))
        (guarded-read (v salary allowed)
          (write! out v))
        (ok (= (mod-value out) 100))
        (write! (member-mod "carol" :hr) nil)
        (propagate-parallel!)
        (ok (eq (mod-value out) :denied))))))

(deftest harness-scenario
  (testing "JSON scenario runs and snapshots match hand computation"
    (let ((json (run-scenario (asdf:system-relative-pathname :psac "scenarios/basic.json"))))
      (ok (search "\"s1\":7" json))    ; initial: 3+4
      (ok (search "\"s3\":25" json))   ; after x1<-10: (10+4)+(5+6)
      (ok (search "\"s3\":20" json))   ; after x2<--3, x3<-7: (10-3)+(7+6)
      (ok (search "\"m1\":13" json)))))
