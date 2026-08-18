# anonymize-region

`anonymize-region` is a small Emacs Lisp package for reversible, local text
anonymization.  Mark a region, replace sensitive values with placeholders such
as `Name1`, `Email1`, `Address1`, or custom labels like `game1`, send the
anonymized text to an AI, then restore the original values when the text comes
back.

The anonymization is regex-based and runs locally in Emacs.  No text is sent to
an external service by this package.

## Inspiration

This package was inspired by Anocrypt's local, regex-based text anonymizer:

- https://anocrypt.com/

Anocrypt also links related guidance pages that informed the general workflow
motivation: anonymize personal data before using AI tools, keep processing local
where possible, and use transparent regex rules for predictable replacement.

- https://anocrypt.com/personal-data-ai-tools
- https://anocrypt.com/ai-llm-overview
- https://anocrypt.com/ai-guidelines

No separate external source bibliography was visible on those pages when this
README note was written.

## Installation

Place `anonymize-region.el` somewhere in your Emacs `load-path`, for example:

```sh
mkdir -p ~/.emacs.d/lisp
cp anonymize-region.el ~/.emacs.d/lisp/
```

Add this to your Emacs configuration:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp")
(require 'anonymize-region)
```

With `use-package`:

```elisp
(use-package anonymize-region
  :load-path "~/.emacs.d/lisp"
  :commands (anonymize-region
             anonymize-region-restore
             anonymize-region-save-map
             anonymize-region-load-map
             anonymize-region-clear-map)
  :bind (("C-c a a" . anonymize-region)
         ("C-c a r" . anonymize-region-restore)))
```

Optional key bindings:

```elisp
(global-set-key (kbd "C-c a a") #'anonymize-region)
(global-set-key (kbd "C-c a r") #'anonymize-region-restore)
```

## Basic Usage

1. Mark a region containing sensitive text.
2. Run `M-x anonymize-region`.
3. Send the anonymized text to the AI or other external tool.
4. Replace or insert the returned text into Emacs.
5. Mark the returned region.
6. Run `M-x anonymize-region-restore`.

Example:

```text
Albert Einstein lives on Main Street 42 and uses albert@example.com.
```

May become:

```text
Name1 lives on Address1 and uses Email1.
```

When the returned text still contains `Name1`, `Address1`, and `Email1`,
`anonymize-region-restore` can put the original values back.

## Commands

`M-x anonymize-region`

Anonymize the active region.  With a prefix argument, for example
`C-u M-x anonymize-region`, the existing in-memory mapping is cleared before
anonymizing.

`M-x anonymize-region-restore`

Restore placeholders in the active region using the current mapping.

`M-x anonymize-region-save-map`

Save the current placeholder mapping to a file.

`M-x anonymize-region-load-map`

Load a saved placeholder mapping from a file.

`M-x anonymize-region-clear-map`

Clear the current in-memory mapping.

## Custom Terms

Custom terms can be configured either in Emacs Lisp:

```elisp
(setq anonymize-region-custom-terms
      '(("mahjong" . "game")
        (:literal "Blue Sparrow Project" :label "project")
        (:regexp "\\bCLIENT-[0-9]+\\b" :label "client")))
```

Or in the default custom terms file:

```text
~/.emacs.d/anonymize-region-terms.el
```

That file should contain one Lisp list:

```elisp
(("mahjong" . "game")
 (:literal "Blue Sparrow Project" :label "project")
 (:regexp "\\bCLIENT-[0-9]+\\b" :label "client"))
```

Supported custom entry formats:

```elisp
("original text" . "label")
```

Treats `original text` as literal text and replaces it with `label1`,
`label2`, etc.

```elisp
(:literal "original text" :label "label")
```

Same as above, but written as a property list.

```elisp
(:regexp "\\bSECRET-[0-9]+\\b" :label "secret")
```

Uses a regular expression and replaces each distinct match with `secret1`,
`secret2`, etc.

Custom terms run before the built-in patterns.

## Built-In Patterns

The default patterns cover common values:

- Names, using a simple capitalized-word heuristic
- Email addresses
- URLs
- IP addresses
- Phone-number-like values
- Dates
- IBAN-like values
- Approximate street addresses

These patterns are intentionally conservative enough to be useful, but they are
not a legal, medical, or compliance-grade anonymization system.  Review the
output before sending sensitive text elsewhere.

## Options

`anonymize-region-custom-file`

Path to the custom terms file.  Defaults to:

```text
~/.emacs.d/anonymize-region-terms.el
```

`anonymize-region-save-map`

When non-nil, automatically save the placeholder map after each anonymization.

`anonymize-region-map-file`

Path used by `anonymize-region-save-map` and `anonymize-region-load-map`.

`anonymize-region-case-fold-search`

When non-nil, custom literals and built-in regex patterns are matched
case-insensitively.  The name heuristic remains case-sensitive.

`anonymize-region-enable-name-pattern`

When non-nil, replace likely names such as `Albert Einstein`.  Disable this if
your text contains many title-cased phrases that should not be anonymized.

`anonymize-region-patterns`

The built-in regex pattern list.  You can customize this if you want to add,
remove, or replace default detectors.

## Notes

The restore step depends on the placeholder mapping.  Keep the same Emacs
session open, or save the map with `anonymize-region-save-map` before closing
Emacs.  Load it again with `anonymize-region-load-map` before restoring text.

## Testing

Run the ERT test suite from the repository root:

```sh
emacs -Q --batch -L . -L test -l test/anonymize-region-test.el -f ert-run-tests-batch-and-exit
```

To byte-compile the package and tests:

```sh
emacs -Q --batch -L . -L test -f batch-byte-compile anonymize-region.el test/anonymize-region-test.el
```
