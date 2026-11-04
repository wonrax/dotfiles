(in-package #:autolith)

;; Keep shared commands and reviewed Lisp customizations here.

;; Loaded from this file's directory. The MCP configuration parser has to accept
;; :deferred before the first mcp.sexp read, and user init runs at startup.
(let ((script (merge-pathnames
               "mcp-deferred.lisp"
               (uiop:pathname-directory-pathname *load-pathname*))))
  (when (uiop:file-exists-p script)
    (load script)))

;; Autolith only collects AGENTS.md along the workspace path. Put the shared
;; user file at the head of that chain so it applies in every workspace and a
;; workspace AGENTS.md refines it.
(-> system-prompt--instruction-paths (pathname) list)
(defun system-prompt--instruction-paths (working-directory)
  "Return AGENTS.md paths from the shared user root and the project root down
  to WORKING-DIRECTORY."
  (let* ((root   (workspace-project-root working-directory))
         (shared (merge-pathnames ".agents/AGENTS.md"
                                  (user-homedir-pathname)))
         (walked
           (let ((directories
                   (loop for directory = working-directory
                           then (uiop:pathname-parent-directory-pathname
                                 directory)
                         repeat *workspace-project-depth-limit*
                         collect directory
                         until (or (equal directory root)
                                   (equal directory
                                          (uiop:pathname-parent-directory-pathname
                                           directory))))))
             (loop for directory in (reverse directories)
                   for path = (merge-pathnames "AGENTS.md" directory)
                   when (uiop:file-exists-p path)
                     collect path))))
    (remove-duplicates
     (if (uiop:file-exists-p shared)
         (cons shared walked)
         walked)
     :test #'string=
     :key  #'namestring)))
