;;; anonymize-region.el --- Reversible regex anonymization for regions -*- lexical-binding: t; -*-

;; Author: anonymize-region contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "26.1"))
;; Keywords: convenience, privacy, tools

;;; Commentary:

;; Mark a region and run `anonymize-region' to replace sensitive values with
;; placeholders such as Name1, Email1, Address1, or custom labels like game1.
;; Run `anonymize-region-restore' on returned text to put the original values
;; back using the mapping kept in Emacs.
;;
;; This package was inspired by Anocrypt's local, regex-based text anonymizer:
;;
;;   https://anocrypt.com/
;;
;; The same site links related guidance pages that informed the general
;; workflow motivation: anonymizing personal data before using AI tools, keeping
;; processing local where possible, and preferring transparent regex rules for
;; predictable replacement:
;;
;;   https://anocrypt.com/personal-data-ai-tools
;;   https://anocrypt.com/ai-llm-overview
;;   https://anocrypt.com/ai-guidelines
;;
;; No separate external source bibliography was visible on those pages when this
;; package note was written.
;;
;; Custom terms can be configured with `anonymize-region-custom-terms' or with
;; `anonymize-region-custom-file'.  The file should contain one Lisp list:
;;
;;   (("mahjong" . "game")
;;    (:literal "Blue Sparrow Project" :label "project")
;;    (:regexp "\\bCLIENT-[0-9]+\\b" :label "client"))
;;
;; String pairs are literal replacements.  Property-list entries may use
;; :literal or :regexp with :label.  Labels are used as placeholder prefixes,
;; so "game" becomes game1, game2, etc.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup anonymize-region nil
  "Reversible local anonymization for selected text."
  :group 'convenience
  :prefix "anonymize-region-")

(defcustom anonymize-region-custom-file
  (locate-user-emacs-file "anonymize-region-terms.el")
  "File containing custom anonymization terms.
The file should contain one Lisp list.  See `anonymize-region-custom-terms'
for accepted entry formats."
  :type 'file)

(defcustom anonymize-region-custom-terms nil
  "Custom anonymization terms.
Each entry may be one of:

  (ORIGINAL . LABEL)
    Treat ORIGINAL as literal text and replace it with LABEL plus a counter.

  (:literal ORIGINAL :label LABEL)
    Same as above, but written as a property list.

  (:regexp REGEXP :label LABEL)
    Replace text matching REGEXP with LABEL plus a counter.

For example, (\"mahjong\" . \"game\") replaces mahjong with game1."
  :type '(repeat sexp))

(defcustom anonymize-region-save-map nil
  "When non-nil, save the anonymization map after each anonymization."
  :type 'boolean)

(defcustom anonymize-region-map-file
  (locate-user-emacs-file "anonymize-region-map.el")
  "File used by `anonymize-region-save-map' and `anonymize-region-load-map'."
  :type 'file)

(defcustom anonymize-region-case-fold-search t
  "When non-nil, match custom literals and built-in regexes case-insensitively."
  :type 'boolean)

(defcustom anonymize-region-enable-name-pattern t
  "When non-nil, replace likely person/company names.
This heuristic matches two or more adjacent capitalized words, for example
\"Albert Einstein\".  Disable it if your text has many title-cased phrases that
should not be anonymized."
  :type 'boolean)

(defcustom anonymize-region-patterns
  '((:label "Email"
     :regexp "\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z][A-Z]+\\b")
    (:label "Url"
     :regexp "\\b\\(?:https?://\\|www\\.\\)[^[:space:]<>()\"']+")
    (:label "Iban"
     :regexp "\\b[A-Z][A-Z][0-9][0-9][[:space:]]?\\(?:[A-Z0-9][[:space:]]?\\)\\{11,30\\}\\b")
    (:label "Ip"
     :regexp "\\b\\(?:[0-9]\\{1,3\\}\\.\\)\\{3\\}[0-9]\\{1,3\\}\\b")
    (:label "Date"
     :regexp "\\b\\(?:[0-3]?[0-9][./-][01]?[0-9][./-][0-9]\\{2,4\\}\\|[0-9]\\{4\\}-[01][0-9]-[0-3][0-9]\\)\\b")
    (:label "Phone"
     :regexp "\\b\\(?:\\+?[0-9][0-9 .()/-]\\{6,\\}[0-9]\\)\\b")
    (:label "Address"
     :regexp "\\b[[:upper:]][[:alpha:]'’.-]+\\(?:[[:space:]]+[[:upper:]][[:alpha:]'’.-]+\\)*[[:space:]]+\\(?:Street\\|St\\.?\\|Road\\|Rd\\.?\\|Avenue\\|Ave\\.?\\|Boulevard\\|Blvd\\.?\\|Lane\\|Ln\\.?\\|Drive\\|Dr\\.?\\|Way\\|Place\\|Pl\\.?\\|Square\\|Sq\\.?\\|Strasse\\|Straße\\|Gade\\|Vej\\)\\(?:[[:space:]]+[0-9]+[A-Za-z]?\\)?\\b"
     :case-fold nil))
  "Built-in anonymization regex patterns.
Each entry is a property list with :label and :regexp.  The label is used as
the placeholder prefix."
  :type '(repeat sexp))

(defvar anonymize-region--forward-map (make-hash-table :test 'equal)
  "Hash table mapping internal replacement keys to placeholders.")

(defvar anonymize-region--reverse-map (make-hash-table :test 'equal)
  "Hash table mapping placeholders to original strings.")

(defvar anonymize-region--counters (make-hash-table :test 'equal)
  "Hash table mapping labels to the next placeholder counter.")

(defconst anonymize-region--name-pattern
  "\\b[[:upper:]][[:lower:]]\\{2,\\}\\(?:[[:space:]]+[[:upper:]][[:lower:]]\\{1,\\}\\)\\{1,4\\}\\b"
  "Heuristic regex for likely names.")

(defun anonymize-region-clear-map ()
  "Clear all in-memory anonymization mappings."
  (interactive)
  (setq anonymize-region--forward-map (make-hash-table :test 'equal)
        anonymize-region--reverse-map (make-hash-table :test 'equal)
        anonymize-region--counters (make-hash-table :test 'equal))
  (when (called-interactively-p 'interactive)
    (message "anonymize-region: cleared mapping")))

(defun anonymize-region--read-data-file (file)
  "Read one Lisp expression from FILE, returning nil when FILE is absent."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (condition-case nil
          (read (current-buffer))
        (end-of-file nil)))))

(defun anonymize-region--custom-terms ()
  "Return configured custom terms from variables and the custom file."
  (append anonymize-region-custom-terms
          (let ((terms (anonymize-region--read-data-file
                        anonymize-region-custom-file)))
            (unless (or (null terms) (listp terms))
              (user-error "Custom terms file must contain a Lisp list"))
            terms)))

(defun anonymize-region--quote-literal (literal)
  "Return a regexp that matches LITERAL as text."
  (regexp-quote literal))

(defun anonymize-region--normalize-custom-entry (entry)
  "Convert custom ENTRY to a pattern property list."
  (cond
   ((and (consp entry) (stringp (car entry)) (stringp (cdr entry)))
    (list :label (cdr entry)
          :regexp (anonymize-region--quote-literal (car entry))))
   ((and (listp entry) (plist-get entry :literal) (plist-get entry :label))
    (list :label (plist-get entry :label)
          :regexp (anonymize-region--quote-literal (plist-get entry :literal))))
   ((and (listp entry) (plist-get entry :regexp) (plist-get entry :label))
    (list :label (plist-get entry :label)
          :regexp (plist-get entry :regexp)))
   (t
    (user-error "Invalid custom anonymize-region entry: %S" entry))))

(defun anonymize-region--patterns ()
  "Return all active patterns with custom patterns first."
  (append (mapcar #'anonymize-region--normalize-custom-entry
                  (anonymize-region--custom-terms))
          anonymize-region-patterns
          (when anonymize-region-enable-name-pattern
            (list (list :label "Name"
                        :regexp anonymize-region--name-pattern
                        :case-fold nil)))))

(defun anonymize-region--replacement-key (label original)
  "Return stable key for LABEL and ORIGINAL."
  (concat label "\0" original))

(defun anonymize-region--placeholder (label original)
  "Return placeholder for ORIGINAL under LABEL, creating it if needed."
  (let* ((key (anonymize-region--replacement-key label original))
         (existing (gethash key anonymize-region--forward-map)))
    (or existing
        (let* ((next (or (gethash label anonymize-region--counters) 1))
               (placeholder (format "%s%d" label next)))
          (puthash label (1+ next) anonymize-region--counters)
          (puthash key placeholder anonymize-region--forward-map)
          (puthash placeholder original anonymize-region--reverse-map)
          placeholder))))

(defun anonymize-region--overlap-p (a-start a-end b-start b-end)
  "Return non-nil when ranges A-START A-END and B-START B-END overlap."
  (and (< a-start b-end) (< b-start a-end)))

(defun anonymize-region--covered-p (start end ranges)
  "Return non-nil when START END overlaps any range in RANGES."
  (cl-some (lambda (range)
             (anonymize-region--overlap-p start end (car range) (cdr range)))
           ranges))

(defun anonymize-region--collect-matches (text)
  "Collect anonymization matches in TEXT.
Return a list of (START END LABEL ORIGINAL).  Overlapping matches are resolved
by pattern order, then by earliest and longest match."
  (let ((candidates nil)
        (priority 0))
    (dolist (pattern (anonymize-region--patterns))
      (let ((label (plist-get pattern :label))
            (regexp (plist-get pattern :regexp))
            (case-fold-search
             (if (plist-member pattern :case-fold)
                 (plist-get pattern :case-fold)
               anonymize-region-case-fold-search)))
        (unless (and (stringp label) (stringp regexp))
          (user-error "Invalid anonymize-region pattern: %S" pattern))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (while (re-search-forward regexp nil t)
            (let ((start (match-beginning 0))
                  (end (match-end 0))
                  (original (match-string-no-properties 0)))
              (when (< start end)
                (push (list start end label original priority) candidates))))))
      (setq priority (1+ priority)))
    (let ((chosen nil)
          (covered nil)
          (sorted-candidates
           (sort candidates
                 (lambda (a b)
                   (let ((a-start (nth 0 a))
                         (a-end (nth 1 a))
                         (a-priority (nth 4 a))
                         (b-start (nth 0 b))
                         (b-end (nth 1 b))
                         (b-priority (nth 4 b)))
                     (cond
                      ((/= a-priority b-priority) (< a-priority b-priority))
                      ((/= a-start b-start) (< a-start b-start))
                      (t (> (- a-end a-start) (- b-end b-start)))))))))
      (dolist (candidate sorted-candidates)
        (let ((start (nth 0 candidate))
              (end (nth 1 candidate)))
          (unless (anonymize-region--covered-p start end covered)
            (push (cl-subseq candidate 0 4) chosen)
            (push (cons start end) covered))))
      (sort chosen (lambda (a b) (< (car a) (car b)))))))

(defun anonymize-region--replace-region (beg end replacements)
  "Apply REPLACEMENTS inside BEG END.
REPLACEMENTS must contain absolute (START END TEXT) entries."
  (ignore beg end)
  (save-excursion
    (dolist (replacement
             (sort replacements (lambda (a b) (> (car a) (car b)))))
      (let ((start (nth 0 replacement))
            (finish (nth 1 replacement))
            (text (nth 2 replacement)))
        (goto-char start)
        (delete-region start finish)
        (insert text)))))

;;;###autoload
(defun anonymize-region (beg end &optional reset-map)
  "Anonymize sensitive text in region from BEG to END.
With prefix argument RESET-MAP, clear the current mapping before anonymizing."
  (interactive "r\nP")
  (when (and (called-interactively-p 'interactive) (not (use-region-p)))
    (user-error "Select a region to anonymize"))
  (unless (< beg end)
    (user-error "Region is empty"))
  (when reset-map
    (anonymize-region-clear-map))
  (let* ((text (buffer-substring-no-properties beg end))
         (matches (anonymize-region--collect-matches text))
         (replacements
          (mapcar (lambda (match)
                    (let* ((start (+ beg (nth 0 match) -1))
                           (finish (+ beg (nth 1 match) -1))
                           (label (nth 2 match))
                           (original (nth 3 match))
                           (placeholder
                            (anonymize-region--placeholder label original)))
                      (list start finish placeholder)))
                  matches)))
    (anonymize-region--replace-region beg end replacements)
    (when anonymize-region-save-map
      (anonymize-region-save-map))
    (message "anonymize-region: replaced %d item%s"
             (length replacements)
             (if (= (length replacements) 1) "" "s"))))

(defun anonymize-region--reverse-replacements (beg end)
  "Return absolute reverse replacements for placeholders in BEG END."
  (let ((case-fold-search nil)
        (text (buffer-substring-no-properties beg end))
        (replacements nil)
        (placeholders nil))
    (maphash (lambda (placeholder original)
               (push (cons placeholder original) placeholders))
             anonymize-region--reverse-map)
    (dolist (entry (sort placeholders
                         (lambda (a b) (> (length (car a)) (length (car b))))))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (search-forward (car entry) nil t)
          (push (list (+ beg (match-beginning 0) -1)
                      (+ beg (match-end 0) -1)
                      (cdr entry))
                replacements))))
    replacements))

;;;###autoload
(defun anonymize-region-restore (beg end)
  "Restore anonymized placeholders in region from BEG to END."
  (interactive "r")
  (when (and (called-interactively-p 'interactive) (not (use-region-p)))
    (user-error "Select a region to restore"))
  (unless (< beg end)
    (user-error "Region is empty"))
  (let ((replacements (anonymize-region--reverse-replacements beg end)))
    (anonymize-region--replace-region beg end replacements)
    (message "anonymize-region: restored %d item%s"
             (length replacements)
             (if (= (length replacements) 1) "" "s"))))

(defun anonymize-region--map-data ()
  "Return current map as printable Lisp data."
  (let ((data nil))
    (maphash (lambda (placeholder original)
               (push (cons placeholder original) data))
             anonymize-region--reverse-map)
    (sort data (lambda (a b) (string< (car a) (car b))))))

;;;###autoload
(defun anonymize-region-save-map (&optional file)
  "Save current anonymization map to FILE.
When called interactively, prompt for FILE.  Defaults to
`anonymize-region-map-file'."
  (interactive
   (list (read-file-name "Save anonymize map: "
                         nil anonymize-region-map-file nil
                         (file-name-nondirectory anonymize-region-map-file))))
  (let ((target (or file anonymize-region-map-file)))
    (make-directory (file-name-directory target) t)
    (with-temp-file target
      (let ((print-length nil)
            (print-level nil))
        (prin1 (anonymize-region--map-data) (current-buffer))
        (insert "\n")))
    (message "anonymize-region: saved map to %s" target)))

;;;###autoload
(defun anonymize-region-load-map (&optional file)
  "Load anonymization map from FILE.
When called interactively, prompt for FILE.  Defaults to
`anonymize-region-map-file'."
  (interactive
   (list (read-file-name "Load anonymize map: "
                         nil anonymize-region-map-file t
                         (file-name-nondirectory anonymize-region-map-file))))
  (let ((data (anonymize-region--read-data-file
               (or file anonymize-region-map-file))))
    (unless (listp data)
      (user-error "Map file must contain an alist"))
    (anonymize-region-clear-map)
    (dolist (entry data)
      (unless (and (consp entry) (stringp (car entry)) (stringp (cdr entry)))
        (user-error "Invalid map entry: %S" entry))
      (let* ((placeholder (car entry))
             (original (cdr entry))
             (label (replace-regexp-in-string "[0-9]+\\'" "" placeholder))
             (number (string-to-number
                      (or (and (string-match "\\([0-9]+\\)\\'" placeholder)
                               (match-string 1 placeholder))
                          "0"))))
        (puthash placeholder original anonymize-region--reverse-map)
        (puthash (anonymize-region--replacement-key label original)
                 placeholder anonymize-region--forward-map)
        (puthash label
                 (max (or (gethash label anonymize-region--counters) 1)
                      (1+ number))
                 anonymize-region--counters)))
    (message "anonymize-region: loaded %d mapping%s"
             (hash-table-count anonymize-region--reverse-map)
             (if (= (hash-table-count anonymize-region--reverse-map) 1)
                 ""
               "s"))))

(provide 'anonymize-region)

;;; anonymize-region.el ends here
