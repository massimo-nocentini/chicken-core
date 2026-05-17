;;; unicode tests, taken from Chibi

(import (chicken port) (chicken sort))
(import (chicken string) (chicken io))
(import (chicken bytevector))
(import (only (scheme base) write-string))

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
