;;;; egg-info processing and compilation
;
; Copyright (c) 2017-2022, The CHICKEN Team
; All rights reserved.
;
; Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following
; conditions are met:
;
;   Redistributions of source code must retain the above copyright notice, this list of conditions and the following
;     disclaimer.
;   Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
;     disclaimer in the documentation and/or other materials provided with the distribution.
;   Neither the name of the author nor the names of its contributors may be used to endorse or promote
;     products derived from this software without specific prior written permission.
;
; THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
; AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR
; CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
; CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
; SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
; OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
; POSSIBILITY OF SUCH DAMAGE.


(define default-extension-options '())
(define default-program-options '())
(define default-static-program-link-options '())
(define default-dynamic-program-link-options '())
(define default-static-extension-link-options '())
(define default-dynamic-extension-link-options '())
(define default-static-compilation-options '("-O2" "-d1"))
(define default-dynamic-compilation-options '("-O2" "-d1"))
(define default-import-library-compilation-options '("-O2" "-d0"))

(define default-program-linkage
  (if staticbuild '(static) '(dynamic)))

(define default-extension-linkage
  (if staticbuild '(static) '(static dynamic)))

(define +unix-executable-extension+ "")
(define +windows-executable-extension+ ".exe")
(define +unix-object-extension+ ".o")
(define +unix-archive-extension+ ".a")
(define +windows-object-extension+ ".obj")
(define +windows-archive-extension+ ".a")
(define +link-file-extension+ ".link")

(define keep-generated-files #f)
(define dependency-targets '())


;;; some utilities

(define override-prefix
  (let ((prefix (get-environment-variable "CHICKEN_INSTALL_PREFIX")))
    (lambda (dir default)
      (if prefix
          (string-append prefix dir)
          default))))

(define (object-extension platform)
  (case platform
    ((unix) +unix-object-extension+)
    ((windows) +windows-object-extension+)))

(define (archive-extension platform)
  (case platform
    ((unix) +unix-archive-extension+)
    ((windows) +windows-archive-extension+)))

(define (executable-extension platform)
  (case platform
     ((unix) +unix-executable-extension+)
     ((windows) +windows-executable-extension+)))

(define (copy-directory-command platform)
  "cp -r")

(define (copy-file-command platform)
  "cp")

(define (mkdir-command platform)
  "mkdir -p")

(define (install-executable-command platform)
  (string-append default-install-program " "
                 default-install-program-executable-flags))

(define (install-file-command platform)
  (string-append default-install-program " "
                 default-install-program-data-flags))

(define (remove-file-command platform)
  "rm -f")

(define (cd-command platform)
  "cd")

(define (uses-compiled-import-library? mode)
  (not (and (eq? mode 'host) staticbuild)))

;; this one overrides "destination-repository" in egg-environment to allow use of
;; CHICKEN_INSTALL_PREFIX (via "override-prefix")
(define (effective-destination-repository mode #!optional run)
   (if (eq? 'target mode)
       (if run target-run-repo target-repo)
       (or (get-environment-variable "CHICKEN_INSTALL_REPOSITORY")
           (override-prefix (string-append "/lib/chicken/" (number->string binary-version))
                            host-repo))))

;;; topological sort with cycle check

(define (sort-dependencies dag eq)
  (condition-case (topological-sort dag eq)
    ((exn runtime cycle)
     (error "cyclic dependencies" dag))))


;;; collect import libraries for all modules

(define (import-libraries mods dest rtarget mode)
  (define (implib name)
    (conc dest "/" name ".import."
          (if (uses-compiled-import-library? mode)
              "so"
              "scm")))
  (if mods
      (map implib mods)
      (list (implib rtarget))))


;;; normalize target path for "random files" (data, c-include, scheme-include)

(define (normalize-destination dest mode)
  (let ((dest* (normalize-pathname dest)))
    (if (irregex-search '(: bos ".." ("\\/")) dest*)
        (error "destination must be relative to CHICKEN install prefix" dest)
        (normalize-pathname
         (make-pathname (if (eq? mode 'target)
                            default-prefix
                            (override-prefix "/" host-prefix))
                        dest*)))))


;;; check condition in conditional clause

(define (check-condition tst mode link)
  (define (fail x)
    (error "invalid conditional expression in `cond-expand' clause"
           x))
  (let walk ((x tst))
    (cond ((and (list? x) (pair? x))
           (cond ((and (eq? (car x) 'not) (= 2 (length x)))
                  (not (walk (cadr x))))
                 ((eq? 'and (car x)) (every walk (cdr x)))
                 ((eq? 'or (car x)) (any walk (cdr x)))
                 (else (fail x))))
          ((memq x '(dynamic static)) (memq x link))
          ((memq x '(target host)) (memq x mode))
          ((symbol? x) (feature? x))
          (else (fail x)))))


;;; parse custom configuration information from script

(define (parse-custom-config eggfile arg)
  (define (read-all)
    (let loop ((lst '()))
      (let ((x (read)))
        (if (eof-object? x)
            (reverse lst)
            (loop (append (reverse (flatten x)) lst))))))
  (if (and (list? arg) (eq? 'custom-config (car arg)))
      (let* ((args (cdr arg))
             (in (with-input-from-pipe
                  (string-intersperse
                    (append 
                      (list default-csi "-s"
                            (make-pathname (pathname-directory eggfile)
                                           (->string (car args))))
                      (cdr args))
                    " ")
                  read-all)))
        (map ->string in))
      (list arg)))


;;; compile an egg-information tree into abstract build/install operations

(define (compile-egg-info eggfile info version platform mode)
  (let ((exts '())
        (prgs '())
        (objs '())
        (data '())
        (genfiles '())
        (cinc '())
        (scminc '())
        (target #f)
        (src #f)
        (files '())
        (ifiles '())
        (cbuild #f)
        (oname #f)
        (link '())
        (dest #f)
        (sdeps '())
        (cdeps '())
        (lopts '())
        (opts '())
        (mods #f)
        (lobjs '())
        (tfile #f)
        (ptfile #f)
        (ifile #f)
        (install #t)
        (eggfile (locate-egg-file eggfile))
        (objext (object-extension platform))
        (arcext (archive-extension platform))
        (exeext (executable-extension platform)))
    (define (check-target t lst)
      (when (member t lst)
        (error "target multiply defined" t))
      t)
    (define (addfiles . filess)
      (set! ifiles (concatenate (cons ifiles filess)))
      files)
    (define (checkfiles files target)
      (when (null? files)
        (warning "target has no files" target)))
    (define (compile-component info)
      (case (car info)
        ((extension)
          (fluid-let ((target (check-target (cadr info) exts))
                      (cdeps '())
                      (sdeps '())
                      (src #f)
                      (cbuild #f)
                      (link (if (null? link) default-extension-linkage link))
                      (tfile #f)
                      (ptfile #f)
                      (ifile #f)
                      (lopts lopts)
                      (lobjs '())
                      (oname #f)
                      (mods #f)
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (effective-destination-repository mode #t))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (when (eq? #t tfile) (set! tfile rtarget))
              (when (eq? #t ifile) (set! ifile rtarget))
              (addfiles
                (if (memq 'static link)
                    (list (conc dest "/" rtarget
                                (if (null? lobjs)
                                    objext
                                    arcext))
                          (conc dest "/" rtarget +link-file-extension+))
                    '())
                (if (memq 'dynamic link) (list (conc dest "/" rtarget ".so")) '())
                (if tfile
                    (list (conc dest "/" tfile ".types"))
                    '())
                (if ifile
                    (list (conc dest "/" ifile ".inline"))
                    '())
                (import-libraries mods dest rtarget mode))
              (set! exts
                (cons (list target
                            dependencies: cdeps
                            source: src options: opts
                            link-options: lopts linkage: link custom: cbuild
                            mode: mode types-file: tfile inline-file: ifile
                            predefined-types: ptfile eggfile: eggfile
                            modules: (or mods (list rtarget))
                            source-dependencies: sdeps
                            link-objects: lobjs
                            output-file: rtarget)
                    exts)))))
        ((installed-c-object c-object)
          (fluid-let ((target (check-target (cadr info) exts))
                      (cdeps '())
                      (sdeps '())
                      (src #f)
                      (cbuild #f)
                      (link (if (null? link) default-extension-linkage link))
                      (oname #f)
                      (mods #f)
                      (install (eq? 'installed-c-object (car info)))
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (effective-destination-repository mode #t))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (when install
                (addfiles (list (conc dest "/" rtarget objext))))
              (set! objs
                (cons (list target dependencies: cdeps source: src
                            options: opts
                            linkage: link custom: cbuild
                            mode: mode
                            eggfile: eggfile
                            source-dependencies: sdeps
                            output-file: rtarget)
                      objs)))))
        ((data)
          (fluid-let ((target (check-target (cadr info) data))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (checkfiles files target)
            (let* ((dest (or (and dest (normalize-destination dest mode))
                             (if (eq? mode 'target)
                                 default-sharedir
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! data
              (cons (list target dependencies: '() files: files
                          destination: dest mode: mode)
                    data))))
        ((generated-source-file)
          (fluid-let ((target (check-target (cadr info) data))
                      (src #f)
                      (cbuild #f)
                      (sdeps '())
                      (cdeps '()))
            (for-each compile-extension/program (cddr info))
            (unless cbuild
              (error "generated source files need a custom build step" target))
            (set! genfiles
              (cons (list target dependencies: cdeps source: src
                          custom: cbuild source-dependencies: sdeps
                          eggfile: eggfile)
                    genfiles))))
        ((c-include)
          (fluid-let ((target (check-target (cadr info) cinc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (checkfiles files target)
            (let* ((dest (or (and dest (normalize-destination dest mode))
                             (if (eq? mode 'target)
                                 default-incdir
                                 (override-prefix "/include" host-incdir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! cinc
              (cons (list target dependencies: '() files: files
                          destination: dest mode: mode)
                    cinc))))
        ((scheme-include)
          (fluid-let ((target (check-target (cadr info) scminc))
                      (dest #f)
                      (files '()))
            (for-each compile-data/include (cddr info))
            (checkfiles files target)
            (let* ((dest (or (and dest (normalize-destination dest mode))
                             (if (eq? mode 'target)
                                 default-sharedir
                                 (override-prefix "/share" host-sharedir))))
                   (dest (normalize-pathname (conc dest "/"))))
              (addfiles (map (cut conc dest <>) files)))
            (set! scminc
              (cons (list target dependencies: '() files: files
                          destination: dest mode: mode)
                    scminc))))
        ((program)
          (fluid-let ((target (check-target (cadr info) prgs))
                      (cdeps '())
                      (sdeps '())
                      (cbuild #f)
                      (src #f)
                      (link (if (null? link) default-program-linkage link))
                      (lobjs '())
                      (lopts lopts)
                      (oname #f)
                      (opts opts))
            (for-each compile-extension/program (cddr info))
            (let ((dest (if (eq? mode 'target)
                            default-bindir
                            (override-prefix "/bin" host-bindir)))
                  ;; Respect install-name if specified
                  (rtarget (or oname target)))
              (addfiles (list (conc dest "/" rtarget exeext)))
	      (set! prgs
		(cons (list target dependencies: cdeps
                            source: src options: opts
			    link-options: lopts linkage: link
                            custom: cbuild
			    mode: mode output-file: rtarget
                            source-dependencies: sdeps
                            link-objects: lobjs
                            eggfile: eggfile)
		      prgs)))))
        (else (compile-common info compile-component 'component))))
    (define (compile-extension/program info)
      (case (car info)
        ((linkage)
         (set! link (cdr info)))
        ((types-file)
         (set! tfile
           (cond ((null? (cdr info)) #t)
                 ((not (pair? (cadr info)))
                  (arg info 1 name?))
                 (else
                   (set! ptfile #t)
                   (set! tfile
                     (or (null? (cdadr info))
                         (arg (cadr info) 1 name?)))))))
        ((objects)
         (let ((los (map ->string (cdr info))))
           (set! lobjs (append lobjs los))
           (set! cdeps (append cdeps (map ->dep los)))))
        ((inline-file)
         (set! ifile (or (null? (cdr info)) (arg info 1 name?))))
        ((custom-build)
         (set! cbuild (->string (arg info 1 name?))))
        ((csc-options)
         (set! opts
           (apply append
             opts
             (map (cut parse-custom-config eggfile <>) (cdr info)))))
        ((link-options)
         (set! lopts
           (apply append
             lopts
             (map (cut parse-custom-config eggfile <>) (cdr info)))))
        ((source)
         (set! src (->string (arg info 1 name?))))
        ((install-name)
         (set! oname (->string (arg info 1 name?))))
        ((modules)
         (set! mods (map library-id (cdr info))))
        ((component-dependencies)
         (set! cdeps (append cdeps (map ->dep (cdr info)))))
        ((source-dependencies)
         (set! sdeps (append sdeps (map ->dep (cdr info)))))
        (else (compile-common info compile-extension/program 'extension/program))))
    (define (compile-common info walk context)
      (case (car info)
        ((target)
         (when (eq? mode 'target)
           (for-each walk (cdr info))))
        ((host)
         (when (eq? mode 'host)
           (for-each walk (cdr info))))
        ((error)
         (apply error (cdr info)))
        ((cond-expand)
         (compile-cond-expand info walk))
        (else
          (fprintf (current-error-port) "\nWarning (~a): property `~a' invalid or in wrong context (~a)\n\n" eggfile (car info) context))))
    (define (compile-data/include info)
      (case (car info)
        ((destination)
         (set! dest (->string (arg info 1 name?))))
        ((files)
         (set! files (append files (map ->string (cdr info)))))
        (else (compile-common info compile-data/include 'data/include))))
    (define (compile-options info)
      (define (custom info)
        (map (cut parse-custom-config eggfile <>) info))
      (case (car info)
        ((csc-options) (set! opts (apply append opts (custom (cdr info)))))
        ((link-options) (set! lopts (apply append lopts (custom (cdr info)))))
        ((linkage) (set! link (apply append link (custom (cdr info)))))
        (else (error "invalid component-options specification" info))))
    (define (compile-cond-expand info walk)
      (let loop ((clauses (cdr info)))
        (cond ((null? clauses)
               (error "no matching clause in `cond-expand' form"
                      info))
              ((or (eq? 'else (caar clauses))
                   (check-condition (caar clauses) mode link))
               (for-each walk (cdar clauses)))
              (else (loop (cdr clauses))))))
    (define (->dep x)
      (if (name? x)
          (if (symbol? x) x (string->symbol x))
          (error "invalid dependency" x)))
    (define (compile info)
      (case (car info)
        ((synopsis dependencies test-dependencies category version author maintainer
                   license build-dependencies foreign-dependencies platform
                   distribution-files) #f)
        ((components) (for-each compile-component (cdr info)))
        ((component-options)
         (for-each compile-options (cdr info)))
        (else (compile-common info compile 'toplevel))))
    (define (arg info n #!optional (pred (constantly #t)))
      (when (< (length info) n)
        (error "missing argument" info n))
      (let ((x (list-ref info n)))
        (unless (pred x)
          (error "argument has invalid type" x))
        x))
    (define (name? x) (or (string? x) (symbol? x)))
    (define dep=? equal?)
    (define (filter pred lst)
      (cond ((null? lst) '())
            ((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
            (else (filter pred (cdr lst)))))
    (define (filter-deps name deps)
      (filter (lambda (dep)
                (and (symbol? dep)
                     (or (assq dep exts)
                         (assq dep objs)
                         (assq dep data)
                         (assq dep cinc)
                         (assq dep scminc)
                         (assq dep genfiles)
                         (assq dep prgs)
                         (error "unknown component dependency" dep))))
              deps))
    ;; collect information
    (for-each compile info)
    ;; sort topologically, by dependencies
    (let* ((all (append prgs exts objs genfiles))
           (order (reverse (sort-dependencies
                            (map (lambda (dep)
                                   (cons (car dep)
                                         (filter-deps (car dep)
                                                      (get-keyword dependencies: (cdr dep)))))
                              all)
                            dep=?))))
      ;; generate + return build/install commands
      (values
        ;; build commands
        (append-map
          (lambda (id)
            (cond ((assq id exts) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data)))
                           (mods (get-keyword modules: (cdr data))))
                       (append (if (memq 'dynamic link)
                                   (list (apply compile-dynamic-extension data))
                                   '())
                               (if (memq 'static link)
                                   ;; if compiling both static + dynamic, override
                                   ;; modules/types-file/inline-file properties to
                                   ;; avoid generating things twice:
                                   (list (apply compile-static-extension
                                                (if (memq 'dynamic link)
                                                    (cons (car data)
                                                          (append '(modules: #f
                                                                    types-file: #f
                                                                    inline-file: #f)
                                                                  (cdr data)))
                                                    data)))
                                   '())
                               (if (uses-compiled-import-library? mode)
                                   (map (lambda (mod)
                                          (apply compile-import-library
                                             mod (cdr data))) ; override name
                                     mods)
                                   '())))))
                  ((assq id prgs) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data))))
                       (append (if (memq 'dynamic link)
                                   (list (apply compile-dynamic-program data))
                                   '())
                               (if (memq 'static link)
                                   (list (apply compile-static-program data))
                                   '())))))
                  ((assq id objs) =>
                   (lambda (data)
                     (let ((link (get-keyword linkage: (cdr data))))
                       (append (if (memq 'dynamic link)
                                   (list (apply compile-dynamic-object data))
                                   '())
                               (if (memq 'static link)
                                   (list (apply compile-static-object data))
                                   '())))))
                  ((assq id genfiles) =>
                   (lambda (data)
                     (list (apply compile-generated-file data))))
                  ((or (assq id data)
                       (assq id cinc)
                       (assq id scminc))
                   '()) ;; nothing to build for data components
                  (else (error "Error in chicken-install, don't know how to build component" id))))
          order)
        ;; installation commands
        (append
          (append-map
            (lambda (ext)
              (let ((link (get-keyword linkage: (cdr ext)))
                    (mods (get-keyword modules: (cdr ext))))
                (append
                  (if (memq 'static link)
                      (list (apply install-static-extension ext))
                      '())
                  (if (memq 'dynamic link)
                      (list (apply install-dynamic-extension ext))
                      '())
                  (if (and (memq 'dynamic link)
                           (uses-compiled-import-library? (get-keyword mode: ext)))
                      (map (lambda (mod)
                             (apply install-import-library
                                    mod (cdr ext))) ; override name
                        mods)
                      (map (lambda (mod)
                             (apply install-import-library-source
                                    mod (cdr ext))) ; s.a.
                        mods))
                  (if (get-keyword types-file: (cdr ext))
                      (list (apply install-types-file ext))
                      '())
                  (if (get-keyword inline-file: (cdr ext))
                      (list (apply install-inline-file ext))
                      '()))))
             exts)
          (map (lambda (obj) (apply install-object obj)) objs)
          (map (lambda (prg) (apply install-program prg)) prgs)
          (map (lambda (data) (apply install-data data)) data)
          (map (lambda (cinc) (apply install-c-include cinc)) cinc)
          (map (lambda (scminc) (apply install-data scminc)) scminc))
        ;; augmented egg-info
        (append `((installed-files ,@ifiles))
                (if version `((version ,version)) '())
                info)))))


;;; shell code generation - build operations

(define ((compile-static-extension name #!key mode dependencies
                                   source-dependencies
                                   source (options '())
                                   predefined-types eggfile
                                   link-objects modules
                                   custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
		  default-csc))
         (sname (prefix srcdir name))
         (tfile (prefix srcdir (conc types-file ".types")))
         (ifile (prefix srcdir (conc inline-file ".inline")))
         (lfile (conc sname +link-file-extension+))
         (opts (append (if (null? options)
                           default-static-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file" tfile)
                           '())
                       (if inline-file
                           (list "-emit-inline-file" ifile)
                           '())))
         (out1 (conc sname ".static"))
         (out2 (target-file (conc out1
                                  (object-extension platform))
                            mode))
         (out3 (if (null? link-objects)
                   out2
                   (target-file (conc out1
                                      (archive-extension platform))
                                mode)))
         (imps (map (lambda (m)
                      (prefix srcdir (conc m ".import.scm")))
                 (or modules '())))
         (targets (append (list out3 lfile)
                          (maybe types-file tfile)
                          (maybe inline-file ifile)
                          imps))
         (src (or source (conc name ".scm"))))
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command targets
			 `(,@(filelist srcdir source-dependencies) ,src ,eggfile
			   ,@(if custom (list cmd) '())
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			    ,cmd ,@(if keep-generated-files '("-k") '())
				"-regenerate-import-libraries"
				,@(if modules '("-J") '()) "-M"
				"-setup-mode" "-static" "-I" ,srcdir
				"-emit-link-file" ,lfile
				,@(if (eq? mode 'host) '("-host") '())
				"-D" "compiling-extension"
				"-c" "-unit" ,name
				"-D" "compiling-static-extension"
				"-C" ,(conc "-I" srcdir)
				,@opts ,src "-o" ,out2)
			 platform)
    (when (pair? link-objects)
      (let ((lobjs (filelist srcdir
                             (map (cut conc <> ".static" (object-extension platform))
                               link-objects))))
	(print-build-command (list out3)
			     `(,out2 ,@lobjs)
			     `(,target-librarian ,target-librarian-options ,out3 ,out2 ,@lobjs)
			     platform)))
    (print-end-command platform)))

(define ((compile-dynamic-extension name #!key mode mode dependencies
                                    source (options '())
                                    (link-options '())
                                    predefined-types eggfile
                                    link-objects
                                    source-dependencies modules
                                    custom types-file inline-file)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
                  default-csc))
         (sname (prefix srcdir name))
         (tfile (prefix srcdir (conc types-file ".types")))
         (ifile (prefix srcdir (conc inline-file ".inline")))
         (opts (append (if (null? options)
                           default-dynamic-compilation-options
                           options)
                       (if (and types-file
                                (not predefined-types))
                           (list "-emit-types-file" tfile)
                           '())
                       (if inline-file
                           (list "-emit-inline-file" ifile)
                           '())))
         (out (target-file (conc sname ".so") mode))
         (src (or source (conc name ".scm")))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (imps (map (lambda (m)
                      (prefix srcdir (conc m ".import.scm")))
                 modules))
         (targets (append (list out)
                          (maybe inline-file ifile)
                          (maybe (and types-file
                                      (not predefined-types)) tfile)
                          imps)))
    (add-dependency-target name out)
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command targets
			 `(,src ,eggfile ,@(if custom (list cmd) '())
			   ,@(filelist srcdir lobjs)
			   ,@(filelist srcdir source-dependencies)
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			    ,cmd ,@(if keep-generated-files '("-k") '())
				,@(if (eq? mode 'host) '("-host") '())
				"-D" "compiling-extension"
				"-J" "-s" "-regenerate-import-libraries"
				"-setup-mode" "-I" ,srcdir
				"-C" ,(conc "-I" srcdir)
				,@opts
				,@link-options
				,src
				,@(filelist srcdir lobjs)
				"-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-import-library name #!key mode
                                 source-dependencies
                                 (options '()) (link-options '()))
         srcdir platform)
  (let* ((cmd default-csc)
         (sname (prefix srcdir name))
         (opts (if (null? options)
                   default-import-library-compilation-options
                   options))
         (out (target-file (conc sname ".import.so") mode))
         (src (conc name ".import.scm")))
    (print-build-command (list out)
			 ;; TODO: eggfile not part of dependencies?
			 `(,src #;,eggfile ,@(filelist srcdir source-dependencies))
			 `(,cmd ,@(if keep-generated-files '("-k") '())
			   "-setup-mode" "-s"
			   ,@(if (eq? mode 'host) '("-host") '())
			   "-I" ,srcdir "-C" ,(conc "-I" srcdir)
			   ,@opts ,@link-options
			   ,src
			   "-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-static-object name #!key mode dependencies
                                source-dependencies
                                source (options '())
                                eggfile custom)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
                  default-csc))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (opts (if (null? options)
                   default-static-compilation-options
                   options))
         (out (target-file (conc sname
                                 ".static"
                                 (object-extension platform))
                           mode))
         (src (or ssname (conc sname ".c"))))
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command (list out)
			 `(,@(filelist srcdir source-dependencies) ,src ,eggfile
			   ,@(if custom (list cmd) '())
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			    ,cmd "-setup-mode" "-static" "-I" ,srcdir
				,@(if (eq? mode 'host) '("-host") '())
				"-c" "-C" ,(conc "-I" srcdir)
				,@opts ,src "-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-dynamic-object name #!key mode mode dependencies
                                 source (options '())
                                 eggfile
                                 source-dependencies
                                 custom)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
                  default-csc))
         (opts (if (null? options)
                   default-dynamic-compilation-options
                   options))
         (sname (prefix srcdir name))
         (ssname (and source (prefix srcdir source)))
         (out (target-file (conc sname
                                 (object-extension platform))
                           mode))
         (src (or ssname (conc sname ".c"))))
    (add-dependency-target name out)
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command (list out)
			 `(,src ,eggfile ,@(if custom (list cmd) '())
			   ,@(filelist srcdir source-dependencies)
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			   ,cmd "-setup-mode"
                           ,@(if (eq? mode 'host) '("-host") '())
			   "-s" "-c" "-C" ,(conc "-I" srcdir)
			   ,@opts ,src "-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-dynamic-program name #!key source mode dependencies
                                  (options '()) (link-options '())
                                  source-dependencies
                                  custom eggfile link-objects)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
		  default-csc))
         (sname (prefix srcdir name))
         (opts (if (null? options)
                   default-dynamic-compilation-options
                   options))
         (out (target-file (conc sname
				 (executable-extension platform))
			   mode))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (src (or source (conc name ".scm"))))
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command (list out)
			 `(,src ,eggfile ,@(if custom (list cmd) '())
			   ,@(filelist srcdir source-dependencies)
			   ,@(filelist srcdir lobjs)
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			    ,cmd ,@(if keep-generated-files '("-k") '())
				"-setup-mode"
				,@(if (eq? mode 'host) '("-host") '())
				"-I" ,srcdir
				"-C" ,(conc "-I" srcdir)
				,@opts ,@link-options ,src
				,@(filelist srcdir lobjs)
				"-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-static-program name #!key source dependencies
                                 (options '()) (link-options '())
                                 source-dependencies
                                 custom mode eggfile link-objects)
         srcdir platform)
  (let* ((cmd (or (custom-cmd custom srcdir platform)
		  default-csc))
         (sname (prefix srcdir name))
         (opts (if (null? options)
                   default-static-compilation-options
                   options))
         (out (target-file (conc sname
				 (executable-extension platform))
			   mode))
         (lobjs (map (lambda (lo)
                       (target-file (conc lo
                                          (object-extension platform))
                                    mode))
                  link-objects))
         (src (or source (conc name ".scm"))))
    (when custom
      (prepare-custom-command cmd platform))
    (print-build-command (list out)
			 `(,src ,eggfile ,@(if custom (list cmd) '())
			   ,@(filelist srcdir lobjs)
			   ,@(filelist srcdir source-dependencies)
                           ,@(get-dependency-targets dependencies))
			 `(,@(if custom '("sh") '())
			    ,cmd ,@(if keep-generated-files '("-k") '())
				,@(if (eq? mode 'host) '("-host") '())
				"-static" "-setup-mode" "-I" ,srcdir
				"-C" ,(conc "-I" srcdir)
				,@opts ,@link-options ,src
				,@(filelist srcdir lobjs)
				"-o" ,out)
			 platform)
    (print-end-command platform)))

(define ((compile-generated-file name #!key source custom dependencies
                                 source-dependencies eggfile)
         srcdir platform)
  (let ((cmd (custom-cmd custom srcdir platform))
        (out (or source name)))
    (add-dependency-target name out)
    (prepare-custom-command cmd platform)
    (print-build-command (list out)
			 (append
			   (filelist srcdir source-dependencies)
                           (get-dependency-targets dependencies))
			 `("sh" ,cmd ,eggfile)
			 platform)
    (print-end-command platform)))


;; installation operations

(define ((install-static-extension name #!key mode output-file
                                   link-objects)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (ext (if (null? link-objects)
                  (object-extension platform)
                  (archive-extension platform)))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ".static" ext) mode)))
         (outlnk (qs* (conc sname +link-file-extension+)))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
           (qs* (conc dest "/" output-file ext)))
    (print cmd " " outlnk " " ddir
           (qs* (conc dest "/" output-file +link-file-extension+)))
    (print-end-command platform)))

(define ((install-dynamic-extension name #!key mode (ext ".so")
                                    output-file)
         srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ext) mode)))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR"))
         (destf (qs* (conc dest "/" output-file ext))))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir destf)
    (print-end-command platform)))

(define ((install-import-library name #!key mode)
         srcdir platform)
  ((install-dynamic-extension name mode: mode ext: ".import.so"
                              output-file: name)
   srcdir platform))

(define ((install-import-library-source name #!key mode)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ".import.scm") mode)))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" name ".import.scm")))
    (print-end-command platform)))

(define ((install-types-file name #!key mode types-file)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (qs* (prefix srcdir (conc types-file ".types"))))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" types-file ".types")))
    (print-end-command platform)))

(define ((install-inline-file name #!key mode inline-file)
         srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (out (qs* (prefix srcdir (conc inline-file ".inline"))))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
          (qs* (conc dest "/" inline-file ".inline")))
    (print-end-command platform)))

(define ((install-program name #!key mode output-file) srcdir platform)
  (let* ((cmd (install-executable-command platform))
         (mkdir (mkdir-command platform))
         (ext (executable-extension platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ext) mode)))
         (dest (if (eq? mode 'target)
                   default-bindir
                   (override-prefix "/bin" host-bindir)))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR"))
         (destf (qs* (conc dest "/" output-file ext))))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir destf)
    (print-end-command platform)))

(define ((install-object name #!key mode output-file) srcdir platform)
  (let* ((cmd (install-file-command platform))
         (mkdir (mkdir-command platform))
         (ext (object-extension platform))
         (sname (prefix srcdir name))
         (out (qs* (target-file (conc sname ext) mode)))
         (dest (effective-destination-repository mode))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (print cmd " " out " " ddir
           (qs* (conc dest "/" output-file ext)))
    (print-end-command platform)))

(define (install-random-files dest files mode srcdir platform)
  (let* ((fcmd (install-file-command platform))
         (dcmd (copy-directory-command platform))
         (root (string-append srcdir "/"))
         (mkdir (mkdir-command platform))
         (sfiles (map (cut prefix srcdir <>) files))
         (dfile (qs* dest))
         (ddir (shell-variable "DESTDIR")))
    (print "\n" mkdir " " ddir dfile)
    (let-values (((ds fs) (partition directory? sfiles)))
      (for-each
       (lambda (d)
         (let* ((ds (strip-dir-prefix srcdir d))
                (fdir (pathname-directory ds)))
           (when fdir
             (print mkdir " " ddir
                    (qs* (make-pathname dest fdir))))
           (print dcmd " " (qs* d)
                  " " ddir
                  (if fdir
                      (qs* (make-pathname dest fdir))
                      dfile))
           (print-end-command platform)))
       ds)
      (when (pair? fs)
        (for-each
          (lambda (f)
            (let* ((fs (strip-dir-prefix srcdir f))
                   (fdir (pathname-directory fs)))
              (when fdir
                (print mkdir " " ddir
                       (qs* (make-pathname dest fdir))))
              (print fcmd " " (qs* f)
                     " " ddir
                     (if fdir
                         (qs* (make-pathname dest fdir))
                         dfile)))
            (print-end-command platform))
          fs)))))

(define ((install-data name #!key files destination mode)
         srcdir platform)
  (install-random-files (or destination
                            (if (eq? mode 'target)
                                default-sharedir
                                (override-prefix "/share"
                                                 host-sharedir)))
                        files mode srcdir platform))

(define ((install-c-include name #!key deps files destination mode)
         srcdir platform)
  (install-random-files (or destination
                            (if (eq? mode 'target)
                                default-incdir
                                (override-prefix "/include"
                                                 host-incdir)))
                        files mode srcdir platform))

;; manage dependency-targets

(define (add-dependency-target target output)
  (cond ((assq target dependency-targets) =>
         (lambda (a)
           (set-cdr! a output)))
        (else (set! dependency-targets
                (cons (cons target output) dependency-targets)))))

(define (get-dependency-targets targets)
  (append-map
    (lambda (t)
      (cond ((assq t dependency-targets) => (lambda (a) (list (cdr a))))
            (else '())))
    targets))


;;; Generate shell or batch commands from abstract build/install operations

(define (generate-shell-commands platform cmds dest srcdir prefix suffix keep)
  (fluid-let ((keep-generated-files keep))
    (with-output-to-file dest
      (lambda ()
        (prefix platform)
        (print (cd-command platform) " " (qs* srcdir))
        (for-each
          (lambda (cmd) (cmd srcdir platform))
          cmds)
        (suffix platform)))))


;;; affixes for build- and install-scripts

(define ((build-prefix mode name info) platform)
  (printf #<<EOF
#!/bin/sh~%
set -e
PATH=~a:$PATH
export CHICKEN_CC=~a
export CHICKEN_CXX=~a
export CHICKEN_CSC=~a
export CHICKEN_CSI=~a

EOF
             (qs* default-bindir) (qs* default-cc)
	     (qs* default-cxx) (qs* default-csc)
	     (qs* default-csi)))

(define ((build-suffix mode name info) platform)
  (printf #<<EOF
EOF
             ))

(define ((install-prefix mode name info) platform)
  (printf #<<EOF
#!/bin/sh~%
set -e

EOF
             ))

(define ((install-suffix mode name info) platform)
  (let* ((infostr (with-output-to-string (cut pp info)))
         (dcmd (remove-file-command platform))
         (mkdir (mkdir-command platform))
         (dir (destination-repository mode))
         (qdir (qs* dir))
         (dest (qs* (make-pathname dir name +egg-info-extension+)))
         (ddir (shell-variable "DESTDIR")))
     (printf #<<EOF

~a ~a~a
~a ~a~a
cat >~a~a <<'ENDINFO'
~aENDINFO~%
EOF
               mkdir ddir qdir
               dcmd ddir dest
               ddir dest infostr)))

;;; some utilities for mangling + quoting

(define (qs* arg)
  (qs (->string arg)))

(define (prefix dir name)
  (make-pathname dir (->string name)))

(define (system+ str platform)
  (system (if (eq? platform 'windows)
              (string-append "sh -c \"" str "\"")
	      str)))

(define (target-file fname mode)
  (if (eq? mode 'target) (string-append fname ".target") fname))

(define (joins strs platform)
  (string-intersperse (map qs* strs) " "))

(define (filelist dir lst)
  (map (cut prefix dir <>) lst))

(define (shell-variable var)
  (string-append "\"${" var "}\""))

(define prepare-custom-command void)

(define (custom-cmd custom srcdir platform)
  (and custom (prefix srcdir custom)))

(define (print-build-command targets sources command-and-args platform)
  (print "\n" (qs* default-builder) " "
         (joins targets platform)
         " : " (joins sources platform) " "
         " : " (joins command-and-args platform)))

(define print-end-command void)

(define (strip-dir-prefix prefix fname)
  (let* ((plen (string-length prefix))
         (p1 (substring fname 0 plen)))
    (assert (string=? prefix p1) "wrong prefix" prefix p1)
    (substring fname (add1 plen))))

(define (maybe f x) (if f (list x) '()))

(define (ensure-line-limit str lim)
  (when (>= (string-length str) lim)
    (error "line length exceeds platform limit: " str))
  str)
