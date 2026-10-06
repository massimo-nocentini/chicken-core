(import (chicken file)
        (chicken pathname)
        (chicken platform)
        (chicken process-context))

;; Skip this test on Windows altogether, regardless of Windows variant
(when (eq? (software-type) 'windows)
  (print "Skipping test-create-temporary-file.scm due to problematic unsetenv behaviour on Windows")
  (exit 0))

(define (with-environment-variable var val thunk)
  (let ((old-val (get-environment-variable var)))
    (set-environment-variable! var val)
     (thunk)
     (if old-val
         (set-environment-variable! var old-val)
         (unset-environment-variable! var))))

(let ((tmp (create-temporary-file)))
  (delete-file tmp)
  (assert (pathname-directory tmp)))

;; Assert that changes to the environment variables used by
;; create-temporary-file and create-temporary-directory get used (see
;; https://bugs.call-cc.org/ticket/1830).
;;
;; Here the use of "" as value of TMPDIR is because
;; (pathname-directory (make-pathname "" filename)) => #f
(with-environment-variable "TMPDIR" ""
  (lambda ()
    (let ((tmp (create-temporary-file)))
      (delete-file tmp)
      (assert (not (pathname-directory tmp))))))

(with-environment-variable "TMPDIR" ""
  (lambda ()
    (let ((tmp (create-temporary-directory)))
      (delete-directory tmp)
      (assert (not (pathname-directory tmp))))))

(for-each
  (lambda (ext)
    (let* ((tmp (create-temporary-file ext))
           (suffix (if (zero? (string-length ext)) "" (string-append "." ext))))
      (assert (equal? (substring tmp (- (string-length tmp) (string-length suffix)))
                      suffix))
      (assert (file-exists? tmp))
      (assert (call-with-input-file tmp (lambda (p) (eof-object? (read-char p)))))
      (delete-file tmp)))
  '("" "tmp" "привет"))

(let ((dir (create-temporary-directory)))
  (with-environment-variable "TMPDIR" dir
    (lambda ()
      (let ((port #f)
            (name #f))
        (assert
          (eq? 'done
            (call-with-temporary-file
              (lambda (p tmp)
                (set! port p)
                (set! name tmp)
                (assert (output-port? p))
                (assert (not (port-closed? p)))
                (assert (file-exists? tmp))
                (assert (equal? (pathname-directory tmp) dir))
                (assert (not (pathname-extension tmp)))
                (display "привет" p)
                'done))))
        (assert (port-closed? port))
        (assert (file-exists? name))
        (assert (equal? 'привет (call-with-input-file name read)))
        (delete-file name))))
  (delete-directory dir))
