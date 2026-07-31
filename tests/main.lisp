(defpackage #:psac/tests
  (:use #:cl #:rove #:psac))
(in-package #:psac/tests)

(defmacro deftest-fresh (name &body body)
  "ROVE:DEFTEST wrapped in WITH-FRESH-STATE: every test runs in its own isolated world
\(graph, bills, scenarios, policy, principals, counters), leaving globals untouched."
  `(deftest ,name
     (with-fresh-state
       ,@body)))

(deftest-fresh core-propagation
  (testing "chain propagation and cutoff"
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

(deftest-fresh reduce-tree
  (testing "balanced reduction updates in O(log n)"
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

(deftest-fresh randomized-consistency
  (testing "incremental result equals from-scratch after random updates"
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

(deftest-fresh cost-attribution
  (testing "bills are conserved and split deterministically"
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

(deftest-fresh provenance
  (testing "support, selective provenance, counterfactual probes"
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
        (ok (= (bill-total) bill-before)))
      ;; under ties, every argmax witness is in the selective slice
      (write! (third inputs) 40)
      (propagate!)
      (ok (equal (sort (mapcar #'modref-name (support mx)) #'string<)
                 (list "p2" "p3"))))))

(deftest-fresh policy-revocation
  (testing "revocation and re-admission are change propagation"
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

(deftest-fresh label-enforcement
  (testing "pc-label must flow to the written mod"
    (let ((*enforce-labels* t))
      (let ((secret (make-mod 42 :label 1))
            (public (make-mod nil :label 0))
            (sink (make-mod nil :label 1)))
        (ok (signals (adaptive-read ((v secret)) (write! public v)) 'label-flow-error))
        (adaptive-read ((v secret)) (write! sink v))
        (ok (= (mod-value sink) 42))))))

(deftest-fresh release-gate-differencing
  (testing "aggregate release gate blocks single-owner differencing"
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

(deftest-fresh parallel-propagation
  (testing "parallel waves match from-scratch; bills conserved"
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

(deftest-fresh parallel-nested
  (testing "nested reads rebuild correctly under parallel propagation"
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

(deftest-fresh parallel-stratified
  (testing "policy stratum quiesces before data even in parallel waves"
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

(deftest-fresh par-fork-join
  (testing "PAR branches with nested reads: incremental matches from-scratch, :par context recorded"
    (ensure-kernel)
    (let* ((trigger (make-mod 0 :name "trigger"))
           (l (make-mod 2 :name "l"))
           (r (make-mod 3 :name "r"))
           (out-l (make-mod nil :name "out-l"))
           (out-r (make-mod nil :name "out-r"))
           (out (make-mod nil :name "out"))
           (parent (register-read (list trigger)
                                  (lambda (tv)
                                    (par (adaptive-read ((a l)) (write! out-l (+ tv (* a a))))
                                         (adaptive-read ((b r)) (write! out-r (+ tv (* b b))))))
                                  :name "par-parent")))
      (adaptive-read ((a out-l) (b out-r)) (write! out (+ a b)))
      (ok (= (mod-value out) 13))
      (ok (every (lambda (c) (eq (psac::rnode-context c) :par))
                 (psac::rnode-children parent)))
      ;; a leaf update re-runs only its branch
      (write! l 4)
      (propagate!)
      (ok (= (mod-value out) 25))
      ;; parent re-run rebuilds both branches via PAR mid-propagation
      (write! trigger 10)
      (propagate!)
      (ok (= (mod-value out) (+ 10 16 10 9)))
      ;; same under parallel waves; stale dirty children are dead and skipped
      (write! trigger 1)
      (write! r 5)
      (propagate-parallel!)
      (ok (= (mod-value out) (+ 1 16 1 25))))))

(deftest-fresh par-map-consistency
  (testing "PAR-MAP inside one node matches its sequential result across updates"
    (ensure-kernel)
    (let ((in (make-mod 1 :name "pm-in"))
          (out (make-mod nil :name "pm-out"))
          (items (loop for i below 33 collect i)))
      (register-read (list in)
                     (lambda (v)
                       (write! out (reduce #'+ (par-map (lambda (i) (* (+ v i) (+ v i))) items))))
                     :name "pm-node")
      (flet ((expected (v) (loop for i below 33 sum (* (+ v i) (+ v i)))))
        (ok (= (mod-value out) (expected 1)))
        (dolist (v '(5 -3 42))
          (write! in v)
          (propagate!)
          (ok (= (mod-value out) (expected v))))
        (write! in 7)
        (propagate-parallel!)
        (ok (= (mod-value out) (expected 7)))
        ;; billing: the single node re-ran once per update
        (ok (= (bill-total (last-bill)) 1))))))

(deftest-fresh scenario-updates
  (testing "tagged / private / as-if updates roll back and bill their owner"
    (let ((x (make-mod 1 :name "sx"))
          (y (make-mod nil :name "sy")))
      (adaptive-read ((v x)) (write! y (* v 10)))
      ;; nested scenarios: inner rolls back to the outer world, outer to base
      (with-scenario ("outer" :owner "alice")
        (scenario-write! x 2)
        (scenario-propagate!)
        (ok (= (mod-value y) 20))
        (with-scenario ("inner" :owner "bob")
          (scenario-write! x 5)
          (scenario-propagate!)
          (ok (= (mod-value y) 50)))
        (ok (= (mod-value y) 20)))
      (ok (= (mod-value x) 1))
      (ok (= (mod-value y) 10))
      ;; tagged registry with per-owner attribution of hypothetical work
      (ok (equal (scenario-bill-alist "outer") (list (cons (intern-principal "alice") 1))))
      (ok (equal (scenario-bill-alist "inner") (list (cons (intern-principal "bob") 1))))
      (ok (not (scenario-live-p (find-scenario "outer"))))
      ;; non-local exit still rolls back
      (ok (signals (with-scenario ("boom")
                     (scenario-write! x 99)
                     (scenario-propagate!)
                     (error "boom"))
                   'error))
      (ok (= (mod-value x) 1))
      (ok (= (mod-value y) 10)))))

(deftest-fresh scenario-portfolio-stress
  (testing "WHAT-IF stress on the portfolio leaves base world, bill, and log untouched"
    (let ((u (make-universe '(("AAPL" 19000 100 18000 2)
                              ("MSFT" 41000 50 40000 2)
                              ("GOOG" 17500 -30 18000 2))
                            '("AAPL"))))
      (tick! u "GOOG" 17600)
      (ok (= (mod-value (universe-firm-pnl u)) 162000))
      (let ((bill-before (bill-alist))
            (log-before (explain-update)))
        (multiple-value-bind (vals sc)
            (what-if (list (cons (asset-price-mod (find-asset u "AAPL")) 18000)
                           (cons (asset-price-mod (find-asset u "MSFT")) 39000))
                     (list (universe-firm-pnl u))
                     :tag "crash-test" :owner "alice")
          ;; AAPL pnl 0, MSFT pnl -50000, GOOG pnl 12000
          (ok (equal vals '(-38000)))
          ;; hypothetical recompute billed to alice on the scenario, not the base bill
          (ok (equal (scenario-bill-alist sc)
                     (list (cons (intern-principal "alice") 17))))
          (ok (consp (scenario-explain "crash-test"))))
        ;; base universe exactly as before
        (ok (= (mod-value (universe-firm-pnl u)) 162000))
        (ok (equal (bill-alist) bill-before))
        (ok (equal (explain-update) log-before))))))

(deftest-fresh portfolio-scenario
  (testing "portfolio risk: access control, request billing, provenance report"
    (let ((u (make-universe '(("AAPL" 19000 100 18000 2)
                              ("MSFT" 41000 50 40000 2)
                              ("GOOG" 17500 -30 18000 2))
                            '("AAPL"))))
      (ok (= (mod-value (universe-firm-pnl u)) (+ 100000 50000 15000)))
      ;; feed tick: recompute cost blamed on the feed
      (tick! u "AAPL" 19500)
      (ok (= (mod-value (universe-firm-pnl u)) (+ 150000 50000 15000)))
      (ok (equal (bill-alist)
                 (list (cons (intern-principal "feed") 16)))) ; pnl 1 + firm 5 + desk 3 + expo 4 + worst 3
      ;; alice sees everything; charge = fee + source costs + calc costs over the slice
      (multiple-value-bind (v c) (request u "alice" :firm-pnl)
        (ok (= v 215000))
        (ok (= c (+ 1 (+ 2 2 2) (+ 1 1 1 5)))))
      ;; bob gets his desk aggregate, and a smaller slice = smaller charge
      (multiple-value-bind (v c) (request u "bob" :desk-b-pnl)
        (ok (= v 150000))
        (ok (= c (+ 1 2 1 3))))
      ;; bob is denied raw prices, per-position detail, and firm-wide numbers
      (ok (eq (request u "bob" :firm-pnl) :denied))
      (ok (eq (request u "bob" (cons :price "AAPL")) :denied))
      (ok (eq (request u "bob" (cons :pnl "MSFT")) :denied))
      (ok (> (cdr (assoc "alice" (ledger-alist u) :test #'equal))
             (cdr (assoc "bob" (ledger-alist u) :test #'equal))))
      ;; alice's provenance report (before any further propagation touches the log)
      (let ((report (risk-report u :shock-ticker "AAPL" :shock-bps -1000)))
        (ok (search "firm P&L: 215000" report))
        (ok (search "determined by: basis[GOOG], qty[GOOG], price[GOOG]" report))
        (ok (search "blame: feed" report))
        ;; AAPL -10%: pnl = 100*(17550-18000) = -45000; firm = -45000+50000+15000
        (ok (search "firm P&L would be 20000" report))
        ;; probe left the world untouched
        (ok (= (mod-value (universe-firm-pnl u)) 215000)))
      ;; revocation is change propagation: bob loses even his aggregate
      (revoke! "bob" :desk-b)
      (ok (eq (request u "bob" :desk-b-pnl) :denied)))))

(deftest-fresh multi-universe
  (testing "universes coexist in one graph: independent values, bills, ledgers, what-ifs"
    ;; same tickers on purpose: mods are per-universe structs, names are just labels.
    ;; NOTE interleaved use within one dynamic state: *last-bill* / *last-update-log* and
    ;; the scenario stack are shared here. For concurrent calculations give each thread
    ;; its own WITH-FRESH-STATE (see concurrent-fresh-states).
    (let ((u1 (make-universe '(("AAPL" 19000 100 18000 2)) '("AAPL")))
          (u2 (make-universe '(("AAPL" 20000 10 19000 2)) '("AAPL"))))
      (ok (= (mod-value (universe-firm-pnl u1)) 100000))
      (ok (= (mod-value (universe-firm-pnl u2)) 10000))
      ;; a tick in one universe re-runs only that universe's nodes
      (tick! u1 "AAPL" 19500)
      (ok (= (mod-value (universe-firm-pnl u1)) 150000))
      (ok (= (mod-value (universe-firm-pnl u2)) 10000))
      (ok (= (bill-total) 16))  ; pnl 1 + firm 5 + desk 3 + expo 4 + worst 3, u1 only
      ;; and vice versa
      (tick! u2 "AAPL" 21000)
      (ok (= (mod-value (universe-firm-pnl u2)) 20000))
      (ok (= (mod-value (universe-firm-pnl u1)) 150000))
      (ok (= (bill-total) 16))
      ;; request ledgers live on the universe struct: charging u1 leaves u2's ledger empty
      (request u1 "alice" :firm-pnl)
      (ok (equal (ledger-alist u2) '()))
      ;; a what-if against u1 is invisible in u2 and rolls back cleanly
      (multiple-value-bind (vals sc)
          (what-if (list (cons (asset-price-mod (find-asset u1 "AAPL")) 18000))
                   (list (universe-firm-pnl u1) (universe-firm-pnl u2))
                   :tag "multi-u" :owner "alice")
        (declare (ignore sc))
        (ok (equal vals '(0 20000))))
      (ok (= (mod-value (universe-firm-pnl u1)) 150000))
      (ok (= (mod-value (universe-firm-pnl u2)) 20000)))))

(deftest-fresh fresh-state-isolation
  (testing "WITH-FRESH-STATE rebinds all mutable state with dynamic extent"
    (let ((x (make-mod 1 :name "gx"))
          (y (make-mod nil :name "gy")))
      (adaptive-read ((v x)) (write! y (* v 2)))
      (with-principal ("carol")
        (write! x 5))
      (propagate!)
      (ok (= (mod-value y) 10))
      (let ((outer-bill (bill-total))
            (outer-log (explain-update)))
        (with-fresh-state
          ;; inner world: its own graph queue, bills, logs, principals
          (let ((a (make-mod 3))
                (b (make-mod nil)))
            (adaptive-read ((v a)) (write! b (1+ v)))
            (with-principal ("alice")
              (write! a 7))
            (propagate!)
            (ok (= (mod-value b) 8))
            (ok (= (bill-total) 1))
            ;; alice was interned into the fresh tables, right after system
            (ok (= (intern-principal "alice") 1))
            ;; parallel propagation works under rebound state (buckets conveyed to workers)
            (ensure-kernel)
            (write! a 100)
            (propagate-parallel!)
            (ok (= (mod-value b) 101))))
        ;; outer bill, log, and graph untouched by the inner propagations
        (ok (= (bill-total) outer-bill))
        (ok (equal (explain-update) outer-log))
        (write! x 6)
        (propagate!)
        (ok (= (mod-value y) 12))))))

(deftest-fresh concurrent-fresh-states
  (testing "one WITH-FRESH-STATE per thread: independent worlds compute simultaneously"
    (let ((results (make-array 2 :initial-element nil)))
      (flet ((worker (i base)
               (lambda ()
                 (with-fresh-state
                   (let* ((inputs (loop for k below 16 collect (make-mod (+ base k))))
                          (total (adaptive-reduce #'+ inputs)))
                     (dotimes (r 200)
                       (with-principal ("alice")
                         (write! (nth (mod r 16) inputs) (+ base r)))
                       (propagate!))
                     (setf (aref results i)
                           (= (mod-value total)
                              (reduce #'+ (mapcar #'mod-value inputs)))))))))
        (let ((t1 (bt:make-thread (worker 0 100) :name "psac-u1"))
              (t2 (bt:make-thread (worker 1 2000) :name "psac-u2")))
          (bt:join-thread t1)
          (bt:join-thread t2)))
      (ok (aref results 0))
      (ok (aref results 1)))))

(deftest-fresh policy-group-sets
  (testing "allowed-mod caches per (principal, class, group-set), order-insensitively"
    (admit! "alice" :g1)
    (grant-class! :g1 :secret)
    (let ((via-g1 (allowed-mod "alice" :secret :groups '(:g1)))
          (via-g2 (allowed-mod "alice" :secret :groups '(:g2))))
      ;; different group sets are different decisions, not one shared cache entry
      (ok (not (eq via-g1 via-g2)))
      (ok (eq (mod-value via-g1) t))
      (ok (null (mod-value via-g2)))
      ;; same set in a different order hits the same cached mod
      (ok (eq (allowed-mod "alice" :secret :groups '(:g2 :g1))
              (allowed-mod "alice" :secret :groups '(:g1 :g2)))))))

(deftest parallel-fresh-state-conveyance
  (testing "worker thunks run in the coordinator's fresh world, not the globals"
    (let ((global-ids psac::*principal-ids*))
      (with-fresh-state
        (ensure-kernel)
        (let ((x1 (make-mod 0)) (x2 (make-mod 0))
              (o1 (make-mod nil)) (o2 (make-mod nil)))
          (adaptive-read ((v x1))
            (when (plusp v) (intern-principal "w-one"))
            (write! o1 v))
          (adaptive-read ((v x2))
            (when (plusp v) (intern-principal "w-two"))
            (write! o2 v))
          (write! x1 1)
          (write! x2 1)
          (propagate-parallel!)
          ;; both principals landed in the fresh tables with distinct ids after system=0
          (let ((one (gethash "w-one" psac::*principal-ids*))
                (two (gethash "w-two" psac::*principal-ids*)))
            (ok (member one '(1 2)))
            (ok (member two '(1 2)))
            (ok (/= one two))
            ;; the shared counter box saw both increments: no id reuse
            (ok (= (intern-principal "w-next") 3)))))
      ;; nothing leaked into the global world
      (ok (null (gethash "w-one" global-ids)))
      (ok (null (gethash "w-two" global-ids))))))

(deftest-fresh propagation-error-recovery
  (testing "a signaling thunk leaves its node dirty; propagation retries, never no-ops"
    (let ((x (make-mod 0 :name "ex"))
          (y (make-mod nil :name "ey")))
      (adaptive-read ((v x))
        (when (= v 1) (error "boom"))
        (write! y v))
      (write! x 1)
      (ok (signals (propagate!) 'error))
      ;; still dirty: a second propagate! retries (and signals again) instead of no-opping
      (ok (signals (propagate!) 'error))
      (write! x 2)
      (propagate!)
      (ok (= (mod-value y) 2))
      ;; same under parallel waves
      (write! x 1)
      (ensure-kernel)
      (ok (signals (propagate-parallel!) 'error))
      (write! x 3)
      (propagate-parallel!)
      (ok (= (mod-value y) 3)))))

(deftest-fresh single-writer-enforcement
  (testing "a second live node writing the same mod signals SINGLE-WRITER-ERROR"
    (let ((a (make-mod 1))
          (b (make-mod 2))
          (out (make-mod nil)))
      (adaptive-read ((v a)) (write! out v))
      (ok (signals (adaptive-read ((v b)) (write! out v)) 'single-writer-error))
      ;; external writes (no node) and the original writer remain allowed
      (write! a 5)
      (propagate!)
      (ok (= (mod-value out) 5)))))

(deftest-fresh seq-par-equivalence
  (testing "identical graphs and writes: sequential and parallel agree on values and bills"
    (flet ((run (parallel)
             (with-fresh-state
               (when parallel (ensure-kernel))
               (let* ((inputs (loop for i below 16 collect (make-mod i)))
                      (squares (adaptive-map (lambda (v) (* v v)) inputs))
                      (total (adaptive-reduce #'+ squares))
                      (mx (adaptive-max squares)))
                 (with-principal ("alice")
                   (write! (nth 3 inputs) 100)
                   (write! (nth 7 inputs) -5))
                 (with-principal ("bob")
                   (write! (nth 7 inputs) 42)
                   (write! (nth 11 inputs) 9))
                 (if parallel (propagate-parallel!) (propagate!))
                 (list (mod-value total) (mod-value mx) (bill-alist))))))
      (ok (equal (run nil) (run t))))))

(deftest-fresh input-validation
  (testing "empty combinators and unknown tickers signal clear errors"
    (ok (signals (adaptive-reduce #'+ '()) 'error))
    (ok (signals (adaptive-max '()) 'error))
    (ok (signals (adaptive-avg '()) 'error))
    (ok (signals (adaptive-filter #'evenp '()) 'error))
    (let ((u (make-universe '(("AAPL" 19000 100 18000 2)) '("AAPL"))))
      (ok (signals (tick! u "NOPE" 1) 'error))
      (ok (signals (book-trade! u "NOPE" 1 1) 'error)))))

(deftest-fresh harness-scenario
  (testing "JSON scenario runs and snapshots match hand computation"
    (let ((json (run-scenario (asdf:system-relative-pathname :psac "scenarios/basic.json"))))
      (ok (search "\"s1\":7" json))    ; initial: 3+4
      (ok (search "\"s3\":25" json))   ; after x1<-10: (10+4)+(5+6)
      (ok (search "\"s3\":20" json))   ; after x2<--3, x3<-7: (10-3)+(7+6)
      (ok (search "\"m1\":13" json)))))
