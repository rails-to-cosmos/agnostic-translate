;;; agnostic-translate.el --- multi-language translation  -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Dmitry Akatov
;; Author: Dmitry Akatov <dmitry.akatov@protonmail.com>
;; URL: https://github.com/rails-to-cosmos/agnostic-translate
;; Package-Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4"))
;; Keywords: convenience, i18n

;;; Commentary:
;;
;; Translate text into multiple languages at once using an LLM backend.
;; Auto-detects the source language from the input and translates into
;; every other language in a configurable list (seeded from system locale
;; and keyboard layouts).
;;
;; Results appear in an animated child-frame popup with easy copy-paste
;; and a persistent history.  Language list is managed via a transient
;; menu and survives restarts through `customize'.
;;
;; Requires `claude' CLI (https://docs.anthropic.com/en/docs/claude-cli)
;; on PATH.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'ansi-color)

(declare-function face-remap-remove-relative "face-remap")

;;; Customization

(defgroup agnostic-translate nil
  "LLM-powered translation."
  :group 'tools
  :prefix "agnostic-translate-")

(defconst agnostic-translate--locale-map
  '(("en" . "English") ("ru" . "Russian") ("de" . "German")
    ("fr" . "French")  ("es" . "Spanish") ("it" . "Italian")
    ("pt" . "Portuguese") ("ja" . "Japanese") ("zh" . "Chinese")
    ("ko" . "Korean")  ("ar" . "Arabic")  ("hi" . "Hindi")
    ("nl" . "Dutch")   ("pl" . "Polish")  ("tr" . "Turkish")
    ("uk" . "Ukrainian") ("cs" . "Czech") ("sv" . "Swedish")
    ("us" . "English") ("gb" . "English") ("br" . "Portuguese")
    ("ua" . "Ukrainian") ("cz" . "Czech") ("se" . "Swedish")
    ("jp" . "Japanese"))
  "Map locale/XKB codes to language names.")

(defun agnostic-translate--detect-languages ()
  "Derive a language list from system locale and X11 keyboard layouts."
  (let (codes)
    (when-let ((lang (or (getenv "LANG") (getenv "LC_ALL") (getenv "LANGUAGE"))))
      (when (string-match "\\`\\([a-z][a-z]\\)" lang)
        (cl-pushnew (match-string 1 lang) codes :test #'string=)))
    (with-temp-buffer
      (when (zerop (or (ignore-errors
                        (call-process "setxkbmap" nil t nil "-query"))
                       1))
        (goto-char (point-min))
        (when (re-search-forward "^layout:\\s-*\\(.+\\)" nil t)
          (dolist (code (split-string (match-string 1) "[, ]+" t))
            (cl-pushnew code codes :test #'string=)))))
    (let ((langs (cl-remove-duplicates
                  (delq nil (mapcar (lambda (c)
                                     (cdr (assoc c agnostic-translate--locale-map)))
                                   codes))
                  :test #'string=)))
      (or langs '("English")))))

(defcustom agnostic-translate-languages (agnostic-translate--detect-languages)
  "List of languages the user works with.
When translating, the source language is auto-detected and the text
is translated into every other language in this list.
Initialized from system locale and keyboard layouts."
  :type '(repeat string)
  :group 'agnostic-translate)

(defcustom agnostic-translate-model nil
  "Model passed to claude as `--model'.
Nil means use claude's default."
  :type '(choice (const :tag "Default" nil)
                 (string :tag "Model name"))
  :group 'agnostic-translate)

(defconst agnostic-translate-all-languages
  '("English" "Russian" "German" "French" "Spanish" "Italian"
    "Portuguese" "Japanese" "Chinese" "Korean" "Arabic" "Hindi"
    "Dutch" "Polish" "Turkish" "Ukrainian" "Czech" "Swedish")
  "All languages offered when adding to the active list.")

(defcustom agnostic-translate-frame-size '(80 . 20)
  "Target (COLS . ROWS) for the translation popup."
  :type '(cons integer integer)
  :group 'agnostic-translate)

(defcustom agnostic-translate-bubble-steps 8
  "Number of animation frames for the popup grow effect."
  :type 'integer
  :group 'agnostic-translate)

(defcustom agnostic-translate-bubble-interval 0.018
  "Seconds between animation steps."
  :type 'number
  :group 'agnostic-translate)

;;; Faces

(defface agnostic-translate-frame-face
  '((((background dark))
     :background "#2a2a3a" :foreground "#e6e6ee")
    (t :background "#fff8e6" :foreground "#1a1a1a"))
  "Default text and background for the translation popup."
  :group 'agnostic-translate)

(defface agnostic-translate-frame-border-face
  '((((background dark)) :background "#9ece6a")
    (t :background "#40a02b"))
  "Border color for the translation popup."
  :group 'agnostic-translate)

(defface agnostic-translate-header-face
  '((t :inherit header-line :slant italic))
  "Face for the popup header line."
  :group 'agnostic-translate)

(defface agnostic-translate-source-face
  '((t :inherit shadow))
  "Face for the source text echo."
  :group 'agnostic-translate)

(defface agnostic-translate-result-face
  '((((background dark))  :foreground "#c0caf5" :weight bold)
    (((background light)) :foreground "#1e1e2e" :weight bold))
  "Face for the translated text."
  :group 'agnostic-translate)

(defface agnostic-translate-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for the animated thinking indicator."
  :group 'agnostic-translate)

(defface agnostic-translate-lang-face
  '((((background dark))  :foreground "#7aa2f7")
    (((background light)) :foreground "#5c7cfa"))
  "Face for language labels."
  :group 'agnostic-translate)

;;; Frame parameters

(defvar agnostic-translate-frame-parameters
  '((minibuffer . nil)
    (undecorated . t)
    (internal-border-width . 2)
    (child-frame-border-width . 1)
    (left-fringe . 8) (right-fringe . 8)
    (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0) (tool-bar-lines . 0) (tab-bar-lines . 0)
    (no-accept-focus . nil)
    (unsplittable . t)
    (no-other-frame . t)
    (cursor-type . box)
    (visibility . nil))
  "Frame parameters for the translation popup child frame.")

;;; State

(defvar agnostic-translate--frame nil
  "Currently visible translation child frame, or nil.")

(defvar agnostic-translate--history nil
  "List of past translations, newest first.
Each entry is a plist (:source :results :time).
:results is an alist ((LANG . TEXT) ...).")

(defvar-local agnostic-translate--face-cookie nil
  "Cookie from `face-remap-add-relative' for the popup buffer.")

(defvar-local agnostic-translate--process nil
  "Async `claude -p' process for this buffer.")

(defvar-local agnostic-translate--source-text nil
  "The source text being translated.")

(defvar-local agnostic-translate--result-start nil
  "Marker at the start of the translation output.")

(defvar-local agnostic-translate--thinking-overlay nil
  "Overlay for the thinking animation.")

(defvar-local agnostic-translate--thinking-timer nil
  "Timer driving the thinking animation.")

(defvar-local agnostic-translate--thinking-tick 0
  "Counter for the thinking dots animation.")

(defvar-local agnostic-translate--input-mode nil
  "Non-nil when the popup is in text-input mode (before sending).")

;;; Anchor / frame plumbing

(defun agnostic-translate--anchor-xy ()
  "Return pixel (X . Y) at point in the selected window's frame."
  (let* ((edges (window-inside-pixel-edges))
         (posn (posn-at-point))
         (xy (and posn (posn-x-y posn))))
    (if xy
        (cons (+ (nth 0 edges) (car xy))
              (+ (nth 1 edges) (cdr xy) (default-line-height)))
      (cons (nth 0 edges) (nth 1 edges)))))

(defun agnostic-translate--apply-styles (frame buf)
  "Apply faces to FRAME and BUF."
  (let ((bg (face-attribute 'agnostic-translate-frame-face :background nil 'default))
        (fg (face-attribute 'agnostic-translate-frame-face :foreground nil 'default))
        (bd (face-attribute 'agnostic-translate-frame-border-face :background nil 'default)))
    (when (stringp bg) (set-frame-parameter frame 'background-color bg))
    (when (stringp fg) (set-frame-parameter frame 'foreground-color fg))
    (dolist (face '(internal-border child-frame-border))
      (when (facep face)
        (set-face-background face (if (stringp bd) bd 'unspecified) frame)))
    (with-current-buffer buf
      (when agnostic-translate--face-cookie
        (face-remap-remove-relative agnostic-translate--face-cookie))
      (setq agnostic-translate--face-cookie
            (face-remap-add-relative 'default 'agnostic-translate-frame-face)))))

(defun agnostic-translate--make-frame (buf anchor)
  "Create the translation child frame showing BUF at ANCHOR."
  (let* ((parent (selected-frame))
         (params (append `((parent-frame . ,parent)
                           (left . ,(car anchor))
                           (top  . ,(cdr anchor))
                           (width . 1) (height . 1))
                         agnostic-translate-frame-parameters))
         (frame (make-frame params))
         (win (frame-selected-window frame)))
    (set-window-buffer win buf)
    (set-window-dedicated-p win t)
    (set-window-parameter win 'no-other-window t)
    (agnostic-translate--apply-styles frame buf)
    (make-frame-visible frame)
    frame))

(defun agnostic-translate--animate-frame (frame target-w target-h)
  "Grow FRAME from 1x1 to TARGET-W x TARGET-H."
  (let* ((i 0) (steps agnostic-translate-bubble-steps) timer)
    (setq timer
          (run-with-timer
           0 agnostic-translate-bubble-interval
           (lambda ()
             (cl-incf i)
             (cond
              ((not (frame-live-p frame))
               (cancel-timer timer))
              ((>= i steps)
               (set-frame-size frame target-w target-h)
               (select-frame-set-input-focus frame)
               (cancel-timer timer))
              (t
               (let ((k (/ (float i) steps)))
                 (set-frame-size frame
                                 (max 1 (round (* target-w k)))
                                 (max 1 (round (* target-h k))))))))))))

(defun agnostic-translate--close-frame ()
  "Delete the translation child frame."
  (when (and agnostic-translate--frame (frame-live-p agnostic-translate--frame))
    (delete-frame agnostic-translate--frame t))
  (setq agnostic-translate--frame nil))

;;; Thinking animation

(defun agnostic-translate--thinking-string (tick)
  "Return animated dots for TICK."
  (propertize (make-string (1+ (mod tick 3)) ?.)
              'face 'agnostic-translate-thinking-face))

(defun agnostic-translate--thinking-tick-fn (buf)
  "Advance thinking animation in BUF."
  (when (and (buffer-live-p buf)
             (overlayp (buffer-local-value 'agnostic-translate--thinking-overlay buf)))
    (with-current-buffer buf
      (cl-incf agnostic-translate--thinking-tick)
      (overlay-put agnostic-translate--thinking-overlay
                   'after-string
                   (agnostic-translate--thinking-string agnostic-translate--thinking-tick)))))

(defun agnostic-translate--start-thinking (buf)
  "Begin thinking animation in BUF."
  (with-current-buffer buf
    (agnostic-translate--stop-thinking buf)
    (let* ((pos (point-max))
           (ov (make-overlay pos pos buf t nil)))
      (overlay-put ov 'after-string (agnostic-translate--thinking-string 0))
      (setq-local agnostic-translate--thinking-overlay ov)
      (setq-local agnostic-translate--thinking-tick 0)
      (setq-local agnostic-translate--thinking-timer
                  (run-with-timer 0.4 0.4
                                  #'agnostic-translate--thinking-tick-fn buf)))))

(defun agnostic-translate--stop-thinking (buf)
  "Stop thinking animation in BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when (timerp agnostic-translate--thinking-timer)
        (cancel-timer agnostic-translate--thinking-timer))
      (setq-local agnostic-translate--thinking-timer nil)
      (when (overlayp agnostic-translate--thinking-overlay)
        (delete-overlay agnostic-translate--thinking-overlay))
      (setq-local agnostic-translate--thinking-overlay nil))))

;;; Process plumbing

(defun agnostic-translate--clean-chunk (chunk)
  "Strip ANSI/OSC/CR and stray control chars from CHUNK."
  (let* ((no-cr  (replace-regexp-in-string "\r" "" chunk))
         (no-osc (replace-regexp-in-string "\e\\][^\a]*\\(?:\a\\|\e\\\\\\)" "" no-cr))
         (no-csi (replace-regexp-in-string "\e\\[[?<>=]*[0-9;]*[a-zA-Z]" "" no-osc))
         (no-esc (replace-regexp-in-string "\e" "" no-csi))
         (result (ansi-color-apply no-esc)))
    (if (string-match-p "\\`[0-9[:space:]]*\\'" result) "" result)))

(defun agnostic-translate--filter (proc chunk)
  "Process filter: append cleaned CHUNK to PROC's buffer."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let ((inhibit-read-only t)
            (first-chunk (overlayp agnostic-translate--thinking-overlay))
            (was-at-end (= (point) (point-max)))
            (cleaned (agnostic-translate--clean-chunk chunk)))
        (when first-chunk
          (agnostic-translate--stop-thinking (current-buffer))
          (save-excursion
            (goto-char (point-max))
            (insert "\n")
            (setq-local agnostic-translate--result-start (point-marker))))
        (save-excursion
          (goto-char (point-max))
          (insert (propertize cleaned 'face 'agnostic-translate-result-face)))
        (when (or first-chunk was-at-end)
          (goto-char (point-max)))))))

(defun agnostic-translate--parse-results (raw)
  "Parse RAW output into an alist of (LANG . TEXT).
Expects lines like \"[Language]: translation text\"."
  (let (results current-lang current-lines)
    (dolist (line (split-string raw "\n"))
      (if (string-match "^\\[\\([^]]+\\)\\]:\\s-*\\(.*\\)" line)
          (progn
            (when current-lang
              (push (cons current-lang
                          (string-trim (mapconcat #'identity
                                                  (nreverse current-lines) "\n")))
                    results))
            (setq current-lang (match-string 1 line))
            (setq current-lines (list (match-string 2 line))))
        (when current-lang
          (push line current-lines))))
    (when current-lang
      (push (cons current-lang
                  (string-trim (mapconcat #'identity
                                          (nreverse current-lines) "\n")))
            results))
    (nreverse results)))

(defun agnostic-translate--sentinel (proc _event)
  "Process sentinel: update header, record history."
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (agnostic-translate--stop-thinking (current-buffer))
      (setq-local agnostic-translate--process nil)
      (let ((status (process-status proc))
            (inhibit-read-only t))
        (pcase status
          ('exit
           (let* ((raw (when (markerp agnostic-translate--result-start)
                         (string-trim
                          (buffer-substring-no-properties
                           agnostic-translate--result-start (point-max)))))
                  (results (when raw (agnostic-translate--parse-results raw))))
             (when (and raw (not (string-empty-p raw)))
               (push (list :source agnostic-translate--source-text
                           :results (or results (list (cons "?" raw)))
                           :time (format-time-string "%Y-%m-%d %H:%M"))
                     agnostic-translate--history)))
           (setq header-line-format
                 (propertize
                  " Translate  RET copy | C-c C-k close | n new | h history"
                  'face 'agnostic-translate-header-face)))
          ('signal
           (setq header-line-format
                 (propertize " Translate  (cancelled)"
                             'face 'agnostic-translate-header-face))))))))

(defun agnostic-translate--build-prompt (text langs)
  "Build a prompt to detect language and translate TEXT into LANGS."
  (format "Detect the language of the following text, then translate it into each of the other languages from this list: %s.
Skip the detected source language (do not repeat the original text).
Format each translation on its own line as:
[Language]: translation

Output ONLY the translations in that format, nothing else — no explanations, no source language label, no extra text.

Text to translate:
%s"
          (mapconcat #'identity langs ", ")
          text))

(defun agnostic-translate--spawn (buf text)
  "Spawn `claude -p' to translate TEXT into all target languages, output to BUF."
  (with-current-buffer buf
    (setq-local agnostic-translate--source-text text)
    (let ((inhibit-read-only t)
          (langs agnostic-translate-languages))
      (erase-buffer)
      (insert (propertize text 'face 'agnostic-translate-source-face))
      (insert "\n\n")
      (insert (propertize (format "[-> %s] " (mapconcat #'identity langs ", "))
                          'face 'agnostic-translate-lang-face)))
    (agnostic-translate--start-thinking buf)
    (setq header-line-format
          (propertize " Translate  (running...)"
                      'face 'agnostic-translate-header-face))
    (let* ((prompt (agnostic-translate--build-prompt text agnostic-translate-languages))
           (args (append (list "claude" "--output-format" "text")
                         (when agnostic-translate-model
                           (list "--model" agnostic-translate-model))
                         (list "-p" prompt)))
           (process-environment
            (append '("NO_COLOR=1" "CLICOLOR=0" "TERM=dumb")
                    process-environment))
           (proc (apply #'start-process "agnostic-translate" buf args)))
      (setq-local agnostic-translate--process proc)
      (set-process-filter   proc #'agnostic-translate--filter)
      (set-process-sentinel proc #'agnostic-translate--sentinel))))

;;; Major mode

(defvar agnostic-translate-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")     #'agnostic-translate-copy)
    (define-key map (kbd "C-c C-c") #'agnostic-translate-send)
    (define-key map (kbd "C-c C-k") #'agnostic-translate-close)
    (define-key map (kbd "q")       #'agnostic-translate-close)
    (define-key map (kbd "n")       #'agnostic-translate-new)
    (define-key map (kbd "h")       #'agnostic-translate-show-history)
    map)
  "Keymap for `agnostic-translate-mode'.")

(defvar agnostic-translate-input-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'agnostic-translate-send)
    (define-key map (kbd "C-c C-k") #'agnostic-translate-close)
    map)
  "Keymap active during text input in the translation popup.")

(define-derived-mode agnostic-translate-mode special-mode "Translate"
  "Major mode for the translation popup."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

;;; Commands

(defun agnostic-translate-copy ()
  "Copy the translation result to the kill ring."
  (interactive)
  (if (and (markerp agnostic-translate--result-start)
           (> (point-max) agnostic-translate--result-start))
      (let ((text (string-trim
                   (buffer-substring-no-properties
                    agnostic-translate--result-start (point-max)))))
        (kill-new text)
        (message "Copied: %s" (truncate-string-to-width text 60 nil nil "...")))
    (user-error "No translation result yet")))

(defun agnostic-translate-close ()
  "Cancel any running process and close the popup."
  (interactive)
  (when (process-live-p agnostic-translate--process)
    (kill-process agnostic-translate--process))
  (agnostic-translate--stop-thinking (current-buffer))
  (let ((buf (current-buffer)))
    (agnostic-translate--close-frame)
    (kill-buffer buf)))

(defun agnostic-translate-new ()
  "Start a new translation in the current popup."
  (interactive)
  (when (process-live-p agnostic-translate--process)
    (kill-process agnostic-translate--process)
    (setq-local agnostic-translate--process nil))
  (agnostic-translate--stop-thinking (current-buffer))
  (let ((inhibit-read-only t))
    (erase-buffer))
  (setq-local agnostic-translate--input-mode t)
  (setq buffer-read-only nil)
  (use-local-map agnostic-translate-input-mode-map)
  (setq header-line-format
        (propertize " Translate  C-c C-c send | C-c C-k close"
                    'face 'agnostic-translate-header-face)))

(defun agnostic-translate-send ()
  "Send the buffer text for translation."
  (interactive)
  (when (process-live-p agnostic-translate--process)
    (user-error "Translation in progress"))
  (let ((text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "Nothing to translate"))
    (setq-local agnostic-translate--input-mode nil)
    (setq buffer-read-only t)
    (use-local-map agnostic-translate-mode-map)
    (agnostic-translate--spawn (current-buffer) text)))

(defun agnostic-translate-show-history ()
  "Show translation history in a temporary buffer."
  (interactive)
  (unless agnostic-translate--history
    (user-error "No translation history"))
  (let ((buf (get-buffer-create "*translate-history*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (agnostic-translate-history-mode)
        (dolist (entry agnostic-translate--history)
          (insert (propertize (format "%s\n" (or (plist-get entry :time) ""))
                              'face 'agnostic-translate-lang-face))
          (insert (propertize (plist-get entry :source)
                              'face 'agnostic-translate-source-face))
          (insert "\n")
          (dolist (pair (plist-get entry :results))
            (let ((start (point)))
              (insert (propertize (format "[%s]: " (car pair))
                                  'face 'agnostic-translate-lang-face))
              (insert (propertize (cdr pair) 'face 'agnostic-translate-result-face))
              (put-text-property start (point) 'agnostic-translate-text (cdr pair))
              (insert "\n")))
          (insert "\n"))
        (goto-char (point-min))))
    (agnostic-translate--close-frame)
    (pop-to-buffer buf)))

;;; History mode

(defvar agnostic-translate-history-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agnostic-translate-history-copy)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `agnostic-translate-history-mode'.")

(define-derived-mode agnostic-translate-history-mode special-mode "Translate-History"
  "Mode for browsing translation history.
RET copies the translation at point."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq header-line-format
        (propertize " Translation History  RET copy | q close"
                    'face 'agnostic-translate-header-face)))

(defun agnostic-translate-history-copy ()
  "Copy the translation line at point."
  (interactive)
  (let ((text (get-text-property (point) 'agnostic-translate-text)))
    (if text
        (progn
          (kill-new text)
          (message "Copied: %s" (truncate-string-to-width text 60 nil nil "...")))
      (user-error "No translation at point"))))

;;; Entry points

;;;###autoload
(defun agnostic-translate (&optional text)
  "Translate TEXT (or active region, or prompt for input) in a popup.
Auto-detects source language and translates to all other languages
in `agnostic-translate-languages'."
  (interactive)
  (let* ((region-text (when (use-region-p)
                        (prog1 (buffer-substring-no-properties
                                (region-beginning) (region-end))
                          (deactivate-mark))))
         (source (or text region-text))
         (buf (generate-new-buffer "*translate*")))
    (with-current-buffer buf
      (agnostic-translate-mode))
    (agnostic-translate--close-frame)
    (if (display-graphic-p)
        (let* ((size agnostic-translate-frame-size)
               (anchor (agnostic-translate--anchor-xy))
               (frame (agnostic-translate--make-frame buf anchor)))
          (setq agnostic-translate--frame frame)
          (agnostic-translate--animate-frame frame (car size) (cdr size)))
      (pop-to-buffer buf))
    (with-current-buffer buf
      (if source
          (agnostic-translate--spawn buf source)
        (setq-local agnostic-translate--input-mode t)
        (setq buffer-read-only nil)
        (use-local-map agnostic-translate-input-mode-map)
        (setq header-line-format
              (propertize " Translate  C-c C-c send | C-c C-k close"
                          'face 'agnostic-translate-header-face))))))

;;; Transient

(defun agnostic-translate--language-choices ()
  "Return `agnostic-translate-all-languages'."
  agnostic-translate-all-languages)

;;;###autoload (autoload 'agnostic-translate-menu "agnostic-translate" nil t)

(transient-define-suffix agnostic-translate--menu-translate ()
  "Translate region or prompt for text."
  :description "Translate"
  (interactive)
  (call-interactively #'agnostic-translate))

(transient-define-suffix agnostic-translate--menu-add-lang ()
  "Add a language to the active list."
  :description "Add language"
  :transient t
  (interactive)
  (let ((lang (completing-read "Add language: "
                               (cl-set-difference agnostic-translate-all-languages
                                                  agnostic-translate-languages
                                                  :test #'string=)
                               nil t)))
    (when (and lang (not (member lang agnostic-translate-languages)))
      (customize-save-variable 'agnostic-translate-languages
                               (append agnostic-translate-languages (list lang)))
      (message "Added %s (saved)" lang))))

(transient-define-suffix agnostic-translate--menu-remove-lang ()
  "Remove a language from the active list."
  :description "Remove language"
  :transient t
  (interactive)
  (let ((lang (completing-read "Remove language: "
                               agnostic-translate-languages nil t)))
    (when lang
      (let ((new (cl-remove lang agnostic-translate-languages :test #'string=)))
        (when (< (length new) 2)
          (user-error "Need at least 2 languages"))
        (customize-save-variable 'agnostic-translate-languages new)
        (message "Removed %s (saved)" lang)))))

(transient-define-suffix agnostic-translate--menu-show-langs ()
  "Show the current language list."
  :description (lambda ()
                 (format "Languages: %s"
                         (mapconcat #'identity agnostic-translate-languages ", ")))
  (interactive)
  (message "Languages: %s"
           (mapconcat #'identity agnostic-translate-languages ", ")))

(transient-define-prefix agnostic-translate-menu ()
  "Translation commands."
  [["Translate"
    ("t" agnostic-translate--menu-translate)
    ("h" "History" agnostic-translate-show-history)]
   ["Languages"
    ("i" agnostic-translate--menu-show-langs)
    ("a" agnostic-translate--menu-add-lang)
    ("r" agnostic-translate--menu-remove-lang)]])

(provide 'agnostic-translate)

;;; agnostic-translate.el ends here
