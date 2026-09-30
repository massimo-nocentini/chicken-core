;;;; wasm-eggs.scm - plan the static WebAssembly build of eggs (WASM_EGGS)
;
; Copyright (c) 2026, The CHICKEN Team
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

; usage: csi -s wasm-eggs.scm OUTPUT EGG ...
;
; Run by the host csi in a WebAssembly build directory (see
; Makefile.emscripten).  Each EGG is an egg name or the directory of a
; local egg (holding its .egg file).  Named eggs, and the dependencies
; of all eggs, are taken from the chicken-install cache, retrieved into
; it with the host chicken-install if missing.  OUTPUT is a makefile
; with the rules that compile every extension of these eggs, in
; dependency order, as a static unit with csc-wasm, and variables that
; list the units and objects to link into csi.
;
; This follows chicken-install's static build of an extension (see
; compile-static-extension in egg-compile.scm) for the target, and
; mirrors how it reads .egg files, with the dependency mappings of
; setup.defaults.  What cannot be done statically for WebAssembly
; (custom build scripts, generated sources, extensions without static
; linkage) is an error.  Programs are not built and data files are not
; installed (with a warning); c-include and scheme-include files are
; installed where the eggs built after them find them, but not into
; the images.  Dependency versions are not enforced: a warning says
; when the egg found is older than the one asked for.
;
; Environment:
;   WASM_EGGS_CHICKEN_INSTALL  command retrieving an egg: "CMD -r NAME"
;   WASM_EGGS_CORE             modules provided by the core system:
;                              eggs of these names are not built
;   WASM_EGGS_RESERVED         unit names taken by the core system
;   WASM_EGGS_DEFAULTS         chicken-install's setup.defaults, for
;                              its (map ...) entries
;   WASM_EGG_DIR               where the eggs are built (the directory
;                              records where each egg's sources came
;                              from, in EGG/origin)

(import scheme
	(chicken base)
	(chicken file)
	(chicken format)
	(chicken io)
	(chicken irregex)
	(chicken keyword)
	(chicken pathname)
	(chicken platform)
	(chicken process)
	(chicken process-context)
	(chicken sort)
	(chicken string)
	(chicken version))

(define program "wasm-eggs")

; the eggs whose dependencies are being resolved, innermost first
(define needed-by '())

(define (fail fmt . args)
  (fprintf (current-error-port) "~a: ~?~a~%" program fmt args
	   (if (null? needed-by)
	       ""
	       (sprintf " (needed by ~a)"
			(string-intersperse (map ->string needed-by) " <- "))))
  (exit 1))

(define (warn fmt . args)
  (fprintf (current-error-port) "~a: warning: ~?~%" program fmt args))

(define (env-list var)
  (map string->symbol
       (string-split (or (get-environment-variable var) ""))))

(define core-eggs (cons 'chicken (env-list "WASM_EGGS_CORE")))
(define reserved-units (env-list "WASM_EGGS_RESERVED"))
(define chicken-install
  (let ((cmd (get-environment-variable "WASM_EGGS_CHICKEN_INSTALL")))
    (and cmd (not (string=? "" cmd)) cmd)))
(define egg-directory
  (let ((d (get-environment-variable "WASM_EGG_DIR")))
    (if (and d (not (string=? "" d))) d "eggs")))

;; chicken-install's egg mappings: ((NAME ...) . (NAME ...)) ...  A
;; dependency on a name of the left is one on those of the right (none,
;; for eggs that became part of the core system, such as r7rs).
(define mappings
  (let ((file (get-environment-variable "WASM_EGGS_DEFAULTS")))
    (if (and file (not (string=? "" file)))
	(let ((forms (handle-exceptions ex
			 (begin
			   (fprintf (current-error-port) "~a: cannot read ~a~%" program file)
			   (exit 1))
		       (with-input-from-file file
			 (lambda ()
			   (let loop ((acc '()))
			     (let ((x (read)))
			       (if (eof-object? x) (reverse acc) (loop (cons x acc))))))))))
	  (apply append
		 (map (lambda (form)
			(if (and (pair? form) (eq? 'map (car form)))
			    (map (lambda (m)
				   (let loop ((m m) (from '()))
				     (cond ((null? m) (cons (reverse from) '()))
					   ((eq? '-> (car m)) (cons (reverse from) (cdr m)))
					   (else (loop (cdr m) (cons (car m) from))))))
				 (cdr form))
			    '()))
		      forms)))
	'())))

(define (apply-mappings names)
  (delete-duplicates
   (append-map (lambda (n)
		 (cond ((find (lambda (m) (memq n (car m))) mappings) => cdr)
		       (else (list n))))
	       names)))

;; The features of the target (a csi built by "make wasm" reports these
;; in `features'), for `cond-expand' and `platform' in .egg files.
(define target-features
  '(chicken chicken-6 chicken-6.0 32bit ptables little-endian wasm32 clang
    emscripten unix posix r7rs ieee-float ratios exact-complex
    full-numeric-tower full-unicode srfi-0 srfi-2 srfi-4 srfi-6 srfi-8 srfi-9
    srfi-10 srfi-11 srfi-12 srfi-15 srfi-16 srfi-17 srfi-23 srfi-26 srfi-28
    srfi-30 srfi-31 srfi-39 srfi-46 srfi-55 srfi-61 srfi-62 srfi-87 srfi-88))

;; Names and paths end up in make rules and shell commands.
(define (safe-name? s)
  (irregex-match '(+ (or alnum ("._+-"))) s))

(define (safe-path? s)
  (irregex-match '(+ (or alnum ("._+-/@,=~"))) s))

(define (check-name egg what x)
  (let ((s (->string x)))
    (unless (safe-name? s)
      (fail "egg `~a': unsupported ~a name ~s" egg what s))
    s))

(define (check-path egg p)
  (unless (safe-path? p)
    (fail "egg `~a': unsupported character in path ~s" egg p))
  p)

;; a word for the shell, inside a make recipe
(define (sh x)
  (let ((s (->string x)))
    (irregex-replace/all
     "\\$"
     (if (irregex-match '(+ (or alnum ("._+-/@,=:~"))) s)
	 s
	 (string-append "'" (irregex-replace/all "'" s "'\\''") "'"))
     "$$")))


;;; locating eggs

(define cache-directory
  (or (get-environment-variable "CHICKEN_EGG_CACHE")
      (make-pathname (or (system-cache-directory) (current-directory))
		     "chicken-install")))

(define (normalize-directory dir)
  (let ((d (normalize-pathname dir)))
    (if (and (> (string-length d) 1)
	     (char=? #\/ (string-ref d (- (string-length d) 1))))
	(substring d 0 (- (string-length d) 1))
	d)))

;; the .egg file of a local egg directory: DIR/NAME.egg for the
;; directory's own name, or its only .egg file
(define (egg-file-in dir)
  (let ((own (make-pathname dir (pathname-file dir) "egg")))
    (if (file-exists? own)
	own
	(let ((eggs (glob (make-pathname dir "*" "egg"))))
	  (cond ((null? eggs) #f)
		((null? (cdr eggs)) (car eggs))
		(else (fail "~a holds several .egg files: ~a" dir
			    (string-intersperse eggs " "))))))))

(define (cached-egg-file name)
  (let ((f (make-pathname (make-pathname cache-directory (symbol->string name))
			  (symbol->string name) "egg")))
    (and (file-exists? f) f)))

(define (retrieve-egg name)
  (or (cached-egg-file name)
      (begin
	(unless chicken-install
	  (fail "egg `~a' is not in the cache ~a" name cache-directory))
	(let ((cmd (sprintf "~a -r ~a" chicken-install (sh name))))
	  (print cmd)
	  (unless (zero? (system cmd))
	    (fail "cannot retrieve egg `~a' (~a failed)" name cmd)))
	(or (cached-egg-file name)
	    (fail "egg `~a' not found in ~a after retrieving it (is there such an egg?)"
		  name cache-directory)))))

(define (read-egg-file file)
  (let ((info (handle-exceptions ex
		  (fail "cannot read ~a" file)
		(with-input-from-file file read))))
    (unless (and (list? info) (every-pair? info))
      (fail "~a: invalid egg file" file))
    info))

(define (every-pair? lst)
  (or (null? lst)
      (and (pair? (car lst)) (every-pair? (cdr lst)))))


;;; .egg files

; An egg is (NAME DIR EGG-FILE DEPENDENCIES COMPONENTS INCLUDES VERSION
; WANTED), where each component is one of
;   (extension NAME unit: U source: FILE options: (OPT ...)
;    link-options: (OPT ...) objects: (NAME ...) dependencies: (NAME ...)
;    modules: (NAME ...) declared-modules: BOOL types-file: NAME|#f
;    predefined-types: BOOL)
;   (c-object NAME source: FILE options: (OPT ...) dependencies: (NAME ...))
; each include is (c-include|scheme-include NAME (FILE ...) DESTINATION),
; VERSION is the egg's version (or #f), and WANTED the versions asked
; for its dependencies, ((NAME . VERSION) ...).

(define (egg-name e) (car e))
(define (egg-dir e) (cadr e))
(define (egg-file e) (caddr e))
(define (egg-dependencies e) (cadddr e))
(define (egg-components e) (list-ref e 4))
(define (egg-includes e) (list-ref e 5))
(define (egg-version e) (list-ref e 6))
(define (egg-wanted e) (list-ref e 7))

(define (component-kind c) (car c))
(define (component-name c) (cadr c))
(define (component-get c key) (get-keyword key (cddr c)))

(define (check-condition egg x)
  (let walk ((x x))
    (cond ((and (list? x) (pair? x))
	   (case (car x)
	     ((not) (if (= 2 (length x))
			(not (walk (cadr x)))
			(fail "egg `~a': invalid condition ~s" egg x)))
	     ((and) (every walk (cdr x)))
	     ((or) (any walk (cdr x)))
	     (else (fail "egg `~a': invalid condition ~s" egg x))))
	  ((memq x '(static target)) #t)
	  ((memq x '(dynamic host)) #f)
	  ((symbol? x) (and (memq x target-features) #t))
	  (else (fail "egg `~a': invalid condition ~s" egg x)))))

(define (every pred lst)
  (or (null? lst) (and (pred (car lst)) (every pred (cdr lst)))))

(define (any pred lst)
  (and (pair? lst) (or (pred (car lst)) (any pred (cdr lst)))))

(define (dependency-name egg d)
  (string->symbol
   (check-name egg "dependency"
	       (cond ((or (symbol? d) (string? d)) d)
		     ((and (pair? d) (or (symbol? (car d)) (string? (car d))))
		      (car d))
		     (else (fail "egg `~a': invalid dependency ~s" egg d))))))

(define (option-strings egg prop)
  (map (lambda (o)
	 (cond ((or (string? o) (symbol? o) (number? o)) (->string o))
	       ((and (pair? o) (eq? 'custom-config (car o)))
		(fail "egg `~a': (custom-config ...) options cannot be used for WebAssembly"
		      egg))
	       (else (fail "egg `~a': invalid option ~s" egg o))))
       (cdr prop)))

(define (dependency-version d)
  (and (pair? d) (pair? (cdr d)) (->string (cadr d))))

(define (parse-egg name dir file)
  (let ((info (read-egg-file file))
	(deps '())
	(wanted '())
	(version #f)
	(component-props '())           ; the components, where they apply
	(components '())
	(includes '())
	(others '())                    ; components not compiled
	(opts '())
	(lopts '()))
    (define (unsupported what)
      (fail "egg `~a': ~a cannot be used for WebAssembly (eggs are built statically with csc-wasm)"
	    name what))
    ;; the walkers handle the clauses common to every context
    (define (common prop walk context)
      (case (car prop)
	((target) (for-each walk (cdr prop)))
	((host) #f)
	((cond-expand)
	 (let loop ((clauses (cdr prop)))
	   (cond ((null? clauses)
		  (fail "egg `~a': no matching clause in ~s" name prop))
		 ((or (eq? 'else (caar clauses))
		      (check-condition name (caar clauses)))
		  (for-each walk (cdar clauses)))
		 (else (loop (cdr clauses))))))
	((error)
	 (fail "egg `~a': ~a" name
	       (string-intersperse (map ->string (cdr prop)) " ")))
	(else (warn "egg `~a': ignoring unknown ~a property ~s"
		    name context (car prop)))))
    (define (component prop)
      (case (car prop)
	((extension c-object installed-c-object)
	 (let* ((kind (if (eq? 'extension (car prop)) 'extension 'c-object))
		(cname (check-name name "component" (cadr prop)))
		(src #f) (copts opts) (clopts lopts) (objs '()) (cdeps '())
		(mods #f) (tfile #f) (ptypes #f) (link #f) (iname #f))
	   (define (property p)
	     (case (car p)
	       ((source) (set! src (->string (cadr p))))
	       ((csc-options) (set! copts (append copts (option-strings name p))))
	       ((link-options) (set! clopts (append clopts (option-strings name p))))
	       ((linkage) (set! link (cdr p)))
	       ((objects)
		(let ((os (map (lambda (o) (check-name name "object" o)) (cdr p))))
		  (set! objs (append objs os))
		  (set! cdeps (append cdeps os))))
	       ((component-dependencies)
		(set! cdeps (append cdeps (map (lambda (d) (check-name name "component" d))
					       (cdr p)))))
	       ((source-dependencies) #f) ; in the copied source tree
	       ((modules)
		(set! mods (map (lambda (m)
				  (check-name name "module"
					      (if (list? m)
						  (string-intersperse (map ->string m) ".")
						  m)))
				(cdr p))))
	       ((types-file)
		(cond ((null? (cdr p)) (set! tfile #t))
		      ((pair? (cadr p))
		       (set! ptypes #t)
		       (set! tfile (if (null? (cdadr p)) #t (->string (cadr (cadr p))))))
		      (else (set! tfile (->string (cadr p))))))
	       ((inline-file) #f)
	       ((install-name) (set! iname (check-name name "install" (cadr p))))
	       ((custom-build)
		(unsupported (sprintf "component `~a' has a custom build script, which" cname)))
	       (else (common p property "component"))))
	   (for-each property (cddr prop))
	   (when (and link (not (memq 'static link)))
	     (fail "egg `~a': component `~a' has no static linkage, which WebAssembly needs"
		   name cname))
	   (let ((out (or iname cname)))
	     (set! components
	       (cons (if (eq? kind 'extension)
			 (list 'extension cname
			       unit: cname
			       source: (or src (string-append cname ".scm"))
			       options: copts link-options: clopts
			       objects: objs dependencies: cdeps
			       modules: (or mods (list out))
			       declared-modules: (and mods #t)
			       types-file: (if (eq? tfile #t) out tfile)
			       predefined-types: ptypes)
			 (list 'c-object cname
			       source: (or src (string-append cname ".c"))
			       options: copts dependencies: cdeps))
		     components)))))
	((c-include scheme-include)
	 ;; installed for the eggs built after this one, as chicken-install
	 ;; would (by default in PREFIX/include/chicken or
	 ;; PREFIX/share/chicken, on the C and Scheme include paths), but
	 ;; not into the images
	 (let ((cname (check-name name "component" (cadr prop)))
	       (files '())
	       (dest #f))
	   (define (property p)
	     (case (car p)
	       ((files)
		(set! files (append files (map (lambda (f) (check-path name (->string f)))
					       (cdr p)))))
	       ((destination)
		(let ((d (normalize-pathname (->string (cadr p)))))
		  (when (or (absolute-pathname? d) (irregex-search '(: bos "..") d))
		    (fail "egg `~a': destination of `~a' must be relative to the prefix: ~s"
			  name cname (cadr p)))
		  (set! dest (check-path name d))))
	       ((component-dependencies) #f)
	       (else (common p property "component"))))
	   (for-each property (cddr prop))
	   (set! others (cons cname others))
	   (set! includes
	     (cons (list (car prop) cname files
			 (or dest (if (eq? 'c-include (car prop))
				      "include/chicken"
				      "share/chicken")))
		   includes))))
	((data)
	 (set! others (cons (check-name name "component" (cadr prop)) others))
	 (warn "egg `~a': data component `~a' is not installed in WebAssembly images"
	       name (cadr prop)))
	((program)
	 (set! others (cons (check-name name "component" (cadr prop)) others))
	 (warn "egg `~a': program `~a' is not built" name (cadr prop)))
	((generated-source-file)
	 (unsupported (sprintf "generated source file `~a' needs a custom build script and" (cadr prop))))
	(else (common prop component "components"))))
    (define (options prop)
      (case (car prop)
	((csc-options) (set! opts (append opts (option-strings name prop))))
	((link-options) (set! lopts (append lopts (option-strings name prop))))
	((linkage) #f)
	(else (fail "egg `~a': invalid component-options ~s" name prop))))
    (define (toplevel prop)
      (case (car prop)
	((dependencies build-dependencies)
	 (for-each (lambda (d)
		     (let ((n (dependency-name name d))
			   (v (dependency-version d)))
		       (set! deps (append deps (apply-mappings (list n))))
		       (when v (set! wanted (cons (cons n v) wanted)))))
		   (cdr prop)))
	((version) (set! version (->string (cadr prop))))
	((synopsis author maintainer category license test-dependencies
	  foreign-dependencies distribution-files)
	 #f)
	((platform)
	 (unless (check-condition name (cadr prop))
	   (fail "egg `~a' does not support this platform: ~s" name (cadr prop))))
	((custom-build) (unsupported "the egg has a custom build script, which"))
	((component-options) (for-each options (cdr prop)))
	;; also those in a toplevel cond-expand or target
	((components) (set! component-props (append component-props (cdr prop))))
	(else (common prop toplevel "egg"))))
    ;; options first: chicken-install gives them to all components
    (for-each toplevel info)
    (for-each component component-props)
    (when (and (null? components) (null? includes))
      (warn "egg `~a' has no extension for the target (a host-only egg?): nothing is built for it"
	    name))
    (list name dir file
	  (delete-duplicates deps)
	  (sort-components name (reverse components) others)
	  (reverse includes)
	  version
	  wanted)))

(define (delete-duplicates lst)
  (let loop ((lst lst) (acc '()))
    (cond ((null? lst) (reverse acc))
	  ((member (car lst) acc) (loop (cdr lst) acc))
	  (else (loop (cdr lst) (cons (car lst) acc))))))

;; depth-first topological order, keeping the given order otherwise
(define (topological name-of deps-of lookup items what)
  (let ((done '()) (order '()))
    (let visit-all ((items items) (path '()))
      (for-each
       (lambda (x)
	 (let ((n (name-of x)))
	   (cond ((member n done) #f)
		 ((member n path)
		  (fail "cyclic ~a dependencies: ~a" what
			(string-intersperse (map ->string (reverse (cons n path))) " -> ")))
		 (else
		  (visit-all (map (cut lookup <> (cons n path)) (deps-of x))
			     (cons n path))
		  (set! done (cons n done))
		  (set! order (cons x order))))))
       items))
    (reverse order)))

; OTHERS name the components that are not compiled (include files,
; data, programs): dependencies on them are dropped, as include files
; are in place before any component is compiled.
(define (sort-components egg comps others)
  (define (lookup n #!optional path)
    (or (find (lambda (c) (equal? n (component-name c))) comps)
	(fail "egg `~a': unknown component dependency `~a'" egg n)))
  (define (built-dependencies c)
    (filter (lambda (d) (not (member d others)))
	    (component-get c dependencies:)))
  (define (drop-others c)
    (let loop ((props (cddr c)) (acc (list (component-name c) (component-kind c))))
      (cond ((null? props) (reverse acc))
	    ((eq? dependencies: (car props))
	     (loop (cddr props) (cons (built-dependencies c) (cons dependencies: acc))))
	    (else (loop (cddr props) (cons (cadr props) (cons (car props) acc)))))))
  (for-each (lambda (c)
	      (for-each (lambda (o)
			  (unless (eq? 'c-object (component-kind (lookup o)))
			    (fail "egg `~a': object `~a' of `~a' is not a c-object"
				  egg o (component-name c))))
			(or (component-get c objects:) '())))
	    comps)
  (map drop-others
       (topological component-name built-dependencies lookup comps "component")))

(define (find pred lst)
  (cond ((null? lst) #f)
	((pred (car lst)) (car lst))
	(else (find pred (cdr lst)))))


;;; resolving WASM_EGGS

(define (resolve entries)
  (let ((eggs '()))                     ; ((name . egg) ...)
    (define (add! name dir file)
      (check-path name dir)
      (let ((egg (parse-egg name dir file)))
	(set! eggs (cons (cons name egg) eggs))
	egg))
    (define (by-name name)
      (cond ((assq name eggs) => cdr)
	    (else
	     (let ((file (retrieve-egg name)))
	       (add! name (normalize-directory (pathname-directory file)) file)))))
    ;; local eggs first, so that their names shadow the cache
    (let ((roots
	   (append-map
	    (lambda (entry)
		  (if (directory-exists? entry)
		      (let* ((dir (normalize-directory entry))
			     (file (or (egg-file-in dir)
				       (fail "~a holds no .egg file" dir)))
			     (name (string->symbol
				    (check-name (pathname-file file) "egg"
						(pathname-file file)))))
			(when (assq name eggs)
			  (fail "egg `~a' given twice" name))
			(add! name dir file)
			(list name))
		      (if (or (substring-index "/" entry) (not (safe-name? entry)))
			  (fail "no such egg directory: ~a" entry)
			  (let* ((name (string->symbol entry))
				 (names (apply-mappings (list name))))
			    (when (null? names)
			      (warn "egg `~a' is provided by the core system" name))
			    names))))
		entries)))
      (let* ((core? (lambda (n) (memq n core-eggs)))
	     (roots (filter (lambda (n)
			      (if (core? n)
				  (begin
				    (warn "egg `~a' is provided by the core system" n)
				    #f)
				  #t))
			    roots))
	     (lookup (lambda (n #!optional (path '()))
		       (fluid-let ((needed-by path))
			 (by-name n)))))
	(let ((order (topological egg-name
				  (lambda (e) (filter (lambda (d) (not (core? d)))
						      (egg-dependencies e)))
				  lookup (map lookup roots) "egg")))
	  (check-versions order)
	  order)))))

;; Versions are not enforced (the egg found is built, as for a local
;; egg directory); an egg older than asked for gets a warning.
(define (check-versions eggs)
  (for-each
   (lambda (e)
     (for-each
      (lambda (w)
	(let ((d (find (lambda (x) (eq? (car w) (egg-name x))) eggs)))
	  (when (and d (egg-version d) (not (version>=? (egg-version d) (cdr w))))
	    (warn "egg `~a' needs version ~a of `~a', but ~a has version ~a"
		  (egg-name e) (cdr w) (car w) (egg-dir d) (egg-version d)))))
      (reverse (egg-wanted e))))
   eggs))

(define (filter pred lst)
  (cond ((null? lst) '())
	((pred (car lst)) (cons (car lst) (filter pred (cdr lst))))
	(else (filter pred (cdr lst)))))


;;; the makefile

(define (egg-files dir)
  ;; the egg's source tree, without version control metadata
  (sort (find-files dir
		    test: (lambda (f) (not (directory-exists? f)))
		    limit: 8
		    dotfiles: #f)
	string<?))

(define (egg-directories dir)
  (cons dir
	(sort (find-files dir test: directory-exists? limit: 8 dotfiles: #f)
	      string<?)))

(define (words lst)
  (string-intersperse (map ->string lst) " "))

; csc's -L passes its argument to the linker; emcc takes the rest as is
(define (link-options opts)
  (let loop ((opts opts) (acc '()))
    (cond ((null? opts) (reverse acc))
	  ((and (string=? "-L" (car opts)) (pair? (cdr opts)))
	   (loop (cddr opts) (append (reverse (string-split (cadr opts))) acc)))
	  (else (loop (cdr opts) (cons (car opts) acc))))))

; Each egg E is built in $(WASM_EGG_DIR)/E.  src is a copy of its
; sources, made again when they change or come from another directory
; (E/origin names it: the planner rewrites it only when the directory
; changes).  The egg's include files are installed below
; $(WASM_EGG_DIR)/prefix, on the include paths of the eggs built after
; it.  The components are compiled one after the other, in the egg's
; order, as chicken-install does: csc-wasm runs in src for a C object,
; and in a directory of its own, C.build, for an extension, which so
; shows the import libraries of all the modules it defines.  These go
; to $(WASM_EGG_DIR)/repo, with its types file, and C.installs lists
; them.  done.stamp follows the whole egg.
(define (write-makefile eggs)
  (let* ((units '()) (objects '()) (ldopts '()) (stamps '()) (install-lists '())
	 (owner '())                    ; ((unit . egg) ...)
	 (dir (lambda (e) (sprintf "$(WASM_EGG_DIR)/~a" (egg-name e))))
	 (abs (lambda (e) (sprintf "$(CURDIR)/$(WASM_EGG_DIR)/~a" (egg-name e))))
	 (src (lambda (e) (sprintf "$(CURDIR)/$(WASM_EGG_DIR)/~a/src" (egg-name e))))
	 (stamp (lambda (name) (sprintf "$(WASM_EGG_DIR)/~a/done.stamp" name)))
	 (built? (lambda (name) (any (lambda (x) (eq? name (egg-name x))) eggs)))
	 (csc "$(CURDIR)/$(WASM_CSC)")
	 (repo "$(CURDIR)/$(WASM_EGG_DIR)/repo")
	 (prefix "$(CURDIR)/$(WASM_EGG_DIR)/prefix"))
    (printf "# GENERATED BY emscripten/wasm-eggs.scm from WASM_EGGS -- do not edit~%~%")
    (for-each
     (lambda (e)
       (let ((name (egg-name e))
	     (files (map (cut check-path (egg-name e) <>) (egg-files (egg-dir e))))
	     (includes (egg-includes e)))
	 (printf "# egg ~a (~a)~%~%" name (egg-dir e))
	 ;; normally written by the planner (see record-origin)
	 (printf "~a/origin:~%\tmkdir -p ~a~%\techo ~a >$@~%~%" (dir e) (dir e) (sh (egg-dir e)))
	 ;; a private copy of the sources: builds write next to them
	 (printf "~a/src.stamp: ~a/origin ~a~%" (dir e) (dir e) (words files))
	 (printf "\trm -rf ~a/src~%\tmkdir -p ~a~%\tcp -R ~a ~a/src~%\ttouch $@~%~%"
		 (dir e) (dir e) (sh (egg-dir e)) (dir e))
	 (for-each (lambda (f) (printf "~a:~%" f)) files)
	 (newline)
	 (unless (null? includes)
	   (printf "~a/includes.stamp: ~a/src.stamp~%" (dir e) (dir e))
	   (for-each
	    (lambda (i)
	      (let ((dest (sprintf "~a/~a" prefix (cadddr i))))
		(printf "\tmkdir -p ~a~%" dest)
		(unless (null? (caddr i))
		  (printf "\tcd ~a && cp -R ~a ~a/~%" (src e) (words (map sh (caddr i))) dest))))
	    includes)
	   (printf "\ttouch $@~%~%"))
	 ;; components wait for the eggs they depend on (the core
	 ;; system's are not built), and for the one before them
	 (let* ((ready (sprintf "~a/~a.stamp" (dir e) (if (null? includes) "src" "includes")))
		(after (cons ready (map stamp (filter built? (egg-dependencies e)))))
		(outs '()))
	   (for-each
	    (lambda (c)
	      (let* ((cname (component-name c))
		     (obj (sprintf "~a/~a.o" (dir e) cname))
		     (deps (append after
				   (if (null? outs) '() (list (car outs)))
				   (map (lambda (d) (sprintf "~a/~a.o" (dir e) d))
					(component-get c dependencies:))))
		     (opts (words (map sh (let ((o (component-get c options:)))
					    (if (null? o) '("-O2" "-d1") o))))))
		(printf "~a: ~a $(WASM_EGG_DEPS) | $(WASM_CSC)~%" obj (words (delete-duplicates deps)))
		(case (component-kind c)
		  ((c-object)
		   (printf "\tcd ~a && ~a -c -C -I~a -C -I~a/include/chicken ~a ~a -o ../~a.o~%~%"
			   (src e) csc (src e) prefix opts
			   (sh (component-get c source:)) cname))
		  ((extension)
		   (let* ((unit (component-get c unit:))
			  (usym (string->symbol unit))
			  (build (sprintf "~a/~a.build" (dir e) cname))
			  (installs (sprintf "~a/~a.installs" (dir e) cname))
			  (tfile (and (component-get c types-file:)
				      (string-append (component-get c types-file:) ".types")))
			  (ptypes (component-get c predefined-types:)))
		     (when (memq usym reserved-units)
		       (fail "egg `~a': extension `~a' has the name of a core unit" name unit))
		     (cond ((assq usym owner)
			    => (lambda (o)
				 (fail "egg `~a': extension `~a' is also in egg `~a'"
				       name unit (cdr o)))))
		     (set! owner (cons (cons usym name) owner))
		     (printf "\trm -rf ~a~%\tmkdir -p ~a $(WASM_EGG_DIR)/repo~%" build build)
		     ;; as chicken-install's compile-static-extension
		     (printf "\tcd ~a && CHICKEN_REPOSITORY_PATH=$(WASM_EGG_REPOSITORY_PATH) ~a ~
			      -setup-mode -regenerate-import-libraries -J -M -I ~a ~
			      -I ~a/share/chicken -D compiling-extension -D compiling-static-extension ~
			      -c -unit ~a -C -I~a -C -I~a/include/chicken ~a~a ~a/~a -o ../~a.o~%"
			     build csc (src e) prefix unit (src e) prefix opts
			     (if (and tfile (not ptypes)) (sprintf " -emit-types-file ~a" (sh tfile)) "")
			     (src e) (sh (component-get c source:)) cname)
		     (when (and tfile ptypes)
		       (printf "\tcp ~a/~a ~a/~%" (src e) (sh tfile) build))
		     ;; the modules the egg names must be there
		     (when (component-get c declared-modules:)
		       (printf "\tcd ~a && for m in ~a; do test -f \"$$m.import.scm\" || ~
				{ echo \"wasm-eggs: egg ~a: extension ~a defines no module $$m\" >&2; exit 1; }; done~%"
			       build (words (map sh (component-get c modules:))) name cname))
		     (printf "\tcd ~a && for f in *.import.scm~a; do test -f \"$$f\" || continue; ~
			      cp \"$$f\" ~a/ || exit 1; echo \"$(WASM_EGG_DIR)/repo/$$f\"; done >../~a.installs~%~%"
			     build (if tfile (string-append " " (sh tfile)) "") repo cname)
		     (set! units (cons unit units))
		     (set! install-lists (cons installs install-lists))
		     (set! ldopts (append ldopts (link-options (component-get c link-options:))))
		     (set! objects
		       (append objects
			       (list obj)
			       (map (lambda (o) (sprintf "~a/~a.o" (dir e) o))
				    (component-get c objects:)))))))
		(set! outs (cons obj outs))))
	    (egg-components e))
	   (printf "~a: ~a~%\ttouch $@~%~%" (stamp name) (words (cons ready (reverse outs))))
	   (set! stamps (cons (stamp name) stamps)))))
     eggs)
    (printf "WASM_EGG_NAMES = ~a~%" (words (map egg-name eggs)))
    (printf "WASM_EGG_UNITS = ~a~%" (words (reverse units)))
    (printf "WASM_EGG_OBJECTS = ~a~%" (words (delete-duplicates objects)))
    (printf "WASM_EGG_LDOPTS = ~a~%" (words (map sh ldopts)))
    (printf "WASM_EGG_INSTALLS = ~a~%" (words (reverse install-lists)))
    (printf "WASM_EGG_STAMPS = ~a~%~%" (words (reverse stamps)))
    ;; replan when an egg (or the set of files in its tree) changes
    (let ((inputs (append-map (lambda (e) (cons (egg-file e) (egg-directories (egg-dir e))))
			      eggs)))
      (printf "wasm-eggs.mk: ~a~%" (words inputs))
      (for-each (lambda (f) (printf "~a:~%" f)) inputs))))

(define (append-map f lst)
  (apply append (map f lst)))

;; EGG/origin names the directory that EGG/src is copied from; it is
;; rewritten only when that changes, so that the copy is made again.
(define (record-origin e)
  (let* ((d (make-pathname egg-directory (symbol->string (egg-name e))))
	 (f (make-pathname d "origin"))
	 (text (string-append (egg-dir e) "\n")))
    (unless (and (file-exists? f)
		 (equal? text (call-with-input-file f (lambda (p) (read-string #f p)))))
      (create-directory d #t)
      (with-output-to-file f (lambda () (display text))))))

(define (main args)
  (when (null? args)
    (fail "usage: csi -s wasm-eggs.scm OUTPUT EGG ..."))
  (let* ((out (car args))
	 (eggs (resolve (cdr args)))
	 (tmp (string-append out ".tmp")))
    (for-each (lambda (e)
		(printf "~a: egg ~a from ~a~%" program (egg-name e) (egg-dir e)))
	      eggs)
    (with-output-to-file tmp (lambda () (write-makefile eggs)))
    (for-each record-origin eggs)
    (rename-file tmp out #t)))

(main (command-line-arguments))
