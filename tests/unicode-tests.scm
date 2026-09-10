;;; unicode tests, taken from Chibi

(import (chicken port) (chicken sort))
(import (chicken string) (chicken io))
(import (chicken bytevector))
(import (only (scheme base) write-string))
(import (only (scheme char) string-foldcase string-upcase string-downcase))

(include "test.scm")
                           
(test-begin "scheme")

(test-equal #\Р (string-ref "Русский" 0))
(test-equal #\и (string-ref "Русский" 5))
(test-equal #\й (string-ref "Русский" 6))

(test-equal 7 (string-length "Русский"))

(test-equal #\日 (string-ref "日本語" 0))
(test-equal #\本 (string-ref "日本語" 1))
(test-equal #\語 (string-ref "日本語" 2))

(test-equal 3 (string-length "日本語"))

(test-equal '(#\日 #\本 #\語) (string->list "日本語"))
(test-equal "日本語" (list->string '(#\日 #\本 #\語)))

(test-equal "日本" (substring "日本語" 0 2))
(test-equal "本語" (substring "日本語" 1 3))

(test-equal "日-語"
      (let ((s (substring "日本語" 0 3)))
        (string-set! s 1 #\-)
        s))

(test-equal "日本人"
      (let ((s (substring "日本語" 0 3)))
        (string-set! s 2 #\人)
        s))

(test-equal "字字字" (make-string 3 #\字))

(test-equal "字字字"
      (let ((s (make-string 3)))
        (string-fill! s #\字)
        s))

; tests from the utf8 egg:

(test-equal 2 (string-length "漢字"))

(test-equal 28450 (char->integer (string-ref "漢字" 0)))

(define str (string-copy "漢字"))

(test-equal "赤字" (begin (string-set! str 0 (string-ref "赤" 0)) str))

(test-equal "赤外" (begin (string-set! str 1 (string-ref "外" 0)) str))

(test-equal "赤x" (begin (string-set! str 1 #\x) str))

(test-equal "赤々" (begin (string-set! str 1 (string-ref "々" 0)) str))

(test-equal "文字列" (substring "文字列" 0))
(test-equal "字列" (substring "文字列" 1))
(test-equal "列" (substring "文字列" 2))
(test-equal "文" (substring "文字列" 0 1))
(test-equal "字" (substring "文字列" 1 2))
(test-equal "文字" (substring "文字列" 0 2))

(define *string* "文字列")
(define *list* '("文" "字" "列"))
(define *chars* '(25991 23383 21015))

(test-equal *chars* (map char->integer (string->list "文字列")))

(test-equal *list* (map string (map integer->char *chars*)))

(test-equal *string* (list->string (map integer->char '(25991 23383 21015))))

(test-equal "列列列" (make-string 3 (string-ref "列" 0)))

(test-equal "文文文" (let ((s (string-copy "abc"))) (string-fill! s (string-ref "文" 0)) s))

(test-equal (string-ref "ﾊ" 0) (with-input-from-string "全角ﾊﾝｶｸ"
                           (lambda () (read-char) (read-char) (read-char))))

(test-equal "個々" (with-output-to-string
              (lambda ()
                (write-char (string-ref "個" 0))
                (write-char (string-ref "々" 0)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; library

(test-equal "出力改行\n" (with-output-to-string
                   (lambda () (print "出" (string-ref "力" 0) "改行"))))

(test-equal "出力" (with-output-to-string
              (lambda () (print* "出" (string-ref "力" 0) ""))))

(test-equal "逆リスト→文字列" (reverse-list->string
                     (map (cut string-ref <> 0)
                          '("列" "字" "文" "→" "ト" "ス" "リ" "逆"))))

(test-error (utf8->string #u8(255 1 2)))
(test-equal "BC" (utf8->string #u8(65 66 67) 1 3))
(test-assert (bytes->string #u8(255 1 2)))
(test-equal (string-length (bytes->string #u8(255 1 2))) 3)

;; `end' was range-checked here but `start' never was.  A negative start
;; read behind the bytevector's data - (utf8->string #u8(65 66 67 68 69) -1)
;; used to answer "PABCDE", the P being the low byte of the bytevector's own
;; header - and a start past the end produced a negative length that reached
;; ##sys#make-bytevector, which segfaulted.  A non-fixnum start segfaulted too.
(test-error "utf8->string rejects a negative start"
            (utf8->string #u8(65 66 67 68 69) -1))
(test-error "utf8->string rejects a very negative start"
            (utf8->string #u8(65 66 67 68 69) -3))
(test-error "utf8->string rejects a start past the end"
            (utf8->string #u8(65 66 67 68 69) 6))
(test-error "utf8->string rejects a start past an explicit end"
            (utf8->string #u8(65 66 67 68 69) 4 2))
(test-error "utf8->string rejects a non-fixnum start"
            (utf8->string #u8(65 66 67) 'x))
(test-equal "utf8->string accepts start = length"
            (utf8->string #u8(65 66 67) 3) "")
(test-equal "utf8->string accepts start = end"
            (utf8->string #u8(65 66 67) 2 2) "")
(test-equal "utf8->string still decodes the whole range"
            (utf8->string #u8(65 66 67) 0 3) "ABC")
(test-equal "utf8->string still decodes multi-byte sequences"
            (utf8->string #u8(228 184 173 230 150 135)) "\x4e2d;\x6587;")
(test-equal "utf8->string still decodes a sub-range of multi-byte input"
            (utf8->string #u8(65 228 184 173 66) 1 4) "\x4e2d;")

;; bytes->string, nine lines below utf8->string in library.scm, had the same
;; hole: (bytes->string #u8(65 66 67 68 69) -1) answered "PABCDE" too.  A
;; start past the end already raised there, via a downstream check, so only
;; the negative side leaked.
(test-error "bytes->string rejects a negative start"
            (bytes->string #u8(65 66 67 68 69) -1))
(test-error "bytes->string rejects a very negative start"
            (bytes->string #u8(65 66 67 68 69) -3))
(test-error "bytes->string rejects a start past an explicit end"
            (bytes->string #u8(65 66 67 68 69) 4 2))
(test-equal "bytes->string accepts start = length"
            (bytes->string #u8(65 66 67) 3) "")
(test-equal "bytes->string accepts start = end"
            (bytes->string #u8(65 66 67) 2 2) "")
(test-equal "bytes->string still copies the whole range"
            (bytes->string #u8(65 66 67) 0 3) "ABC")

;; utf8->string now labels the copied bytes with the codepoint count that
;; C_utf_validate already computed, instead of rescanning them through
;; C_utf_range_length.  Pin that count down for every sequence length, for
;; sub-ranges, and for the empty range.
(test-equal "utf8->string counts 1-byte sequences"
            (string-length (utf8->string #u8(65 66 67))) 3)
(test-equal "utf8->string counts 2-byte sequences"
            (string-length (utf8->string #u8(195 169 195 168))) 2)
(test-equal "utf8->string counts 3-byte sequences"
            (string-length (utf8->string #u8(228 184 173 230 150 135))) 2)
(test-equal "utf8->string counts 4-byte sequences"
            (string-length (utf8->string #u8(240 159 152 128))) 1)
(test-equal "utf8->string counts mixed sequence lengths"
            (string-length (utf8->string #u8(65 195 169 228 184 173 240 159 152 128))) 4)
(test-equal "utf8->string counts a sub-range"
            (string-length (utf8->string #u8(65 195 169 228 184 173 240 159 152 128) 1 6)) 2)
(test-equal "utf8->string counts an empty sub-range"
            (string-length (utf8->string #u8(65 66 67) 1 1)) 0)
(test-equal "utf8->string counts an empty bytevector"
            (string-length (utf8->string #u8())) 0)
(test-equal "utf8->string round-trips 2000 4-byte characters"
            (utf8->string (string->utf8 (make-string 2000 (integer->char #x1f600))))
            (make-string 2000 (integer->char #x1f600)))
(test-equal "utf8->string round-trips a long ASCII string"
            (utf8->string (string->utf8 (make-string 20000 #\z)))
            (make-string 20000 #\z))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; case conversion buffer sizing

;; string-foldcase sized its scratch buffer at 2n bytes like -upcase and
;; -downcase, but folding is not a 1:1 codepoint mapping: 16 rows of utf.c's
;; `fold2' table expand one codepoint to three.  U+0390 and U+03B0 are the
;; two that reach a 3x *byte* expansion (two bytes in, six out), so a string
;; of them overran the buffer by half its length.
(test-equal "foldcase U+0390 -> 3 codepoints"
            (string-foldcase "\x390;") "\x3b9;\x308;\x301;")
(test-equal "foldcase U+03B0 -> 3 codepoints"
            (string-foldcase "\x3b0;") "\x3c5;\x308;\x301;")
(test-equal "foldcase U+1FE7 -> 3 codepoints"
            (string-foldcase "\x1fe7;") "\x3c5;\x308;\x342;")
(test-equal "foldcase U+FB03 -> ffi"
            (string-foldcase "\xfb03;") "ffi")
(test-equal "foldcase U+00DF -> ss"
            (string-foldcase "\xdf;") "ss")

(define (repeat-string s n)
  (with-output-to-string
    (lambda () (do ((i 0 (+ i 1))) ((= i n)) (write-string s)))))

(define (fold-repeatedly char n reps)   ; keep every result alive
  (let loop ((i 0) (acc '()))
    (if (= i reps)
        acc
        (loop (+ i 1) (cons (string-foldcase (make-string n char)) acc)))))

(define (all-string=? strings s)
  (let loop ((l strings))
    (or (null? l) (and (string=? (car l) s) (loop (cdr l))))))

;; Folding repeatedly and keeping every result alive is what turns the
;; overrun from latent into observable: each folded string claims 3n bytes
;; out of a 2n allocation, so the bytes past the allocation are handed out
;; again and rewritten under it.  Before the fix the 16000-character case
;; reported #f on every run, and a few thousand characters in a tighter
;; loop killed the runtime outright.
(test-assert "20 folds of 2000 x U+0390 kept alive are all intact"
             (all-string=? (fold-repeatedly (integer->char #x390) 2000 20)
                           (repeat-string "\x3b9;\x308;\x301;" 2000)))
(test-assert "10 folds of 8000 x U+0390 kept alive are all intact"
             (all-string=? (fold-repeatedly (integer->char #x390) 8000 10)
                           (repeat-string "\x3b9;\x308;\x301;" 8000)))
(test-assert "10 folds of 16000 x U+03B0 kept alive are all intact"
             (all-string=? (fold-repeatedly (integer->char #x3b0) 16000 10)
                           (repeat-string "\x3c5;\x308;\x301;" 16000)))

(test-equal "foldcase 4000 x U+0390 has 12000 codepoints"
            (string-length (string-foldcase (make-string 4000 (integer->char #x390))))
            12000)
(test-equal "foldcase 4000 x U+0390 is not corrupted"
            (string-foldcase (make-string 4000 (integer->char #x390)))
            (repeat-string "\x3b9;\x308;\x301;" 4000))
(test-equal "foldcase 4000 x U+03B0 is not corrupted"
            (string-foldcase (make-string 4000 (integer->char #x3b0)))
            (repeat-string "\x3c5;\x308;\x301;" 4000))
(test-equal "foldcase 4000 x U+FB03 is not corrupted"
            (string-foldcase (make-string 4000 (integer->char #xfb03)))
            (repeat-string "ffi" 4000))

;; -upcase and -downcase stay at 2n: both are 1:1 codepoint mappings and
;; their widest byte growth over the whole codepoint space is 1.5x, reached
;; by U+023A -> U+2C65 and U+023F -> U+2C7E (two bytes in, three out).
(test-equal "downcase U+023A grows from 2 to 3 bytes"
            (string-downcase "\x23a;") "\x2c65;")
(test-equal "upcase U+023F grows from 2 to 3 bytes"
            (string-upcase "\x23f;") "\x2c7e;")
(test-equal "downcase 4000 x U+023A is not corrupted"
            (string-downcase (make-string 4000 (integer->char #x23a)))
            (make-string 4000 (integer->char #x2c65)))
(test-equal "upcase 4000 x U+023F is not corrupted"
            (string-upcase (make-string 4000 (integer->char #x23f)))
            (make-string 4000 (integer->char #x2c7e)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; extras

(test-equal "这是" (with-input-from-string "这是中文" (cut read-string 2)))

(define s "abcdef")
(call-with-input-string "这是中文" (cut read-string! 2 s <> 2))
(test-equal "ab这是ef" s)
       
(define s "这是中文")
(call-with-input-string "abcd" (cut read-string! 1 s <> 2))
(test-equal "这是a文" s)
       
(test-equal "这是" (with-output-to-string (cut write-string "这是中文" (current-output-port) 0 2)))

(test-equal "我爱她" (conc (with-input-from-string "我爱你"
                      (cut read-token (lambda (c)
                                        (memv c (map (cut string-ref <> 0)
                                                     '("爱" "您" "我"))))))
                        "她"))

(test-equal '("第一" "第二" "第三") (string-chop "第一第二第三" 2))

(test-equal '("第一" "第二" "第三" "…") (string-chop "第一第二第三…" 2))

(test-equal '("a" "bc" "第" "f几") (string-split "a,bc、第,f几" ",、"))

(test-equal "THE QUICK BROWN FOX JUMPED OVER THE LAZY SLEEPING DOG"
    (string-translate "the quick brown fox jumped over the lazy sleeping dog"
                      "abcdefghijklmnopqrstuvwxyz"
                      "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
(test-equal ":foo:bar:baz" (string-translate "/foo/bar/baz" "/" ":"))
(test-equal "你爱我" (string-translate "我爱你" "我你" "你我"))
(test-equal "你爱我" (string-translate "我爱你" '(#\我 #\你) '(#\你 #\我)))
(test-equal "我你" (string-translate "我爱你" "爱"))
(test-equal "我你" (string-translate "我爱你" #\爱))

(test-assert (substring=? "日本語" "日本語"))
(test-assert (substring=? "日本語" "日本"))
(test-assert (substring=? "日本" "日本語"))
(test-assert (substring=? "日本語" "本語" 1))
(test-assert (substring=? "日本語" "本" 1 0 1))
(test-assert (substring=? "听说上海的东西很贵" "上海的东西很便宜" 2 0 5))

(test-equal 2 (substring-index "上海" "听说上海的东西很贵"))

;; case folding

(test-assert (string-ci=? "abc" "ABC"))
(test-assert (string-ci=? "Xῌηιx" "xηιῌX"))
(test-assert (string-ci=? "αβξ" "αβξ"))
(test-assert (string-ci=? "αβξ" "ΑΒΞ"))

;; Contributed by Anton Idukov:

(import (scheme char))

(test-equal "ru_RU(съешь ещё этих мягких французских булок, да выпей чаю.)"
            (utf8->string
              (string->utf8 "ru_RU(съешь ещё этих мягких французских булок, да выпей чаю.)")))


(test-equal "Привет, МИР!"
            (list->string (map integer->char (map char->integer (string->list "Привет, МИР!")))))


(test-equal "ПРИВЕТ, МИР!"
            (symbol->string
              (string->symbol
                (list->string
                  (map char-upcase (string->list "Привет, МИР!"))))))


(test-equal "DZIŚ JEST BARDZO GORĄCY DZIEŃ"
            (list->string
              (map char-upcase
                   (string->list
                     (list->string
                       (map char-downcase
                            (string->list "DZIŚ JEST BARDZO GORĄCY DZIEŃ")))))))


(test-equal 7
            (apply + (map digit-value
                '(#\3 #\x0664 #\x0AE6))))


(test-equal "ru_RU(съешь ещё этих мягких французских булок, да выпей чаю.)"
            (list->string
              (reverse
                (string->list
                  (list->string
                    (reverse
                      (string->list "ru_RU(съешь ещё этих мягких французских булок, да выпей чаю.)")))))))

(test-equal #t (string<? "ABCD" "ABCd" "ABcd"))
(test-equal #f (string-ci<? "ABCD" "ABCd" "ABcd"))

(test-equal #t (string<? "АБВГ" "АБВг" "АБвг"))
(test-equal #f (string-ci<? "АБВГ" "АБВг" "АБвг"))

(test-equal #t (string>? "АБвг" "АБВг" "АБВГ"))
(test-equal #f (string-ci>? "АБвг" "АБВг" "АБВГ"))

(test-equal #t (string<=? "ПРИВЕТ" "ПРИВЕТ" "ПРИвет"))
(test-equal #t (string-ci<=? "ПРИВЕТ" "ПРИВЕТ" "ПРИвет"))

(test-equal #t (string>=? "АБвг" "АБвг" "АБВг"))
(test-equal #t (string-ci>=? "АБвг" "АБвг" "АБВг"))

(test-equal '("ЭЭЭЭЭЭЭЭ" 8)
            (let ((s (make-string 8 #\newline)))
              (string-fill! s #\Э)
              (list s (string-length s))))


(test-error (string-fill "Hello" 4 #\x))

(test-end)

(test-exit)
