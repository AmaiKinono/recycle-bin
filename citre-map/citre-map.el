;;; citre-map.el --- A map in the maze of code reading -*- lexical-binding: t -*-

;; Copyright (C) 2020 Hao Wang

;; Author: Hao Wang <amaikinono@gmail.com>
;; Maintainer: Hao Wang <amaikinono@gmail.com>
;; Created: 28 Feb 2020
;; Keywords: convenience, tools
;; Homepage: https://github.com/AmaiKinono/citre
;; Version: 0

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

;; To see the outline of this file, run M-x outline-minor-mode and
;; then press C-c @ C-t. To also show the top-level functions and
;; variable declarations in each section, run M-x occur with the
;; following query: ^;;;;* \|^(

;;;; Libraries

(require 'citre)

;;;; User options

(defcustom citre-code-map-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") 'next-line)
    (define-key map (kbd "p") 'previous-line)
    (define-key map (kbd "f") 'citre-code-map-forward)
    (define-key map (kbd "RET") 'citre-code-map-forward)
    (define-key map (kbd "b") 'citre-code-map-backward)
    (define-key map (kbd "o") 'citre-code-map-open-file)
    (define-key map (kbd "m") 'citre-code-map-mark)
    (define-key map (kbd "u") 'citre-code-map-unmark-all)
    (define-key map (kbd "h") 'citre-code-map-hide)
    (define-key map (kbd "d") 'citre-code-map-delete)
    (define-key map (kbd "k") 'citre-code-map-keep)
    (define-key map (kbd "S") 'citre-code-map-show-all)
    (define-key map (kbd "M") 'citre-code-map-mark-missing)
    (define-key map (kbd "R") 'citre-code-map-replace-file)
    (define-key map (kbd "U") 'citre-code-map-update)
    (define-key map [remap save-buffer] 'citre-save-code-map)
    (define-key map [remap find-file] 'citre-load-code-map)
    map)
  "Keymap used in citre-code-map-mode."
  :group 'citre
  :type 'keymap)

;;;; Helpers

(defun citre--buffer-relative-file-name (&optional buffer)
  "Return the path relative to project root of file in current buffer.
If the file is not under its project, return the absolute path.
When BUFFER is specified, use filename and project in BUFFER
instead."
  (let* ((buf (or buffer (current-buffer))))
    (citre--relative-path (buffer-file-name buf) (citre--project-root buf))))

(defun citre--key-in-alist (elt alist)
  "Non-nil if ELT is a key in ALIST.
The test is done using `equal'."
  (cl-member elt alist :key #'car :test #'equal))

(defun citre--print-value-to-file (filename value)
  "Print VALUE to file FILENAME."
  (with-temp-file filename
    (prin1 value (current-buffer))))

(defun citre--read-value-from-file (filename)
  "Read value from file FILENAME."
  (with-temp-buffer
    (insert-file-contents filename)
    (goto-char (point-min))
    (read (current-buffer))))

;;;; Action: map

;;;;; Data Structures

(defvar citre--code-map-alist nil
  "Alist for code maps.
The key is a project path, value is its code map.  A code map is
another nested alist with a structure like:

  (alist of:
   file-name -> (alist of:
                 symbol -> (list of:
                            (definition-record . hide-or-not))))

Once you know how to use the code map, this structure will make
sense.  See README for the user guide.")

(defvar citre--code-map-position-alist nil
  "Alist for latest positions in code maps.
The key is a project path, value is the latest position in its
code map.  The position means the state after your last
`citre-code-map-forward', `citre-code-map-backward', or opening
the code map with commands like `citre-see-symbol-in-code-map'.
It is a list of:

  (file-name symbol definition-location current-depth)

The meaning of current-depth is:

  0: In the file list.
  1: In the symbol list.
  2: In the definition list.")

(defvar citre--code-map-disk-state-alist nil
  "Alist for the disk state of code maps.
The key is a project path, value is a cons pair, whose car is t
or nil, indicating whether the code map has been modified since
last save, and cdr is the location on the disk.")

(defmacro citre--get-in-code-map (&optional file symbol project)
  "Return the place form of a list in code map in current project.
If no optional arguments is given, return the place form of the
file list in current project.

If FILE is given, return the place form of the symbol list under
it.

If SYMBOL is also given, return the place form of the definition
list under it.

If project root PROJECT is given, use that project instead.

Notice: Since this is a macro, the arguments are considered to be
non-nil as long as a form that is non-nil is presented, even when
its value is nil."
  (let* ((project (or project '(citre--project-root))))
    (if file
        (if symbol
            `(alist-get ,symbol (citre--get-in-code-map ,file nil ,project)
                        nil nil #'equal)
          `(alist-get ,file (citre--get-in-code-map nil nil ,project)
                      nil nil #'equal))
      `(alist-get ,project citre--code-map-alist
                  nil nil #'equal))))

(defmacro citre--code-map-position (&optional project)
  "Return the place form of the code map position in current project.
If project root PROJECT is given, use that project instead.

Notice: Since this is a macro, the arguments are considered to be
non-nil as long as a form that is non-nil is presented, even when
its value is nil."
  (let ((project (or project '(citre--project-root))))
    `(alist-get ,project citre--code-map-position-alist
                nil nil #'equal)))

(defun citre--current-list-in-code-map (&optional project)
  "Return the current list in code map in current project.
\"Current list\" is determined by
`citre--code-map-position-alist'.

If project root PROJECT is given, use that project instead."
  (let* ((project (or project (citre--project-root)))
         (pos (citre--code-map-position project)))
    (pcase (nth 3 pos)
      (0 (citre--get-in-code-map nil nil project))
      (1 (citre--get-in-code-map (car pos) nil project))
      (2 (citre--get-in-code-map (car pos) (nth 1 pos) project))
      (_ (error
          "Current depth in code map position should be an integer in 0~3")))))

(defun citre--set-hide-state (record state)
  "Set the hide state of RECORD in current definition list to STATE."
  (let ((pos (citre--code-map-position)))
    (unless (= (nth 3 pos) 2)
      (error "Not browsing an definition list"))
    (let* ((definition-list (citre--get-in-code-map (car pos) (nth 1 pos)))
           (idx (cl-position record definition-list
                             :key #'car :test #'equal)))
      (unless idx
        (error "RECORD not found in current definition list"))
      (setf (cdr (nth idx
                      (citre--get-in-code-map (car pos) (nth 1 pos))))
            state))))

(defun citre--delete-item-in-code-map (item)
  "Remove ITEM in current list in code map."
  (let* ((pos (citre--code-map-position))
         (pos-depth (nth 3 pos)))
    (pcase pos-depth
      (0 (setf (citre--get-in-code-map)
               (cl-delete item (citre--get-in-code-map)
                          :key #'car :test #'equal)))
      (1 (setf (citre--get-in-code-map (nth 0 pos))
               (cl-delete item (citre--get-in-code-map (nth 0 pos))
                          :key #'car :test #'equal)))
      (2 (error "Definitions can't be deleted")))))

(defun citre--set-code-map-position (&optional filename symbol
                                               definition project)
  "Set the code map position in current project.
This modifies `citre--code-map-position-alist' based on FILENAME,
SYMBOL and DEFINITION.

If project root PROJECT is given, use that project instead."
  (let ((project (or project (citre--project-root))))
    (cl-symbol-macrolet ((pos (citre--code-map-position project)))
      (let* ((file-presented (when filename (string= filename (car pos))))
             (symbol-presented (when symbol (string= symbol (nth 1 pos)))))
        ;; If map position is empty, set it first.
        (unless (consp pos)
          (setf pos '(nil nil nil 0)))
        (when (and (not filename) (not symbol) (not definition))
          (setf (nth 3 pos) 0))
        (when filename
          (unless file-presented
            (setf (car pos) filename))
          (setf (nth 3 pos) 1))
        (when (and filename symbol)
          (unless (and file-presented symbol-presented)
            (setf (nth 1 pos) symbol))
          (setf (nth 3 pos) 2))
        (when (and filename symbol definition)
          (setf (nth 2 pos) definition)
          (setf (nth 3 pos) 2))))))

(defun citre--set-code-map-disk-state (modified &optional location project)
  "Set the disk state of current code map to LOCATION and MODIFIED.
See the docstring of `citre--code-map-disk-state-alist' to know
their meaning.

When project root PROJECT is given, set the state of the code map
of PROJECT.

If called without LOCATION, this function will only have effect
when LOCATION already exists in the disk state.  The typical
usage is to call it with LOCATION after load/save a code map, and
without when changing its state in other situations."
  (let ((project (or project (citre--project-root))))
    (if location
        (setf (alist-get project
                         citre--code-map-disk-state-alist
                         nil nil #'equal)
              (cons modified location))
      (when (and (cl-member project
                            citre--code-map-disk-state-alist
                            :key #'car :test #'equal)
                 (car (alist-get project citre--code-map-alist
                                 nil nil #'equal)))
        (setf (car (alist-get project
                              citre--code-map-disk-state-alist
                              nil nil #'equal))
              modified)))))

(defun citre--get-code-map-disk-state (&optional project)
  "Get the disk state of the code map of current project.
When project root PROJECT is given, use that project instead."
  (let ((project (or project (citre--project-root))))
    (alist-get project citre--code-map-disk-state-alist
               nil nil #'equal)))

;;;;; Helpers: tabulated-list-mode extensions

;; TODO: customize mark
(defun citre--tabulated-list-mark ()
  "A wrapper around `tabulated-list-put-tag'.
This gives the mark a special text property so it can be detected
by `citre--tabulated-list-marked-p'."
  (tabulated-list-put-tag (propertize ">" 'face 'error 'citre-map-mark t)))

(defun citre--tabulated-list-unmark ()
  "Remove the mark in current line."
  (save-excursion
    (beginning-of-line)
    (when (tabulated-list-get-entry)
      (let ((inhibit-read-only t)
            (beg (point)))
        (forward-char tabulated-list-padding)
        (insert-and-inherit (make-string tabulated-list-padding ?\s))
        (delete-region beg (+ beg tabulated-list-padding))))))

(defun citre--tabulated-list-marked-p ()
  "Check if current line is marked."
  (save-excursion
    (beginning-of-line)
    (get-text-property (point) 'citre-map-mark)))

(defun citre--clamp-region (beg end)
  "Shrink the region from BEG to END.
BEG and END are two positions in the buffer.  A cons pair is
returned, its car is the next beginning of line after or at BEG,
and cdr is the previous beginning of line before END.

When such shrinked region doesn't exist (like BEG is in the last
line, or the car in the result is larger than cdr), nil will be
returned.

See `citre-code-map-mark' to get an idea about what's the purpose
of this function."
  (let ((result-beg nil)
        (result-end nil)
        (fail-flag nil))
    (save-excursion
      (goto-char beg)
      (unless (bolp)
        (forward-line)
        (when (eobp) (setq fail-flag t))
        (beginning-of-line))
      (setq result-beg (point))
      (goto-char end)
      (when (bobp) (setq fail-flag t))
      (if (bolp) (forward-line -1)
        (beginning-of-line))
      (setq result-end (point)))
    (when (and (not fail-flag) (<= result-beg result-end))
      (cons result-beg result-end))))

(defun citre--tabulated-list-marked-positions (&optional beg end)
  "Return positions of marked items in a tabulated list buffer.
The \"position of item\" means the beginning of its line.  When
BEG and/or END are specified, use them as inclusive boundaries of
search.  That is, the lines at BEG and END are also checked."
  (let ((positions nil)
        (beg-limit (or beg (point-min)))
        (end-limit (or end (point-max))))
    (save-excursion
      (goto-char beg-limit)
      (beginning-of-line)
      (while (and (<= (point) end-limit) (not (eobp)))
        (when (get-text-property (point) 'citre-map-mark)
          (push (point) positions))
        (forward-line)))
    positions))

(defun citre--tabulated-list-selected-positions ()
  "Return positions of items selected by an active region.
The \"position of item\" means the beginning of its line.

An item is \"selected by an active region\" means the beginning
of its line is in the \"clamped\" active region (including at its
boundaries), which is done by `citre--clamp-region'."
  (when (use-region-p)
    (let* ((positions nil)
           (region (citre--clamp-region (region-beginning) (region-end)))
           (beg (car region))
           (end (cdr region)))
      (goto-char beg)
      (while (<= (point) end)
        (push (point) positions)
        (forward-line))
      positions)))

;;;;; Code map mode and its helpers

(define-derived-mode citre-code-map-mode tabulated-list-mode
  "Code map"
  "Major mode for code map."
  (setq tabulated-list-padding 2))

(defun citre--find-position-near-region ()
  "Find a position near region.
See `citre--tabulated-list-print' to know its use."
  (when (region-active-p)
    (let ((upper nil)
          (lower nil)
          (pos nil)
          (region (citre--clamp-region (region-beginning)
                                       (region-end))))
      (save-excursion
        (goto-char (car region))
        (unless (bobp)
          (forward-line -1)
          (setq upper (point)))
        (goto-char (cdr region))
        (forward-line)
        (unless (eobp)
          (setq lower (point))))
      (if (= (point) (region-beginning))
          (setq pos (or upper lower))
        (setq pos (or lower upper)))
      pos)))

(defun citre--find-position-near-marked-items ()
  "Find a position near marked items when there is one at point.
See `citre--tabulated-list-print' to know its use."
  (when (citre--tabulated-list-marked-p)
    (let ((pos nil))
      (save-excursion
        (while (and (citre--tabulated-list-marked-p) (not (eobp)))
          (forward-line))
        (unless (citre--tabulated-list-marked-p)
          (setq pos (point))))
      (unless pos
        (save-excursion
          (while (and (citre--tabulated-list-marked-p) (not (bobp)))
            (forward-line -1))
          (unless (citre--tabulated-list-marked-p)
            (setq pos (point)))))
      pos)))

(defun citre--find-position-near-line ()
  "Find a position near this line.
See `citre--tabulated-list-print' to know its use."
  (let ((pos nil))
    (if (and (citre--tabulated-list-marked-positions)
             (not (citre--tabulated-list-marked-p)))
        (setq pos (point))
      (save-excursion
        (forward-line)
        (unless (eobp)
          (setq pos (point))))
      (unless pos
        (save-excursion
          (forward-line -1)
          (unless (bobp)
            (setq pos (point))))))
    pos))

(defun citre--code-map-print (&optional style)
  "A wrapper around `tabulated-list-print'.
This tries to always put the point and scroll the window to a
position that feels not intrusive and makes sense when browsing a
code map.

About the argument STYLE, see the docstring of
`citre--code-map-refresh'."
  (cond
   ((eq style 'remove-item)
    ;; Find the nearest item that's not to be removed, and goto there before
    ;; printing.
    (let ((pos (or (citre--find-position-near-region)
                   (citre--find-position-near-marked-items)
                   (citre--find-position-near-line))))
      (if pos (progn (goto-char pos)
                     (tabulated-list-print 'remember-pos 'update))
        (tabulated-list-print nil 'update))))
   ((eq style 'add-item)
    ;; When the added items are above the current line, some items will be
    ;; pushed beyond the start of window.  In a code map, items can fit in one
    ;; screen most of the time, so this can be confusing (where do my item
    ;; goes?).  We try to scroll down to restore the original line at the start
    ;; of window, but doesn't push current point below the end of window.
    (let ((window-start-linum-orig (line-number-at-pos (window-start)))
          (window-start-linum-new nil)
          (linum-in-window nil)
          (scroll-amount nil))
      (tabulated-list-print 'remember-pos 'update)
      (setq window-start-linum-new (line-number-at-pos (window-start)))
      (setq linum-in-window (1+ (- (line-number-at-pos)
                                   window-start-linum-new)))
      (setq scroll-amount (min (- (window-body-height) linum-in-window)
                               (max 0 (- window-start-linum-new
                                         window-start-linum-orig))))
      (scroll-down scroll-amount)))
   ((eq style 'switch-page)
    ;; We try to goto the line when we visit the page last time.
    (tabulated-list-print)
    (let* ((pos (citre--code-map-position))
           (idx (cl-position (nth (nth 3 pos) pos)
                             (citre--current-list-in-code-map)
                             :key #'car)))
      (when idx
        (goto-char (point-min))
        (forward-line idx))))
   (t
    (tabulated-list-print 'remember-pos 'update))))

(defun citre--code-map-make-entry-string (str)
  "Make entry for file names and symbols in the code map buffer.
STR is the file name or symbol name."
  (list str (vector str)))

;; TODO: If we extract a function in citre.el to convert from a record to a
;; location string, this can be simplified.
(defun citre--code-map-make-entry-definition (record)
  "Make entry for definition locations in the code map buffer.
RECORD is the record of the definition."
  (list record
        (vector (format "%s: %s"
                        (propertize (citre--relative-path
                                     (citre-get-field 'path record))
                                    'face 'warning)
                        (citre-get-field 'line record)))))

(defun citre--code-map-refresh (&optional style)
  "Refresh the code map in current buffer.
This is based on the position information in
`citre--code-map-position-alist'.

STYLE determines how should we put the point and scroll the
window.  Its value can be:

- `remove-item': Use this if selected items or current item will
  be hidden/removed after refresh, and this is the only change.
- `add-item': Use this if some item(s) will be added after
  refresh, and the current item is guaranteed to still exist.
- `switch-page': Use this if the page will be switched after
  refresh.
- nil: Don't specify STYLE if we are on the same page and no
  fancy things happen."
  (let* ((pos (citre--code-map-position))
         (pos-depth (nth 3 pos))
         (list (citre--current-list-in-code-map))
         (header (pcase pos-depth
                   (0 '[("File" 0 nil)])
                   (1 '[("Symbol" 0 nil)])
                   (_ '[("Definition" 0 nil)])))
         (locations (when (>= 2 pos-depth)
                      (cl-delete nil
                                 (mapcar
                                  (lambda (location)
                                    (unless (cdr location) (car location)))
                                  list))))
         (entries (if (<= pos-depth 1)
                      (mapcar #'citre--code-map-make-entry-string
                              (mapcar #'car list))
                    (mapcar #'citre--code-map-make-entry-definition
                            locations))))
    (setq tabulated-list-format header)
    (setq tabulated-list-entries entries)
    (tabulated-list-init-header)
    (citre--code-map-print style)))

(defun citre--open-code-map (&optional project current-window)
  "Open code map for current project.
If project root PROJECT is given, use that project instead.  If
CURRENT-WINDOW is non-nil, use current window."
  (let* ((project (or project (citre--project-root)))
         (map-buf-name (format "*Code map: %s*"
                               (abbreviate-file-name project)))
         (map-buf-presented (get-buffer map-buf-name))
         (map-buf (or map-buf-presented (generate-new-buffer map-buf-name))))
    (if current-window
        (switch-to-buffer map-buf)
      (pop-to-buffer map-buf))
    (unless map-buf-presented
      (citre-code-map-mode)
      (setq citre-project-root project))
    (citre--code-map-refresh 'switch-page)))

(defun citre--error-if-not-in-code-map ()
  "Signal an error if not browsing a code map."
  (unless (derived-mode-p 'citre-code-map-mode)
    (user-error "This command is for code map only")))

;;;;; Commands

(defun citre-see-symbol-in-code-map ()
  "See the definition list of the symbol at point.
If the symbol is not in the symbol list, add it to the list."
  (interactive)
  (let ((sym (thing-at-point 'symbol 'no-properties)))
    (unless sym
      (user-error "No symbol at point"))
    (unless (citre--key-in-alist sym
                                 (citre--get-in-code-map
                                  (citre--buffer-relative-file-name)))
      (let ((locations (citre-get-records sym 'exact)))
        (unless locations
          (user-error "Can't find definition"))
        (setf (citre--get-in-code-map
               (citre--buffer-relative-file-name) sym)
              (mapcar #'list locations))
        (citre--set-code-map-disk-state t)))
    (citre--set-code-map-position (citre--buffer-relative-file-name) sym)
    (citre--open-code-map)))

(defun citre-see-file-in-code-map ()
  "See the symbol list of current file."
  (interactive)
  (let ((file (citre--buffer-relative-file-name)))
    (unless (citre--key-in-alist file
                                 (citre--get-in-code-map))
      (user-error
       "File not in code map.  Add a symbol in this file to the map first"))
    (citre--set-code-map-position file)
    (citre--open-code-map)))

(defun citre-see-code-map ()
  "See the code map.
This will restore the status when you leave the map."
  (interactive)
  (let* ((map-buf-name (format "*Code map: %s*"
                               (abbreviate-file-name
                                (citre--project-root)))))
    ;; Don't refresh buffer (by calling `citre--open-code-map') if we have an
    ;; existing code map buffer.
    (if (get-buffer map-buf-name)
        (pop-to-buffer (get-buffer map-buf-name))
      (citre--open-code-map))))

(defun citre-code-map-backward ()
  "Go \"back\" in the code map.
This means to go from the definition list to the symbol list, or
further to the file list."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos-depth (nth 3 (citre--code-map-position))))
    (when (>= pos-depth 1)
      (setf (nth 3 (citre--code-map-position)) (1- pos-depth))
      (citre--code-map-refresh 'switch-page))))

(defun citre-code-map-forward ()
  "Go \"forward\" in the code map.
This means to go from the file list into the symbol list, or
further to the definition list, and finally to the location of a
definition."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((id (tabulated-list-get-id))
         (pos-depth (nth 3 (citre--code-map-position))))
    (when id
      (setf (nth pos-depth (citre--code-map-position)) id)
      (if (< pos-depth 2)
          (progn
            (setf (nth 3 (citre--code-map-position)) (1+ pos-depth))
            (citre--code-map-refresh 'switch-page))
        (citre--open-file-and-goto-line (citre-get-field 'path id)
                                        (citre-get-field 'linum id)
                                        'other-window-noselect)))))

(defun citre-code-map-open-file ()
  "Open the current file in a file list."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let ((pos-depth (nth 3 (citre--code-map-position))))
    (unless (= pos-depth 0)
      (user-error "Not in a file list"))
    (let ((file (tabulated-list-get-id))
          (path (expand-file-name (tabulated-list-get-id)
                                  (citre--project-root))))
      (if (file-exists-p path)
          (pop-to-buffer (find-file-noselect path))
        (user-error "%s doesn't exist" file)))))

(defun citre-code-map-mark ()
  "Mark or unmark current item.
When a region is active, mark all items in the region, or unmark
if they are already all marked.

An item is considered to be in the region if its beginning of
line is inside, or at the beginning, but not at the end of the
region.  This should be intuitive to use."
  (interactive)
  (citre--error-if-not-in-code-map)
  (if (use-region-p)
      (let* ((pos-in-region (citre--tabulated-list-selected-positions))
             (marked-pos (citre--tabulated-list-marked-positions))
             (region-all-marked-p (cl-subsetp pos-in-region marked-pos)))
        (save-excursion
          (dolist (pos pos-in-region)
            (goto-char pos)
            (if region-all-marked-p
                (citre--tabulated-list-unmark)
              (citre--tabulated-list-mark)))))
    (if (citre--tabulated-list-marked-p)
        (citre--tabulated-list-unmark)
      (citre--tabulated-list-mark))
    (forward-line)))

(defun citre-code-map-unmark-all ()
  "Unmark all items."
  (interactive)
  (citre--error-if-not-in-code-map)
  (save-excursion
    (goto-char (point-min))
    (while (and (<= (point) (point-max)) (not (eobp)))
      (when (get-text-property (point) 'citre-map-mark)
        (citre--tabulated-list-unmark))
      (forward-line))))

(defun citre-code-map-hide ()
  "Hide selected definitions, or current definition."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos-depth (nth 3 (citre--code-map-position)))
         (current-record (nth 2 (citre--code-map-position)))
         (pos-to-hide (or (citre--tabulated-list-selected-positions)
                          (citre--tabulated-list-marked-positions)
                          (list (point))))
         (hide-current-record-flag nil))
    (when (< pos-depth 2)
      (user-error "Hide can only be used on definitions"))
    (when pos-to-hide
      (save-excursion
        (dolist (pos pos-to-hide)
          (goto-char pos)
          (let ((id (tabulated-list-get-id)))
            (citre--set-hide-state id t)
            (when (equal id current-record)
              (setq hide-current-record-flag t)))))
      (when hide-current-record-flag
        (setf (nth 2 (citre--code-map-position)) nil))
      (citre--set-code-map-disk-state t)
      (citre--code-map-refresh 'remove-item))))

(defun citre-code-map-delete ()
  "Delete selected items, or current item.

This can only be used on symbols or files.  This operation can't
be undone, so Citre will ask if you really want to delete them."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos-depth (nth 3 (citre--code-map-position)))
         ;; TODO: we must be precise on the word "current".  In the code,
         ;; sometimes it refers to the thing in current line, and sometimes the
         ;; current thing in `citre--code-map-position-alist'.
         (current-item (nth pos-depth (citre--code-map-position)))
         (pos-to-delete (or (citre--tabulated-list-selected-positions)
                            (citre--tabulated-list-marked-positions)
                            (list (point))))
         (delete-current-item-flag nil))
    (when (= pos-depth 2)
      (user-error "Only symbols or files can be removed"))
    (when (and pos-to-delete
               (y-or-n-p "This can't be undone.  Really delete the item(s)? "))
      (save-excursion
        (dolist (pos pos-to-delete)
          (goto-char pos)
          (let ((id (tabulated-list-get-id)))
            (citre--delete-item-in-code-map (tabulated-list-get-id))
            (when (equal id current-item)
              (setq delete-current-item-flag t)))))
      (when delete-current-item-flag
        (dolist (i (number-sequence pos-depth 2))
          (setf (nth i (citre--code-map-position)) nil)))
      (citre--set-code-map-disk-state t)
      (citre--code-map-refresh 'remove-item))))

(defun citre-code-map-show-all ()
  "Show hidden definitions."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos (citre--code-map-position))
         (pos-depth (nth 3 (citre--code-map-position)))
         (definition-list (citre--get-in-code-map (car pos) (nth 1 pos)))
         (added-ids nil))
    (when (< pos-depth 2)
      (user-error "Hide is only for definitions"))
    (dotimes (n (length definition-list))
      (when (cdr (nth n definition-list))
        (push (car (nth n definition-list)) added-ids))
      (setf (cdr (nth n (citre--get-in-code-map (car pos) (nth 1 pos)))) nil))
    (citre--set-code-map-disk-state t)
    (citre--code-map-refresh 'add-item)
    (save-excursion
      (goto-char (point-min))
      (while (and (<= (point) (point-max)) (not (eobp)))
        (when (member (tabulated-list-get-id) added-ids)
          (citre--tabulated-list-mark))
        (forward-line)))))

(defun citre-code-map-keep ()
  "Keep selected items.
This means hide other items in a definition list, or delete other
items in a symbol or file list.

The delete operation can't be undone, so Citre will ask if you
really want to delete them."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos-depth (nth 3 (citre--code-map-position)))
         (current-item (nth pos-depth (citre--code-map-position)))
         (pos-to-keep (or (citre--tabulated-list-selected-positions)
                          (citre--tabulated-list-marked-positions)))
         (number-of-items (length (citre--current-list-in-code-map)))
         (remove-current-item-flag nil))
    (when (= number-of-items (length pos-to-keep))
      (pcase pos-depth
        (2 (user-error "Nothing left to hide"))
        (_ (user-error "Nothing left to delete"))))
    (when (null pos-to-keep)
      (user-error "Nothing selected"))
    (when pos-to-keep
      (pcase pos-depth
        (2 (save-excursion
             (goto-char (point-min))
             (while (not (eobp))
               (unless (memq (point) pos-to-keep)
                 (let ((id (tabulated-list-get-id)))
                   (citre--set-hide-state (tabulated-list-get-id) t)
                   (when (equal id current-item)
                     (setq remove-current-item-flag t))))
               (forward-line))))
        (_ (when (y-or-n-p
                  "This can't be undone.  Really delete unselected item(s)? ")
             (save-excursion
               (goto-char (point-min))
               (while (not (eobp))
                 (unless (memq (point) pos-to-keep)
                   (let ((id (tabulated-list-get-id)))
                     (citre--delete-item-in-code-map (tabulated-list-get-id))
                     (when (equal id current-item)
                       (setq remove-current-item-flag t))))
                 (forward-line))))))
      (when remove-current-item-flag
        (dolist (i (number-sequence pos-depth 2))
          (setf (nth i (citre--code-map-position)) nil)))
      (citre--set-code-map-disk-state t)
      (citre--code-map-refresh 'remove-item))))

;; In the future ctags will have the ability to handle a source tree, which
;; means it knows all external entities (all the imports/includes/dependencies
;; ) of a file.  So finding the definition of a symbol is not just match its
;; name with all the tags, but also influenced by other things in that file.
;; This is wanted because we want more accurate candidates in
;; completion/jumping to definition.  But it sure will make handle file changes
;; in code map much more harder, because the concept of a code map actually
;; assumes the code is not changing.  However, at least we still need a manual
;; way to deal with changes, because deprecating a code map only due to file
;; changes is simply unacceptable.
(defun citre-code-map-update ()
  "Update the code map.
This means updating the definition locations for all symbols in
the code map.  If you see the lines in definition lists are
messed up due to file changes, update your tags file and call
this command.

This will unhide all hidden definitions, since there's no way to
tell whether a new definition location is the \"updated version\"
of an old one."
  (interactive)
  (citre--error-if-not-in-code-map)
  (when (y-or-n-p "This will unhide all hidden definitions.  Continue? ")
    (dolist (file (citre--get-in-code-map))
      (dolist (sym (cdr file))
        (setf (citre--get-in-code-map (car file) (car sym))
              (mapcar #'list (citre-get-records (car sym) 'exact)))))
    ;; The original definitions are gone, so we remove the definition location
    ;; in current position to prevent possible errors.
    (setf (nth 2 (citre--code-map-position)) nil)
    (citre--set-code-map-disk-state t)
    ;; File/symbol lists won't change, so we only refresh when inside a
    ;; definition list.
    (when (= (nth 3 (citre--code-map-position)) 2)
      ;; The `switch-page' style is appropriate here, see its implementation.
      ;; It does a complete refresh, which is needed since the definition lists
      ;; are completely changed.
      (citre--code-map-refresh 'switch-page))))

(defun citre-code-map-mark-missing ()
  "Mark missing items in a code map.
This means missing files in a file list, or symbols that don't
have definitions in a symbol list."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let ((pos-depth (nth 3 (citre--code-map-position))))
    (when (= pos-depth 2)
      (user-error "Mark missing is only for files and symbols"))
    (citre-code-map-unmark-all)
    (pcase pos-depth
      (0 (save-excursion
           (goto-char (point-min))
           (while (not (eobp))
             (unless (file-exists-p (expand-file-name
                                     (tabulated-list-get-id)
                                     (citre--project-root)))
               (citre--tabulated-list-mark))
             (forward-line))))
      (1 (save-excursion
           (goto-char (point-min))
           (while (not (eobp))
             (unless (citre-get-records (tabulated-list-get-id) 'exact)
               (citre--tabulated-list-mark))
             (forward-line)))))))

(defun citre-code-map-replace-file ()
  "Replace current file.
Use this when a file in file list doesn't exist due to changes of
the code."
  (interactive)
  (citre--error-if-not-in-code-map)
  (let* ((pos (citre--code-map-position))
         (current-file (tabulated-list-get-id))
         (last-browsed-file (nth 0 pos))
         (pos-depth (nth 3 pos)))
    (when (> pos-depth 0)
      (user-error "Replace is only for files"))
    (let ((file (citre--relative-path
                 (expand-file-name
                  (read-file-name "New file name: "
                                  (file-name-directory
                                   (expand-file-name current-file
                                                     (citre--project-root)))
                                  nil t)))))
      (when (cl-member file (citre--current-list-in-code-map)
                       :key #'car :test #'equal)
        (user-error "Duplicated file found in current list"))
      (setf (car (nth (cl-position current-file (citre--get-in-code-map)
                                   :key #'car :test #'equal)
                      (citre--get-in-code-map)))
            file)
      (when (equal last-browsed-file current-file)
        (setf (car (citre--code-map-position)) file)))
    (citre--set-code-map-disk-state t)
    (citre--code-map-refresh)))

(defun citre-save-code-map (&optional project)
  "Save code map to a file.
When PROJECT is specified, save the code map of PROJECT."
  (interactive)
  (let* ((project (or project (citre--project-root)))
         (file (cdr (citre--get-code-map-disk-state project)))
         (dir (if file (file-name-directory file) project))
         (filename (if file (file-name-nondirectory file) ".codemap"))
         (saveto (read-file-name "Save to: " dir nil nil filename)))
    (unless (string-empty-p saveto)
      (citre--print-value-to-file
       saveto
       `(:project-root
         ,project
         :map
         ,(citre--get-in-code-map nil nil project)
         :position
         ,(citre--code-map-position project)))
      (citre--set-code-map-disk-state nil saveto project)
      (message "Code map of %s saved" project))))

(defun citre-load-code-map ()
  "Load code map from file."
  (interactive)
  (let* ((file (cdr (citre--get-code-map-disk-state)))
         (dir (if file (file-name-directory file) (citre--project-root)))
         (filename (when (and dir
                              (file-readable-p (concat dir ".codemap")))
                     ".codemap"))
         (readfrom (read-file-name "Read from: " dir nil t filename)))
    (unless (string-empty-p readfrom)
      (let* ((data (citre--read-value-from-file readfrom))
             (project (plist-get data :project-root))
             (map (plist-get data :map))
             (pos (plist-get data :position)))
        ;; We don't require MAP to be presented since you can actually save an
        ;; empty code map, though that's not very interesting.
        (unless (and project pos)
          (user-error "The file is not a code map, or is corrupted"))
        (when (or (not (car (citre--get-code-map-disk-state project)))
                  (y-or-n-p
                   (format "Current code map of %s is not saved.  Continue? "
                           project)))
          (setf (citre--get-in-code-map nil nil project) map)
          (setf (citre--code-map-position project) pos)
          (citre--set-code-map-disk-state nil readfrom project)
          (citre--open-code-map project 'current-window)
          (message "Code map of %s loaded" project))))))

;;;; Setup

(defun citre--ask-for-save-code-map ()
  "Ask the user to save unsaved code maps.
This is run when you quit Emacs with
`save-buffers-kill-terminal'.  It only deals with code maps you
read from disk or saved once."
  (when citre--code-map-disk-state-alist
    (dolist (pair citre--code-map-disk-state-alist)
      (when (cadr pair)
        (when (y-or-n-p (format "Save code map of %s? " (car pair)))
          (citre-save-code-map (car pair))))))
  t)

(add-hook 'kill-emacs-query-functions #'citre--ask-for-save-code-map)

(provide 'citre-map)

;; Local Variables:
;; indent-tabs-mode: nil
;; outline-regexp: ";;;;* "
;; End:

;;; citre-map.el ends here
