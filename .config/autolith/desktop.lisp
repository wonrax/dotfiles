(in-package #:autolith)

(unless (string= *autolith-version* "0.67.22")
  (error "The desktop adapter requires Autolith 0.67.22, found ~A." *autolith-version*))

;; The desktop reads through Localgroup. All input, including permission
;; decisions, still goes through the native controlling terminal attachment.
(defvar *desktop-localgroup-dispatch* (fdefinition 'localgroup--dispatch-request))
(defvar *desktop-terminal-event-p* (fdefinition 'localgroup--terminal-event-p))
(defvar *desktop-serve-attachment* (fdefinition 'localgroup--serve-attachment))
(defvar *desktop-controlling-attachment* nil)
(defvar *desktop-controller-lost* (fdefinition 'localgroup--controller-lost))
(defvar *desktop-picker-sequence* 0)
(defvar *desktop-authorization-detail* "")
(defvar *desktop-ask-command* (fdefinition 'application--ask-command-permission))
(defvar *desktop-ask-tool* (fdefinition 'application--ask-tool-permission))
(defvar *desktop-present* (fdefinition 'application-present))
(defvar *desktop-notices* (make-hash-table :weakness :key))
(defvar *desktop-notice-sequence* 0)
(defvar *desktop-terminal-select* (fdefinition 'terminal-ui-select))
(defvar *desktop-pickers* (make-hash-table :weakness :key))
(defvar *desktop-history* (make-hash-table :weakness :key))
(defvar *desktop-application-observer* (fdefinition 'application-agent-observer))
(defvar *desktop-observers* (make-hash-table :weakness :key))
(defvar *desktop-tails* (make-hash-table :weakness :key))
(defvar *desktop-lock* (sb-thread:make-mutex :name "Desktop stream"))

(defun desktop-record-delta (observer index text)
  (sb-thread:with-mutex (*desktop-lock*)
    (let ((application (gethash observer *desktop-observers*)))
      (when (and application
                 (or (zerop index) (application-reasoning-traces-p application)))
        (let* ((tails (or (gethash application *desktop-tails*)
                          (setf (gethash application *desktop-tails*) (vector "" ""))))
               (previous (aref tails index)))
          (setf (aref tails index)
                (concatenate 'string (subseq previous (max 0 (- (length previous) 16000)))
                             (subseq text (max 0 (- (length text) 16000))))))))))

(defmethod agent-observer-text :after ((observer callback-agent-observer) (text string))
  (desktop-record-delta observer 0 text))

(defmethod agent-observer-reasoning :after ((observer callback-agent-observer) (text string))
  (desktop-record-delta observer 1 text))

(defmethod agent-observer-status :after ((observer callback-agent-observer) status details)
  (declare (ignore details))
  (when (member status '(:provider-request-started :provider-retrying
                         :assistant-response-persisted :provider-request-completed))
    (sb-thread:with-mutex (*desktop-lock*)
      (let ((application (gethash observer *desktop-observers*)))
        (when application
          (remhash application *desktop-tails*))))))

(defun desktop-wrap-observer (application &rest arguments)
  (let ((observer (apply *desktop-application-observer* application arguments)))
    (sb-thread:with-mutex (*desktop-lock*)
      (setf (gethash observer *desktop-observers*) application))
    observer))

(define-application-command desktop-select-model-command
    (:name "/desktop-model"
     :argument "MODEL :provider PROVIDER"
     :description "Select a provider model from the desktop."
     :tip "The selection uses Autolith's normal model persistence."
     :busy-behavior :apply
     :terminal-behavior :shared
     :callable t)
    (application model &key provider)
  (application-set-model application model :provider provider)
  ':continue)

(defun desktop-models (application)
  (coerce (loop for item in (application--model-items application)
                collect (agentcomms:json-object
                         "id" (getf item :model) "provider" (getf item :provider)
                         "current" (if (getf item :current-p) t (argo:json-false))))
          'vector))

(defun desktop-commands ()
  (coerce (loop for command in (application-command-list)
                collect (agentcomms:json-object
                         "name" (application-command-name command)
                         "argument" (or (application-command-argument command) "")
                         "description" (application-command-description command)
                         "tip" (application-command-tip command)))
          'vector))

(defun desktop-settings (application)
  (let ((configuration (application-configuration application)))
    (coerce (loop for setting in (configuration-setting-list configuration)
                  when (setting-visible-p setting)
                    collect (acp-extension--setting-item application configuration setting))
            'vector)))

(define-application-command desktop-setting-command
    (:name "/desktop-setting"
     :argument "NAME VALUE"
     :description "Apply a desktop setting using Autolith's setting parser."
     :tip "Uses Autolith's normal runtime setting validation and persistence."
     :busy-behavior :apply
     :terminal-behavior :shared
     :callable t)
    (application name value)
  (let* ((configuration (application-configuration application))
         (setting (configuration-setting configuration (application--setting-name name))))
    (unless (and (setting-visible-p setting) (application--setting-adjustable-p setting))
      (error 'configuration-error :message "This setting is fixed by configuration."))
    (application-settings-command application name (setting-parse setting value configuration)))
  ':continue)

(defun desktop-generations (application)
  (coerce (loop for generation in (generation-list (application-configuration application))
                collect (agentcomms:json-object
                         "id" (generation-identifier generation)
                         "created" (application--calendar-description
                                    (generation-created-at generation))
                         "compatible" (if (generation-compatible-p generation)
                                          t (argo:json-false))
                         "source" (or (generation-git-commit generation) "")
                         "image" (or (generation-image-commit-identifier generation) "base")))
          'vector))

(defun desktop-ask-command (application command directory)
  (let ((*desktop-authorization-detail* (format nil "~A~%~%Working directory: ~A" command directory)))
    (funcall *desktop-ask-command* application command directory)))

(defun desktop-ask-tool (application tool arguments)
  (let ((*desktop-authorization-detail* (application--tool-authorization-request tool arguments)))
    (funcall *desktop-ask-tool* application tool arguments)))

(defun desktop-present (application entry &key identifier)
  (let ((presented (funcall *desktop-present* application entry :identifier identifier)))
    (when (and presented entry)
      (let ((text (if (stringp entry) entry (terminal--spans-text entry))))
        (unless (or (zerop (length text))
                    (and (search "AUTOLITH v" text)
                         (search "Sandboxing is no substitute for human oversight" text)))
          (sb-thread:with-mutex (*desktop-lock*)
            (let* ((conversation (application-conversation application))
                   (items (gethash conversation *desktop-notices*)))
              (setf (gethash conversation *desktop-notices*)
                    (cons (agentcomms:json-object
                           "id" (incf *desktop-notice-sequence*)
                           "text" (subseq text 0 (min 12000 (length text))))
                          (subseq items 0 (min 19 (length items))))))))))
    presented))

(defun desktop-choice-event-p (event)
  (typep event '(cons (eql :desktop-choice)
                     (cons (integer 1) (cons (integer -1 100000) null)))))

(defun desktop-terminal-event-p (event)
  (or (desktop-choice-event-p event)
      (funcall *desktop-terminal-event-p* event)))

(defun desktop-picker-options (items)
  (coerce (loop for item in items
                collect (agentcomms:json-object
                         "label" (getf item :name)
                         "detail" (let ((description (getf item :description)))
                                    (if (stringp description) description ""))))
          'vector))

(defun desktop-wrap-terminal-select (ui &rest arguments)
  (let* ((items (getf arguments :items))
         (token (sb-thread:with-mutex (*desktop-lock*)
                  (incf *desktop-picker-sequence*)))
         (on-event (getf arguments :on-event))
         (permission-p (eq (getf arguments :status-kind) ':permission)))
    (unless items
      (return-from desktop-wrap-terminal-select
        (apply *desktop-terminal-select* ui arguments)))
    (sb-thread:with-mutex (*desktop-lock*)
      (setf (gethash ui *desktop-pickers*)
            (agentcomms:json-object
             "id" token "title" (getf arguments :title "Choose an option")
             "permission" (if permission-p t (argo:json-false))
             "detail" *desktop-authorization-detail*
             "options" (desktop-picker-options items))))
    (unwind-protect
         (progn
           (setf (getf arguments :on-event)
                 (lambda (event selector)
                   (cond
                     ((desktop-choice-event-p event)
                      (destructuring-bind (kind id index) event
                        (declare (ignore kind))
                        (cond
                          ((/= id token) :continue)
                          ((= index -1) (list :cancel))
                          (t (let ((item (nth index items)))
                               (if item
                                   (list :accept (or (getf item :value) (getf item :name)))
                                   :continue))))))
                     (on-event
                      (let ((action (funcall on-event event selector)))
                        (when (and (consp action) (eq (first action) :replace))
                          (setf items (third action))
                          (sb-thread:with-mutex (*desktop-lock*)
                            (setf token (incf *desktop-picker-sequence*)
                                  (gethash ui *desktop-pickers*)
                                  (agentcomms:json-object
                                   "id" token "title" (second action)
                                   "permission" (if permission-p t (argo:json-false))
                                   "detail" *desktop-authorization-detail*
                                   "options" (desktop-picker-options items)))))
                        action)))))
           (apply *desktop-terminal-select* ui arguments))
      (sb-thread:with-mutex (*desktop-lock*)
        (remhash ui *desktop-pickers*)))))

(defun desktop-serve-attachment (session request &rest arguments)
  (let ((*desktop-controlling-attachment*
          (eq (getf (localgroup--request-field request :arguments) :desktop-p) t)))
    (apply *desktop-serve-attachment* session request arguments)))

(defun desktop-controller-lost (session)
  (if (or *desktop-controlling-attachment*
          (equal (uiop:getenv "AUTOLITH_KEEP_ALIVE") "1"))
      (progn (localgroup--mark-explicit-detach session) nil)
      (funcall *desktop-controller-lost* session)))

(defun desktop-tool-value (value)
  (let ((text (cond ((stringp value) value)
                    ((or (hash-table-p value) (vectorp value)) (json-encode value))
                    (t ""))))
    (subseq text 0 (min 8000 (length text)))))

(defun desktop-history (conversation)
  (unless (conversation-persisted-p conversation)
    (return-from desktop-history #()))
  (let* ((sequence (with-recursive-lock-held ((conversation-append-lock conversation))
                     (conversation-next-sequence conversation)))
         (cached (sb-thread:with-mutex (*desktop-lock*)
                   (gethash conversation *desktop-history*))))
    (when (and cached (= sequence (car cached)))
      (return-from desktop-history (cdr cached)))
    (let ((updates nil))
      (acp-replay-map-updates
       conversation
       (lambda (update)
         (push (agentcomms:json-object
                "type" (json-get update "sessionUpdate")
                "text" (let ((content (json-get update "content")))
                         (if (hash-table-p content)
                             (or (json-get content "text") "")
                             ""))
                "toolId" (or (json-get update "toolCallId") "")
                "title" (or (json-get update "title") "")
                "status" (or (json-get update "status") "")
                "input" (desktop-tool-value (json-get update "rawInput"))
                "output" (desktop-tool-value (json-get update "rawOutput")))
               updates)))
      (let ((recent (coerce (nreverse (subseq updates 0 (min 120 (length updates)))) 'vector)))
        (sb-thread:with-mutex (*desktop-lock*)
          (setf (gethash conversation *desktop-history*) (cons sequence recent)))
        recent))))

(defun desktop-snapshot (session application)
  (let* ((status (rest (localgroup-status-snapshot session)))
         (active (getf status :active-turn-p))
         (configuration (application-configuration application))
         (conversation (application-conversation application))
         (approval (sb-thread:with-mutex (*desktop-lock*)
                     (gethash (application-ui application) *desktop-pickers*)))
         (tails (sb-thread:with-mutex (*desktop-lock*)
                  (and active (copy-seq (or (gethash application *desktop-tails*) #("" "")))))))
    (agentcomms:json-object
     "sessionId" (getf status :session-id) "pid" (getf status :pid)
     "cwd" (getf status :cwd) "title" (or (getf status :conversation-title) "")
     "state" (string-downcase (symbol-name (getf status :state)))
     "booting" (if (terminal-ui-boot-waiting-p (application-ui application))
                   t (argo:json-false))
     "active" (if active t (argo:json-false))
     "queued" (getf status :queued-input-count)
     "steering" (getf status :steering-input-count)
     "tasks" (getf status :task-live-count)
     "permission" (string-downcase (symbol-name (getf status :permission-mode)))
     "effort" (let ((effort (getf status :reasoning-effort)))
                (if effort (string-downcase (princ-to-string effort)) ""))
     "model" (or (config :model configuration) "")
     "provider" (or (config :model-provider configuration) "")
     "updates" (desktop-history conversation) "approval" (if (and approval (eq (json-get approval "permission") t))
                                                   (json-get approval "title") "")
     "picker" (or approval :null)
     "notices" (sb-thread:with-mutex (*desktop-lock*)
                 (coerce (reverse (gethash conversation *desktop-notices*)) 'vector))
     "stream" (if tails (aref tails 0) "") "reasoning" (if tails (aref tails 1) ""))))

(defvar *desktop-shutdown-relays* (make-hash-table :weakness :key))
(defvar *desktop-handle-request* (fdefinition 'localgroup--handle-request))

(defun desktop-request-shutdown (session owner)
  (let ((expected (uiop:getenv "AUTOLITH_DESKTOP_OWNER")))
    (unless (and expected (stringp owner) (string= expected owner))
      (return-from desktop-request-shutdown
        (list :error :message "This session was not launched by this desktop instance."))))
  (let* ((terminal (localgroup--terminal session))
         (controller (application-input-controller (localgroup-session-application session)))
         (result
           (with-lock-held ((image-daemon:daemon-runtime-lock session))
             (cond
               ((gethash terminal *desktop-shutdown-relays*) :stopping)
               ((not (eq (image-daemon:relay-attachment-kind terminal) :detached)) :in-use)
               ((null controller) :unavailable)
               (t (setf (gethash terminal *desktop-shutdown-relays*) t)
                  :requested)))))
    (list :ok :shutdown result)))

(defun desktop-handle-request (session request &key socket stream)
  (if (and (eq (localgroup--request-field request :operation) :desktop-quit)
           (localgroup--valid-request-p request session))
      (let ((response (desktop-request-shutdown
                       session (getf (localgroup--request-field request :arguments) :owner))))
        (unwind-protect
             (daemon-write-packet stream response)
          (when (eq (getf (rest response) :shutdown) :requested)
            (application-input-controller--request-exit
             (application-input-controller (localgroup-session-application session))
             :localgroup-kill))))
      (funcall *desktop-handle-request* session request :socket socket :stream stream))
  nil)

(defun desktop-localgroup-dispatch (session request)
  (let ((operation (localgroup--request-field request :operation)))
    (if (and (member operation '(:desktop-snapshot :desktop-models :desktop-commands :desktop-generations :desktop-settings))
             (localgroup--valid-request-p request session))
        (handler-case
            (let ((application (localgroup-session-application session)))
              (list :ok :json
                    (json-encode (ecase operation
                                   (:desktop-snapshot (desktop-snapshot session application))
                                   (:desktop-models (desktop-models application))
                                   (:desktop-commands (desktop-commands))
                                   (:desktop-generations (desktop-generations application))
                                   (:desktop-settings (desktop-settings application))))))
          (error () (list :error :message "The desktop snapshot is temporarily unavailable.")))
        (funcall *desktop-localgroup-dispatch* session request))))

(setf (fdefinition 'localgroup--dispatch-request) #'desktop-localgroup-dispatch
      (fdefinition 'localgroup--handle-request) #'desktop-handle-request
      (fdefinition 'application-agent-observer) #'desktop-wrap-observer
      (fdefinition 'terminal-ui-select) #'desktop-wrap-terminal-select
      (fdefinition 'localgroup--terminal-event-p) #'desktop-terminal-event-p
      (fdefinition 'application--ask-command-permission) #'desktop-ask-command
      (fdefinition 'application--ask-tool-permission) #'desktop-ask-tool
      (fdefinition 'application-present) #'desktop-present
      (fdefinition 'localgroup--serve-attachment) #'desktop-serve-attachment
      (fdefinition 'localgroup--controller-lost) #'desktop-controller-lost)

;; On the pinned image-daemon, takeover can abortively close a buffered
;; SBCL stream while the old attachment's reader is blocked in READ-CHAR.
;; Shut the socket down to wake both threads. The daemon request thread
;; closes the socket and its cached stream after attachment cleanup joins
;; the writer.
(setf (fdefinition 'image-daemon::attachment--close-stream)
      #'image-daemon::attachment--shutdown-socket)

(defvar *desktop-daemon-close-attachment* (fdefinition 'image-daemon:attachment-close))

(defun desktop-close-attachment (attachment)
  ;; Takeover already owns the runtime mutex shared by the old attachment.
  ;; Wake its request thread and let that thread perform ordinary cleanup.
  (if (sb-thread:holding-mutex-p (image-daemon::attachment-transport-lock attachment))
      (unless (image-daemon::attachment-socket-shutdown-p attachment)
        (setf (image-daemon::attachment-socket-shutdown-p attachment) t)
        (ignore-errors
          (sb-bsd-sockets:socket-shutdown
           (image-daemon::attachment-socket attachment) :direction :io)))
      (funcall *desktop-daemon-close-attachment* attachment))
  nil)

(setf (fdefinition 'image-daemon:attachment-close) #'desktop-close-attachment)

(defvar *desktop-relay-attach* (fdefinition 'image-daemon:relay-attach))

(defun desktop-relay-attach (transport attachment &rest arguments)
  (handler-case
      (if (gethash transport *desktop-shutdown-relays*)
          (progn
            (image-daemon:daemon-write-packet
             (image-daemon:attachment-stream attachment)
             (list :error :message "The desktop is shutting down this session."))
            nil)
          (apply *desktop-relay-attach* transport attachment arguments))
    (image-daemon:daemon-error (condition)
      ;; A busy controller is rejected before the handshake is queued.
      ;; Send the reason before the attachment cleanup shuts the socket down.
      (image-daemon:daemon-write-packet
       (image-daemon::attachment-stream attachment)
       (list :error :message (image-daemon:daemon-error-message condition)))
      nil)))

(setf (fdefinition 'image-daemon:relay-attach) #'desktop-relay-attach)
