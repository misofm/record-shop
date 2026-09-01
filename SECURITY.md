# Security

## Invariants

- External packages cannot construct `miso_record_shop::witness::Witness` by
  packing it or by calling its package-visible constructor.
- A purchase cannot mint unless the bound Pressing currently authorizes that exact
  witness type.
- A Listing cannot be rebound: Release and Pressing IDs have no setters and are
  sourced from the Pressing during its derived-object claim.
- One `(Pressing, Currency)` can claim only one Listing, permanently.
- Listing creation and updates require the matching `PressingAdminCap`.
- Fixed listings reject both underpayment and overpayment; Floor listings reject
  underpayment and intentionally keep overpayment.
- The full expected-Pricing check protects a prepared PTB from amount changes and
  equal-amount changes between Fixed and Floor semantics.
- All payment is sent to the stored Release ID; no proceeds remain in a Listing or
  Record Shop-owned object.
- Record lineage, numbering, buyer, purchase timestamp, Distributor type, and
  maximum supply are enforced by `miso_record`. Currency and price are attestations
  from the authorized Distributor; this Record Shop binds them to the consumed
  `Balance<Currency>`.

## Trust boundaries

The holder of a `PressingAdminCap` can reprice, disable, or enable its Listing and
can authorize or revoke Distributor types on the Pressing. Secure capability
custody is therefore required. Revocation immediately stops new Record Shop mints,
but does not affect Records already sold.

`PressingAdminCap` and `ReleaseAdminCap` must remain address-owned or wrapped in
trusted custody. Never share or freeze either capability: doing so makes its
reference publicly available and therefore makes its authority public.

The package must be made immutable before its Witness is authorized. Retaining its
`UpgradeCap` would allow later code to construct the same authorized Witness while
bypassing Listing payment and state checks.

A Floor price deliberately allows arbitrary overpayment, and the entire amount is
non-refundable at the contract layer. Frontends should make this behavior explicit.

Funds use Sui's native object-address accumulator. Withdrawing proceeds requires
mutable access to the Release UID, which `miso::release` gates with the matching
`ReleaseAdminCap`. Operators must ensure the relevant network enables object-funds
withdrawal before relying on that withdrawal path.

`Record.purchased_by` is the transaction sender, not necessarily the final recipient.
The caller must consume the returned Record in the same PTB, normally with
`transfer::public_transfer`; this permits gifts and composition. `RecordSoldEvent` records
the accepted Pricing and complete purchase provenance but does not claim a final
owner.

## Verification

`make verify` runs success and abort-path unit tests plus two external compile-fail
fixtures. The end-to-end scenario covers Release → capped Pressing → Witness
authorization → derived shared Listing → nonzero buyer payment → returned Record →
buyer ownership → exact Release-owner proceeds withdrawal.

Report suspected vulnerabilities privately through this repository's GitHub
Security Advisory workflow before public disclosure.
