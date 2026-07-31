(defpackage #:psac
  (:use #:cl)
  (:local-nicknames (#:jzon #:com.inuoe.jzon))
  (:export
   ;; principals
   #:intern-principal #:principal-name #:with-principal #:*current-principal*
   ;; mods
   #:make-mod #:modref #:modref-p #:mod-value #:modref-name #:modref-label #:modref-owner
   ;; caps
   #:grant-read #:grant-write #:read-cap #:read-cap-p #:write-cap #:write-cap-p
   ;; conditions
   #:label-flow-error #:*enforce-labels* #:height-invariant-error #:single-writer-error
   ;; core
   #:adaptive-read #:register-read #:write! #:propagate! #:reset-graph!
   ;; parallel
   #:propagate-parallel! #:ensure-kernel #:bench-parallel
   ;; fork-join (RSP-lite)
   #:par #:par-map #:*par-max-depth* #:bench-par-within
   ;; cost
   #:last-bill #:bill-total #:bill-alist #:last-update-log
   ;; provenance
   #:support #:explain #:explain-update #:probe
   ;; scenarios (tagged / private / as-if updates)
   #:with-scenario #:scenario-write! #:scenario-propagate! #:what-if
   #:find-scenario #:scenario-explain #:scenario-bill-alist
   #:scenario-tag #:scenario-owner #:scenario-live-p
   ;; policy
   #:member-mod #:grant-mod #:allowed-mod #:admit! #:revoke! #:grant-class! #:guarded-read #:release-gated
   #:reset-policy! #:reset-all! #:with-fresh-state
   ;; examples
   #:adaptive-map #:adaptive-filter #:adaptive-reduce #:adaptive-max #:adaptive-avg
   ;; portfolio scenario
   #:make-universe #:tick! #:book-trade! #:request #:ledger-alist #:risk-report
   #:run-portfolio-demo #:*request-fee* #:find-asset
   #:universe-firm-pnl #:universe-desk-pnl #:universe-exposure #:universe-worst
   #:asset-ticker #:asset-price-mod #:asset-qty-mod #:asset-basis-mod #:asset-pnl-mod
   ;; harness
   #:run-scenario))
