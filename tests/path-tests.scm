(import (chicken pathname))

(define-syntax test
  (syntax-rules ()
    ((_ r x) (let ((y x)) (print y) (assert (equal? r y))))))

(test "/" (pathname-directory "/"))
(test "/" (pathname-directory "/abc"))
(test "abc" (pathname-directory "abc/"))
(test "abc" (pathname-directory "abc/def"))
(test "abc" (pathname-directory "abc/def.ghi"))
(test "abc" (pathname-directory "abc/.def.ghi"))
(test "abc" (pathname-directory "abc/.ghi"))
(test "/abc" (pathname-directory "/abc/"))
(test "/abc" (pathname-directory "/abc/def"))
(test "/abc" (pathname-directory "/abc/def.ghi"))
(test "/abc" (pathname-directory "/abc/.def.ghi"))
(test "/abc" (pathname-directory "/abc/.ghi"))
(test "q/abc" (pathname-directory "q/abc/"))
(test "q/abc" (pathname-directory "q/abc/def"))
(test "q/abc" (pathname-directory "q/abc/def.ghi"))
(test "q/abc" (pathname-directory "q/abc/.def.ghi"))
(test "q/abc" (pathname-directory "q/abc/.ghi"))

(test "." (normalize-pathname "" 'unix))
(test "." (normalize-pathname "" 'windows))
(test "/" (normalize-pathname "/" 'unix))
(test "/" (normalize-pathname "/." 'unix))
(test "/" (normalize-pathname "/./" 'unix))
(test "/" (normalize-pathname "/./." 'unix))
(test "." (normalize-pathname "./" 'unix))
(test "a" (normalize-pathname "./a"))
(test "a" (normalize-pathname ".///a"))
(test "a" (normalize-pathname "a"))
(test "a/" (normalize-pathname "a/" 'unix))
(test "a/b" (normalize-pathname "a/b" 'unix))
(test "a\\b" (normalize-pathname "a\\b" 'unix))
(test "a/b/" (normalize-pathname "a/b/" 'unix))
(test "a/b/" (normalize-pathname "a/b//" 'unix))
(test "a/b" (normalize-pathname "a//b" 'unix))
(test "/a/b" (normalize-pathname "/a//b" 'unix))
(test "/a/b" (normalize-pathname "///a//b" 'unix))
(test "c:a/b" (normalize-pathname "c:a/./b" 'windows))
(test "c:/a/b" (normalize-pathname "c:/a/./b" 'unix))
(test "c:a/b" (normalize-pathname "c:a/./b" 'windows))
(test "c:b" (normalize-pathname "c:a/../b" 'windows))
(test "c:/b" (normalize-pathname "c:/a/../b" 'windows))
(test "a/b" (normalize-pathname "a/./././b" 'unix))
(test "a/b" (normalize-pathname "a/b/c/d/../.." 'unix))
(test "a/b/" (normalize-pathname "a/b/c/d/../../" 'unix))
(test "../../foo" (normalize-pathname "../../foo" 'unix))
(test "c:/" (normalize-pathname "c:/" 'windows))
(test "c:/" (normalize-pathname "c:/." 'windows))
(test "c:/" (normalize-pathname "c:/./" 'windows))
(test "c:/" (normalize-pathname "c:/./." 'windows))

(test "~/foo" (normalize-pathname "~/foo" 'unix))
(test "c:~/foo" (normalize-pathname "c:~/foo" 'unix))
(test "c:~/foo" (normalize-pathname "c:~/foo" 'windows))

(assert (directory-null? "/.//"))
(assert (directory-null? ""))
(assert (not (directory-null? "//foo//")))

(test '(#f "/" (".")) (receive (decompose-directory "/.//")))

(if ##sys#windows-platform
    (test '(#f "/" #f) (receive (decompose-directory "///\\///")))
    (test '(#f "/" ("\\")) (receive (decompose-directory "///\\///"))))

(test '(#f "/" ("foo")) (receive (decompose-directory "//foo//")))
(test '(#f "/" ("foo" "bar")) (receive (decompose-directory "//foo//bar")))
(test '(#f #f (".")) (receive (decompose-directory ".//")))
(test '(#f #f ("." "foo")) (receive (decompose-directory ".//foo//")))
(test '(#f #f (" " "foo" "bar")) (receive (decompose-directory " //foo//bar")))
(test '(#f #f ("foo" "bar")) (receive (decompose-directory "foo//bar/")))

(test '(#f #f #f) (receive (decompose-pathname "")))
(test '("/" #f #f) (receive (decompose-pathname "/")))

(test '("/" "a" #f) (receive (decompose-pathname "/a")))

(test '("/" #f #f) (receive (decompose-pathname "///")))

(test '("/" "a" #f) (receive (decompose-pathname "///a")))

(test '("/a" "b" #f) (receive (decompose-pathname "/a/b")))

(test '("/a" "b" "c") (receive (decompose-pathname "/a/b.c")))

(test '("." "a" #f) (receive (decompose-pathname "./a")))

(test '("." "a" "b") (receive (decompose-pathname "./a.b")))

(test '("./a" "b" #f) (receive (decompose-pathname "./a/b")))

(test '(#f "a" #f) (receive (decompose-pathname "a")))
(test '(#f "a." #f) (receive (decompose-pathname "a.")))
(test '(#f ".a" #f) (receive (decompose-pathname ".a")))
(test '("a" "b" #f) (receive (decompose-pathname "a/b")))

(test '("a" "b" #f) (receive (decompose-pathname "a///b")))

(test '("a/b" "c" #f) (receive (decompose-pathname "a/b/c")))

(test '("a/b/c" #f #f) (receive (decompose-pathname "a/b/c/")))

(test '("a/b/c" #f #f) (receive (decompose-pathname "a/b/c///")))

(test '(#f "a" "b") (receive (decompose-pathname "a.b")))
(test '("a.b" #f #f) (receive (decompose-pathname "a.b/")))

(test '(#f "a.b" "c") (receive (decompose-pathname "a.b.c")))
(test '(#f "a." "b") (receive (decompose-pathname "a..b")))
(test '(#f "a.." "b") (receive (decompose-pathname "a...b")))
(test '("a." ".b" #f) (receive (decompose-pathname "a./.b")))

;; Multi-byte UTF-8: every position these return is a CODEPOINT index, so a
;; byte-oriented scan or compare would land inside a character and split it.
;; "é" is 2 bytes, "中" 3, "😀" 4, so byte length and codepoint
;; length differ by 1x, 2x and 3x here.

(test '(#f "é" #f) (receive (decompose-pathname "é")))
(test '(#f "é" "é") (receive (decompose-pathname "é.é")))
(test '(#f "ééé" "é") (receive (decompose-pathname "ééé.é")))
(test '(#f "é" "ééé") (receive (decompose-pathname "é.ééé")))
(test '("中" "文" "txt") (receive (decompose-pathname "中/文.txt")))
(test '("中文" "日本語" "拡張子") (receive (decompose-pathname "中文/日本語.拡張子")))
(test '("/é" "é" "é") (receive (decompose-pathname "/é/é.é")))
(test '("/путь" "файл" "текст") (receive (decompose-pathname "/путь/файл.текст")))
(test '("😀" "😀" "😀") (receive (decompose-pathname "😀/😀.😀")))
(test '("aéb" "céd" "eéf") (receive (decompose-pathname "aéb/céd.eéf")))

(test '(#f #f ("é")) (receive (decompose-directory "é")))
(test '(#f "/" ("éé")) (receive (decompose-directory "//éé//")))
(test '(#f #f ("中" "文")) (receive (decompose-directory "中/文")))
(test '(#f "/" ("😀" "x")) (receive (decompose-directory "/😀/x")))
(test '(#f #f ("é" "é")) (receive (decompose-directory "é//é/")))
(test '(#f "/" ("путь" "к" "файлу")) (receive (decompose-directory "/путь//к//файлу")))

(test "éé" (pathname-file "é/éé.あああ"))
(test "あああ" (pathname-extension "é/éé.あああ"))
(test "é" (pathname-directory "é/éé.あああ"))
(test "éé.あああ" (pathname-strip-directory "é/éé.あああ"))
(test "é/éé" (pathname-strip-extension "é/éé.あああ"))
(test "😀" (pathname-file "😀/😀.😀"))
(test "😀" (pathname-extension "😀/😀.😀"))
(test "😀" (pathname-directory "😀/😀.😀"))
(test "😀.😀" (pathname-strip-directory "😀/😀.😀"))
(test "😀/😀" (pathname-strip-extension "😀/😀.😀"))
(test "файл" (pathname-file "путь/файл.тек"))
(test "тек" (pathname-extension "путь/файл.тек"))
(test "путь" (pathname-directory "путь/файл.тек"))
(test "файл.тек" (pathname-strip-directory "путь/файл.тек"))
(test "путь/файл" (pathname-strip-extension "путь/файл.тек"))

;; The replace-* family rebuilds the pathname around one decomposed component;
;; a byte/codepoint mix-up shows up here as a truncated or mangled result.
(test "é/éé.х" (pathname-replace-extension "é/éé.あああ" "х"))
(test "😀/😀.тек" (pathname-replace-extension "😀/😀.😀" "тек"))
(test "中/文.日本語" (pathname-replace-extension "中/文.txt" "日本語"))
(test "é/х.あああ" (pathname-replace-file "é/éé.あああ" "х"))
(test "😀/тек.😀" (pathname-replace-file "😀/😀.😀" "тек"))
(test "путь/éé.あああ" (pathname-replace-directory "é/éé.あああ" "путь"))
(test "中文/😀.😀" (pathname-replace-directory "😀/😀.😀" "中文"))

       (test "x/y/z.q" (make-pathname "x/y" "z" "q"))
       (test "x/y/z.q" (make-pathname "x/y" "z.q"))
       (test "x/y/z.q" (make-pathname "x/y/" "z.q"))
       (test "x/y/z.q" (make-pathname "x/y/" "z.q"))
       (test "x/y\\/z.q" (make-pathname "x/y\\" "z.q"))
       (test "x//y/z.q" (make-pathname "x//y/" "z.q"))
       (test "x\\y/z.q" (make-pathname "x\\y" "z.q"))

(test 'error (handle-exceptions _ 'error (make-pathname '(#f) "foo")))

(test "/x/y/z" (make-pathname #f "/x/y/z"))
       (test "/x/y/z" (make-pathname "/" "x/y/z"))
       (test "/x/y/z" (make-pathname "/x" "/y/z"))
       (test "/x/y/z" (make-pathname '("/") "x/y/z"))
       (test "/x/y/z" (make-pathname '("/" "x") "y/z"))
       (test "/x/y/z" (make-pathname '("/x" "y") "z"))
       (test "/x/y/z/" (make-pathname '("/x" "y" "z") #f))
