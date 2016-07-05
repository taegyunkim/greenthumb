#lang racket

(require "../machine.rkt" "../inst.rkt" "../memory-rosette.rkt")

(provide llvm-mem-machine% (all-defined-out))

(define llvm-mem-machine%
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

    (define (get-constructor) llvm-mem-machine%)
    
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

    ))
      