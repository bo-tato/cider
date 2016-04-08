;;; cider-eldoc.el --- eldoc support for Clojure -*- lexical-binding: t -*-

;; Copyright © 2012-2016 Tim King, Phil Hagelberg
;; Copyright © 2013-2016 Bozhidar Batsov, Artur Malabarba and CIDER contributors
;;
;; Author: Tim King <kingtim@gmail.com>
;;         Phil Hagelberg <technomancy@gmail.com>
;;         Bozhidar Batsov <bozhidar@batsov.com>
;;         Artur Malabarba <bruce.connor.am@gmail.com>
;;         Hugo Duncan <hugo@hugoduncan.org>
;;         Steve Purcell <steve@sanityinc.com>

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; eldoc support for Clojure.

;;; Code:

(require 'cider-client)
(require 'cider-common) ; for cider-symbol-at-point
(require 'cider-compat)
(require 'cider-util)

(require 'seq)

(require 'eldoc)

(defvar cider-extra-eldoc-commands '("yas-expand")
  "Extra commands to be added to eldoc's safe commands list.")

(defvar cider-eldoc-max-num-sexps-to-skip 30
  "The maximum number of sexps to skip while searching the beginning of current sexp.")

(defvar-local cider-eldoc-last-symbol nil
  "The eldoc information for the last symbol we checked.")

(defun cider-eldoc-format-thing (ns symbol thing)
  "Format the eldoc subject defined by NS, SYMBOL and THING.
Normally NS and SYMBOL are used, but when empty we fallback
to THING (e.g. for Java methods)."
  (if (and ns (not (string= ns "")))
      (format "%s/%s"
              (cider-propertize ns 'ns)
              (cider-propertize symbol 'var))
    (cider-propertize thing 'var)))

(defun cider-highlight-args (arglist pos)
  "Format the the function ARGLIST for eldoc.
POS is the index of the currently highlighted argument."
  (let* ((rest-pos (cider--find-rest-args-position arglist))
         (i 0))
    (mapconcat
     (lambda (arg)
       (let ((argstr (format "%s" arg)))
         (if (string= arg "&")
             argstr
           (prog1
               (if (or (= (1+ i) pos)
                       (and rest-pos
                            (> (+ 1 i) rest-pos)
                            (> pos rest-pos)))
                   (propertize argstr 'face
                               'eldoc-highlight-function-argument)
                 argstr)
             (setq i (1+ i)))))) arglist " ")))

(defun cider--find-rest-args-position (arglist)
  "Find the position of & in the ARGLIST vector."
  (seq-position arglist "&"))

(defun cider-highlight-arglist (arglist pos)
  "Format the ARGLIST for eldoc.
POS is the index of the argument to highlight."
  (concat "[" (cider-highlight-args arglist pos) "]"))

(defun cider-eldoc-format-arglist (arglist pos)
  "Format all the ARGLIST for eldoc.
POS is the index of current argument."
  (concat "("
          (mapconcat (lambda (args) (cider-highlight-arglist args pos))
                     arglist
                     " ")
          ")"))

(defun cider-eldoc-beginning-of-sexp ()
  "Move to the beginning of current sexp.

Return the number of nested sexp the point was over or after.  Return nil
if the maximum number of sexps to skip is exceeded."
  (let ((parse-sexp-ignore-comments t)
        (num-skipped-sexps 0))
    (condition-case _
        (progn
          ;; First account for the case the point is directly over a
          ;; beginning of a nested sexp.
          (condition-case _
              (let ((p (point)))
                (forward-sexp -1)
                (forward-sexp 1)
                (when (< (point) p)
                  (setq num-skipped-sexps 1)))
            (error))
          (while
              (let ((p (point)))
                (forward-sexp -1)
                (when (< (point) p)
                  (setq num-skipped-sexps
                        (unless (and cider-eldoc-max-num-sexps-to-skip
                                     (>= num-skipped-sexps
                                         cider-eldoc-max-num-sexps-to-skip))
                          ;; Without the above guard,
                          ;; `cider-eldoc-beginning-of-sexp' could traverse the
                          ;; whole buffer when the point is not within a
                          ;; list. This behavior is problematic especially with
                          ;; a buffer containing a large number of
                          ;; non-expressions like a REPL buffer.
                          (1+ num-skipped-sexps)))))))
      (error))
    num-skipped-sexps))

(defun cider-eldoc-info-in-current-sexp ()
  "Return a list of the current sexp and the current argument index."
  (save-excursion
    (when-let ((beginning-of-sexp (cider-eldoc-beginning-of-sexp))
               (argument-index (1- beginning-of-sexp)))
      ;; If we are at the beginning of function name, this will be -1.
      (when (< argument-index 0)
        (setq argument-index 0))
      ;; Don't do anything if current word is inside a string, vector,
      ;; hash or set literal.
      (if (member (or (char-after (1- (point))) 0) '(?\" ?\{ ?\[))
          nil
        (list (cider-symbol-at-point) argument-index)))))

(defun cider-eldoc-info (thing)
  "Return the info for THING.
This includes the arglist and ns and symbol name (if available)."
  ;; a dirty hack to handle the keywords used by the ns macro
  (let ((thing (pcase thing
                 (":import" "clojure.core/import")
                 (":refer-clojure" "clojure.core/refer-clojure")
                 (":use" "clojure.core/use")
                 (":refer" "clojure.core/refer")
                 (_ thing))))
    (when (and (cider-nrepl-op-supported-p "eldoc")
               thing
               ;; ignore empty strings
               (not (string= thing ""))
               ;; ignore strings
               (not (string-prefix-p "\"" thing))
               ;; ignore regular expressions
               (not (string-prefix-p "#" thing))
               ;; ignore chars
               (not (string-prefix-p "\\" thing))
               ;; ignore numbers
               (not (string-match-p "^[0-9]" thing)))
      ;; check if we can used the cached eldoc info
      (cond
       ;; handle keywords for map access
       ((string-prefix-p ":" thing) (list nil thing '(("map") ("map" "not-found"))))
       ;; handle Classname. by displaying the eldoc for new
       ((string-match-p "^[A-Z].+\\.$" thing) (list nil thing '(("args*"))))
       ;; generic case
       (t (if (equal thing (car cider-eldoc-last-symbol))
              (cdr cider-eldoc-last-symbol)
            (when-let ((eldoc-info (cider-sync-request:eldoc thing)))
              (let ((arglist (nrepl-dict-get eldoc-info "eldoc"))
                    (ns (nrepl-dict-get eldoc-info "ns"))
                    (symbol (nrepl-dict-get eldoc-info "name")))
                ;; middleware eldoc lookups are expensive, so we
                ;; cache the last lookup.  This eliminates the need
                ;; for extra middleware requests within the same sexp.
                (setq cider-eldoc-last-symbol (list thing ns symbol arglist))
                (list ns symbol arglist)))))))))

(defun cider-eldoc ()
  "Backend function for eldoc to show argument list in the echo area."
  (when (and (cider-connected-p)
             ;; don't clobber an error message in the minibuffer
             (not (member last-command '(next-error previous-error))))
    (let* ((sexp-info (cider-eldoc-info-in-current-sexp))
           (thing (car sexp-info))
           (pos (cadr sexp-info))
           (eldoc-info (cider-eldoc-info thing))
           (ns (nth 0 eldoc-info))
           (symbol (nth 1 eldoc-info))
           (arglists (nth 2 eldoc-info)))
      (when eldoc-info
        (format "%s: %s"
                (cider-eldoc-format-thing ns symbol thing)
                (cider-eldoc-format-arglist arglists pos))))))

(defun cider-eldoc-setup ()
  "Setup eldoc in the current buffer.
eldoc mode has to be enabled for this to have any effect."
  (setq-local eldoc-documentation-function #'cider-eldoc)
  (apply #'eldoc-add-command cider-extra-eldoc-commands))

(define-obsolete-function-alias 'cider-turn-on-eldoc-mode 'eldoc-mode)

(provide 'cider-eldoc)

;;; cider-eldoc.el ends here
