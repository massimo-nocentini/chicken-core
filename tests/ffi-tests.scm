;;; FFI tests

(import (only (scheme base) open-output-string get-output-string))
(import (chicken memory representation))

(include "test.scm")
             
(import (chicken foreign))
                             
(foreign-declare "typedef struct foo {int x;} FOO; 
int bar(struct foo x) {return x.x;}
struct foo baz(int x) {struct foo y;y.x=x;return y;}
int bar_t(FOO x) {return x.x;}
FOO baz_t(int x) {struct foo y;y.x=x;return y;}")

(test-begin "struct arg/return")

(define bar (foreign-lambda int "bar" (struct "foo")))
(define bar_t (foreign-lambda int "bar" (struct ("FOO"))))

(define safe-bar (foreign-safe-lambda int "bar" (struct "foo")))
(define safe-bar_t (foreign-safe-lambda int "bar_t" (struct ("FOO"))))

(define baz (foreign-lambda (struct "foo") "baz" int))
(define baz_t (foreign-lambda (struct ("FOO")) "baz" int))

(define safe-baz (foreign-safe-lambda (struct "foo") "baz" int))
(define safe-baz_t (foreign-safe-lambda (struct ("FOO")) "baz" int))

(define x (baz 123))
(define x_t (baz_t 123))
(define safe-x (safe-baz 123))
(define safe-x_t (safe-baz_t 123))

(test-assert "struct return" (record-instance? x '|struct foo|))
(test-assert "struct return (typedef)" (record-instance? x_t '|FOO|))
(test-assert "struct return (safe)" (record-instance? safe-x '|struct foo|))
(test-assert "struct return (safe, typedef)" (record-instance? safe-x_t '|FOO|))

(define out (open-output-string))
(display x out)
(test-equal "string representation" "#<struct foo>" (get-output-string out))
(define out (open-output-string))
(display x_t out)
(test-equal "string representation" "#<FOO>" (get-output-string out))
(test-equal "struct argument" 123 (bar x))
(test-equal "struct argument (typedef)" 123 (bar_t x_t))
(test-equal "struct arg (safe)" 123 (safe-bar x))
(test-equal "struct arg (safe, typedef)" 123 (safe-bar_t x_t))
(test-equal "foreign value" 99 (bar (foreign-value "(struct foo){99}" (struct foo))))
(test-equal "location" 100 (let-location ((f1 (struct foo) (baz 100)))
                              (bar f1)))            
(test-end)
(test-exit)
