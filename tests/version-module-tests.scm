(import (chicken eval)
        (chicken load)
        (chicken version))

(cond-expand
 (compiling
  (include "test.scm") )
 (else
  (load-relative "test.scm")))

(test-begin "chicken.version")

(test-assert "0 >= 0"                 (version>=? "0" "0"))
(test-assert "1 >= 0"                 (version>=? "1" "0"))
(test-assert "1.0 >= 0.0.1"           (version>=? "1.0" "0.0.1"))
(test-assert "1.0 >= 0.1.1"           (version>=? "1.0" "0.1.1"))
(test-assert "0.0.0 >= 0.0.0"         (version>=? "0.0.0" "0.0.0"))
(test-assert "0.0.0 >= 0.0"           (version>=? "0.0.0" "0.0"))
(test-assert "0.0.1 >= 0.0.0"         (version>=? "0.0.1" "0.0.0"))
(test-assert "1.0.0 >= 0.0.0"         (version>=? "1.0.0" "0.0.0"))
(test-assert "1.0.0 >= 0.0.0b"        (version>=? "1.0.0" "0.0.0b"))
(test-assert "1.0.0b >= 1.0.0"        (version>=? "1.0.0b" "1.0.0"))
(test-assert "1.0.0 >= 0.9.9-rc1"     (version>=? "1.0.0" "0.9.9-rc1"))
(test-assert "1.10 >= 1.09"           (version>=? "1.10" "1.09"))
(test-assert "1.10.2 >= 1.09.2"       (version>=? "1.10.2" "1.09.2"))

(test-end "chicken.version")

(test-exit)
