(asdf:defsystem "psac"
  :description "Self-adjusting computation with cost attribution, provenance, and access rights."
  :author "egao1980"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("alexandria" "com.inuoe.jzon" "bordeaux-threads" "lparallel")
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "primitives")
               (:file "cost")
               (:file "trace")
               (:file "propagate")
               (:file "parallel")
               (:file "provenance")
               (:file "policy")
               (:file "examples")
               (:file "harness"))
  :in-order-to ((asdf:test-op (asdf:test-op "psac/tests"))))

(asdf:defsystem "psac/tests"
  :depends-on ("psac" "rove")
  :serial t
  :pathname "tests/"
  :components ((:file "main"))
  :perform (asdf:test-op (op c) (uiop:symbol-call :rove :run c)))
