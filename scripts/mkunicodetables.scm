;;;; mkunicodetables.scm - generate utf-tables.c from the Unicode character database
;
; Populate the UCD directory first:
;
;   mkdir ucd && cd ucd
;   curl -O https://www.unicode.org/Public/UNIDATA/UnicodeData.txt
;   curl -O https://www.unicode.org/Public/UNIDATA/PropList.txt
;   curl -O https://www.unicode.org/Public/UNIDATA/DerivedCoreProperties.txt
;   curl -O https://www.unicode.org/Public/UNIDATA/CaseFolding.txt
;
; Then, from the CHICKEN source directory:
;
;   csi -s scripts/mkunicodetables.scm ucd > utf-tables.c

(import (chicken base)
        (chicken fixnum)
        (chicken io)
        (chicken pathname)
        (chicken process-context)
        (chicken string))

(include "mini-srfi-1.scm")


;;;
;;; Miscellaneous
;;;

(define (fields line) (string-split line ";" #t))

(define (words s) (string-split s " "))

(define (fromhex s) (and (not (string=? s "")) (string->number s 16)))

(define (suffix? s p)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s (- (string-length s) (string-length p))) p)))

;;;
;;; UnicodeData.txt parsing
;;;

;; Singleton:
;; 0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;
;;
;; Range:
;; 4E00;<CJK Ideograph, First>;Lo;0;L;;;;;N;;;;;
;; 9FFF;<CJK Ideograph, Last>;Lo;0;L;;;;;N;;;;;
(define (lines->entries lines)
  (let loop ((es (map fields lines)) (start #f) (out '()))
    (if (null? es)
        (reverse out)
        (let ((e (car es)) (rest (cdr es)))
          (cond ((suffix? (second e) ", First>")
                 (loop rest (fromhex (first e)) out))
                ((suffix? (second e) ", Last>")
                 (loop rest #f (append (reverse (expand-range start e)) out)))
                (else (loop rest start (cons e out))))))))

;; One entry per codepoint from START to E inclusive
(define (expand-range start e)
  (list-tabulate (add1 (- (fromhex (first e)) start))
                 (lambda (i) (cons (number->string (+ start i) 16) (cdr e)))))

;; Fields of an entry by position:
;; - 2 category,
;; - 6 decimal value,
;; - 12 simple uppercase mapping,
;; - 13 simple lowercase mapping.
;;
;; 0041;LATIN CAPITAL LETTER A;Lu;0;L;;;;;N;;;;0061;
;;                             ^^ 2            ^^^^ 13
;;
;; 0061;LATIN SMALL LETTER A;Ll;0;L;;;;;N;;;0041;;0041
;;                           ^^ 2           ^^^^ 12
;;
;; 0660;ARABIC-INDIC DIGIT ZERO;Nd;0;AN;;0;0;0;N;;;;;
;;                              ^^ 2     ^ 6
(define (category e) (list-ref e 2))
(define (decimal e) (list-ref e 6))
(define (upper-map e) (list-ref e 12))
(define (lower-map e) (list-ref e 13))

;; A codepoint and what FIELD maps it to.
;; 0130;LATIN CAPITAL LETTER I WITH DOT ABOVE;Lu;0;L;0049 0307;;;;N;LATIN CAPITAL LETTER I DOT;;;0069;
;; ^^^^                                                                                          ^^^^
;; with lower-map  =>  (304 105)
(define (mapping->columns e field) (list (fromhex (first e)) (fromhex (field e))))

;; A digit's codepoint and its decimal value.
;; 0663;ARABIC-INDIC DIGIT THREE;Nd;0;AN;;3;3;3;N;;;;;  =>  (1635 3)
(define (digit->columns e) (list (fromhex (first e)) (string->number (decimal e))))

;;;
;;; CaseFolding.txt parsing
;;;

;; FB02; F; 0066 006C; # LATIN SMALL LIGATURE FL
(define (lines->folds lines)
  (map
   (lambda (line)
     (let ((f (fields line)))
       (cons* (first (words (first f)))
              (first (words (second f)))
              (words (third f)))))
   lines))

;; There may be one to three fold targets, depending on class.
;; ABBF; C; 13EF; # CHEROKEE SMALL LETTER YA
;;     with n=1  =>  (43967 5103)
;; FB02; F; 0066 006C; # LATIN SMALL LIGATURE FL
;;     with n=3  =>  (64258 102 108 0)
;; FB03; F; 0066 0066 0069; # LATIN SMALL LIGATURE FFI
;;     with n=3  =>  (64259 102 102 105)
(define (folds->columns f n)
  (map fromhex (cons (first f) (take (append (drop f 2) '("0" "0")) n))))

;;;
;;; PropList.txt parsing
;;;

;; One row per codepoint the line covers, so a range line yields many.
;;
;; Singleton:
;; 0085          ; White_Space # Cc       <control-0085>   =>  ((133))
;;
;; Range:
;; 0009..000D    ; White_Space # Cc   [5] ...  =>  ((9) (10) (11) (12) (13))
(define (property->columns line)
  (let* ((bounds (string-split (first (words (first (fields line)))) "."))
         (lo (fromhex (first bounds)))
         (hi (if (pair? (cdr bounds)) (fromhex (second bounds)) lo)))
    (list-tabulate (add1 (- hi lo)) (lambda (i) (list (+ lo i))))))

;;;
;;; Selecting codepoints
;;;

(define (of-category e c) (string=? (category e) c))

;; Entries with non-empty FIELD.
;; 24B6;CIRCLED LATIN CAPITAL LETTER A;So;0;L;<circle> 0041;;;;N;;;;24D0;
;; 01C5;LATIN CAPITAL ... Z WITH CARON;Lt;0;L;<compat> 0044 017E;;;;N;...;01C4;01C6;01C5
(define (has-mapping e field) (not (string=? (field e) "")))

;; Folds of a given status; C and S together make the simple folding, F the
;; full one, and T the Turkic variant we do not emit.
;; 1E9E; F; 0073 0073; # LATIN CAPITAL LETTER SHARP S
;;          ^^^^^^^^^
;; 1E9E; S; 00DF; # LATIN CAPITAL LETTER SHARP S
;;          ^^^^
(define (has-status f statuses) (member (second f) statuses))

;; Lines carrying a given property.
;; 0085          ; White_Space # Cc       <control-0085>
;;                 ^^^^^^^^^^^
(define (has-property line name)
  (string=? (first (words (second (fields line)))) name))

;;;
;;; Compressing flat codepoint list into spans
;;;

;; A span keeps running as long as all inputs keep monotonously increasing.
;; Singletons are encoded as a span of length 1.  A row is the first and last
;; codepoint, then whatever extra columns held at the start of the span.
;;
;; (compress '((65) (66) (67) (90)))      => ((65 67) (90 90))
;; (compress '((120791 9) (120792 0)))    => ((120791 120791 9) (120792 120792 0))
(define (compress rows)
  (let* ((v (list->vector rows))
         (n (vector-length v))
         (at (lambda (i) (vector-ref v i)))
         (span-continues? (lambda (i)
                            (and (< (add1 i) n)
                                 (equal? (at (add1 i)) (map add1 (at i)))))))
    (let loop ((i 0) (start 0) (rows '()))
      (cond ((= i n) (reverse rows))
            ((span-continues? i) (loop (add1 i) start rows))
            (else (loop (add1 i) (add1 i)
                        (cons (cons* (first (at start)) (first (at i))
                                     (cdr (at start)))
                              rows)))))))


;; The Nd ranges.
;;
;; ...
;; 0660;ARABIC-INDIC DIGIT ZERO;Nd;0;AN;;0;0;0;N;;;;;
;; 0661;ARABIC-INDIC DIGIT ONE;Nd;0;AN;;1;1;1;N;;;;;
;; 0662;ARABIC-INDIC DIGIT TWO;Nd;0;AN;;2;2;2;N;;;;;
;; 0663;ARABIC-INDIC DIGIT THREE;Nd;0;AN;;3;3;3;N;;;;;
;; 0664;ARABIC-INDIC DIGIT FOUR;Nd;0;AN;;4;4;4;N;;;;;
;; 0665;ARABIC-INDIC DIGIT FIVE;Nd;0;AN;;5;5;5;N;;;;;
;; 0666;ARABIC-INDIC DIGIT SIX;Nd;0;AN;;6;6;6;N;;;;;
;; 0667;ARABIC-INDIC DIGIT SEVEN;Nd;0;AN;;7;7;7;N;;;;;
;; 0668;ARABIC-INDIC DIGIT EIGHT;Nd;0;AN;;8;8;8;N;;;;;
;; 0669;ARABIC-INDIC DIGIT NINE;Nd;0;AN;;9;9;9;N;;;;;
;; ...
;;
;; =>  (... (1632 1641) ...)
(define (digit-ranges data)
  (map (cut take <> 2)
       (compress (map digit->columns (filter (cut of-category <> "Nd") data)))))

;;;
;;; Read the ground truth and generate C tables
;;;

(define (read-file dir name)
  (with-input-from-file (make-pathname dir name) read-lines))

(define (uncomment line)
  (let ((s (first (string-split line "#" #t))))
    (and (not (string=? s "")) s)))

(define (columns->row xs)
  (let ((xs (map (lambda (n) (conc "0x" (number->string n 16))) xs)))
    (conc "\t{ " (string-intersperse xs ", ") " },\n")))

;; Format ROWS (a list of lists) into a 2-dimensional C array NAME.
(define (emit-table name rows)
  (display #<#EOF
static const int #{name}[][#{(length (first rows))}] = {
#{(apply conc (map columns->row rows))}};

EOF
))

(define (emit dir)
  (let* ((unicode-data (filter-map uncomment (read-file dir "UnicodeData.txt")))
         (prop-list (filter-map uncomment (read-file dir "PropList.txt")))
         (derived-core (filter-map uncomment (read-file dir "DerivedCoreProperties.txt")))
         (case-folding (filter-map uncomment (read-file dir "CaseFolding.txt")))
         (data (lines->entries unicode-data))
         (folds (lines->folds case-folding)))
    (display #<<EOF
/* utf-tables.c - Unicode character tables for utf.c.
   Generated by scripts/mkunicodetables.scm; do not edit. */


EOF
)
    ;; R7RS 6.6
    ;;
    ;; (char-alphabetic? char)
    ;; (char-numeric? char)
    ;; (char-whitespace? char)
    ;; (char-upper-case? letter)
    ;; (char-lower-case? letter)
    ;;
    ;; These procedures return #t if their arguments are alphabetic, numeric,
    ;; whitespace, upper case, or lower case characters, respectively,
    ;; otherwise they return #f.
    ;;
    ;; Specifically, they must return #t when applied to characters with the
    ;; Unicode properties Alphabetic, Numeric Digit, White Space, Uppercase,
    ;; and Lowercase respectively, and #f when applied to any other Unicode
    ;; characters. Note that many Unicode characters are alphabetic but
    ;; neither upper nor lower case.
    (emit-table "alpha"
                (compress (append-map property->columns
                                      (filter (cut has-property <> "Alphabetic") derived-core))))
    (emit-table "upper"
                (compress (append-map property->columns
                                      (filter (cut has-property <> "Uppercase") derived-core))))
    (emit-table "lower"
                (compress (append-map property->columns
                                      (filter (cut has-property <> "Lowercase") derived-core))))
    (emit-table "space"
                (compress (append-map property->columns
                                      (filter (cut has-property <> "White_Space") prop-list))))
    (emit-table "digit" (digit-ranges data))

    ;; (char-downcase char)
    ;;
    ;; The char-downcase procedure, given an argument that is the uppercase
    ;; part of a Unicode casing pair, returns the lowercase member of the pair,
    ;; provided that both characters are supported by the Scheme
    ;; implementation. Note that language-sensitive casing pairs are not used.
    ;; If the argument is not the uppercase member of such a pair, it is
    ;; returned.
    (emit-table "lowermap"
                (compress (map (cut mapping->columns <> lower-map)
                               (filter (cut has-mapping <> lower-map) data))))

    ;; (char-upcase char)
    ;;
    ;; The char-upcase procedure, given an argument that is the lowercase part
    ;; of a Unicode casing pair, returns the uppercase member of the pair,
    ;; provided that both characters are supported by the Scheme
    ;; implementation. Note that language-sensitive casing pairs are not used.
    ;; If the argument is not the lowercase member of such a pair, it is
    ;; returned.
    ;;
    ;; Note that many Unicode lowercase characters do not have uppercase
    ;; equivalents.
    (emit-table "uppermap"
                (compress (map (cut mapping->columns <> upper-map)
                               (filter (cut has-mapping <> upper-map) data))))

    ;; (char-foldcase char)
    ;;
    ;; The char-foldcase procedure applies the Unicode simple case-folding
    ;; algorithm to its argument and returns the result. Note that
    ;; language-sensitive folding is not used. If the argument is an uppercase
    ;; letter, the result will be either a lowercase letter or the same as the
    ;; argument if the lowercase letter does not exist or is not supported by
    ;; the implementation. See UAX #29 [11] (part of the Unicode Standard) for
    ;; details.
    (emit-table "fold1" (map (cut folds->columns <> 1)
                             (filter (cut has-status <> '("C" "S")) folds)))

    ;; R7RS 6.7
    ;;
    ;; (string-foldcase string)
    ;;
    ;; These procedures apply the Unicode full string uppercasing,
    ;; lowercasing, and case-folding algorithms to their arguments and return
    ;; the result. In certain cases, the result differs in length from the
    ;; argument. If the result is equal to the argument in the sense of
    ;; string=?, the argument may be returned. Note that language-sensitive
    ;; mappings and foldings are not used.
    (emit-table "fold2" (map (cut folds->columns <> 3)
                             (filter (cut has-status <> '("F")) folds)))))

(when (pair? (command-line-arguments))
  (emit (first (command-line-arguments))))
