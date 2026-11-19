CHICKEN Scheme REPL in WebAssembly (wasm64 and wasm32)
======================================================

The unmodified CHICKEN interpreter (csi) and compiler (chicken), built
with Emscripten for WebAssembly, running entirely in your browser.
This directory is a deployed copy of build-wasm/web from
  make wasm WASM_WEB_ARCHS="wasm64 wasm32"
which has two builds: wasm64 (64-bit WebAssembly) beside index.html,
and wasm32 (32-bit) in wasm32/.  The page picks one when it loads.

Run it locally
  1. In this directory run:   python3 serve.py        (or: python3 serve.py 9000)
  2. Open http://localhost:8080/ if a browser does not open by itself.

  Any static web server works, e.g.  python3 -m http.server 8080
  Opening index.html directly (file://) does NOT work: browsers do not
  run workers or load .wasm files from file:// URLs.
  If the server sends a Content-Security-Policy header with
  repl-worker.js, it must allow script-src 'unsafe-eval' there for
  js-eval, JavaScript cells and ,js.  JavaScript run this way (and
  imported notebooks) can fetch from any site the server's policy
  allows.

Browser requirements
  wasm64 runs where the browser has 64-bit WebAssembly (memory64) and
  standard WebAssembly exception handling (exnref): Chrome or Edge
  137+, Firefox 134+.  Elsewhere the page runs wasm32, which needs the
  legacy exception handling instructions only: Chrome or Edge 95 to
  136, Firefox 100 to 133, Safari 15.4+ (not tested).  Without either
  the page says what is missing.  The header shows the build running.
  Firefox warns in the console that the legacy exception handling of
  wasm32 is deprecated; it still works.

  To ask for a build, add ?arch=wasm32 or ?arch=wasm64 to the URL
  (?arch=auto for the automatic choice), or choose it under "WebAssembly
  build" in the Settings (kept in the browser; the URL overrides it).
  A build the browser cannot run is ignored, with a note in the REPL.

Using it
  REPL tab      Enter evaluates, Shift+Enter adds a line, Esc or Ctrl+C
                stops a running evaluation, Ctrl+D ends input, Up/Down
                recall history.  ,? lists csi's toplevel commands.
  Upload        puts files in the REPL's home directory; load them with
                ,l name.scm  (plain-Scheme eggs can be loaded this way, and
                extensions compiled for this build with csc-wasm -shared:
                ,l name.so, or import them).
  Notebook      code and Markdown cells, Scheme syntax-highlighted; Shift+Enter
                runs a cell and moves on, Ctrl+Enter runs it in place, Run all /
                Stop / Restart kernel.  (import notebook) gives rich output:
                html, svg, markdown, table, image.  Saved in the browser;
                export (.scm, .json, or .html: a static page with no scripts)
                and import (.scm, .json) from More.
  JavaScript    (import js) and JavaScript cells in the notebook (key l),
                ,js in the REPL: they run the worker's JavaScript, which
                can call Scheme back: see the README.
  Compile to C  translates Scheme to C with the CHICKEN compiler itself.
  Saved         Ctrl+S or the Saved button (REPL), More → Save in this
                browser… / Saved notebooks… (Notebook): named copies in
                this browser; open, rename, delete, download, import.
  Settings      .csirc contents, extra csi options, theme, WebAssembly build.
  Packages      Settings → Packages… (or More → Packages… in the Notebook)
                loads packages of compiled extensions (eggs) made with
                "make wasm-package": type the URL of a package's
                manifest.json or directory, then import its modules in
                the REPL or a notebook.  Loaded packages are kept in the
                browser and load at every start; ?pkg=URL in the page's
                URL loads one too (asking first for another site's).
                The page may fetch packages from its own origin only,
                unless it was built with WASM_WEB_PACKAGE_ORIGINS.

Files
  index.html, repl.js, repl-worker.js, repl-driver.js, js-lexer.js,
  notebook.js, notebook-lib.js, nb-kernel.js,
  session-store.js, sessions.js,
  packages.js, package-check.js                    the page
  chicken-repl.js / .wasm         csi (+ all core libraries and import files);
                                  it loads compiled extensions (.so)
  chicken-compiler.js / .wasm     the chicken compiler (Compile to C tab)
  wasm32/                         the same two modules, built for wasm32
  compiler-worker.js, chicken.png, serve.py
