 
;; SkyChainTrace Parts NFT Contract
;; Clarity v2 (using latest syntax as of Stacks 2.1+)
;; Implements minting, updating metadata, burning of NFTs representing aircraft parts
;; Includes admin controls, authorized minters, metadata history logging (simplified), and robust error handling
;; Designed for traceability in aviation supply chain

;; Error constants
(define-constant ERR-NOT-AUTHORIZED u100) ;; Caller not authorized
(define-constant ERR-NFT-NOT-EXISTS u101) ;; NFT does not exist
(define-constant ERR-NFT-ALREADY-EXISTS u102) ;; NFT already minted
(define-constant ERR-INVALID-METADATA u103) ;; Invalid metadata provided
(define-constant ERR-PAUSED u104) ;; Contract is paused
(define-constant ERR-ZERO-ADDRESS u105) ;; Invalid zero address
(define-constant ERR-INVALID-STATUS u106) ;; Invalid lifecycle status
(define-constant ERR-NOT-OWNER u107) ;; Caller not owner
(define-constant ERR-ALREADY-BURNED u108) ;; NFT already burned
(define-constant ERR-INVALID-ID u109) ;; Invalid token ID
(define-constant ERR-MAX-ID-REACHED u110) ;; Maximum ID reached (safety limit)

;; Contract metadata
(define-constant CONTRACT-NAME "SkyChainTrace Parts NFT")
(define-constant MAX-ID u100000000) ;; Arbitrary max ID to prevent overflow issues

;; Allowed lifecycle statuses (enforced for robustness)
(define-constant STATUS-NEW "new")
(define-constant STATUS-INSTALLED "installed")
(define-constant STATUS-IN-USE "in-use")
(define-constant STATUS-REMOVED "removed")
(define-constant STATUS-SCRAPPED "scrapped")

;; Admin and state variables
(define-data-var admin principal tx-sender) ;; Contract admin
(define-data-var paused bool false) ;; Pause flag for emergency stops
(define-data-var last-token-id uint u0) ;; Incremental token ID counter

;; Maps
(define-non-fungible-token part uint) ;; Core NFT definition
(define-map owners uint principal) ;; Token ID to owner (redundant with NFT but for explicitness)
(define-map metadata uint
  {
    serial: (string-ascii 32), ;; Serial number
    manufacturer: (string-ascii 64), ;; Manufacturer name
    specs: (buff 512), ;; Detailed specifications (binary for flexibility)
    manufacture-date: uint, ;; Block height or timestamp approximation
    status: (string-ascii 20), ;; Lifecycle status
    additional-notes: (optional (buff 1024)) ;; Optional extra data
  }
) ;; Metadata map
(define-map authorized-minters principal bool) ;; Principals allowed to mint/update
(define-map metadata-history uint (list 10 { updater: principal, block: uint, changes: (buff 512) })) ;; Simplified history log (up to 10 updates)

;; Private helpers

;; Check if caller is admin
(define-private (is-admin)
  (is-eq tx-sender (var-get admin))
)

;; Check if caller is authorized (admin or minter)
(define-private (is-authorized)
  (or (is-admin) (default-to false (map-get? authorized-minters tx-sender)))
)

;; Ensure contract not paused
(define-private (ensure-not-paused)
  (asserts! (not (var-get paused)) (err ERR-PAUSED))
)

;; Validate lifecycle status
(define-private (is-valid-status (status (string-ascii 20)))
  (or
    (is-eq status STATUS-NEW)
    (is-eq status STATUS-INSTALLED)
    (is-eq status STATUS-IN-USE)
    (is-eq status STATUS-REMOVED)
    (is-eq status STATUS-SCRAPPED)
  )
)

;; Validate metadata inputs
(define-private (validate-metadata (serial (string-ascii 32)) (manufacturer (string-ascii 64)) (specs (buff 512)) (status (string-ascii 20)))
  (and
    (> (len serial) u0)
    (> (len manufacturer) u0)
    (is-valid-status status)
  )
)

;; Log metadata update (simplified, append to list)
(define-private (log-update (token-id uint) (changes (buff 512)))
  (let ((current-history (default-to (list) (map-get? metadata-history token-id))))
    (map-set metadata-history token-id (unwrap-panic (as-max-len? (append current-history {updater: tx-sender, block: block-height, changes: changes}) u10)))
  )
)

;; Public functions

;; Transfer admin rights
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq new-admin 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (var-set admin new-admin)
    (ok true)
  )
)

;; Pause/unpause contract
(define-public (set-paused (pause bool))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (var-set paused pause)
    (ok pause)
  )
)

;; Add/remove authorized minter
(define-public (set-authorized-minter (minter principal) (authorized bool))
  (begin
    (asserts! (is-admin) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq minter 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (map-set authorized-minters minter authorized)
    (ok true)
  )
)

;; Mint new NFT
(define-public (mint (recipient principal) (serial (string-ascii 32)) (manufacturer (string-ascii 64)) (specs (buff 512)) (status (string-ascii 20)))
  (begin
    (ensure-not-paused)
    (asserts! (is-authorized) (err ERR-NOT-AUTHORIZED))
    (asserts! (not (is-eq recipient 'SP000000000000000000002Q6VF78)) (err ERR-ZERO-ADDRESS))
    (asserts! (validate-metadata serial manufacturer specs status) (err ERR-INVALID-METADATA))
    (let ((new-id (+ (var-get last-token-id) u1)))
      (asserts! (<= new-id MAX-ID) (err ERR-MAX-ID-REACHED))
      (asserts! (is-none (nft-get-owner? part new-id)) (err ERR-NFT-ALREADY-EXISTS))
      (try! (nft-mint? part new-id recipient))
      (map-set owners new-id recipient)
      (map-set metadata new-id
        {
          serial: serial,
          manufacturer: manufacturer,
          specs: specs,
          manufacture-date: block-height,
          status: status,
          additional-notes: none
        }
      )
      (var-set last-token-id new-id)
      (print {event: "mint", token-id: new-id, recipient: recipient}) ;; Event emission
      (ok new-id)
    )
  )
)

;; Update metadata
(define-public (update-metadata (token-id uint) (new-serial (optional (string-ascii 32))) (new-manufacturer (optional (string-ascii 64))) (new-specs (optional (buff 512))) (new-status (optional (string-ascii 20))) (new-notes (optional (buff 1024))))
  (begin
    (ensure-not-paused)
    (asserts! (is-authorized) (err ERR-NOT-AUTHORIZED))
    (asserts! (> token-id u0) (err ERR-INVALID-ID))
    (let ((current-meta (unwrap! (map-get? metadata token-id) (err ERR-NFT-NOT-EXISTS))))
      (asserts! (match (nft-get-owner? part token-id) owner true (err ERR-ALREADY-BURNED)) (err ERR-ALREADY-BURNED))
      (if (is-some new-status) (asserts! (is-valid-status (unwrap-panic new-status)) (err ERR-INVALID-STATUS)) true)
      (let (
        (updated-meta {
          serial: (default-to (get serial current-meta) new-serial),
          manufacturer: (default-to (get manufacturer current-meta) new-manufacturer),
          specs: (default-to (get specs current-meta) new-specs),
          manufacture-date: (get manufacture-date current-meta), ;; Immutable
          status: (default-to (get status current-meta) new-status),
          additional-notes: new-notes
        })
      )
        (map-set metadata token-id updated-meta)
        ;; Log changes (simplified buff of changes)
        (log-update token-id (concat (concat (unwrap-panic (to-consensus-buff? new-status)) (unwrap-panic (to-consensus-buff? new-notes))) (as-max-len? specs u512)))
        (print {event: "update", token-id: token-id}) ;; Event
        (ok true)
      )
    )
  )
)

;; Burn NFT
(define-public (burn (token-id uint))
  (begin
    (ensure-not-paused)
    (asserts! (is-authorized) (err ERR-NOT-AUTHORIZED))
    (asserts! (> token-id u0) (err ERR-INVALID-ID))
    (let ((owner (unwrap! (nft-get-owner? part token-id) (err ERR-NFT-NOT-EXISTS))))
      (asserts! (is-eq tx-sender owner) (err ERR-NOT-OWNER)) ;; Or authorized, but strict for now
      (try! (nft-burn? part token-id tx-sender))
      (map-delete owners token-id)
      (map-delete metadata token-id)
      (map-delete metadata-history token-id)
      (print {event: "burn", token-id: token-id}) ;; Event
      (ok true)
    )
  )
)

;; Read-only functions

;; Get owner of NFT
(define-read-only (get-owner (token-id uint))
  (ok (nft-get-owner? part token-id))
)

;; Get metadata
(define-read-only (get-metadata (token-id uint))
  (ok (map-get? metadata token-id))
)

;; Get metadata history
(define-read-only (get-history (token-id uint))
  (ok (map-get? metadata-history token-id))
)

;; Get last token ID
(define-read-only (get-last-token-id)
  (ok (var-get last-token-id))
)

;; Get admin
(define-read-only (get-admin)
  (ok (var-get admin))
)

;; Check if paused
(define-read-only (is-paused)
  (ok (var-get paused))
)

;; Check if minter authorized
(define-read-only (is-minter-authorized (minter principal))
  (ok (default-to false (map-get? authorized-minters minter)))
)

;; Additional read-only: total minted (derived from last-id, assuming no gaps)
(define-read-only (get-total-minted)
  (ok (var-get last-token-id))
)

;; Helper: check if NFT exists
(define-read-only (nft-exists (token-id uint))
  (ok (is-some (nft-get-owner? part token-id)))
)