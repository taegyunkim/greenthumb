#lang racket

(require "../forwardbackward.rkt" "../ast.rkt"
         "arm-ast.rkt" "arm-machine.rkt")

(provide arm-forwardbackward%)

(define arm-forwardbackward%
  (class forwardbackward%
    (super-new)
    (inherit-field machine validator validator-precise)
    (override vector->id mask-in inst->vector
              reduce-precision increase-precision
	      get-live-mask
              try-cmp?)

    (define bit (get-field bit machine))
    (define max-val (arithmetic-shift 1 bit))
    (define mask (sub1 (arithmetic-shift 1 bit)))
    (define inst-id (get-field inst-id machine))
    (define cmp-inst
      (map (lambda (x) (vector-member x inst-id))'(cmp tst cmp# tst#)))

    (define (vector->id state)
      ;; (define z (vector-ref state 2))
      (define regs (vector-ref state 0))
      (define id 0)
        
      (for ([r regs]) (set! id (+ (* id max-val) (bitwise-and r mask))))
      
      ;; (+ id (* (vector-member z z-range-db) (power max-val nregs))))
      id)

    (define (inst->vector x)
      (vector (inst-op x) (inst-args x) (inst-shfop x) (inst-shfarg x) (inst-cond x)))

    (define (mask-in state-vec live-list #:keep-flag [keep #t])
      (define live-reg (car live-list))
      (define live-mem (cdr live-list))
      
      (define regs (vector-ref state-vec 0))
      (define mems (vector-ref state-vec 1))
      (define z (vector-ref state-vec 2))
      (define fp (vector-ref state-vec 3))
      (vector
       (for/vector ([r regs] [i (in-naturals)])
		   (and (member i live-reg) r))
       (for/vector ([m mems] [i (in-naturals)])
		   (and (member i live-mem) m))
       (if keep z -1) fp))
    
    (define bit-nonprecise (get-field bit (get-field machine validator)))
    (define bit-precise (get-field bit (get-field machine validator-precise)))
    
    (define (reduce-inst x change)
      (define opcode-name (send machine get-inst-name (inst-op x)))
      (define args (inst-args x))
      (define shfop-name (and (inst-shfop x) (send machine get-shf-inst-name (inst-shfop x))))
      (define shfarg (inst-shfarg x))
      (define types (send machine get-arg-types opcode-name))
      
      (define new-args
        (for/vector
         ([arg args]
          [type types])
         (if (member type '(op2 bit bit-no-0))
             (change arg)
             arg)))

      (define new-shfarg
        (if (member shfop-name '(lsr# asr# lsl#))
            (change shfarg)
            shfarg))

      (arm-inst (inst-op x) new-args (inst-shfop x) new-shfarg (inst-cond x)))
    
    (define (reduce-precision prog)
      (define (change arg)
        (cond
         [(= arg bit-precise) bit-nonprecise]
         [(= arg (sub1 bit-precise)) (sub1 bit-nonprecise)]
         [(= arg (/ bit-precise 2)) (/ bit-nonprecise 2)]
         [else arg]))
      (for/vector ([x prog]) (reduce-inst x change)))
    
    (define (increase-precision prog)
      (define (change arg)
        (cond
         [(= arg bit-nonprecise) bit-precise]
         [(= arg (sub1 bit-nonprecise)) (sub1 bit-precise)]
         [(= arg (/ bit-nonprecise 2)) (/ bit-precise 2)]
         [else arg]))
      (for/vector ([x prog]) (reduce-inst x change)))

    (define (get-live-mask state-vec)
      (cons
       (filter number?
               (for/list ([i (in-naturals)]
                          [r (vector-ref state-vec 0)])
                         (and r i)))
       (filter number?
               (for/list ([i (in-naturals)]
                          [r (vector-ref state-vec 1)])
                         (and r i)))
       )
      )

    (define (try-cmp? code state live)
      (define z (progstate-z state))
      (define live-z (progstate-z live))
      (define use-cond1 (for/or ([x code]) (member (inst-op x) cmp-inst)))
      (define use-cond2 (for/or ([x code]) (not (= (inst-cond x) 0))))

      (cond
       [(and live-z (> z -1) use-cond1) 1]
       [(and (> z -1) (or use-cond1 use-cond2)) 2]
       [else 0]))
      

    ))