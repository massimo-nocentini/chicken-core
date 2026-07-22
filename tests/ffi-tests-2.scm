;; -d3 caused shadowing of variable assigned to callback wrapper, which in 
;; turn resulted in an invalid optimization of the callback, assuming the
;; Scheme-level procedure was not externally visible.

(module testcase () ;; NOTE: It does *not* fail outside a module!
  (import scheme (chicken base) (chicken foreign))

  (define-external (some_callback ((c-pointer void) blabla)) scheme-object
    #t)

  (define (test-callback)
    ((foreign-safe-lambda* void ()
       "C_return(some_callback(NULL));")))

  (test-callback))
