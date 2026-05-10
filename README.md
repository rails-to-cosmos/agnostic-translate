# agnostic-translate

Multi-language translation package for Emacs.

Auto-detects the source language from the input and translates into every
other language in your configured list. Results appear in an animated
child-frame popup with easy copy-paste and a persistent history.

The language list is seeded from your system locale and X11 keyboard
layouts, managed via a transient menu, and persisted through `customize`.

## Requirements

- Emacs 28.1+
- [`transient`](https://github.com/magit/transient) 0.4+
- The [`claude`](https://docs.anthropic.com/en/docs/claude-cli) CLI on
  `PATH`, authenticated.

## Installation

### MELPA

Once available on MELPA:

```elisp
(use-package agnostic-translate
  :ensure t
  :bind ("C-c t" . agnostic-translate-menu))
```

### Manual

Clone the repo and add it to your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/agnostic-translate")
(require 'agnostic-translate)
```

## Usage

- `M-x agnostic-translate` — translate the active region, or open an input
  popup if no region is selected. `C-c C-c` sends, `C-c C-k` closes.
- `M-x agnostic-translate-menu` — transient menu for translation and
  language management.
- `M-x agnostic-translate-show-history` — browse past translations; `RET`
  copies the line at point.

### Popup keys

| Key       | Action                          |
|-----------|---------------------------------|
| `w`       | Copy translation (prompts if multiple) |
| `n`       | Start a new translation         |
| `h`       | Show history                    |
| `q`       | Close the popup                 |
| `C-c C-c` | Send (in input mode)            |
| `C-c C-k` | Close                           |

## Configuration

```elisp
;; The languages you work with. Source is auto-detected and skipped.
;; Defaults are derived from $LANG and `setxkbmap -query` layouts.
(setq agnostic-translate-languages '("English" "Russian" "German"))

;; Override the claude model (nil = claude's default).
(setq agnostic-translate-model "claude-sonnet-4-5")

;; Popup geometry and animation.
(setq agnostic-translate-frame-size '(80 . 20))
(setq agnostic-translate-bubble-steps 8)
(setq agnostic-translate-bubble-interval 0.018)
```

Faces `agnostic-translate-frame-face`,
`agnostic-translate-frame-border-face`, `agnostic-translate-header-face`,
`agnostic-translate-source-face`, `agnostic-translate-result-face`,
`agnostic-translate-thinking-face`, and `agnostic-translate-lang-face` are
all customizable via `M-x customize-group RET agnostic-translate RET`.

## Development

```sh
make lint     # package-lint (auto-installs from MELPA)
make compile  # byte-compile with warnings as errors
make          # both (mirrors CI)
```

CI runs against Emacs 28.1, 29.4, and snapshot.

## License

See file headers.
