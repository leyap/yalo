;;;; -*- Mode: Lisp -*-
;;;; Author: 
;;;;     Yujian Zhang <yujian.zhang@gmail.com>
;;;; Description:
;;;;     Lisp Assembly Program.
;;;; License: 
;;;;     GNU General Public License v2
;;;;     http://www.gnu.org/licenses/gpl-2.0.html

(in-package :cc)

;;; CL code in this file will be reused by Ink bootstrapping,
;;; therefore only list data structure is used even though hash table
;;; might be better.

(defparameter *symtab* nil)
(defparameter *revisits* nil "A list of (index length expr) with index
refers to the code position in terms of bytes with starting offset 0,
starting from length bytes will be replaced with value evaluated from
expr.")

(defun asm (listing)
  "One pass assembler. listing is in the form of LAP as described in
       http://code.google.com/p/yalo/wiki/AssemblySyntax
   Returns opcodes as a list of bytes."
  (setf *symtab* nil
        *revisits* nil)
  (let (code
        (origin 0)
        (cursor 0))
    (dolist (e listing)
      (if (listp e) 
          (let (snippet)
            (case (car e)
              (org (unless (null code)
                     (error "asm: org should be placed earlier."))
                   (setf origin (second e)
                         cursor origin))
              (times (setf snippet 
                           (repeat-list 
                            (eval (replacer (replacer (second e) '$$ origin)
                                            '$ cursor))
                            (encode (nthcdr 2 e) origin cursor))))
              (t (setf snippet (encode e origin cursor))))
            (when snippet 
              (setf code (nconc code snippet))))
          (if (assoc e *symtab*)
              (if (eq (cdr (assoc e *symtab*)) '?)
                  (setf (cdr (assoc e *symtab*)) cursor)
                  (error "asm: duplicated symbol ~A." e))
              (push (cons e cursor) *symtab*)))
      (setf cursor (+ origin (length code))))
    (when (rassoc '? *symtab*)
      (error "asm: undefined symbol ~A" (car (rassoc '? *symtab*))))
    (dolist (r *revisits*)
      (ecase (second r)
        (1 (setf (elt code (first r)) 
                 (signed->unsigned (- (cdr (assoc (fourth r) *symtab*)) 
                                      (third r)) 
                                   (second r))))))
    code))

(defun encode (e origin cursor)
  "Opcode encoding, including pseudo instructions like db/dw."
  (mklist 
   (cond
     ((assoc e *x86-64-syntax* :test #'equal) 
      (second (assoc e *x86-64-syntax* :test #'equal)))
     (t (ecase (car e)
          (db (etypecase (second e)
                (string (string->bytes (second e)))
                (number (second e))))
          (dw (word->bytes (second e)))
          (int (list #xcd (second e)))
          (jmp (ecase (second e)
                 ($ (list #xeb 254))
                 (short (encode-jmp 'jmp (third e) cursor 1 origin))))
          (mov (encode-mov e origin cursor)))))))

(defparameter *x86-64-syntax*
  `(((int    3)                 . (#xcc))
    ((int    imm8)              . (#xcd ib))
    ((mov    r8 imm8)           . ((+ #xb0 r) ib))
    ((mov    r16 imm16)         . ((+ #xb8 r) iw)))
  "Syntax table for x86-64. For each entry, 1st part is the mnemonic
  code, 2nd part is the translated machine code. For details, refer to
  http://code.google.com/p/yalo/wiki/AssemblyX64Overview")

(defun lookup-sym (sym index length base origin)
  "If sym has a value other than ? in *symtab*, return the value;
   Otherwise:
     - make a new entry in *symtab* with value ?
     - make a new entry in *revisits*
     - return a length number of ?"
  (if (and (assoc sym *symtab*) (not (eq (cdr (assoc sym *symtab*)) '?)))
      (list (signed->unsigned (- (cdr (assoc sym *symtab*)) base) length))
      (progn
        (push (cons sym '?) *symtab*)
        (push (list (- index origin) length base sym) *revisits*)
        (repeat-element length '?))))

(defun signed->unsigned (value length)
  "Change value from signed to unsigned."
  (if (>= value 0)
      value
      (ecase length
        (1 (+ 256 value)))))

(defun encode-jmp (mnemonic sym cursor length origin)
  "Encode mnemonic jmp and jcc."
  (ecase length
    (1 (cons (jmp->opcode mnemonic length)
             (lookup-sym sym (1+ cursor) length (+ cursor 1 length)
                         origin)))))

(defun jmp->opcode (mnemonic length)
  "Returns the opcode for mnemonic jmp and jcc."
  (ecase length
    (1 (ecase mnemonic
         (jmp #xeb)
         (jne #x75)))))

(defun encode-mov (e origin cursor)
  "Encode mnemonic mov."
  (let ((dest (second e))
        (src (third e)))
    (cond
      ((and (r8? dest) (numberp src)) 
       (list (+ (register->int dest) #xb0) src))
      ((r16? dest)
       (append (list (+ (register->int dest) #xb8)) 
               (word->bytes (if (numberp src)
                                src
                                (car (lookup-sym (third e) (1+ cursor) 2 0 
                                                 origin))))))
      (t -1))))
    
(defun encode-modr/m (mod rm reg)
  "Encode ModR/M byte."
  (+ (* mod #b1000000) (* reg #b1000) rm))

(defun encode-1-operand (dest reg)
  (encode-modr/m #b11 (register->int dest) reg))

(defun r8? (register)
  "Returns t if register is 8-bit."
  (case register
    ((al ah bl bh cl ch dl dh) t)
    (t nil)))

(defun r16? (register)
  "Returns t if register is 16-bit."
  (case register
    ((ax bx cx dx sp bp si di) t)
    (t nil)))

(defun instruction-format (instruction)
  "Returns the instruction format for encoding."
  (cons (car instruction) 
        (mapcar #'operand-type (cdr instruction))))

(defun operand-type (operand)
  "Returns operand type with following values:
     imm8, imm16, imm32, imm64,
     r8, r16, r32, r64"
  (cond
    ((numberp operand)
     (cond 
       ((and (<= (- (expt 2 7))  operand (1- (expt 2 7))))  'imm8)
       ((and (<= (- (expt 2 15)) operand (1- (expt 2 15)))) 'imm16)
       ((and (<= (- (expt 2 31)) operand (1- (expt 2 31)))) 'imm32)
       ((and (<= (- (expt 2 63)) operand (1- (expt 2 31)))) 'imm64)
       (t (error "Invalid operand: ~A" operand))))
    ((listp operand)
     'imm)
    (t 
     (ecase operand
       ((al cl dl bl ah ch dh bh bpl spl dil sil)                       'r8)
       ((ax cx dx bx sp bp si di)                                       'r16)
       ((eax ecx edx ebx esp ebp esi edi)                               'r32)
       ((rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15) 'r64)
       ))))

(defun register->int (register)
  "Returns the integer representation for register when encode ModR/M byte.
   Returns -1 if not a register."
  (case register
    ((al ax eax mm0 xmm0) 0)
    ((cl cx ecx mm1 xmm1) 1)
    ((dl dx edx mm2 xmm2) 2)
    ((bl bx ebx mm3 xmm3) 3)
    ((ah sp esp mm4 xmm4) 4)
    ((ch bp ebp mm5 xmm5) 5)
    ((dh si esi mm6 xmm6) 6)
    ((bh di edi mm7 xmm7) 7)
    (t -1)))

(defun mklist (obj)
  "Returns obj if it is already a list; otherwise lispy it."
  (if (listp obj)
      obj
      (list obj)))

(defun string->bytes (s)
  (map 'list #'char-code s))

(defun word->bytes (w)
  (list (mod w 256) (floor w 256)))

(defun repeat-element (n element)
  (loop for i from 0 below n collect element))

(defun repeat-list (n list)
  (case n
    (1 list)
    (t (append list (repeat-list (1- n) list)))))

(defun replacer (list old new)
  "Recursively search list, replace old with new."
  (cond
    ((null list) nil)
    ((atom (car list)) (cons (if (eq (car list) old)
                                 new
                                 (car list))
                             (replacer (cdr list) old new)))
    (t (cons (replacer (car list) old new)
             (replacer (cdr list) old new)))))

(defun read-image (filename)
  "Return a list of bytes contained in the file with filename."
  (with-open-file (s filename :element-type 'unsigned-byte)
    (when s
      (let (output)
        (loop for byte = (read-byte s nil)
             while byte do (push byte output))
        (nreverse output)))))

(defun write-image (bytes filename)
  "Write a list of bytes to the file with filename."
  (with-open-file (s filename :direction :output :element-type 'unsigned-byte
                     :if-exists :supersede)
    (when s
      (dolist (b bytes)
        (write-byte b s)))))

(defun write-kernel (filename)
  "Output kernel (including bootloader) as an image file with filename."
  (write-image (asm *bootloader*) filename))
    

