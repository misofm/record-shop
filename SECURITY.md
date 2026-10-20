# Security

## Invariants

- External packages cannot construct `record_shop::witness::Witness` by
  packing it or by calling its package-visible constructor.
- A purchase cannot press a Record unless the bound Pressing currently authorizes that exact
  witness type.
- A pricing applies only to the Pressing that stores it, and `purchase` requires
  the Pressing's own Release.
- A Pressing holds at most one pricing per currency.
- Setting and removing a pricing require the Pressing's `PressingAdminCap`.
- Fixed pricing rejects both underpayment and overpayment; Floor pricing rejects
  underpayment and intentionally keeps overpayment.
- The buyer's payment amount is fixed in the signed transaction, so a repricing
  can only make the purchase abort, never charge more. A PTB that sizes its
  payment from `pricing()` at execution time accepts the current price.
- All payment is forwarded to the Release's tracks' royalty pools; no proceeds
  remain in a Pressing or Record Shop-owned object.
- Record lineage, numbering, Distributor type, and maximum supply are enforced
  by `record`. Currency and price are attestations from the authorized
  Distributor; this Record Shop binds them to the consumed `Balance<Currency>`.

- Every Pressing has a positive immutable lifetime supply ceiling shared across
  currencies and distributors. Burns and distributor changes cannot replenish it.
- Editions start at 1 and require the previous edition claim on the same Release;
  this does not require sellout or prevent additional editions.

## Trust boundaries

The holder of a `PressingAdminCap` can price, reprice, or stop selling its Pressing and
can authorize or revoke Distributor types on the Pressing. Secure capability
custody is therefore required. Revocation immediately stops new Record Shop presses,
but does not affect Records already sold.

`PressingAdminCap` and `ReleaseAdminCap` must remain address-owned or wrapped in
trusted custody. Never share or freeze either capability: doing so makes its
reference publicly available and therefore makes its authority public.

The package must be made immutable before its Witness is authorized. Retaining its
`UpgradeCap` would allow later code to construct the same authorized Witness while
bypassing the pricing and payment checks.

A Floor price deliberately allows arbitrary overpayment, and the entire amount is
non-refundable at the contract layer. Frontends should make this behavior explicit.

A free (`fixed(0)`) or pay-what-you-want (`floor(0)`) pricing lets any address
take Records up to `max_supply` for the cost of gas and storage. This package has
no per-buyer limit; gate claims with a separate Distributor if that matters.

Proceeds are forwarded to the tracks' royalty pool addresses with
`release_revenue_forwarder::forward`, which writes no shared object. The published
package links one exact version of the forwarder, so a later forwarder upgrade
cannot redirect this package's proceeds. Funds sent to a pool address wait there
until the pool exists and has registered stakes; the small rounding remainder goes
to the Release, where its administrator's `release_revenue_forwarder::redeem_and_forward`
forwards it later.

A Record stores neither its buyer nor its recipient; the event's transaction sender
is the buyer. It does store the `Clock` time of the purchase. The caller must consume the returned Record in the same PTB, normally
with `transfer::public_transfer`; this permits gifts and composition. Purchase
provenance is in the sale's `RecordPurchasedEvent`, which claims no final owner.

## Verification

`make verify` runs success and abort-path unit tests plus two external compile-fail
fixtures. The end-to-end scenario covers Release → capped Pressing → Witness
authorization → Pressing pricing → buyer payment → returned Record →
buyer ownership → proceeds forwarded to the tracks' royalty pools.

Report suspected vulnerabilities privately through this repository's GitHub
Security Advisory workflow before public disclosure.
