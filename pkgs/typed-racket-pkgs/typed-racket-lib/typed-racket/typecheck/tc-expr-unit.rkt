#lang racket/unit


(require (rename-in "../utils/utils.rkt" [private private-in])
         racket/match (prefix-in - (contract-req))
         "signatures.rkt"
         "check-below.rkt" "tc-app-helper.rkt" "../types/kw-types.rkt"
         (types utils abbrev union subtype type-table classes filter-ops)
         (private-in parse-type type-annotation syntax-properties)
         (rep type-rep filter-rep object-rep)
         (utils tc-utils)
         (env lexical-env tvar-env index-env)
         racket/format racket/list
         racket/private/class-internal
         syntax/parse syntax/stx
         unstable/syntax
         (only-in racket/list split-at)
         (typecheck internal-forms tc-envops)
         ;; Needed for current implementation of typechecking letrec-syntax+values
         (for-template (only-in racket/base letrec-values))

         (for-label (only-in '#%paramz [parameterization-key pz:pk])
                    (only-in racket/private/class-internal find-method/who)))

(import tc-if^ tc-lambda^ tc-app^ tc-let^ tc-send^ check-subforms^ tc-literal^
        check-class^)
(export tc-expr^)

(define-literal-set tc-expr-literals #:for-label
  (find-method/who))

;; do-inst : syntax type -> type
;; Perform a type instantiation, delegating to the appropriate helper
;; function depending on if the argument is a row or not
(define (do-inst stx ty)
  (define inst (type-inst-property stx))
  (if (row-syntax? inst)
      (do-row-inst stx inst ty)
      (do-normal-inst stx inst ty)))

;; row-syntax? Syntax -> Boolean
;; This checks if the syntax object resulted from a row instantiation
(define (row-syntax? stx)
  (define lst (stx->list stx))
  (and lst (pair? lst)
       (eq? (syntax-e (car lst)) '#:row)))

;; do-normal-inst : Syntax Syntax Type -> Type
;; Instantiate a normal polymorphic type
(define (do-normal-inst stx inst ty)
  (define (split-last l)
    (let-values ([(all-but last-list) (split-at l (sub1 (length l)))])
      (values all-but (car last-list))))
  (define (in-improper-stx stx)
    (let loop ([l stx])
      (match l
        [#f null]
        [(cons a b) (cons a (loop b))]
        [e (list e)])))
  (match ty
    [(list ty)
     (list
      (for/fold ([ty ty])
        ([inst (in-list (in-improper-stx inst))])
        (cond [(not inst) ty]
              [(not (or (Poly? ty) (PolyDots? ty)))
               (tc-error/expr #:return (Un) "Cannot instantiate non-polymorphic type ~a"
                              (cleanup-type ty))]
              [(and (Poly? ty)
                    (not (= (syntax-length inst) (Poly-n ty))))
               (tc-error/expr #:return (Un)
                              "Wrong number of type arguments to polymorphic type ~a:\nexpected: ~a\ngot: ~a"
                              (cleanup-type ty) (Poly-n ty) (syntax-length inst))]
              [(and (PolyDots? ty) (not (>= (syntax-length inst) (sub1 (PolyDots-n ty)))))
               ;; we can provide 0 arguments for the ... var
               (tc-error/expr #:return (Un)
                              "Wrong number of type arguments to polymorphic type ~a:\nexpected at least: ~a\ngot: ~a"
                              (cleanup-type ty) (sub1 (PolyDots-n ty)) (syntax-length inst))]
              [(PolyDots? ty)
               ;; In this case, we need to check the last thing.  If it's a dotted var, then we need to
               ;; use instantiate-poly-dotted, otherwise we do the normal thing.
               ;; In the case that the list is empty we also do the normal thing
               (let ((stx-list (syntax->list inst)))
                 (if (null? stx-list)
                     (instantiate-poly ty (map parse-type stx-list))
                     (let-values ([(all-but-last last-stx) (split-last stx-list)])
                       (match (syntax-e last-stx)
                         [(cons last-ty-stx (? identifier? last-id-stx))
                          (unless (bound-index? (syntax-e last-id-stx))
                            (tc-error/stx last-id-stx "~a is not a type variable bound with ..." (syntax-e last-id-stx)))
                          (if (= (length all-but-last) (sub1 (PolyDots-n ty)))
                              (let* ([last-id (syntax-e last-id-stx)]
                                     [last-ty (extend-tvars (list last-id) (parse-type last-ty-stx))])
                                (instantiate-poly-dotted ty (map parse-type all-but-last) last-ty last-id))
                              (tc-error/expr #:return (Un) "Wrong number of fixed type arguments to polymorphic type ~a:\nexpected: ~a\ngot: ~a"
                                             ty (sub1 (PolyDots-n ty)) (length all-but-last)))]
                         [_
                          (instantiate-poly ty (map parse-type stx-list))]))))]
              [else
               (instantiate-poly ty (stx-map parse-type inst))])))]
    [_ (if inst
           (tc-error/expr #:return (Un)
                          "Cannot instantiate expression that produces ~a values"
                          (if (null? ty) 0 "multiple"))
           ty)]))

;; do-row-inst : Syntax ClassRow Type -> Type
;; Instantiate a row polymorphic function
(define (do-row-inst stx row-stx ty)
  ;; At this point, we know `stx` represents a row so we can parse it.
  ;; The parsing is done here because if `inst` did the parsing, it's
  ;; too early and ends up with an empty type environment.
  (define row
    (syntax-parse row-stx
      [(#:row (~var clauses (row-clauses parse-type)))
       (attribute clauses.row)]))
  (match ty
    [(list ty)
     (list
      (cond [(not row) ty]
            [(not (PolyRow? ty))
             (tc-error/expr #:return (Un) "Cannot instantiate non-row-polymorphic type ~a"
                            (cleanup-type ty))]
            [else
             (match-define (PolyRow: _ constraints _) ty)
             (check-row-constraints
              row constraints
              (λ (name)
                (tc-error/delayed
                 (~a "Cannot instantiate row with member " name
                     " that the given row variable requires to be absent"))))
             (instantiate-poly ty (list row))]))]
    [_ (if row
           (tc-error/expr #:return (Un)
                          "Cannot instantiate expression that produces ~a values"
                          (if (null? ty) 0 "multiple"))
           ty)]))

;; typecheck an identifier
;; the identifier has variable effect
;; tc-id : identifier -> tc-results
(define/cond-contract (tc-id id)
  (--> identifier? tc-results/c)
  (let* ([ty (lookup-type/lexical id)])
    (ret ty
         (make-FilterSet (-not-filter (-val #f) id)
                         (-filter (-val #f) id))
         (make-Path null id))))

;; typecheck an expression, but throw away the effect
;; tc-expr/t : Expr -> Type
(define (tc-expr/t e) (match (single-value e)
                        [(tc-result1: t _ _) t]
                        [t (int-err "tc-expr returned ~a, not a single tc-result, for ~a" t (syntax->datum e))]))

(define (tc-expr/check/t e t)
  (match (tc-expr/check e t)
    [(tc-result1: t) t]))

;; typecheck an expression by passing tr-expr/check a tc-results
(define/cond-contract (tc-expr/check/type form expected)
  (--> syntax? Type/c tc-results/c)
  (tc-expr/check form (ret expected)))

(define (tc-expr/check form expected)
  (parameterize ([current-orig-stx form])
    ;; the argument must be syntax
    (unless (syntax? form)
      (int-err "bad form input to tc-expr: ~a" form))
    ;; typecheck form
    (let loop ([form* form] [expected expected] [checked? #f])
      (cond [(type-ascription form*)
             =>
             (lambda (ann)
               (let* ([r (tc-expr/check/internal form* ann)]
                      [r* (check-below (check-below r ann) expected)])
                 ;; add this to the *original* form, since the newer forms aren't really in the program
                 (add-typeof-expr form r)
                 ;; around again in case there is an instantiation
                 ;; remove the ascription so we don't loop infinitely
                 (loop (remove-ascription form*) r* #t)))]
            [(type-inst-property form*)
             ;; check without property first
             ;; to get the appropriate type to instantiate
             (match (tc-expr (type-inst-property form* #f))
               [(tc-results: ts fs os)
                ;; do the instantiation on the old type
                (let* ([ts* (do-inst form* ts)]
                       [ts** (ret ts* fs os)])
                  (add-typeof-expr form ts**)
                  ;; make sure the new type is ok
                  (check-below ts** expected))]
               ;; no annotations possible on dotted results
               [ty (add-typeof-expr form ty) ty])]
            [(external-check-property form*)
             =>
             (lambda (check)
               (check form*)
               (loop (external-check-property form* #f)
                     expected
                     checked?))]
            ;; nothing to see here
            [checked? expected]
            [else 
             (define t (tc-expr/check/internal form* expected))
             (add-typeof-expr form t)
             (check-below t expected)]))))

(define (explicit-fail stx msg var)
  (cond [(and (identifier? var) (lookup-type/lexical var #:fail (λ _ #f)))
         =>
         (λ (t)
           (tc-error/expr #:stx stx
                          (string-append (syntax-e msg) "; missing coverage of ~a")
                          t))]
         [else (tc-error/expr #:stx stx (syntax-e msg))]))

;; check that `expr` doesn't evaluate any references 
;; to `name` that aren't under `lambda`
;; value-restriction? : syntax identifier -> boolean
(define (value-restriction? expr name)
  (syntax-parse expr
    [((~literal #%plain-lambda) . _) #true]
    [((~literal case-lambda) . _) #true]
    [_ #false]))

;; tc-expr/check : syntax tc-results -> tc-results
(define/cond-contract (tc-expr/check/internal form expected)
  (--> syntax? tc-results/c tc-results/c)
  (parameterize ([current-orig-stx form])
    ;(printf "form: ~a\n" (syntax-object->datum form))
    ;; the argument must be syntax
    (unless (syntax? form)
      (int-err "bad form input to tc-expr: ~a" form))
    (syntax-parse form
      #:literal-sets (kernel-literals tc-expr-literals)
      ;; a TR-annotated class
      [stx:tr:class^
       (check-class form expected)]
      [stx:exn-handlers^
       (register-ignored! form)
       (check-subforms/with-handlers/check form expected)]
      [stx:ignore-some^
       (register-ignored! form)
       (check-subforms/ignore form)
       ;; We trust ignore to be only on syntax objects objects that are well typed
       (ret -Bottom)]
      ;; explicit failure
      [t:typecheck-failure
       (explicit-fail #'t.stx #'t.message #'t.var)]
      ;; data
      [(quote #f) (ret (-val #f) -false-filter)]
      [(quote #t) (ret (-val #t) -true-filter)]
      [(quote val)
       (match expected
         [(tc-result1: t)
          (ret (tc-literal #'val t) -true-filter)]
         [_
          (ret (tc-literal #'val #f))])]
      ;; syntax
      [(quote-syntax datum) (ret (-Syntax (tc-literal #'datum)) -true-filter)]
      ;; mutation!
      [(set! id val)
       (match-let* ([(tc-result1: id-t) (single-value #'id)]
                    [(tc-result1: val-t) (single-value #'val)])
         (unless (subtype val-t id-t)
           (type-mismatch id-t val-t "mutation only allowed with compatible types"))
         (ret -Void))]
      ;; top-level variable reference - occurs at top level
      [(#%top . id) (tc-id #'id)]
      [(#%variable-reference . _)
       (ret -Variable-Reference)]
      ;; identifiers
      [x:identifier (tc-id #'x)]
      ;; w-c-m
      [(with-continuation-mark e1 e2 e3)
       (define key-t (single-value #'e1))
       (match key-t
         [(tc-result1: (Continuation-Mark-Keyof: rhs))
          (tc-expr/check/type #'e2 rhs)
          (tc-expr/check #'e3 expected)]
         [(? (λ (result)
               (and (identifier? #'e1)
                    (free-identifier=? #'pz:pk #'e1 #f (syntax-local-phase-level)))))
          (tc-expr/check/type #'e2 Univ)
          (tc-expr/check #'e3 expected)]
         [(tc-result1: key-t)
          ;(check-below key-t -Symbol)
          ;; FIXME -- would need to protect `e2` with any-wrap/c contract
          ;; instead, just fail

          ;(tc-expr/check/type #'e2 Univ)
          ;(tc-expr/check #'e3 expected)
          (tc-error/expr "with-continuation-mark requires a continuation-mark-key, but got ~a" key-t)])]
      ;; application
      [(#%plain-app . _) (tc/app/check form expected)]
      ;; #%expression
      [(#%expression e) (tc-expr/check #'e expected)]
      ;; syntax
      ;; for now, we ignore the rhs of macros
      [(letrec-syntaxes+values stxs vals . body)
       (tc-expr/check (syntax/loc form (letrec-values vals . body)) expected)]
      ;; begin
      [(begin . es) (tc-body/check #'es expected)]
      [(begin0 e . es)
       (begin0
         (tc-expr/check #'e expected)
         (tc-body/check #'es tc-any-results))]
      ;; if
      [(if tst thn els) (tc/if-twoarm #'tst #'thn #'els expected)]
      ;; lambda
      [(#%plain-lambda formals . body)
       (tc/lambda/check form #'(formals) #'(body) expected)]
      [(case-lambda [formals . body] ...)
       (tc/lambda/check form #'(formals ...) #'(body ...) expected)]
      ;; send
      [(let-values (((_) meth))
         (let-values (((_) rcvr))
           (let-values (((_) (~and find-app (#%plain-app find-method/who _ _ _))))
             (let-values ([_arg-var args] ...)
               (if wrapped-object-check
                   ignore-this-case
                   (#%plain-app _ _ _arg-var2 ...))))))
       (register-ignored! form)
       (tc/send #'find-app #'rcvr #'meth #'(args ...) expected)]
      ;; kw function def
      [(~and (let-values ([(f) fun]) . body) _:kw-lambda^)
       (match expected
         [(tc-result1: (and f (or (Function: _)
                                  (Poly: _ (Function: _)))))
          (tc-expr/check/type #'fun (kw-convert f #:split #t))
          expected]
         [(or (tc-results: _) (tc-any-results:))
          (tc-expr (remove-ascription form))])]
      ;; opt function def
      [(~and (let-values ([(f) fun]) . body) opt:opt-lambda^)
       (define conv-type
         (match expected
           [(tc-result1: fun-type)
            (match-define (list required-pos optional-pos)
                          (attribute opt.value))
            (opt-convert fun-type required-pos optional-pos)]
           [_ #f]))
       (if conv-type
           (begin (tc-expr/check/type #'fun conv-type) expected)
           (tc-expr (remove-ascription form)))]
      ;; let
      [(let-values ([(name ...) expr] ...) . body)
       (tc/let-values #'((name ...) ...) #'(expr ...) #'body expected)]
      [(letrec-values ([(name) expr]) name*)
       #:when (and (identifier? #'name*) (free-identifier=? #'name #'name*)
                   (value-restriction? #'expr #'name))
       (match expected
         [(tc-result1: t)
          (with-lexical-env/extend (list #'name) (list t) (tc-expr/check #'expr expected))]
         [(tc-results: ts)
          (tc-error/expr "Expected ~a values, but got only 1" (length ts))])]
      [(letrec-values ([(name ...) expr] ...) . body)
       (tc/letrec-values #'((name ...) ...) #'(expr ...) #'body expected)]
      ;; other
      [_ (int-err "cannot typecheck unknown form : ~s" (syntax->datum form))]
      )))

;; type check form in the current type environment
;; if there is a type error in form, or if it has the wrong annotation, error
;; otherwise, produce the type of form
;; syntax[expr] -> type
(define (tc-expr form)
  ;; do the actual typechecking of form
  ;; internal-tc-expr : syntax -> Type
  (define (internal-tc-expr form)
    (syntax-parse form
      #:literal-sets (kernel-literals tc-expr-literals)
      [stx:tr:class^
       (check-class form #f)]
      ;;
      [stx:exn-handlers^
       (register-ignored! form)
       (check-subforms/with-handlers form) ]
      [stx:ignore-some^
       (register-ignored! form)
       (check-subforms/ignore form)
       (ret Univ)]
      ;; explicit failure
      [t:typecheck-failure
       (explicit-fail #'t.stx #'t.message #'t.var)]
      ;; data
      [(quote #f) (ret (-val #f) -false-filter)]
      [(quote #t) (ret (-val #t) -true-filter)]

      [(quote val)  (ret (tc-literal #'val) -true-filter)]
      ;; syntax
      [(quote-syntax datum) (ret (-Syntax (tc-literal #'datum)) -true-filter)]
      ;; w-c-m
      [(with-continuation-mark e1 e2 e3)
       (define key-t (single-value #'e1))
       (match key-t
         [(tc-result1: (Continuation-Mark-Keyof: rhs))
          (tc-expr/check/type #'e2 rhs)
          (tc-expr #'e3)]
         [(? (λ (result)
               (and (identifier? #'e1)
                    (free-identifier=? #'pz:pk #'e1 #f (syntax-local-phase-level)))))
          (tc-expr/check/type #'e2 Univ)
          (tc-expr #'e3)]
         [(tc-result1: key-t)
          ;; see comments in the /check variant
          (tc-error/expr "with-continuation-mark requires a continuation-mark-key, but got ~a" key-t)])]
      ;; lambda
      [(#%plain-lambda formals . body)
       (tc/lambda form #'(formals) #'(body))]
      [(case-lambda [formals . body] ...)
       (tc/lambda form #'(formals ...) #'(body ...))]
      ;; send
      [(let-values (((_) meth))
         (let-values (((_) rcvr))
           (let-values (((_) (~and find-app (#%plain-app find-method/who _ _ _))))
             (let-values ([_arg-var args] ...)
               (if wrapped-object-check
                   ignore-this-case
                   (#%plain-app _ _ _arg-var2 ...))))))
       (register-ignored! form)
       (tc/send #'find-app #'rcvr #'meth #'(args ...))]
      ;; kw function def
      [(~and _:kw-lambda^
             (let-values ([(f) fun])
               (let-values _
                 (#%plain-app
                  maker
                  lambda-for-kws
                  (case-lambda ; wrapper function
                    (formals . cl-body) ...)
                  (~or (quote (mand-kw:keyword ...))
                       (~and _ (~bind [(mand-kw 1) '()])))
                  (quote (all-kw:keyword ...))
                  . rst))))
       (ret (kw-unconvert (tc-expr/t #'fun)
                          (syntax->list #'(formals ...))
                          (syntax->datum #'(mand-kw ...))
                          (syntax->datum #'(all-kw ...))))]
      ;; opt function def
      [(~and opt:opt-lambda^
             (let-values ([(f) fun])
               (case-lambda (formals . cl-body) ...)))
       (ret (opt-unconvert (tc-expr/t #'fun)
                           (syntax->list #'(formals ...))))]
      ;; let
      [(let-values ([(name ...) expr] ...) . body)
       (tc/let-values #'((name ...) ...) #'(expr ...) #'body)]
      [(letrec-values ([(name ...) expr] ...) . body)
       (tc/letrec-values #'((name ...) ...) #'(expr ...) #'body)]
      ;; mutation!
      [(set! id val)
       (match-let* ([(tc-result1: id-t) (tc-expr #'id)]
                    [(tc-result1: val-t) (tc-expr #'val)])
         (unless (subtype val-t id-t)
           (type-mismatch id-t val-t "mutation only allowed with compatible types"))
         (ret -Void))]
      ;; top-level variable reference - occurs at top level
      [(#%top . id) (tc-id #'id)]
      ;; #%expression
      [(#%expression e) (tc-expr #'e)]
      ;; #%variable-reference
      [(#%variable-reference . _)
       (ret -Variable-Reference)]
      ;; identifiers
      [x:identifier (tc-id #'x)]
      ;; application
      [(#%plain-app . _) (tc/app form)]
      ;; if
      [(if tst thn els) (tc/if-twoarm #'tst #'thn #'els)]



      ;; syntax
      ;; for now, we ignore the rhs of macros
      [(letrec-syntaxes+values stxs vals . body)
       (tc-expr (syntax/loc form (letrec-values vals . body)))]

      ;; begin
      [(begin . es) (tc-body #'es)]
      [(begin0 e . es)
       (begin0
         (tc-expr #'e)
         (tc-body #'es))]
      ;; other
      [_ (int-err "cannot typecheck unknown form : ~s" (syntax->datum form))]))

  (parameterize ([current-orig-stx form])
    ;(printf "form: ~a\n" (syntax->datum form))
    ;; the argument must be syntax
    (unless (syntax? form)
      (int-err "bad form input to tc-expr: ~a" form))
    ;; typecheck form
    (cond
      [(type-ascription form) => (lambda (ann) (tc-expr/check form ann))]
      [else 
       (let ([ty (internal-tc-expr form)])
         (match ty
           [(tc-any-results:)
            (add-typeof-expr form ty)
            ty]
           [(tc-results: ts fs os)
            (let* ([ts* (do-inst form ts)]
                   [r (ret ts* fs os)])
              (add-typeof-expr form r)
              r)]
           [(tc-results: ts fs os dty dbound)
            (define ts* (do-inst form ts))
            (define r (ret ts* fs os dty dbound))
            (add-typeof-expr form r)
            r]))])))

(define (single-value form [expected #f])
  (define t (if expected (tc-expr/check form expected) (tc-expr form)))
  (match t
    [(tc-result1: _ _ _) t]
    [_ (tc-error/expr
          #:stx form
          "expected single value, got multiple (or zero) values")]))


;; check-body-form: (All (A) (syntax? (-> A) -> A))
;; Checks an expression and then calls the function in a context with an extended lexical environment.
;; The environment is extended with the propositions that are true if the expression returns
;; (e.g. instead of raising an error).
(define (check-body-form e k)
  (define results (tc-expr/check e tc-any-results))
  (define props
    (match results
      [(tc-any-results:) empty]
      [(tc-results: _ (FilterSet: f+ f-) _)
       (map -or f+ f-)]
      [(tc-results: _ (FilterSet: f+ f-) _ _ _)
       (map -or f+ f-)]))
  (with-lexical-env (env+ (lexical-env) props (box #t))
    (add-unconditional-prop (k) (apply -and props))))

;; type-check a body of exprs, producing the type of the last one.
;; if the body is empty, the type is Void.
;; syntax[list[expr]] -> tc-results/c
(define (tc-body body)
  (match (syntax->list body)
    [(list) (ret -Void)]
    [(list es ... e-final)
     (define ((continue es))
       (if (empty? es)
           (tc-expr e-final)
           (check-body-form (first es) (continue (rest es)))))
     ((continue es))]))

(define (tc-body/check body expected)
  (match (syntax->list body)
    [(list) (check-below (ret -Void) expected)]
    [(list es ... e-final)
     (define ((continue es))
       (if (empty? es)
           (tc-expr/check e-final expected)
           (check-body-form (first es) (continue (rest es)))))
     ((continue es))]))
