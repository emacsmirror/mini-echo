;;; mini-echo.el --- Echo buffer status in minibuffer window -*- lexical-binding: t -*-

;; Copyright (C) 2023, 2024 liuyinz

;; Author: liuyinz <liuyinz95@gmail.com>
;; Maintainer: liuyinz <liuyinz95@gmail.com>
;; Version: 0.11.1
;; Package-Requires: ((emacs "29.1") (dash "2.19.1") (hide-mode-line "1.0.3"))
;; Keywords: frames
;; Homepage: https://github.com/liuyinz/mini-echo.el

;; This file is not a part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is not a part of GNU Emacs.

;;; Commentary:

;; Echo buffer status in minibuffer window

;;; Code:

(eval-when-compile
  (require 'eieio))

(require 'cl-lib)
(require 'subr-x)
(require 'face-remap)
(require 'pcase)

(require 'dash)
(require 'hide-mode-line)

(require 'mini-echo-segments)

(defgroup mini-echo nil
  "Echo buffer status in minibuffer window."
  :group 'mini-echo)

(defcustom mini-echo-default-segments
  '(:long ("major-mode" "shrink-path" "vcs" "buffer-position"
           "buffer-size" "flymake" "process" "selection-info"
           "narrow" "macro" "profiler" "repeat")
    :short ("buffer-name" "buffer-position" "process"
            "profiler" "selection-info" "narrow" "macro" "repeat"))
  "Plist of segments which are default to all major modes."
  :type '(plist :key-type symbol
                :options '(:long :short)
                :value-type (repeat string))
  :group 'mini-echo)

(defvar mini-echo--ruleset
  '((remove-five ("major-mode" . 0) ("buffer-position" . 0)
                 ("buffer-size" . 0) ("buffer-name" . 0)
                 ("shrink-path" . 0))
    (remove-size/pos ("buffer-position" . 0) ("buffer-size" . 0))
    (keep-path/name ("major-mode" . 0) ("buffer-position" . 0)
                    ("buffer-size" . 0))))

;; TODO support :only to simplify these options
(defcustom mini-echo-rules
  `((vterm-mode :both (,@(alist-get 'remove-five mini-echo--ruleset) ("ide" . 2)))
    (quickrun--mode :both (,@(alist-get 'remove-five mini-echo--ruleset) ("ide" . 2)))
    (nodejs-repl-mode :both (,@(alist-get 'remove-five mini-echo--ruleset)
                             ("process" . 0) ("ide" . 2)))
    (inferior-python-mode :both (,@(alist-get 'remove-five mini-echo--ruleset)
                                 ("ide" . 2)))
    (inferior-emacs-lisp-mode :both (,@(alist-get 'remove-five mini-echo--ruleset)
                                     ("process" . 0) ("ide" . 2)))
    (ibuffer-mode :both (,@(alist-get 'remove-five mini-echo--ruleset)))
    (xwidget-webkit-mode :both (,@(alist-get 'remove-size/pos mini-echo--ruleset)))
    (dired-mode :both (,@(alist-get 'keep-path/name mini-echo--ruleset)
                       ("dired" . 3)))
    (special-mode :both (("buffer-size" . 0))))
  "List of rules which are only take effect in some major mode.
The format is like:
 (MAJOR-MODE :both  ((SEGMENT . POSITION) ...))
             :long  ((SEGMENT . POSITION) ...))
             :short ((SEGMENT . POSITION) ...)).
:both would setup for both long and short style, :long and :short have higher
priority over :both.
If Emacs version >= 30, write rule for a parent mode will take effect in every
children modes.  Otherwise, write rule for every specific major mode instead."
  :type '(alist :key-type symbol
                :value-type (plist :key-type symbol
                                   :options '(:both :long :short)
                                   :value-type (alist :key-type string
                                                      :value-type integer)))
  :package-version '(mini-echo . "0.6.3")
  :group 'mini-echo)

(defcustom mini-echo-short-style-predicate
  #'mini-echo-minibuffer-width-lessp
  "Predicate to select short style segments."
  :type '(choice
          (const :tag "" mini-echo-minibuffer-width-lessp)
          function)
  :package-version '(mini-echo . "0.5.1")
  :group 'mini-echo)

(defcustom mini-echo-separator " "
  "String separator for mini echo segments info."
  :type 'string
  :package-version '(mini-echo . "0.5.0")
  :group 'mini-echo)

(defcustom mini-echo-ellipsis ".."
  "String used to abbreviate text in segments info."
  :type 'string
  :package-version '(mini-echo . "0.5.2")
  :group 'mini-echo)

(defcustom mini-echo-right-padding 0
  "Padding to append after mini echo info.
Set this to avoid truncation."
  :type 'number
  :group 'mini-echo)

(defcustom mini-echo-update-interval 0.3
  "Seconds between update mini echo segments."
  :type 'number
  :group 'mini-echo)

(defcustom mini-echo-window-divider-args '(t 1 1)
  "List of arguments to initialize command `window-divider-mode'.
Format is a list of three argument:
  (`window-divider-default-places'
   `window-divider-default-right-width'
   `window-divider-default-bottom-width')."
  :type '(symbol number number)
  :group 'mini-echo)

(defface mini-echo-minibuffer-window
  '((t :inherit default))
  "Face used to highlight the minibuffer window.")

(defconst mini-echo-managed-buffers
  '(" *Echo Area 0*" " *Echo Area 1*" " *Minibuf-0*"))

(defvar mini-echo-overlays nil)

(defvar-local mini-echo--remap-cookie nil)
(defvar mini-echo--valid-segments nil)
(defvar mini-echo--default-segments nil)
(defvar mini-echo--toggled-segments nil)
(defvar mini-echo--rules nil)
(defvar mini-echo--info-last-build nil)


;;; Segments functions

(defun mini-echo-segment-valid-p (segment)
  "Return non-nil if SEGMENT is valid."
  (member segment mini-echo--valid-segments))

(defun mini-echo-merge-segments (rule style)
  "Return new segments list which combine default and STYLE of RULE."
  (let* ((plst (cdr rule))
         (extra (--filter (mini-echo-segment-valid-p (car it))
                          (cl-remove-duplicates
                           (-concat (plist-get plst :both)
                                    (plist-get plst style))
                           :key #'car :test #'equal)))
         (default-uniq (-difference (plist-get mini-echo--default-segments style)
                                    (-map #'car extra)))
         (extra-active (--remove (= (cdr it) 0) extra))
         (index 1)
         result)
    ;; TODO use length sum as boundary
    (while (consp extra-active)
      (if-let ((match (rassoc index extra-active)))
          (progn
            (push (car match) result)
            (setq extra-active (delete match extra-active)))
        (and-let* ((head (pop default-uniq))) (push head result)))
      (cl-incf index))
    (-concat (reverse result) default-uniq)))

(defun mini-echo-ensure-segments ()
  "Ensure all predefined segments variable ready for mini echo."
  (setq mini-echo--valid-segments (-map #'car mini-echo-segment-alist))
  (setq mini-echo--default-segments
        (--map-when (not (keywordp it))
                    (-filter #'mini-echo-segment-valid-p it)
                    mini-echo-default-segments))
  (setq mini-echo--rules
        (--map (list (car it)
                     :long (mini-echo-merge-segments it :long)
                     :short (mini-echo-merge-segments it :short))
               mini-echo-rules)))

(defun mini-echo-get-segments (target)
  "Return list of segments according to TARGET."
  (pcase target
    ('valid mini-echo--valid-segments)
    ('selected (plist-get
                ;; parent mode rules take effect in children modes if possible
                (or (and (fboundp #'derived-mode-all-parents)
                         (car (--keep (alist-get it mini-echo--rules)
                                      (derived-mode-all-parents major-mode))))
                    (alist-get major-mode mini-echo--rules)
                    mini-echo--default-segments)
                (if (funcall mini-echo-short-style-predicate) :short :long)))
    ('current
     (let ((result (mini-echo-get-segments 'selected))
           extra)
       (--each mini-echo--toggled-segments
         (-let [(segment . enable) it]
           (if enable
               (unless (member segment result)
                 (push segment extra))
             (setq result (remove segment result)))))
       (-concat result extra)))
    ('no-current (-difference (mini-echo-get-segments 'valid)
                              (mini-echo-get-segments 'current)))
    ('toggle (cl-remove-duplicates
              (-concat (-map #'car mini-echo--toggled-segments)
                       (mini-echo-get-segments 'current)
                       (mini-echo-get-segments 'no-current))
              :test #'equal
              :from-end t))))

(defun mini-echo-concat-segments ()
  "Return concatenated information of selected segments."
  (-> (->> (mini-echo-get-segments 'current)
           (--map (with-slots (activate setup fetch update)
                      (alist-get it mini-echo-segment-alist nil nil #'string=)
                    (unless activate
                      (setq activate t)
                      (and setup (funcall setup))
                      (and update (funcall update)))
                    (funcall fetch)))
           (--filter (> (length it) 0))
           (reverse))
      (string-join mini-echo-separator)))

(defun mini-echo--toggle-completion ()
  "Return completion table for command mini echo toggle."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata (display-sort-function . ,#'identity))
      (complete-with-action
       action
       (let ((current (mini-echo-get-segments 'current)))
         (--map (propertize it 'face (if (member it current) 'success 'error))
                (mini-echo-get-segments 'toggle)))
       string pred))))


;;; Ui painting

(defun mini-echo-show-divider (&optional hide)
  "Show window divider when enable mini echo.
If optional arg HIDE is non-nil, disable the mode instead."
  (if hide
      (window-divider-mode -1)
    (-let [(window-divider-default-places
            window-divider-default-right-width
            window-divider-default-bottom-width)
           mini-echo-window-divider-args]
      (window-divider-mode 1))))

(defun mini-echo-fontify-minibuffer-window ()
  "Fontify whole window with user defined face attributes."
  (face-remap-add-relative 'default 'mini-echo-minibuffer-window))

(defun mini-echo-init-echo-area (&optional deinit)
  "Initialize echo area and minibuffer in mini echo.
If optional arg DEINIT is non-nil, remove all overlays."
  ;; delete old overlays by default
  (-each mini-echo-overlays #'delete-overlay)
  (setq mini-echo-overlays nil)
  (if deinit
      (progn
        (--each mini-echo-managed-buffers
          (with-current-buffer (get-buffer-create it)
            (when (minibufferp) (delete-minibuffer-contents))
            (face-remap-remove-relative mini-echo--remap-cookie)
            (setq-local mini-echo--remap-cookie nil)))
        (remove-hook 'minibuffer-inactive-mode-hook
                     #'mini-echo-fontify-minibuffer-window)
        (remove-hook 'minibuffer-setup-hook
                     #'mini-echo-fontify-minibuffer-window))
    (--each mini-echo-managed-buffers
      (with-current-buffer (get-buffer-create it)
        (and (minibufferp) (= (buffer-size) 0) (insert " "))
        (push (make-overlay (point-min) (point-max) nil nil t)
              mini-echo-overlays)
        (setq-local mini-echo--remap-cookie
                    (mini-echo-fontify-minibuffer-window))))
    ;; NOTE every time activating minibuffer would reset face,
    ;; so re-fontify when entering inactive-minibuffer-mode
    (add-hook 'minibuffer-inactive-mode-hook
              #'mini-echo-fontify-minibuffer-window)
    (add-hook 'minibuffer-setup-hook
              #'mini-echo-fontify-minibuffer-window)))

(defun mini-echo-minibuffer-width ()
  "Return width of minibuffer window in current non-child frame."
  (with-selected-frame (or (frame-parent (window-frame))
                           (window-frame))
    (window-width (minibuffer-window))))

(defun mini-echo-minibuffer-width-lessp ()
  "Return non-nil if current minibuffer window width less than 120."
  (< (mini-echo-minibuffer-width) 120))

(defun mini-echo-calculate-length (str)
  "Return length of STR.
On the gui, calculate length based on pixel, otherwise based on char."
  (if (display-graphic-p)
      (unwind-protect
          (ceiling (/ (string-pixel-width str) (float (frame-char-width))))
        (and-let* ((buf (get-buffer " *string-pixel-width*")))
          (kill-buffer buf)))
    (string-width str)))

(defun mini-echo-build-info ()
  "Build mini-echo information."
  (condition-case nil
      (if-let* ((win (get-buffer-window))
                ((window-live-p win)))
          (let* ((combined (mini-echo-concat-segments))
                 (padding (+ mini-echo-right-padding
                             (mini-echo-calculate-length combined)))
                 (prop `(space :align-to (- right-fringe ,padding))))
            (setq mini-echo--info-last-build
                  (concat (propertize " " 'cursor 1 'display prop) combined)))
        mini-echo--info-last-build)
    (format "mini-echo info building error")))

(defun mini-echo-update-overlays (&optional msg)
  "Update mini echo info in overlays according to MSG.
If MSG is nil, then use `current-message' instead."
  (when-let* (((not (active-minibuffer-window)))
              (msg (or msg (current-message) ""))
              (info (mini-echo-build-info)))
    (--each mini-echo-overlays
      (overlay-put it 'after-string
                   (if (or (equal (buffer-name (overlay-buffer it))
                                  " *Minibuf-0*")
                           (> (- (mini-echo-minibuffer-width)
                                 (string-width info)
                                 (string-width msg))
                              0))
                       info "")))))

(defun mini-echo-update-overlays-before-message (&rest args)
  "Update mini echo info before print message.
ARGS is optional."
  (mini-echo-update-overlays (and (car args) (apply #'format-message args))))

(defun mini-echo-update-overlays-when-resized (&rest _)
  "Update mini echo info after resize frame size."
  (mini-echo-update-overlays))

(defun mini-echo-update ()
  "Update mini echo info in minibuf and echo area."
  (unless (active-minibuffer-window)
    ;; update echo area overlays after-string only if it's not empty
    (--each-while mini-echo-overlays
        (not (string-empty-p (overlay-get it 'after-string)))
      (overlay-put it 'after-string (mini-echo-build-info)))))


;;; Commands

;;;###autoload
(defun mini-echo-toggle (&optional reset)
  "Enable or disable selected segment temporarily.
If optional arg RESET is non-nil, clear all toggled segments."
  (interactive "P")
  (if (bound-and-true-p mini-echo-mode)
      (if reset
          (progn
            (setq mini-echo--toggled-segments nil)
            (message "Mini-echo-toggle: reset."))
        (when-let ((segment (completing-read
                             "Mini-echo toggle: "
                             (mini-echo--toggle-completion) nil t)))
          (setf (alist-get segment mini-echo--toggled-segments
                           nil nil #'string=)
                (if (member segment (mini-echo-get-segments 'current)) nil t))))
    (user-error "Please enable mini-echo-mode first")))


;;; Minor mode

;;;###autoload
(define-minor-mode mini-echo-mode
  "Minor mode to show buffer status in echo area."
  :group 'mini-echo
  :global t
  (if mini-echo-mode
      (progn
        (let ((hide-mode-line-excluded-modes nil))
          (global-hide-mode-line-mode 1))
        (mini-echo-ensure-segments)
        (mini-echo-show-divider)
        (mini-echo-init-echo-area)
        ;; FIXME sometimes update twice when switch from echo to minibuf
        (run-with-timer 0 mini-echo-update-interval #'mini-echo-update)
        (advice-add 'message :before #'mini-echo-update-overlays-before-message)
        (add-hook 'window-size-change-functions
                  #'mini-echo-update-overlays-when-resized))
    (global-hide-mode-line-mode -1)
    (mini-echo-show-divider 'hide)
    (mini-echo-init-echo-area 'deinit)
    (cancel-function-timers #'mini-echo-update)
    (advice-remove 'message #'mini-echo-update-overlays-before-message)
    (remove-hook 'window-size-change-functions
                 #'mini-echo-update-overlays-when-resized)))

(provide 'mini-echo)
;;; mini-echo.el ends here
