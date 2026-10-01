CHICKEN Scheme REPL in WebAssembly (wasm64)
===========================================

The unmodified CHICKEN interpreter (csi) and compiler (chicken), built
with Emscripten for 64-bit WebAssembly, running entirely in your browser.

Run it
  1. Unpack this archive.
  2. In this directory run:   python3 serve.py        (or: python3 serve.py 9000)
  3. Open http://localhost:8080/ if a browser does not open by itself.

  Any static web server works, e.g.  python3 -m http.server 8080
  Opening index.html directly (file://) does NOT work: browsers do not
  run workers or load .wasm files from file:// URLs.

Browser requirements
  64-bit WebAssembly (memory64): Chrome or Edge 133+, Firefox 134+.
  Safari has no memory64 in a released version yet; the page says so.

Using it
  REPL tab      Enter evaluates, Shift+Enter adds a line, Esc or Ctrl+C
                stops a running evaluation, Ctrl+D ends input, Up/Down
                recall history.  ,? lists csi's toplevel commands.
  Upload        puts files in the REPL's home directory; load them with
                ,l name.scm  (plain-Scheme eggs can be loaded this way).
  Compile to C  translates Scheme to C with the CHICKEN compiler itself.
  Settings      .csirc contents, extra csi options, theme.

Files
  index.html, repl.js, repl-worker.js, repl-driver.js   the page
  chicken-repl.js / .wasm         csi (+ all core libraries and import files)
  chicken-compiler.js / .wasm     the chicken compiler (Compile to C tab)
  compiler-worker.js, chicken.png, serve.py
