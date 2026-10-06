#!/usr/bin/env python3
"""Serve the CHICKEN WebAssembly REPL on http://localhost:8080/ (or the port given)."""
import http.server, socketserver, os, sys, webbrowser

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
os.chdir(os.path.dirname(os.path.abspath(__file__)))

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                      '.wasm': 'application/wasm', '.js': 'text/javascript'}

with socketserver.TCPServer(('127.0.0.1', port), Handler) as httpd:
    url = f'http://localhost:{port}/'
    print(f'CHICKEN REPL at {url}  (Ctrl-C to stop)')
    try: webbrowser.open(url)
    except Exception: pass
    try: httpd.serve_forever()
    except KeyboardInterrupt: pass
