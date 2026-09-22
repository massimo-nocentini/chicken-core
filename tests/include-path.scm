(import (only (chicken platform) include-path))

(include "test.scm")

(test-assert "(include-path) default" (list? (include-path)))
(include-path (list "./nowhere"))
(test-equal "(include-path) changed" '("./nowhere") (include-path))
