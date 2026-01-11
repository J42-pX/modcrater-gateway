;; ModCrater - Blockchain Infrastructure Platform
;; A decentralized API gateway with performance-based incentives

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_STAKE (err u101))
(define-constant ERR_NODE_NOT_FOUND (err u102))
(define-constant ERR_INVALID_SCORE (err u103))
(define-constant ERR_ALREADY_REGISTERED (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant MIN_STAKE_AMOUNT u1000000) ;; 1 STX in micro-STX

;; Data Variables
(define-data-var total-nodes uint u0)
(define-data-var platform-fee-percentage uint u5) ;; 5% platform fee

;; Data Maps
(define-map node-operators
  principal
  {
    stake-amount: uint,
    reliability-score: uint,
    total-requests: uint,
    successful-requests: uint,
    registered-at: uint,
    is-active: bool
  }
)

(define-map service-agreements
  {developer: principal, node: principal}
  {
    min-uptime: uint,
    max-response-time: uint,
    compensation-rate: uint,
    created-at: uint,
    is-active: bool
  }
)

(define-map performance-penalties
  principal
  {
    total-penalties: uint,
    last-penalty-block: uint
  }
)

(define-map developer-balances
  principal
  uint
)

;; Read-only functions
(define-read-only (get-node-operator (operator principal))
  (map-get? node-operators operator)
)

(define-read-only (get-service-agreement (developer principal) (node principal))
  (map-get? service-agreements {developer: developer, node: node})
)

(define-read-only (get-reliability-score (operator principal))
  (match (map-get? node-operators operator)
    node-data (ok (get reliability-score node-data))
    ERR_NODE_NOT_FOUND
  )
)

(define-read-only (get-total-nodes)
  (ok (var-get total-nodes))
)

(define-read-only (get-developer-balance (developer principal))
  (ok (default-to u0 (map-get? developer-balances developer)))
)

(define-read-only (calculate-performance-score (operator principal))
  (match (map-get? node-operators operator)
    node-data
      (let
        (
          (total (get total-requests node-data))
          (successful (get successful-requests node-data))
        )
        (if (> total u0)
          (ok (/ (* successful u100) total))
          (ok u100)
        )
      )
    ERR_NODE_NOT_FOUND
  )
)

;; Public functions
(define-public (register-node-operator (stake-amount uint))
  (let
    (
      (operator tx-sender)
      (existing-node (map-get? node-operators operator))
    )
    (asserts! (is-none existing-node) ERR_ALREADY_REGISTERED)
    (asserts! (>= stake-amount MIN_STAKE_AMOUNT) ERR_INSUFFICIENT_STAKE)
    
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    
    (map-set node-operators operator
      {
        stake-amount: stake-amount,
        reliability-score: u100,
        total-requests: u0,
        successful-requests: u0,
        registered-at: block-height,
        is-active: true
      }
    )
    
    (var-set total-nodes (+ (var-get total-nodes) u1))
    (ok true)
  )
)

(define-public (create-service-agreement 
  (node principal) 
  (min-uptime uint) 
  (max-response-time uint)
  (compensation-rate uint))
  (let
    (
      (developer tx-sender)
      (node-data (unwrap! (map-get? node-operators node) ERR_NODE_NOT_FOUND))
    )
    (asserts! (get is-active node-data) ERR_NODE_NOT_FOUND)
    
    (map-set service-agreements
      {developer: developer, node: node}
      {
        min-uptime: min-uptime,
        max-response-time: max-response-time,
        compensation-rate: compensation-rate,
        created-at: block-height,
        is-active: true
      }
    )
    (ok true)
  )
)

(define-public (record-request (node principal) (success bool))
  (let
    (
      (node-data (unwrap! (map-get? node-operators node) ERR_NODE_NOT_FOUND))
      (new-total (+ (get total-requests node-data) u1))
      (new-successful (if success 
        (+ (get successful-requests node-data) u1)
        (get successful-requests node-data)
      ))
      (new-score (if (> new-total u0)
        (/ (* new-successful u100) new-total)
        u100
      ))
    )
    (map-set node-operators node
      (merge node-data {
        total-requests: new-total,
        successful-requests: new-successful,
        reliability-score: new-score
      })
    )
    (ok new-score)
  )
)

(define-public (apply-performance-penalty (node principal) (penalty-amount uint))
  (let
    (
      (node-data (unwrap! (map-get? node-operators node) ERR_NODE_NOT_FOUND))
      (current-stake (get stake-amount node-data))
      (penalty-data (default-to 
        {total-penalties: u0, last-penalty-block: u0}
        (map-get? performance-penalties node)
      ))
    )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= penalty-amount current-stake) ERR_INSUFFICIENT_BALANCE)
    
    (map-set node-operators node
      (merge node-data {
        stake-amount: (- current-stake penalty-amount)
      })
    )
    
    (map-set performance-penalties node
      {
        total-penalties: (+ (get total-penalties penalty-data) penalty-amount),
        last-penalty-block: block-height
      }
    )
    
    (ok true)
  )
)

(define-public (compensate-developer (developer principal) (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    
    (try! (as-contract (stx-transfer? amount tx-sender developer)))
    
    (ok true)
  )
)

(define-public (increase-stake (additional-amount uint))
  (let
    (
      (operator tx-sender)
      (node-data (unwrap! (map-get? node-operators operator) ERR_NODE_NOT_FOUND))
    )
    (try! (stx-transfer? additional-amount tx-sender (as-contract tx-sender)))
    
    (map-set node-operators operator
      (merge node-data {
        stake-amount: (+ (get stake-amount node-data) additional-amount)
      })
    )
    (ok true)
  )
)

(define-public (withdraw-stake)
  (let
    (
      (operator tx-sender)
      (node-data (unwrap! (map-get? node-operators operator) ERR_NODE_NOT_FOUND))
      (stake (get stake-amount node-data))
    )
    (asserts! (not (get is-active node-data)) ERR_UNAUTHORIZED)
    
    (try! (as-contract (stx-transfer? stake tx-sender operator)))
    
    (map-delete node-operators operator)
    (ok true)
  )
)

(define-public (deactivate-node)
  (let
    (
      (operator tx-sender)
      (node-data (unwrap! (map-get? node-operators operator) ERR_NODE_NOT_FOUND))
    )
    (map-set node-operators operator
      (merge node-data {is-active: false})
    )
    (ok true)
  )
)

(define-public (update-platform-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (<= new-fee u10) ERR_INVALID_SCORE)
    (var-set platform-fee-percentage new-fee)
    (ok true)
  )
)
