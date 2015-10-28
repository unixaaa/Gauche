;;;
;;; data.ftree-map - functional tree map
;;;
;;;   Copyright (c) 2015  Shiro Kawai  <shiro@acm.org>
;;;
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;

;; This implements functional red-black tree
;; as described in Chris Okasaki's Purely Functional Data Structures.

(define-module data.ftree-map
  (use gauche.sequence)
  (use gauche.dictionary)
  (use gauche.record)
  (use data.queue)
  (use util.match)
  (use srfi-114)
  (export make-ftree-map ftree-map?
          ftree-map-empty?
          ftree-map-exists? ftree-map-get ftree-map-put)
  )
(select-module data.ftree-map)

;;
;; Internal implementation
;;

(define-record-type T #t #t color left elem right)
;; NB: We just use #f as E node.
(define (E? x) (not x))

(define balance
  (match-lambda*
    [(or ('B ($ T 'R ($ T 'R a x b) y c) z d)
         ('B ($ T 'R a x ($ T 'R b y c)) z d)
         ('B a x ($ T 'R ($ T 'R b y c) z d))
         ('B a x ($ T 'R b y ($ T 'R c z d))))
     (make-T 'R (make-T 'B a x b) y (make-T 'B c z d))]
    [(color a x b)
     (make-T color a x b)]))

(define (get key tree cmpr)
  (and (T? tree)
       (match-let1 ($ T _ a p b) tree
         (if3 (comparator-compare cmpr key (car p))
              (get key a cmpr)
              p
              (get key b cmpr)))))

(define (insert key val tree cmpr)
  (define (ins tree)
    (if (E? tree)
      (make-T 'R #f (cons key val) #f)
      (match-let1 ($ T color a p b) tree
        (if3 (comparator-compare cmpr key (car p))
             (balance color (ins a) p b)
             (make-T color a (cons key val) b)
             (balance color a p (ins b))))))
  (match-let1 ($ T _ a p b) (ins tree)
    (make-T 'B a p b)))

;;
;; External interface
;;
(define-class <ftree-map> (<ordered-dictionary>)
  ((comparator :init-keyword :comparator)
   (tree :init-keyword :tree :init-form #f)))

;; API
(define (ftree-map? x) (is-a? x <ftree-map>))

;; API
(define make-ftree-map
  (case-lambda
    [() (make-ftree-map default-comparator)]
    [(cmpr)
     (unless (comparator? cmpr)
       (error "comparator required, but got:" cmpr))
     (make <ftree-map> :comparator cmpr)]
    [(key=? key<?)
     (make-ftree-map (make-comparator #t key=?
                                      (^[a b]
                                        (cond [(key=? a b) 0]
                                              [(key<? a b) -1]
                                              [else 1]))
                                      #f))]))

;; API
(define (ftree-map-empty? ftree) (E? (~ ftree'tree)))

;; API
(define (ftree-map-exists? ftree key)
  (boolean (get key (~ ftree'tree) (~ ftree'comparator))))

;; API
(define (ftree-map-get ftree key :optional default)
  (if-let1 p (get key (~ ftree'tree) (~ ftree'comparator))
    (cdr p)
    (if (undefined? default)
      (errorf "No such key in a ftree-map ~s: ~s" ftree key)
      default)))

;; API
(define (ftree-map-put ftree key val)
  (make <ftree-map>
    :comparator (~ ftree'comparator)
    :tree (insert key val (~ ftree'tree) (~ ftree'comparator))))

;; Fundamental iterators
(define (%ftree-map-fold ftree proc seed)
  (define (rec tree seed)
    (if (E? tree)
      seed
      (match-let1 ($ T _ a p b) tree
        (rec b (proc p (rec a seed))))))
  (rec (~ ftree'tree) seed))

(define (%ftree-map-fold-right ftree proc seed)
  (define (rec tree seed)
    (if (E? tree)
      seed
      (match-let1 ($ T _ a p b) tree
        (rec a (proc p (rec b seed))))))
  (rec (~ ftree'tree) seed))

;; Collection framework
(define-method call-with-iterator ((coll <ftree-map>) proc :allow-other-keys)
  (if (ftree-map-empty? coll)
    (proc (^[] #t) (^[] #t))
    (let1 q (make-queue)  ; only contains T
      (enqueue! q (~ coll'tree))
      (proc (^[] (queue-empty? q))
            (rec (next)
              (match-let1 ($ T c a p b) (dequeue! q)
                (if (E? a)
                  (if (E? b)
                    p
                    (begin (queue-push! q b) p))
                  (begin (queue-push! q (make-T c #f p b))
                         (queue-push! q a)
                         (next)))))))))

;; Dictionary interface
;; As a dictionary, it behaves as immutable dictionary.
(define-method dict-get ((ftree <ftree-map>) key :optional default)
  (ftree-map-get ftree key default))

(define-method dict-put! ((ftree <ftree-map>) key value)
  (errorf "ftree-map is immutable:" ftree))

(define-method dict-comparator ((ftree <ftree-map>))
  (~ ftree'comparator))

(define-method dict-fold ((ftree <ftree-map>) proc seed)
  (%ftree-map-fold ftree (^[p s] (proc (car p) (cdr p) s)) seed))

(define-method dict-fold-right ((ftree <ftree-map>) proc seed)
  (%ftree-map-fold-right ftree (^[p s] (proc (car p) (cdr p) s)) seed))

