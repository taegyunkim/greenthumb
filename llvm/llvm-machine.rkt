#lang racket

(require "../machine.rkt" "../inst.rkt" "../memory-rosette.rkt")

(provide llvm-machine% (all-defined-out))

(define llvm-machine%
  (class machine%
    (super-new)
    (inherit-field bitwidth random-input-bits config
                   opcodes nop-id
                   ;; required fileds for stochastic and enumerative only
		   classes)
    (inherit get-class-id filter-live)
    (override get-constructor set-config get-state
              ;; required functions for stochastic and enumerative only
              reset-arg-ranges get-arg-types get-arg-ranges 
	      update-live update-live-backward
              )

    (define (get-constructor) llvm-machine%)
    
    (unless bitwidth (set! bitwidth 32))
    (set! random-input-bits bitwidth)
    (set! nop-id 0)
    (set! opcodes '#(nop 
                     and or xor add sub
                     and# or# xor# add# sub#
		     _sub
		     shl lshr ashr
		     shl# lshr# ashr#
		     _shl _lshr _ashr
                     ctlz
                     store load
                     ))
    ;;_and _or _xor _add 

    (define var-range #f)
    (define const-range #f)
    (define bit-range #f)

    (when config (set-config config))
    
    (define (set-config x) 
      (set! config x) 
      (reset-arg-ranges))

    ;; Generate program state from function init.
    ;; Our program state is a vector storing values of variables.
    (define (get-state init [extra #f])
      (vector
       (for/vector ([i config]) (init))
       (new memory-rosette% [get-fresh-val init])))

    ;;;;;;;;;;;;;;;;;;;;; For stochastic and enumerative ;;;;;;;;;;;;;;;;;;

    ;; Instruction classes
    (set! classes 
          (vector '(and or xor add sub shl lshr ashr) ;; rrr
        	  '(and# or# xor# add# sub#) ;; rri
        	  '(shl# lshr# ashr#) ;;rri
        	  '(_sub _shl _lshr _ashr) ;;rir (commutative: _and _or _xor _add)
                  ))
	  
    ;; Set valid operands' ranges.
    (define (reset-arg-ranges)
      (set! var-range (list->vector (range config)))
      (set! const-range (vector 0 1 -1 -2 -8))
      (set! bit-range (vector 0 1)))

    ;; Return types of operands given opcode-name.
    (define (get-arg-types opcode-name)
      (define class-id (get-class-id opcode-name))
      (cond
       [(equal? class-id 0) (vector `var-o `var-i `var-i)]
       [(equal? class-id 1) (vector `var-o `var-i `const)]
       [(equal? class-id 2) (vector `var-o `var-i `bit)]
       [(equal? class-id 3) (vector `var-o `const `var-i)]
       [(equal? opcode-name `ctlz) (vector `var-o `var-i)]
       [(equal? opcode-name `load) (vector `var-o `var-i)]
       [(equal? opcode-name `store) (vector `var-i `var-i)]
       [else (vector)]))

    ;; Return valid operands' ranges given opcode-name, live-in, live-out, and mode.
    ;; opcode-name: symbol
    ;; live-in & live-out: compact format
    ;; There are 3 modes.
    ;;  1) `basic (no restriction)
    ;;  2) `no-args = ignore reigster operands. Return `var-o and `var-i for operand that is input variable and output variable respectively. This mode is only used for enumerative search.
    (define (get-arg-ranges opcode-name entry live-in
                            #:live-out [live-out #f] #:mode [mode `basic])
      (define var-i
        (if live-in
            (filter-live var-range (vector-ref live-in 0))
            var-range))
      (define var-o
        (if live-out
            (filter-live var-range (vector-ref live-out 0))
            var-range))

      (for/vector 
       ([type (get-arg-types opcode-name)])
       (if (equal? mode `basic)
           (cond
            [(equal? type `var-o)  var-o]
            [(equal? type `var-i)  var-i]
            [(equal? type `const)  const-range]
            [(equal? type `bit)    bit-range])
           (cond
            [(equal? type `var-o)  `var-o]
            [(equal? type `var-i)  `var-i]
            [(equal? type `const)  const-range]
            [(equal? type `bit)    bit-range]))))

    ;; instruction x: e.g. add v0, v1, v2
    ;; livenss before execute inst (given live): (vector * #t #t)
    ;; liveness after execute inst (output): (vector #t #t #t)
    ;; v0 is live after executing inst, so set the first entry to #t.
    (define (update-live live x)
      (define op (inst-op x))
      (cond
       [(= op nop-id) live]
       [(equal? (vector-ref opcodes op) `store) live]
       [else
        (let ([new-live (vector-copy (vector-ref live 0))])
          (vector-set! new-live (vector-ref (inst-args x) 0) #t)
          (vector new-live (vector-ref live 1)))
        ]))

    ;; For enumerative search
    ;; instruction x: e.g. add v0, v1, v2
    ;; liveness *after* execute inst (given live): (vector #t * *)
    ;; liveness *before* execute inst (output): (vector #f #t #t).
    ;; v1 and v2 must be live-in. v0 is not live-in.
    (define (update-live-backward live x)
      (define new-live (vector-copy (vector-ref live 0)))
      (define opcode-name (vector-ref opcodes (inst-op x)))
      (define args (inst-args x))
      (define args-type (get-arg-types opcode-name))
      (for ([arg args]
            [type args-type])
           (cond
            ;; kill first
            [(equal? type `var-o) (vector-set! new-live arg #f)]
            [(equal? type `var-i) (vector-set! new-live arg #t)]))
      (vector new-live (vector-ref live 1)))

    
    ;; Analyze input code and update operands' ranges.
    (define/override (analyze-args prefix code postfix live-in-list live-out
                          #:only-const [only-const #f] #:vreg [vreg 0])
      (define const-add (vector->list const-range))
      (define bit-add (vector->list bit-range))
      (for ([x (vector-append prefix code postfix)])
           (let ([ans (analyze-args-inst x)])
             (set! const-add (append const-add (first ans)))
             (set! bit-add (append bit-add (second ans)))))

      (set! const-range (list->vector (set->list (list->set const-add))))
      (set! bit-range (list->vector (set->list (list->set bit-add))))
      (pretty-display `(const-range ,const-range))
      (pretty-display `(bit-range ,bit-range))
      )

    (define (analyze-args-inst x)
      (define opcode (vector-ref opcodes (inst-op x)))
      (define args (inst-args x))
      (define const-add (list))
      (define bit-add (list))
      (for ([arg args]
	    [type (get-arg-types opcode)])
           (cond
            [(equal? type `const) (set! const-add (cons arg const-add))]
            [(equal? type `bit) (set! bit-add (cons arg bit-add))]))
      (list const-add bit-add))

    (define (merge-vector-list-unique vec l)
      (list->vector (set->list (list->set (append (vector->list vec) l)))))

    ))
      