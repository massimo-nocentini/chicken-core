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
                ,l name.scm  (plain-Scheme eggs can be loaded this way).
  Notebook      code and Markdown cells; Shift+Enter runs a cell and moves on,
                Ctrl+Enter runs it in place, Run all / Stop / Restart kernel.
                (import notebook) gives rich output: html, svg, markdown,
                table, image.  Saved in the browser; export/import from More.
  Compile to C  translates Scheme to C with the CHICKEN compiler itself.
  Settings      .csirc contents, extra csi options, theme, WebAssembly build.

Files
  index.html, repl.js, repl-worker.js, repl-driver.js,
  notebook.js, notebook-lib.js, nb-kernel.js       the page
  chicken-repl.js / .wasm         csi (+ all core libraries and import files)
  chicken-compiler.js / .wasm     the chicken compiler (Compile to C tab)
  wasm32/                         the same two modules, built for wasm32
  compiler-worker.js, chicken.png, serve.py
