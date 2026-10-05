CHICKEN Scheme REPL in WebAssembly (wasm64)
===========================================

The unmodified CHICKEN interpreter (csi) and compiler (chicken), built
with Emscripten for 64-bit WebAssembly, running entirely in your browser.
This directory is a deployed copy of build-wasm/web from "make wasm".

Run it locally
  1. In this directory run:   python3 serve.py        (or: python3 serve.py 9000)
  2. Open http://localhost:8080/ if a browser does not open by itself.

  Any static web server works, e.g.  python3 -m http.server 8080
  Opening index.html directly (file://) does NOT work: browsers do not
  run workers or load .wasm files from file:// URLs.

Browser requirements
  64-bit WebAssembly (memory64) and standard WebAssembly exception
  handling (exnref): Chrome or Edge 137+, Firefox 134+.  Safari has no
  memory64 in a released version yet; the page says what is missing.
  For older browsers, build with  make wasm WASM_ARCH=wasm32
  (or WASM_SJLJ=wasm-legacy for Chrome and Edge 133 to 136).

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
  Settings      .csirc contents, extra csi options, theme.

Files
  index.html, repl.js, repl-worker.js, repl-driver.js,
  notebook.js, notebook-lib.js, nb-kernel.js       the page
  chicken-repl.js / .wasm         csi (+ all core libraries and import files)
  chicken-compiler.js / .wasm     the chicken compiler (Compile to C tab)
  compiler-worker.js, chicken.png, serve.py
