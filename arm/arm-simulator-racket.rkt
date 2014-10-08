#lang racket

(require "../simulator.rkt" "../ops-racket.rkt" 
         "../ast.rkt"
         "../machine.rkt" "arm-machine.rkt")
(provide arm-simulator-racket%)

(define arm-simulator-racket%
  (class simulator%
    (super-new)
    (init-field machine)
    (override interpret performance-cost)
        
    (define bit (get-field bit machine))
    (define nregs (send machine get-nregs))
    (define nmems (send machine get-nmems))
    (define nop-id (send machine get-inst-id `nop))
    (define inst-id (get-field inst-id machine))

    (define (shl a b) (<< a b bit))
    (define (ushr a b) (>>> a b bit))
    (define-syntax-rule (finitize-bit x) (finitize x bit))

    (define byte0 0)
    (define byte1 (quotient bit 4))
    (define byte2 (* 2 byte1))
    (define byte3 (* 3 byte1))
    (define byte4 bit)
    (define byte-mask (sub1 (arithmetic-shift 1 byte1)))
    (define high-mask (shl (sub1 (shl 1 byte2)) byte2))
    (define mask (sub1 (arithmetic-shift 1 bit)))

    ;; helper functions
    (define-syntax-rule (bool->num b) (if b 1 0))

    (define-syntax-rule (bvop op)     
      (lambda (x y) (finitize-bit (op x y))))

    (define-syntax-rule (bvuop op)     
      (lambda (x) (finitize-bit (op x))))

    (define-syntax-rule (bvcmp op) 
      (lambda (x y) (bool->num (op x y))))

    (define-syntax-rule (bvucmp op)   
      (lambda (x y) 
        (bool->num (if (equal? (< x 0) (< y 0)) (op x y) (op y x)))))

    (define-syntax-rule (bvshift op)
      (lambda (x y)
        (finitize-bit (op x (bitwise-and byte-mask y)))))

    (define-syntax-rule (bvbit op)
      (lambda (a b)
        (if (and (>= b 0) (< b bit))
            (finitize-bit (op a (shl 1 b)))
            a)))

    (define bvadd (bvop +))
    (define bvsub (bvop -))
    (define bvrsub (bvop (lambda (x y) (- y x))))

    (define bvnot (lambda (x) (bitwise-not (finitize-bit x))))
    (define bvand (bvop bitwise-and))
    (define bvor  (bvop bitwise-ior))
    (define bvxor (bvop bitwise-xor))
    (define bvandn (lambda (x y) (bvnot (bitwise-and x y))))
    (define bviorn  (lambda (x y) (bvnot (bitwise-ior x y))))

    (define bvrev (bvuop rev))
    (define bvrev16 (bvuop rev16))
    (define bvrevsh (bvuop revsh))
    (define bvrbit (bvuop rbit))

    (define bvshl  (bvshift shl))
    (define bvshr  (bvshift >>))
    (define bvushr (bvshift ushr))

    (define bvmul (bvop *))
    (define bvmla (lambda (a b c) (finitize-bit (+ c (* a b)))))
    (define bvmls (lambda (a b c) (finitize-bit (- c (* a b)))))

    (define (setbit d a width shift)
      (let* ([mask (sub1 (shl 1 width))]
             [keep (bitwise-and d (bitwise-not (shl mask shift)))]
             [insert (bvshl (bitwise-and a mask) shift)])
        (finitize-bit (bitwise-ior keep insert))))

    (define (clrbit d width shift)
      (let* ([keep (bitwise-not (shl (sub1 (shl 1 width)) shift))])
        (bitwise-and keep d)))

    (define (ext d a width shift)
      (bitwise-and (>> a shift) (sub1 (shl 1 width))))

    (define (sext d a width shift)
      (let ([keep (bitwise-and (>> a shift) (sub1 (shl 1 width)))])
	(bitwise-ior
	 (if (= (bitwise-bit-field keep (sub1 width) width) 1)
	     (shl -1 width)
	     0)
	 keep)))

    (define (clz x)
      (let ([mask (shl 1 (sub1 bit))]
            [count 0]
            [still #t])
        (for ([i bit])
             (when still
                   (let ([res (bitwise-and x mask)])
                     (set! x (shl x 1))
                     (if (= res 0)
                         (set! count (add1 count))
                         (set! still #f)))))
        count))

    (define (rev a)
      (bitwise-ior 
       (shl (bitwise-bit-field a byte0 byte1) byte3)
       (shl (bitwise-bit-field a byte1 byte2) byte2)
       (shl (bitwise-bit-field a byte2 byte3) byte1)
       (bitwise-bit-field a byte3 byte4)))

    (define (rev16 a)
      (bitwise-ior 
       (shl (bitwise-bit-field a byte2 byte3) byte3)
       (shl (bitwise-bit-field a byte3 byte4) byte2)
       (shl (bitwise-bit-field a byte0 byte1) byte1)
       (bitwise-bit-field a byte1 byte2)))

    (define (revsh a)
      (bitwise-ior 
       (if (= (bitwise-bit-field a (sub1 byte1) byte1) 1) high-mask 0)
       (shl (bitwise-bit-field a byte0 byte1) byte1)
       (bitwise-bit-field a byte1 byte2)))

    (define (rbit a)
      (let ([res 0])
        (for ([i bit])
             (set! res (bitwise-ior (shl res 1) (bitwise-and a 1)))
             (set! a (>> a 1)))
        res))
    
    ;; Interpret a given program from a given state.
    ;; state: initial progstate
    ;; policy: a procedure that enforces a policy to speed up synthesis. Default to nothing.
    (define (interpret program state [is-candidate #f] #:dep [dep #f])
      ;;(pretty-display `(interpret))
      (define regs (vector-copy (progstate-regs state)))
      (define memory (vector-copy (progstate-memory state)))
      (define regs-dep (and dep (vector-copy (progstate-regs state))))
      (define memory-dep (and dep (vector-copy (progstate-memory state))))
      (define inter (list))
      (define init-vals (append (list 0) (vector->list regs) (vector->list memory)))
      
      (define-syntax add-inter
        (syntax-rules ()
          ((add-inter x) (set! inter (cons x inter)))
          ((add-inter x y ...) (set! inter (append (list x y ...) inter)))))

      (define (create-node val p)
        (define my-size (+ (if val 1 0) (for/sum ([i (filter node? p)]) (node-size i))))
        (define my-val (if (member val init-vals) #f val))
        (define my-p (list))
        (for ([x p])
          (when (node? x)
            (if (node-val x) 
                (set! my-p (cons x my-p))
                (set! my-p (append (node-p x) my-p)))))
        (node my-val my-size my-p))

      (define (interpret-step step)
        (define op (inst-op step))
        (define args (inst-args step))
                                        ;(pretty-display `(interpret-step ,op ,args))
        
        (define-syntax-rule (inst-eq x) (equal? op (vector-member x inst-id)))

        (define-syntax-rule (args-ref args i) (vector-ref args i))

        ;; sub add
        (define (rrr f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define b (args-ref args 2))
	  (define val (f (vector-ref regs a) (vector-ref regs b)))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list (vector-ref regs-dep a)
						      (vector-ref regs-dep b))))
	      (add-inter val)))

        (define (rrrr f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define b (args-ref args 2))
          (define c (args-ref args 3))
	  (define val (f (vector-ref regs a) (vector-ref regs b) (vector-ref regs c)))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val 
                                                   (list (vector-ref regs-dep a)
                                                         (vector-ref regs-dep b)
                                                         (vector-ref regs-dep c))))
	      (add-inter val)))

        ;; count leading zeros
        (define (rr f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
	  (define val (f (vector-ref regs a)))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list (vector-ref regs-dep a))))
	      (add-inter val)))

        ;; mov
        (define (ri f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
	  (define val (f a))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list a)))
	      (add-inter val)))

        ;; subi addi lw
        (define (rri f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define b (args-ref args 2))
	  (define val (f (vector-ref regs a) b))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list (vector-ref regs-dep a))))
	      (add-inter val)))

        ;; store
        (define (str reg-offset)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define b (args-ref args 2))
	  (define index 
            (if reg-offset
                (+ (vector-ref regs a) (vector-ref regs b))
                (+ (vector-ref regs a) b)))
	  (define val (vector-ref regs d))
          (vector-set! memory index val)
	  (if dep
	      (let* ([val-dep (list (vector-ref regs-dep d))]
                     [index-dep 
                      (if reg-offset
                          (list (vector-ref regs-dep a) (vector-ref regs-dep b))
                          (list (vector-ref regs-dep a)))]) ;; TODO: no b?
		(vector-set! memory-dep index 
                             (create-node #f (list (create-node val val-dep)
                                                   (create-node index index-dep)))))
	      (add-inter index)))

        ;; load
        (define (ldr reg-offset)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define b (args-ref args 2))
	  (define index 
            (if reg-offset
                (+ (vector-ref regs a) (vector-ref regs b))
                (+ (vector-ref regs a) b)))
          (define val (vector-ref memory index))
          (vector-set! regs d val)
	  (if dep
	      (let* ([val-dep (list (vector-ref memory-dep index))]
                     [index-dep 
                      (if reg-offset
                          (list (vector-ref regs-dep a) (vector-ref regs-dep b))
                          (list (vector-ref regs-dep a)))]) ;; TODO: no b?
		(vector-set! regs-dep d 
                             (create-node #f (list (create-node val val-dep)
                                                   (create-node index index-dep)))))
	      (add-inter index)))

        ;; setbit
        (define (rrii f)
          (define d (args-ref args 0))
          (define a (args-ref args 1))
          (define width (args-ref args 3))
          (define shift (args-ref args 2))
	  (define val (f (vector-ref regs d) (vector-ref regs a) width shift))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list (vector-ref regs-dep d)
                                                             (vector-ref regs-dep a))))
	      (add-inter val)))

        ;; clrbit
        (define (rii f)
          (define d (args-ref args 0))
          (define width (args-ref args 2))
          (define shift (args-ref args 1))
	  (define val (f (vector-ref regs d) width shift))
          (vector-set! regs d val)
	  (if dep
	      (vector-set! regs-dep d (create-node val (list (vector-ref regs-dep d))))
	      (add-inter val)))
        
        (cond
         ;; basic
         [(inst-eq `nop) (void)]
         [(inst-eq `add) (rrr bvadd)]
         [(inst-eq `sub) (rrr bvsub)]
         [(inst-eq `rsb) (rrr bvrsub)]

         [(inst-eq `and) (rrr bitwise-and)]
         [(inst-eq `orr) (rrr bitwise-ior)]
         [(inst-eq `eor) (rrr bitwise-xor)]
         [(inst-eq `bic) (rrr bvandn)]
         [(inst-eq `orn) (rrr bviorn)]

	 ;; basic i
         [(inst-eq `addi) (rri bvadd)]
         [(inst-eq `subi) (rri bvsub)]
         [(inst-eq `rsbi) (rri bvrsub)]

         [(inst-eq `andi) (rri bitwise-and)]
         [(inst-eq `orri) (rri bitwise-ior)]
         [(inst-eq `eori) (rri bitwise-xor)]
         [(inst-eq `bici) (rri bvandn)]
         [(inst-eq `orni) (rri bviorn)]
         
	 ;; move
         [(inst-eq `mov) (rr identity)]
         [(inst-eq `mvn) (rr bvnot)]
         
	 ;; move i
         [(inst-eq `movi) (ri identity)]
         [(inst-eq `mvni) (ri bvnot)]

         ;; reverse
         [(inst-eq `rev)   (rr bvrev)]
         [(inst-eq `rev16) (rr bvrev16)]
         [(inst-eq `revsh) (rr bvrevsh)]
         [(inst-eq `rbit)  (rr bvrbit)]

         ;; div & mul
         [(inst-eq `sdiv) (rrr quotient)]
         [(inst-eq `udiv) (rrr (lambda (x y) (quotient (bitwise-and x mask)
						       (bitwise-and y mask))))]
         [(inst-eq `mul)  (rrr bvmul)]
         [(inst-eq `mla)  (rrrr bvmla)]
         [(inst-eq `mls)  (rrrr bvmls)]
         
         ;; shift Rd, Rm, Rs
	 ;; only the least significant byte of Rs is used.
         [(inst-eq `lsr) (rrr bvushr)]
         [(inst-eq `asr) (rrr bvshr)]
         [(inst-eq `lsl) (rrr bvshl)]
         
         ;; shift i
         [(inst-eq `lsri) (rri bvushr)]
         [(inst-eq `asri) (rri bvshr)]
         [(inst-eq `lsli) (rri bvshl)]

         ;; bit
         [(inst-eq `bfc)  (rii  clrbit)]
         [(inst-eq `bfi)  (rrii setbit)]

	 ;; others
         [(inst-eq `sbfx) (rrii sext)]
         [(inst-eq `ubfx) (rrii ext)]
         [(inst-eq `clz)  (rr clz)]

         ;; load/store
         [(inst-eq `ldri) (ldr #f)]
         [(inst-eq `stri) (str #f)]
         [(inst-eq `ldr)  (ldr #t)]
         [(inst-eq `str)  (str #t)]

         [else (assert #f "undefine instruction")]

         ))

      (define exec #t)
      (for ([x program])
           (if exec
               (interpret-step x)
               (set! exec #t)))
      ;; (cond
      ;;  [dep
      ;;   (pretty-display "regs-dep")
      ;;   (for ([i (vector-length regs-dep)])
      ;;        (pretty-display (format "----- reg[~a] -----" i))
      ;;        (display-node (vector-ref regs-dep i)))
      ;;   (pretty-display "memory-dep")
      ;;   (for ([i (vector-length memory-dep)])
      ;;        (pretty-display (format "----- mem[~a] -----" i))
      ;;        (display-node (vector-ref memory-dep i)))
      ;;   ]
      ;;  [else
      ;;   (pretty-display `(inter ,inter))])
      
      (progstate+ regs memory (if dep 
				  (progstate regs-dep memory-dep)
				  inter)))

    (define (performance-cost code)
      (define cost 0)
      (for ([x code])
           (cond
            [(equal? (inst-op x) (vector-member `nop inst-id)) (void)]
            [else (set! cost (add1 cost))])
           )
      (when debug (pretty-display `(performance ,cost)))
      cost)
    ))