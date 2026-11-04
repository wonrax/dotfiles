(in-package #:autolith)

;; Keep shared commands and reviewed Lisp customizations here.

;; Loaded from this file's directory. The MCP configuration parser has to accept
;; :deferred before the first mcp.sexp read, and user init runs at startup.
(let ((script (merge-pathnames
               "mcp-deferred.lisp"
               (uiop:pathname-directory-pathname *load-pathname*))))
  (when (uiop:file-exists-p script)
    (load script)))
