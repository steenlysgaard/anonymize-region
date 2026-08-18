;;; anonymize-region-test.el --- Tests for anonymize-region -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'anonymize-region)

(defmacro anonymize-region-test--with-clean-state (&rest body)
  "Run BODY with isolated anonymize-region state."
  (declare (indent 0) (debug t))
  `(let ((anonymize-region-custom-terms nil)
         (anonymize-region-custom-file
          (make-temp-file "anonymize-region-empty-custom"))
         (anonymize-region-save-map nil)
         (anonymize-region-map-file
          (make-temp-file "anonymize-region-map"))
         (anonymize-region-case-fold-search t)
         (anonymize-region-enable-name-pattern t)
         (anonymize-region-patterns anonymize-region-patterns))
     (unwind-protect
         (progn
           (anonymize-region-clear-map)
           ,@body)
       (anonymize-region-clear-map)
       (when (file-exists-p anonymize-region-custom-file)
         (delete-file anonymize-region-custom-file))
       (when (file-exists-p anonymize-region-map-file)
         (delete-file anonymize-region-map-file)))))

(defun anonymize-region-test--anonymize-string (text)
  "Return anonymized TEXT using the package's region command."
  (with-temp-buffer
    (insert text)
    (anonymize-region (point-min) (point-max))
    (buffer-string)))

(defun anonymize-region-test--restore-string (text)
  "Return restored TEXT using the package's region command."
  (with-temp-buffer
    (insert text)
    (anonymize-region-restore (point-min) (point-max))
    (buffer-string)))

(ert-deftest anonymize-region-test-round-trip-built-ins ()
  "Anonymize and restore common built-in pattern matches."
  (anonymize-region-test--with-clean-state
    (let* ((original "Albert Einstein lives at Main Street 42. Email albert@example.com on 2026-08-18.")
           (anonymized (anonymize-region-test--anonymize-string original)))
      (should (string-match-p "\\bName1\\b" anonymized))
      (should (string-match-p "\\bAddress1\\b" anonymized))
      (should (string-match-p "\\bEmail1\\b" anonymized))
      (should (string-match-p "\\bDate1\\b" anonymized))
      (should (string= (anonymize-region-test--restore-string anonymized)
                       original)))))

(ert-deftest anonymize-region-test-custom-literal ()
  "Custom literal terms are anonymized before built-in patterns."
  (anonymize-region-test--with-clean-state
    (setq anonymize-region-custom-terms
          '(("mahjong" . "game")))
    (let ((anonymized
           (anonymize-region-test--anonymize-string
            "Albert Einstein plays mahjong.")))
      (should (string= anonymized "Name1 plays game1."))
      (should (string= (anonymize-region-test--restore-string anonymized)
                       "Albert Einstein plays mahjong.")))))

(ert-deftest anonymize-region-test-custom-regexp ()
  "Custom regexp entries use their configured label."
  (anonymize-region-test--with-clean-state
    (setq anonymize-region-custom-terms
          '((:regexp "\\bCLIENT-[0-9]+\\b" :label "client")))
    (let ((anonymized
           (anonymize-region-test--anonymize-string
            "Cases CLIENT-123 and CLIENT-456 are open.")))
      (should (string= anonymized "Cases client1 and client2 are open."))
      (should (string= (anonymize-region-test--restore-string anonymized)
                       "Cases CLIENT-123 and CLIENT-456 are open.")))))

(ert-deftest anonymize-region-test-reuses-placeholder-for-repeated-value ()
  "Repeated original values receive the same placeholder."
  (anonymize-region-test--with-clean-state
    (let ((anonymized
           (anonymize-region-test--anonymize-string
            "Albert Einstein emailed Albert Einstein.")))
      (should (string= anonymized "Name1 emailed Name1.")))))

(ert-deftest anonymize-region-test-continues-counters-across-calls ()
  "The in-memory mapping continues counters across anonymization calls."
  (anonymize-region-test--with-clean-state
    (should (string= (anonymize-region-test--anonymize-string "Albert Einstein")
                     "Name1"))
    (should (string= (anonymize-region-test--anonymize-string "Marie Curie")
                     "Name2"))))

(ert-deftest anonymize-region-test-prefix-reset-clears-map ()
  "The RESET-MAP argument clears previous mappings before anonymizing."
  (anonymize-region-test--with-clean-state
    (should (string= (anonymize-region-test--anonymize-string "Albert Einstein")
                     "Name1"))
    (with-temp-buffer
      (insert "Marie Curie")
      (anonymize-region (point-min) (point-max) t)
      (should (string= (buffer-string) "Name1")))))

(ert-deftest anonymize-region-test-overlap-prefers-custom-pattern ()
  "Earlier custom patterns win when they overlap built-in patterns."
  (anonymize-region-test--with-clean-state
    (setq anonymize-region-custom-terms
          '(("Albert Einstein" . "physicist")))
    (should (string=
             (anonymize-region-test--anonymize-string "Albert Einstein wrote.")
             "physicist1 wrote."))))

(ert-deftest anonymize-region-test-custom-file ()
  "Custom terms can be loaded from `anonymize-region-custom-file'."
  (anonymize-region-test--with-clean-state
    (with-temp-file anonymize-region-custom-file
      (prin1 '((:literal "Blue Sparrow Project" :label "project"))
             (current-buffer))
      (insert "\n"))
    (should (string=
             (anonymize-region-test--anonymize-string
              "Blue Sparrow Project launches today.")
             "project1 launches today."))))

(ert-deftest anonymize-region-test-save-and-load-map ()
  "A saved map can be loaded in a fresh state and used for restore."
  (anonymize-region-test--with-clean-state
    (let ((anonymized
           (anonymize-region-test--anonymize-string
            "Albert Einstein plays mahjong.")))
      (anonymize-region-save-map anonymize-region-map-file)
      (anonymize-region-clear-map)
      (anonymize-region-load-map anonymize-region-map-file)
      (should (string= (anonymize-region-test--restore-string anonymized)
                       "Albert Einstein plays mahjong.")))))

(ert-deftest anonymize-region-test-empty-region-errors ()
  "Empty regions signal a user error."
  (anonymize-region-test--with-clean-state
    (with-temp-buffer
      (should-error (anonymize-region (point-min) (point-min))
                    :type 'user-error)
      (should-error (anonymize-region-restore (point-min) (point-min))
                    :type 'user-error))))

(provide 'anonymize-region-test)

;;; anonymize-region-test.el ends here
