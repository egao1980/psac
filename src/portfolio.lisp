(in-package #:psac)

;;;; Real-world scenario: portfolio risk on live market data.
;;;;
;;;; A shared book of positions is priced off ticker mods owned by the "feed" principal.
;;;; Adaptive views: per-asset P&L, firm P&L, desk-B P&L, gross exposure, worst position
;;;; (with selective provenance -- the argmin position explains the number).
;;;;
;;;; Access (policy as SAC): Alice is in :risk with grants to every resource class; Bob is
;;;; in :desk-b and can see only :desk-b aggregates -- raw prices, per-position detail and
;;;; firm-wide numbers answer :denied.
;;;;
;;;; Billing, two channels:
;;;;   * update-driven: ordinary propagation bills -- whoever wrote (feed ticks, Alice's
;;;;     trades) is blamed for the nodes their change re-ran, at each node's :cost;
;;;;   * request-driven: REQUEST charges the caller a flat API fee plus the predefined
;;;;     source-data costs and calc-node costs summed over the provenance slice of the
;;;;     requested view. Bob's smaller slice makes his requests cheaper than Alice's.

(defparameter *request-fee* 1
  "Flat charge per API request, before slice costs.")

(defstruct asset
  ticker
  price-mod
  qty-mod
  basis-mod
  pnl-mod)

(defstruct (universe (:constructor %make-universe))
  (assets '() :type list)
  (desk-tickers '() :type list)
  firm-pnl
  desk-pnl
  exposure
  worst
  ;; view-key -> (mod . resource-class)
  (views (make-hash-table :test #'equal))
  ;; input mod -> predefined cost of one source-data update ("API cost" of that feed)
  (data-costs (make-hash-table :test #'eq))
  ;; principal id -> total charged for requests
  (ledger (make-hash-table :test #'eql)))

(defun find-asset (universe ticker)
  (find ticker (universe-assets universe) :key #'asset-ticker :test #'equal))

(defun require-asset (universe ticker)
  (or (find-asset universe ticker)
      (error "unknown ticker ~s in universe (have: ~{~a~^, ~})"
             ticker (mapcar #'asset-ticker (universe-assets universe)))))

(defun %make-priced-asset (ticker price qty basis)
  "Feed-owned price mod, position mods, and the adaptive per-asset P&L node."
  (let* ((price-mod (with-principal ("feed")
                      (make-mod price :name (format nil "price[~a]" ticker))))
         (qty-mod (make-mod qty :name (format nil "qty[~a]" ticker)))
         (basis-mod (make-mod basis :name (format nil "basis[~a]" ticker)))
         (pnl-mod (make-mod nil :name (format nil "pnl[~a]" ticker))))
    (register-read (list price-mod qty-mod basis-mod)
                   (lambda (p q b) (write! pnl-mod (* q (- p b))))
                   :name (format nil "pnl-node[~a]" ticker)
                   :cost 1)
    (make-asset :ticker ticker :price-mod price-mod :qty-mod qty-mod
                :basis-mod basis-mod :pnl-mod pnl-mod)))

(defun make-universe (specs desk-tickers)
  "SPECS: list of (ticker price qty basis source-cost); prices in integer cents.
DESK-TICKERS: the subset Bob's desk holds. Builds all adaptive views and the access
policy. Assumes a fresh graph (caller does RESET-GRAPH! / RESET-POLICY!)."
  (let ((u (%make-universe :desk-tickers desk-tickers)))
    ;; --- inputs and per-asset P&L ---------------------------------------------
    (dolist (spec specs)
      (destructuring-bind (ticker price qty basis source-cost) spec
        (let ((a (%make-priced-asset ticker price qty basis)))
          (setf (gethash (asset-price-mod a) (universe-data-costs u)) source-cost)
          (push a (universe-assets u)))))
    (setf (universe-assets u) (nreverse (universe-assets u)))
    ;; --- risk measures (predefined calculation costs) -------------------------
    (let* ((assets (universe-assets u))
           (pnl-mods (mapcar #'asset-pnl-mod assets))
           (desk-assets (remove-if-not (lambda (a) (member (asset-ticker a) desk-tickers
                                                           :test #'equal))
                                       assets))
           (firm (make-mod nil :name "firm-pnl"))
           (desk (make-mod nil :name "desk-b-pnl"))
           (expo (make-mod nil :name "gross-exposure"))
           (worst (make-mod nil :name "worst-position")))
      (register-read pnl-mods
                     (lambda (&rest vals) (write! firm (reduce #'+ vals)))
                     :name "firm-pnl-node" :cost 5)
      (register-read (mapcar #'asset-pnl-mod desk-assets)
                     (lambda (&rest vals) (write! desk (reduce #'+ vals)))
                     :name "desk-b-pnl-node" :cost 3)
      (register-read (mapcan (lambda (a) (list (asset-price-mod a) (asset-qty-mod a)))
                             assets)
                     (lambda (&rest vals)
                       (write! expo (loop for (p q) on vals by #'cddr
                                          sum (abs (* p q)))))
                     :name "exposure-node" :cost 4)
      (register-read pnl-mods
                     (lambda (&rest vals)
                       (let ((m (reduce #'min vals)))
                         (write! worst m)
                         m))
                     :name "worst-position-node" :cost 3
                     ;; all argmin witnesses: under ties, every tied position explains the value
                     :provenance (lambda (result vals mods-read)
                                   (loop for v in vals
                                         for m in mods-read
                                         when (= v result) collect m)))
      (setf (universe-firm-pnl u) firm
            (universe-desk-pnl u) desk
            (universe-exposure u) expo
            (universe-worst u) worst)
      ;; --- view catalogue: view-key -> (mod . resource-class) -----------------
      (let ((views (universe-views u)))
        (setf (gethash :firm-pnl views) (cons firm :firm)
              (gethash :desk-b-pnl views) (cons desk :desk-b)
              (gethash :exposure views) (cons expo :firm)
              (gethash :worst-position views) (cons worst :marketdata))
        (dolist (a assets)
          (setf (gethash (cons :price (asset-ticker a)) views)
                (cons (asset-price-mod a) :marketdata)
                (gethash (cons :pnl (asset-ticker a)) views)
                (cons (asset-pnl-mod a) :marketdata)))))
    ;; --- access policy as SAC --------------------------------------------------
    (admit! "alice" :risk)
    (admit! "bob" :desk-b)
    (dolist (class '(:marketdata :firm :desk-b))
      (grant-class! :risk class))
    (grant-class! :desk-b :desk-b)
    u))

;;;; Market and trading events --------------------------------------------------

(defun tick! (universe ticker new-price &key (propagate t))
  "A market-data update from the feed. Recompute costs are blamed on \"feed\"."
  (with-principal ("feed")
    (write! (asset-price-mod (require-asset universe ticker)) new-price))
  (when propagate (propagate!))
  (values))

(defun book-trade! (universe ticker new-qty new-basis &key (principal "alice") (propagate t))
  "A position amendment; recompute costs are blamed on PRINCIPAL."
  (let ((a (require-asset universe ticker)))
    (with-principal (principal)
      (write! (asset-qty-mod a) new-qty)
      (write! (asset-basis-mod a) new-basis)))
  (when propagate (propagate!))
  (values))

;;;; Request-driven billing ------------------------------------------------------

(defun derivation-slice (mod)
  "Values: (inputs nodes) -- source mods and distinct R-nodes in MOD's full derivation."
  (let ((seen-mods (make-hash-table :test #'eq))
        (seen-nodes (make-hash-table :test #'eq))
        (inputs '())
        (nodes '()))
    (labels ((walk (m)
               (unless (gethash m seen-mods)
                 (setf (gethash m seen-mods) t)
                 (let ((w (modref-writer m)))
                   (cond ((null w) (push m inputs))
                         ((not (gethash w seen-nodes))
                          (setf (gethash w seen-nodes) t)
                          (push w nodes)
                          (mapc #'walk (node-deps w nil))))))))
      (walk mod))
    (values inputs nodes)))

(defun slice-cost (universe mod)
  "Predefined cost of serving MOD fresh: source-data update costs + calc costs of the slice."
  (multiple-value-bind (inputs nodes) (derivation-slice mod)
    (+ (loop for m in inputs sum (gethash m (universe-data-costs universe) 0))
       (loop for n in nodes sum (rnode-cost n)))))

(defun request (universe principal view-key)
  "An API request by PRINCIPAL for VIEW-KEY. Checks the (self-adjusting) access policy,
charges the ledger, and returns (values result charge). Denied requests pay the flat fee."
  (let ((entry (gethash view-key (universe-views universe))))
    (unless entry
      (error "unknown view ~s" view-key))
    (destructuring-bind (mod . class) entry
      (let* ((allowed (mod-value (allowed-mod principal class :groups '(:risk :desk-b))))
             (charge (if allowed
                         (+ *request-fee* (slice-cost universe mod))
                         *request-fee*))
             (id (intern-principal principal)))
        (incf (gethash id (universe-ledger universe) 0) charge)
        (values (if allowed (mod-value mod) :denied)
                charge)))))

(defun ledger-alist (universe)
  "((principal-name . total-charged) ...) sorted by id."
  (let ((entries '()))
    (maphash (lambda (id total) (push (cons (principal-name id) total) entries))
             (universe-ledger universe))
    (sort entries #'string< :key #'car)))

;;;; Alice's provenance report ---------------------------------------------------

(defun risk-report (universe &key (shock-ticker nil) (shock-bps -1000))
  "Text report for a principal with full access: risk numbers, per-position P&L
attribution, why the worst position is what it is, the causal chain of the last
update, and a counterfactual probe (SHOCK-TICKER moved by SHOCK-BPS basis points)."
  (with-output-to-string (s)
    (format s "=== Portfolio risk report ===~%")
    (format s "firm P&L: ~a  gross exposure: ~a  worst position P&L: ~a  desk-B P&L: ~a~%"
            (mod-value (universe-firm-pnl universe))
            (mod-value (universe-exposure universe))
            (mod-value (universe-worst universe))
            (mod-value (universe-desk-pnl universe)))
    (format s "~%-- P&L attribution --~%")
    (dolist (a (universe-assets universe))
      (format s "  ~a: qty=~a basis=~a price=~a -> P&L ~a~%"
              (asset-ticker a)
              (mod-value (asset-qty-mod a))
              (mod-value (asset-basis-mod a))
              (mod-value (asset-price-mod a))
              (mod-value (asset-pnl-mod a))))
    (format s "~%-- worst position, explained (selective provenance) --~%")
    (format s "  determined by: ~{~a~^, ~}~%"
            (mapcar #'modref-name (support (universe-worst universe))))
    (format s "~%-- firm P&L support (every input it depends on) --~%")
    (format s "  ~{~a~^, ~}~%"
            (sort (mapcar #'modref-name (support (universe-firm-pnl universe))) #'string<))
    (format s "~%-- last update: causal chain --~%")
    (dolist (entry (explain-update))
      (format s "  ~a re-ran (blame: ~{~a~^,~}) cost ~a -> wrote ~{~a~^, ~}~%"
              (getf entry :node) (getf entry :blame)
              (getf entry :cost) (getf entry :wrote)))
    (when shock-ticker
      (let* ((a (require-asset universe shock-ticker))
             (price (mod-value (asset-price-mod a)))
             (shocked (round (* price (+ 10000 shock-bps)) 10000))
             (would-be (probe (asset-price-mod a) shocked (universe-firm-pnl universe))))
        (format s "~%-- counterfactual --~%")
        (format s "  if ~a moved ~abps (~a -> ~a): firm P&L would be ~a (now ~a)~%"
                shock-ticker shock-bps price shocked
                would-be (mod-value (universe-firm-pnl universe)))))))

;;;; Dynamic membership: firm P&L over a growing book -----------------------------
;;;;
;;;; MAKE-UNIVERSE fixes every read set at build time -- the project's static-topology
;;;; assumption: node read sets never change, heights are computed once, and a topology
;;;; change means building a new universe. Its flat firm-pnl node reads all n positions,
;;;; so *if* it re-registered on membership change it would re-sum the whole book.
;;;;
;;;; The dynamic book shows the sanctioned in-place alternative: shape the aggregate
;;;; like a persistent data structure (ADAPTIVE-FOREST) and make membership change
;;;; *additive* -- path copying, not mutation. ADD-ASSET! creates one pnl node plus
;;;; O(log n) merge nodes over live mods; no existing node is re-registered or
;;;; re-executed, and sibling subtrees are physically reused, trace, provenance and
;;;; all. That is reuse-by-structure: the part of SAC memoization this workload needs,
;;;; without timestamped RSP traces. A tick still re-runs only the leaf-to-root path
;;;; (O(log n)); consumers hold the stable (DYNAMIC-BOOK-FIRM-PNL book) mod across
;;;; insertions. Removal stays non-structural: trade the position to qty 0 (P&L 0 is
;;;; the identity of +), keeping topology static.

(defstruct (dynamic-book (:constructor %make-dynamic-book))
  (assets '() :type list)
  forest)

(defun dynamic-book-firm-pnl (book)
  "Stable firm P&L mod; survives ADD-ASSET!, so views and requests can hold it."
  (forest-total (dynamic-book-forest book)))

(defun add-asset! (book ticker price qty basis)
  "Admit a new position into BOOK: one pnl node + O(log n) forest merge nodes are
created; nothing existing re-runs. Readers of the firm P&L see the new total after
the next PROPAGATE!."
  (let ((a (%make-priced-asset ticker price qty basis)))
    (push a (dynamic-book-assets book))
    (forest-insert! (dynamic-book-forest book) (asset-pnl-mod a))
    a))

(defun make-dynamic-book (specs)
  "SPECS: ((ticker price qty basis) ...). Firm P&L over an ADAPTIVE-FOREST, so the
book accepts new assets in O(log n) new nodes each."
  (let ((book (%make-dynamic-book :forest (adaptive-forest #'+ :name "firm-pnl"))))
    (loop for (ticker price qty basis) in specs
          do (add-asset! book ticker price qty basis))
    book))

(defun run-dynamic-book-demo (&key (stream *standard-output*))
  "Dynamic membership demo: ticks re-run O(log n) nodes, ADD-ASSET! re-runs zero."
  (with-fresh-state
    (let ((book (make-dynamic-book '(("AAPL" 19000 100 18000)
                                     ("MSFT" 41000 50 40000)
                                     ("GOOG" 17500 -30 18000)
                                     ("BTC" 6500000 2 6000000)
                                     ("EURUSD" 10850 1000 10800)))))
      (format stream "~&firm P&L over ~a assets: ~a~%"
              (forest-count (dynamic-book-forest book))
              (mod-value (dynamic-book-firm-pnl book)))
      (with-principal ("feed")
        (write! (asset-price-mod (find "AAPL" (dynamic-book-assets book)
                                       :key #'asset-ticker :test #'equal))
                19500))
      (propagate!)
      (format stream "tick AAPL -> ~a: ~a nodes re-ran (leaf-to-root path + top): ~{~a~^, ~}~%"
              (mod-value (dynamic-book-firm-pnl book))
              (length (last-update-log))
              (mapcar (lambda (e) (getf e :node)) (explain-update)))
      (add-asset! book "TSLA" 25000 10 24000)
      (propagate!)
      (format stream "add TSLA -> ~a: ~a nodes re-ran (insertion is additive: new nodes only)~%"
              (mod-value (dynamic-book-firm-pnl book))
              (length (last-update-log)))
      book)))

;;;; Demo driver ------------------------------------------------------------------

(defun run-portfolio-demo (&key (stream *standard-output*))
  "End-to-end scenario: build the book, tick the market, trade, serve billed requests
for Alice (full access) and Bob (desk aggregates only), print Alice's report and the
request ledger."
  (reset-all!)
  (let ((u (make-universe
            ;; ticker  price  qty  basis  source-cost (per-update API cost of that feed)
            '(("AAPL" 19000 100 18000 2)
              ("MSFT" 41000 50 40000 2)
              ("GOOG" 17500 -30 18000 2)
              ("BTC" 6500000 2 6000000 5)
              ("EURUSD" 10850 1000 10800 1))
            '("AAPL" "MSFT"))))
    (format stream "~&--- market opens: feed ticks ---~%")
    (tick! u "AAPL" 19500 :propagate nil)
    (tick! u "BTC" 6400000 :propagate nil)
    (propagate!)
    (format stream "propagation bill (blamed on writers): ~s~%"
            (mapcar (lambda (e) (cons (principal-name (car e)) (cdr e))) (bill-alist)))
    (format stream "~&--- alice books a trade ---~%")
    (book-trade! u "GOOG" -50 17800 :principal "alice")
    (format stream "propagation bill: ~s~%"
            (mapcar (lambda (e) (cons (principal-name (car e)) (cdr e))) (bill-alist)))
    (format stream "~&--- API requests (flat fee ~a + slice costs) ---~%" *request-fee*)
    (flet ((show (who view)
             (multiple-value-bind (result charge) (request u who view)
               (format stream "  ~a requests ~s -> ~s (charged ~a)~%" who view result charge))))
      (show "alice" :firm-pnl)
      (show "alice" :worst-position)
      (show "bob" :desk-b-pnl)
      (show "bob" :firm-pnl)
      (show "bob" (cons :price "AAPL"))
      (show "bob" (cons :pnl "MSFT")))
    (format stream "~&request ledger: ~s~%" (ledger-alist u))
    (format stream "~%~a" (risk-report u :shock-ticker "AAPL" :shock-bps -1000))
    u))
