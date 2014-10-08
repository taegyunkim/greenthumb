#lang racket

(require "../compress.rkt" "../ast.rkt" "../machine.rkt" "arm-machine.rkt")

(provide arm-compress%)

(define arm-compress%
  (class compress%
    (super-new)
    (inherit-field machine)
    (override compress-reg-space decompress-reg-space 
              ;;pre-constraint-rename
            select-code combine-code combine-live-out)
    
    (define inst-id (get-field inst-id machine))
    (define branch-inst-id (get-field branch-inst-id machine))

    (define (inner-rename x reg-map)
      (define (register-rename r)
        (cond
         [(and (> (string-length r) 1) (equal? (substring r 0 2) "r"))
          (format "r~a" (vector-ref reg-map (string->number (substring r 2))))]
         
         [else r]))
      
      (inst (inst-op x) 
            (list->vector (map register-rename (vector->list (inst-args x))))))

    ;; Input
    ;; program, a list of (inst opcode args) where opcode is string and args is a list of string
    ;; Output
    ;; 1) compressed program in the same format as input
    ;; 2) compressed live-out
    ;; 3) map-back
    ;; 4) machine-info in custom format--- (list nregs nmem) for arm
    (define (compress-reg-space program live-out)
      (define reg-set (mutable-set))
      (define max-reg 0)

      ;; Collect all used register ids.
      (define (inner-collect x)
        (for ([r (inst-args x)])
             (when (and (> (string-length r) 1) (equal? (substring r 0 1) "r"))
                   (let ([reg-id (string->number (substring r 2))])
                     (set-add! reg-set reg-id)
                     (when (> reg-id max-reg) (set! max-reg reg-id))))))
      (for ([x program]) (inner-collect x))

      ;; Construct register map from original to compressed version.
      (define reg-map (make-vector (add1 max-reg) #f))
      (define id 0)
      (for ([i 32])
           (when (set-member? reg-set i)
                 (vector-set! reg-map i id)
                 (set! id (add1 id))))

      ;; Construct register map from compressed back to original version.
      (define reg-map-back (make-vector id))
      (set! id 0)
      (for ([i 32])
           (when (set-member? reg-set i)
                 (vector-set! reg-map-back id i)
                 (set! id (add1 id))))

      ;; Check if program access memory or not.
      (define mem-access #f)
      (for ([x program])
           (let ([opcode (inst-op x)])
             (when (or (equal? opcode "str") (equal? opcode "ldr"))
                   (set! mem-access #t))))

      ;; Generate outputs.
      (define compressed-program 
        (traverse program inst? (lambda (x) (inner-rename x reg-map)))) 
      (define compressed-live-out 
        (map (lambda (x) (vector-ref reg-map x)) 
             (filter (lambda (x) (and (<= x max-reg) (vector-ref reg-map x))) live-out)))

      (values compressed-program
              compressed-live-out
              reg-map-back 
              (list id (if mem-access 8 1))))

    (define (decompress-reg-space program reg-map)
      (traverse program inst? (lambda (x) (inner-rename x reg-map))))

    ;; Select an interesting portion of code to superoptimize.
    ;; Exclude COPY, branching instructions.
    ;; Outputs
    ;; 1. selected-code to be optimized, #f if no code to be optimized
    ;; 2. starting position
    ;; 3. stopping position
    ;; 4. additional live-out in the same format as one used by optimize.rkt--- a list of live registers
    (define (select-code code)
      (print-struct code)
      (define len (vector-length code))
      
      (define (find-interest i succ check)
        (define (f i)
          (if (vector-member (string->symbol (inst-op (vector-ref code i))) inst-id)
              i
              (let ([new-i (succ i)])
                (if (check new-i) (f new-i) new-i))))
        (f i))

      (define (add-live-out x extra-live-out)
        (for ([arg (inst-args x)])
             (when (regexp-match-positions #rx"r" arg)
                   (set! extra-live-out 
                         (cons (string->number (substring arg 2)) extra-live-out))))
        extra-live-out)
      
      (define start (find-interest 0 add1 (lambda (x) (< x len))))
      (define stop 
        (if (>= start len) 
            start
            (find-interest (sub1 len) sub1 (lambda (x) (>= x start)))))
      (pretty-display (format "start=~a, stop=~a" start stop))

      (cond
       [(<= (- stop start) 1) (values #f start stop (list))]

       [else
        (define select (vector-drop (vector-take code (add1 stop)) start))
        (define new-len (vector-length select))
        (define extra-live-out (list))

        (cond
         [(<= new-len 2) (values #f start stop (list))]
         [else
          (define pass
            (for/and ([i select]) 
                     (vector-member (string->symbol (inst-op i)) inst-id)))
          
          (when pass
                (for ([i (range (add1 stop) len)])
                     (set! extra-live-out (add-live-out (vector-ref code i) extra-live-out))))
          
          (values (and pass select) start stop extra-live-out)])
        ]))

    (define (combine-code original select start stop)
      (set! select 
            (vector-filter (lambda (x) (not (equal? (inst-op x) "nop"))) select))
      (vector-append (vector-take original start)
                     select
                     (vector-drop original (add1 stop))))
    
    

    ;; Combine 2 live-out info into one.
    ;; Inputs are in the same format as live-out used by optimize.rkt and returned by (select-code)--- a list of live registers.
    (define (combine-live-out org extra) (remove-duplicates (append org extra)))

    ))