;;; sgf.el --- Smart Game Format (focused on GO)

;; Copyright (C) 2012 Eric Schulte <eric.schulte@gmx.com>

;; Author: Eric Schulte <eric.schulte@gmx.com>
;; Created: 2012-05-15
;; Version: 0.1
;; Keywords: game go

;; This file is not (yet) part of GNU Emacs.
;; However, it is distributed under the same license.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; This file implements a reader, writer and visualizer for sgf files.
;; The sgf format is defined at http://www.red-bean.com/sgf/sgf4.html.

;;; Syntax:

;; BNF
;;
;; Collection = GameTree { GameTree }
;; GameTree   = "(" Sequence { GameTree } ")"
;; Sequence   = Node { Node }
;; Node       = ";" { Property }
;; Property   = PropIdent PropValue { PropValue }
;; PropIdent  = UcLetter { UcLetter }
;; PropValue  = "[" CValueType "]"
;; CValueType = (ValueType | Compose)
;; ValueType  = (None | Number | Real | Double | Color | SimpleText |
;;       	Text | Point  | Move | Stone)

;; Property Value Types
;;
;; UcLetter   = "A".."Z"
;; Digit      = "0".."9"
;; None       = ""
;; Number     = [("+"|"-")] Digit { Digit }
;; Real       = Number ["." Digit { Digit }]
;; Double     = ("1" | "2")
;; Color      = ("B" | "W")
;; SimpleText = { any character (handling see below) }
;; Text       = { any character (handling see below) }
;; Point      = game-specific
;; Move       = game-specific
;; Stone      = game-specific
;; Compose    = ValueType ":" ValueType

;;; Comments:

;; - an sgf tree is just a series of nested lists.
;; - a pointer into the tree marks the current location
;; - navigation using normal Sexp movement
;; - games build such trees as they go
;; - a board is just one interface into such a tree

;;; Notes:

;; Save the board layout associated with each node in the sgf file,
;; and only make new boards if there is not already a known board
;; layout for a node.  That way there is no worry about replacing
;; removed stones when moving backwards in a game.

;;; Code:
(require 'cl)


;;; Utility
(defun aget (key list) (cdr (assoc key list)))

(defun range (a &optional b)
  (block nil
    (let (tmp)
      (unless b
        (cond ((> a 0) (decf a))
              ((= a 0) (return nil))
              ((> 0 a) (incf a)))
        (setq b a a 0))
      (if (> a b) (setq tmp a a b b tmp))
      (let ((res (number-sequence a b)))
        (if tmp (nreverse res) res)))))

(defun other-color (color)
  (if (equal color :b) :w :b))


;;; Parsing
(defmacro parse-many (regexp string &rest body)
  (declare (indent 2))
  `(let (res (start 0))
     (flet ((collect (it) (push it res)))
       (while (string-match ,regexp ,string start)
         (setq start (match-end 0))
         (save-match-data ,@body))
       (nreverse res))))
(def-edebug-spec parse-many (regexp string body))

(defvar parse-prop-val-re
  "[[:space:]\n\r]*\\[\\([^\000]*?[^\\]?\\)\\]")

(defvar parse-prop-re
  (format "[[:space:]\n\r]*\\([[:alpha:]]+\\(%s\\)+\\)" parse-prop-val-re))

(defvar parse-node-re
  (format "[[:space:]\n\r]*;\\(\\(%s\\)+\\)" parse-prop-re))

(defvar parse-tree-part-re
  (format "[[:space:]\n\r]*(\\(%s\\)[[:space:]\n\r]*[()]" parse-node-re))

(defun parse-prop-ident (str)
  (let ((end (if (and (<= ?A (aref str 1))
                      (< (aref str 1) ?Z))
                 2 1)))
    (values (substring str 0 end)
            (substring str end))))

(defun parse-prop-vals (str)
  (parse-many parse-prop-val-re str
    (collect (match-string 1 str))))

(defun parse-prop (str)
  (multiple-value-bind (id rest) (parse-prop-ident str)
    (cons id (parse-prop-vals rest))))

(defun parse-props (str)
  (parse-many parse-prop-re str
    (multiple-value-bind (id rest) (parse-prop-ident (match-string 1 str))
      (collect (cons id (parse-prop-vals rest))))))

(defun parse-nodes (str)
  (parse-many parse-node-re str
    (collect (parse-props (match-string 1 str)))))

(defun parse-trees (str)
  (let ((cont-p 0))
    (parse-many parse-tree-part-re str
      (setq
       start (match-beginning 2)
       res (add-tree cont-p (save-match-data
                              (parse-nodes (match-string 1 str))) res)
       cont-p
       (+ cont-p
          (if (string= "(" (substring (match-string 0 str)
                                      (1- (length (match-string 0 str)))))
(defun closing-paren (str &optional index)
  ;; return index of closing paren watching out for []
  (save-match-data
    (let ((paren-open 0)
          (square-open 0))
      (loop for n from (or index 0) to (1- (length str))
         do (let ((last (when (> n 0) (aref str (1- n))))
                  (char (aref str n)))
              (cond
                ((= char ?\[)                           (incf square-open))
                ((and (= char ?\]) (not (= last ?\\)))  (decf square-open))
                ((and (= char ?\() (zerop square-open)) (incf paren-open))
                ((and (= char ?\)) (zerop square-open)) (decf paren-open))))
         when (zerop paren-open) return n))))

              1 -1))))))

(defun add-tree (cont-p tree-part res)
  (flet ((do-car (n acc) (if (<= n 0) acc (do-car (1- n) `(car ,acc)))))
    (if (null res)
        (setf res (nreverse tree-part))
      ;; TODO: almost there but need to push onto the end
      (eval `(push (nreverse tree-part) ,(do-car (1- cont-p) 'res)))))
  res)

(defun read-from-buffer (buffer)
  (process (parse-trees (with-current-buffer buffer (buffer-string)))))

(defun read-from-file (file)
  (with-temp-buffer
    (insert-file-contents-literally file)
    (read-from-buffer (current-buffer))))


;;; Processing
(defvar sgf-property-alist nil
  "A-list of property names and the function to interpret their values.")

(defun process (raw)
  (unless (listp raw) (error "sgf: can't process atomic sgf element."))
  (if (listp (car raw))
      (mapcar #'process raw)
    (let ((func (aget (car raw) sgf-property-alist)))
      (if func (cons (car raw) (funcall func (cdr raw))) raw))))

(defun process-date (date-args)
  (parse-time-string
   (if (> 1 (length date-args))
       (mapconcat #'number-to-string date-args " ")
     (car date-args))))
(add-to-list 'sgf-property-alist (cons "DT" #'process-date))

(defun process-board-size (size-args)
  (string-to-number (car size-args)))
(add-to-list 'sgf-property-alist (cons "S" #'process-board-size))

(defun char-to-pos (char)
  (cond
   ((or (< char ?A) (< ?z char))
    (error "sgf: invalid char %s" char))
   ((< char ?a) (+ 26 (- char ?A)))
   (t           (- char ?a))))

(defun process-position (position-string)
  (cons (char-to-pos (aref position-string 0))
        (char-to-pos (aref position-string 1))))

(defun process-move (move-args)
  (list (cons :pos (process-position (car move-args)))))
(add-to-list 'sgf-property-alist (cons "B" #'process-move))
(add-to-list 'sgf-property-alist (cons "W" #'process-move))

(defun process-label (label-args)
  (mapcar (lambda (l-arg)
            (if (string-match "\\([[:alpha:]]+\\):\\(.*\\)" l-arg)
                (list
                 (cons :label (match-string 2 l-arg))
                 (cons :pos (process-position (match-string 1 l-arg))))
              (error "sgf: malformed label %S" l-arg)))
          label-args))
(add-to-list 'sgf-property-alist (cons "LB" #'process-label))
(add-to-list 'sgf-property-alist (cons "LW" #'process-label))


;;; Visualization
;; - make buffer to show a board, and notes, etc...
;; - keep an index into the sgf file
;; - write functions for building boards from sgf files (forwards and backwards)
;; - sgf movement keys

(defvar local-board nil "Holds the board local to a GO buffer.")

(defvar local-sgf   nil "Holds the sgf data structure local to a GO buffer.")

(defvar local-index nil "Index into the sgf local to a GO buffer.")

(defun make-board (size) (make-vector (* size size) nil))

(defun board-size (board) (round (sqrt (length board))))

(defvar black-piece "X")

(defvar white-piece "O")

(defun board-header (board)
  (let ((size (board-size board)))
    (concat "    "
            (mapconcat (lambda (n)
                         (let ((char (+ ?A n)))
                           (when (>= char ?I)
                             (setq char (+ 1 char)))
                           (string char)))
                       (range size) " "))))

(defun pos-to-index (pos size)
  (+ (car pos) (* (cdr pos) size)))

(defun board-pos-to-string (board pos)
  (let ((size (board-size board)))
    (flet ((emph (n) (cond
                      ((= size 19)
                       (or (= 3 n)
                           (= 4 (- size n))
                           (= n (/ (- size 1) 2))))
                      ((= size 9)
                       (or (= 2 n)
                           (= 4 n))))))
      (let ((val (aref board (pos-to-index pos size))))
        (cond
         ((equal val :w) white-piece)
         ((equal val :b) black-piece)
         ((and (stringp val) (= 1 (length val)) val))
         (t  (if (and (emph (car pos)) (emph (cdr pos))) "+" ".")))))))

(defun board-row-to-string (board row)
  (let* ((size (board-size board))
         (label (format "%3d" (- size row)))
         (row-body (mapconcat
                    (lambda (n)
                      (board-pos-to-string board (cons row n)))
                    (range size) " ")))
    (concat label " " row-body label)))

(defun board-body-to-string (board)
  (mapconcat (lambda (m) (board-row-to-string board m))
             (range (board-size board)) "\n"))

(defun board-to-string (board)
  (let ((header (board-header board))
        (body (board-body-to-string board)))
    (mapconcat #'identity (list header body header) "\n")))

(defun board-to-pieces (board)
  (let (pieces)
    (dotimes (n (length board) pieces)
      (let ((val (aref board n)))
        (when val (push (cons val n) pieces))))))

(defun pieces-to-board (pieces size)
  (let ((board (make-vector size nil)))
    (dolist (piece pieces board)
      (setf (aref board (cdr piece)) (car piece)))))

(defun update-display ()
  (unless local-sgf (error "sgf: buffer has not associated sgf data"))
  (delete-region (point-min) (point-max))
  (goto-char (point-min))
  (insert
   "\n"
   (board-to-string local-board)
   "\n\n")
  (let ((comment (second (assoc "C" (sgf-ref local-sgf local-index)))))
    (when comment
      (insert (make-string (+ 6 (* 2 (board-size local-board))) ?=)
              "\n\n")
      (let ((beg (point)))
        (insert comment)
        (fill-region beg (point)))))
  (goto-char (point-min)))

(defun display-sgf (game)
  (let* ((root (car game))
         (name (format "*%s*"
                       (or (second (assoc "GN" root))
                           (second (assoc "EV" root))
                           "GO")))
         (buffer (if (get-buffer name)
                     (error "sgf: buffer %s already exists" name)
                   (get-buffer-create name)))
         (size (aget "S" root)))
    (unless size
      (error "sgf: game has no associated size"))
    (with-current-buffer buffer
      (sgf-mode)
      (set (make-local-variable 'local-sgf)   game)
      (set (make-local-variable 'local-board) (make-board size))
      (set (make-local-variable 'local-index) (list 0))
      (push (cons :pieces (board-to-pieces local-board))
            (sgf-ref local-sgf local-index))
      (update-display))
    (pop-to-buffer buffer)))

(defun display-sgf-file (path)
  (interactive "f")
  (display-sgf (car (read-from-file path))))

(defun sgf-ref (sgf index)
  (let ((part sgf))
    (while (car index)
      (setq part (nth (car index) part))
      (setq index (cdr index)))
    part))

(defun set-sgf-ref (sgf index new)
  (eval `(setf ,(reduce (lambda (acc el) (list 'nth el acc))
                        index :initial-value 'sgf)
               ',new)))

(defsetf sgf-ref set-sgf-ref)

(defun up ())

(defun down ())

(defun left (&optional num)
  (interactive "p")
  (prog1 (dotimes (n num n)
           (unless (sgf-ref local-sgf local-index)
             (update-display)
             (error "sgf: no more backwards moves."))
           (decf (car (last local-index)))
           (setq local-board (pieces-to-board
                              (aget :pieces (sgf-ref local-sgf local-index))
                              (length local-board))))
    (update-display)))

(defun right (&optional num)
  (interactive "p")
  (prog1 (dotimes (n num n)
           (incf (car (last local-index)))
           (unless (sgf-ref local-sgf local-index)
             (decf (car (last local-index)))
             (update-display)
             (error "sgf: no more forward moves."))
           (if (aget :pieces (sgf-ref local-sgf local-index))
               (setf local-board (pieces-to-board
                                  (aget :pieces (sgf-ref local-sgf local-index))
                                  (length local-board)))
             (clear-labels local-board)
             (apply-moves local-board (sgf-ref local-sgf local-index))
             (push (cons :pieces (board-to-pieces local-board))
                   (sgf-ref local-sgf local-index))))
    (update-display)))


;;; Board manipulation functions
(defun move-type (move)
  (cond
   ((member (car move) '("B"  "W"))  :move)
   ((member (car move) '("LB" "LW")) :label)))

(defun apply-moves (board moves)
  (flet ((bset (val data)
               (setf (aref board (pos-to-index (aget :pos data)
                                               (board-size board)))
                     (cond ((string= "B"  val)  :b)
                           ((string= "W"  val)  :w)
                           ((string= "LB" val) (aget :label data))
                           ((string= "LW" val) (aget :label data))
                           (t nil)))))
    (dolist (move moves board)
      (case (move-type move)
        (:move
         (bset (car move) (cdr move))
         (let ((color (if (string= "B" (car move)) :b :w)))
           (remove-dead local-board (other-color color))
           (remove-dead local-board color)))
        (:label
         (dolist (data (cdr move)) (bset (car move) data)))))))

(defun clear-labels (board)
  (dotimes (point (length board))
    (when (aref board point)
      (unless (member (aref board point) '(:b :w))
        (setf (aref board point) nil)))))

(defun stones-for (board color)
  (let ((count 0))
    (dotimes (n (length board) count)
      (when (equal color (aref board n)) (incf count)))))

(defun neighbors (board piece)
  (let ((size (board-size board))
        neighbors)
    (when (not (= (mod piece size) (1- size))) (push (1+ piece) neighbors))
    (when (not (= (mod piece size) 0))         (push (1- piece) neighbors))
    (when (< (+ piece size) (length board))    (push (+ piece size) neighbors))
    (when (> (- piece size) 0)                 (push (- piece size) neighbors))
    neighbors))

(defun alive-p (board piece &optional already)
  (let* ((val (aref board piece))
         (enemy (other-color val))
         (neighbors (remove-if (lambda (n) (member n already))
                               (neighbors board piece)))
         (neighbor-vals (mapcar (lambda (n) (aref board n)) neighbors))
         (friendly-neighbors (delete nil (map 'list (lambda (n v)
                                                      (when (equal v val) n))
                                              neighbors neighbor-vals)))
         (already (cons piece already)))
    (or (some (lambda (v) (not (or (equal v enemy) ; touching open space
                                   (equal v val))))
              neighbor-vals)
        (some (lambda (n) (alive-p board n already)) ; touching alive dragon
              friendly-neighbors))))

(defun remove-dead (board color)
  ;; must remove one color at a time for ko situations
  (let (cull)
    (dotimes (n (length board) board)
      (when (and (equal (aref board n) color) (not (alive-p board n)))
        (push n cull)))
    (dolist (n cull cull) (setf (aref board n) nil))))


;;; Display mode
(defvar sgf-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<right>") 'right)
    (define-key map (kbd "<left>")  'left)
    (define-key map (kbd "q") (lambda () (interactive)
                                (kill-buffer (current-buffer))))
    map)
  "Keymap for `sgf-mode'.")

(define-derived-mode sgf-mode nil "SGF"
  "Major mode for editing text written for viewing SGF files.")


;;; Tests
(require 'ert)

(ert-deftest sgf-parse-prop-tests ()
  (flet ((should= (a b) (should (tree-equal a b :test #'string=))))
    (should= (parse-props "B[pq]") '(("B" "pq")))
    (should= (parse-props "GM[1]") '(("GM" "1")))
    (should= (parse-props "GM[1]\nB[pq]\tB[pq]")
             '(("GM" "1") ("B" "pq") ("B" "pq")))
    (should (= (length (cdar (parse-props "TB[as][bs][cq][cr][ds][ep]")))
               6))))

(ert-deftest sgf-parse-multiple-small-nodes-test ()
  (let* ((str ";B[pq];W[dd];B[pc];W[eq];B[cp];W[cm];B[do];W[hq];B[qn];W[cj]")
         (nodes (parse-nodes str)))
    (should (= (length nodes) 10))
    (should (tree-equal (car nodes) '(("B" "pq")) :test #'string=))))

(ert-deftest sgf-parse-one-large-node-test ()
  (let* ((str ";GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]AW[ja][oa]
               [pa][db][eb]")
         (node (car (parse-nodes str))))
    (should (= (length node) 10))
    (should (= (length (cdar (last node))) 5))))

(ert-deftest sgf-parse-simple-tree ()
  (let* ((str "(;GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]AW[ja][oa]
               [pa][db][eb])")
         (tree (parse-trees str)))
    (should (= 1  (length tree)))
    (should (= 1  (length (car tree))))
    (should (= 10 (length (caar tree))))))

(ert-deftest sgf-parse-nested-tree ()
  (let* ((str "(;GM[1]FF[4]
               SZ[19]
               GN[GNU Go 3.7.11 load and print]
               DT[2008-12-14]
               KM[0.0]HA[0]RU[Japanese]AP[GNU Go:3.7.11]
               (;AW[ja][oa][pa][db][eb] ;AB[fa][ha][ia][qa][cb]))")
         (tree (parse-trees str)))
    (should (= 2  (length tree)))
    (should (= 9 (length (car (first tree)))))
    (should (= 2 (length (second tree))))))

(ert-deftest sgf-parse-file-test ()
  (let ((game (car (read-from-file "sgf-files/jp-ming-5.sgf"))))
    (should (= 247 (length game)))))

(ert-deftest sgf-empty-board-to-string-test ()
  (let ((board (make-vector (* 19 19) nil))
        (string (concat "    A B C D E F G H J K L M N O P Q R S T\n"
                        " 19 . . . . . . . . . . . . . . . . . . . 19\n"
                        " 18 . . . . . . . . . . . . . . . . . . . 18\n"
                        " 17 . . . . . . . . . . . . . . . . . . . 17\n"
                        " 16 . . . + . . . . . + . . . . . + . . . 16\n"
                        " 15 . . . . . . . . . . . . . . . . . . . 15\n"
                        " 14 . . . . . . . . . . . . . . . . . . . 14\n"
                        " 13 . . . . . . . . . . . . . . . . . . . 13\n"
                        " 12 . . . . . . . . . . . . . . . . . . . 12\n"
                        " 11 . . . . . . . . . . . . . . . . . . . 11\n"
                        " 10 . . . + . . . . . + . . . . . + . . . 10\n"
                        "  9 . . . . . . . . . . . . . . . . . . .  9\n"
                        "  8 . . . . . . . . . . . . . . . . . . .  8\n"
                        "  7 . . . . . . . . . . . . . . . . . . .  7\n"
                        "  6 . . . . . . . . . . . . . . . . . . .  6\n"
                        "  5 . . . . . . . . . . . . . . . . . . .  5\n"
                        "  4 . . . + . . . . . + . . . . . + . . .  4\n"
                        "  3 . . . . . . . . . . . . . . . . . . .  3\n"
                        "  2 . . . . . . . . . . . . . . . . . . .  2\n"
                        "  1 . . . . . . . . . . . . . . . . . . .  1\n"
                        "    A B C D E F G H J K L M N O P Q R S T")))
    (should (string= string (board-to-string board)))))

(ert-deftest sgf-non-empty-board-to-string-test ()
  (let* ((joseki (car (read-from-file "sgf-files/3-4-joseki.sgf")))
         (root (car joseki))
         (rest (cdr joseki))
         (board (make-board (aget "S" root)))
         (string (concat "    A B C D E F G H J K L M N O P Q R S T\n"
                         " 19 . . . . . . . . . . . . . . . . . . . 19\n"
                         " 18 . . . . . . . . . . . . . . . . . . . 18\n"
                         " 17 . . . . . . . . . . . . . . . . . . . 17\n"
                         " 16 . . . + . . . . . + . . . . . + . . . 16\n"
                         " 15 . . . . . . . . . . . . . . . . . . . 15\n"
                         " 14 . . . . . . . . . . . . . . . . . . . 14\n"
                         " 13 . . . . . . . . . . . . . . . . . . . 13\n"
                         " 12 . . . . . . . . . . . . . . . . . . . 12\n"
                         " 11 . . . . . . . . . . . . . . . . . . . 11\n"
                         " 10 . . X + . . . . . + . . . . . + . . . 10\n"
                         "  9 . . . . . . . . . . . . . . . . . . .  9\n"
                         "  8 . . . . . . . . . . . . . . . . . . .  8\n"
                         "  7 . . . . . . . . . . . . . . . . . . .  7\n"
                         "  6 . . . . . . . . . . . . . . . . . . .  6\n"
                         "  5 . . . X . . . . . . . . . . . . . . .  5\n"
                         "  4 . . X + O . O . . + . . . . . + . . .  4\n"
                         "  3 . . . X O . . . . . O . . . . . . . .  3\n"
                         "  2 . . . X . . . . . . . . . . . . . . .  2\n"
                         "  1 . . . . . . . . . . . . . . . . . . .  1\n"
                         "    A B C D E F G H J K L M N O P Q R S T")))
    (dolist (moves rest)
      (apply-moves board moves))
    (board-to-string board)
    (should t)))

(defmacro with-sgf-file (file &rest body)
  (declare (indent 1))
  `(let* ((sgf    (car (read-from-file ,file)))
          (buffer (display-sgf sgf)))
     (unwind-protect (with-current-buffer buffer ,@body)
       (should (kill-buffer buffer)))))
(def-edebug-spec parse-many (file body))

(ert-deftest sgf-display-fresh-sgf-buffer ()
  (with-sgf-file "sgf-files/3-4-joseki.sgf"
    (should local-board)
    (should local-sgf)
    (should local-index)))

(ert-deftest sgf-independent-points-properties ()
  (with-sgf-file "sgf-files/3-4-joseki.sgf"
    (let ((points-length (length (assoc :points (sgf-ref sgf '(0))))))
      (right 4)
      (should (= points-length
                 (length (assoc :points (sgf-ref sgf '(0)))))))))

(ert-deftest sgf-neighbors ()
  (let ((board (make-board 19)))
    (should (= 2 (length (neighbors board 0))))
    (should (= 2 (length (neighbors board (length board)))))
    (should (= 4 (length (neighbors board (/ (length board) 2)))))
    (should (= 3 (length (neighbors board 1))))))

(ert-deftest sgf-singl-stone-capture ()
  (flet ((counts () (cons (stones-for local-board :b)
                          (stones-for local-board :w))))
    (with-sgf-file "sgf-files/1-capture.sgf"
      (right 3) (should (tree-equal (counts) '(2 . 0))))))

(ert-deftest sgf-remove-dead-stone-ko ()
  (flet ((counts () (cons (stones-for local-board :b)
                          (stones-for local-board :w))))
    (with-sgf-file "sgf-files/ko.sgf"
      (should (tree-equal (counts) '(0 . 0))) (right 1)
      (should (tree-equal (counts) '(1 . 0))) (right 1)
      (should (tree-equal (counts) '(1 . 1))) (right 1)
      (should (tree-equal (counts) '(2 . 1))) (right 1)
      (should (tree-equal (counts) '(2 . 2))) (right 1)
      (should (tree-equal (counts) '(3 . 2))) (right 1)
      (should (tree-equal (counts) '(2 . 3))) (right 1)
      (should (tree-equal (counts) '(3 . 2))) (right 1)
      (should (tree-equal (counts) '(2 . 3))))))

(ert-deftest sgf-two-stone-capture ()
  (flet ((counts () (cons (stones-for local-board :b)
                          (stones-for local-board :w))))
    (with-sgf-file "sgf-files/2-capture.sgf"
      (right 8) (should (tree-equal (counts) '(6 . 0))))))

(ert-deftest sgf-parse-empty-properties ()
  (with-sgf-file "sgf-files/w-empty-properties.sgf"
    (should (remove-if-not (lambda (prop)
                             (let ((val (cdr prop)))
                               (and (sequencep val) (= 0 (length val)))))
                           (car sgf)))))

(ert-deftest sgf-paren-matching ()
  (let ((str "(a (b) [c \\] ) ] d)"))
    (should (= (closing-paren str) (1- (length str))))
    (should (= (closing-paren str 3) 5))))
