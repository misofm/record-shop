# Architecture

## State and identity

`Listing<phantom Currency>` is a key-only object. Its stored fields are:

- the exact Pressing ID;
- `Pricing::Fixed(u64)` or `Pricing::Floor(u64)`;
- `enabled: bool`;
- total gross proceeds in the Listing's currency.

The Release is not stored; `purchase` checks it against the Pressing's `release_id`.

The module-private constructor for `ListingKey<Currency>()` is claimed from the
Pressing UID. This gives a deterministic, claim-once ID without a registry:

```move
listing::derive_address<Currency>(pressing_id)
```

Listings are returned address-owned by `new` and shared only by the separate
`share` function. This permits atomic setup before public access. Purchases mutate
the Listing to accumulate its total gross proceeds. Every mint also mutates the bound
Pressing because the Pressing owns the edition-local sequence and supply cap.

## Events

Events are currency-typed and carry only facts that cannot be derived:

| Event | Fields |
|---|---|
| `ListingCreatedEvent<Currency>` | `listing_id`, `pressing_id`, `pricing` |
| `ListingPriceChangedEvent<Currency>` | `listing_id`, `pricing` |
| `ListingEnabledChangedEvent<Currency>` | `listing_id`, `enabled` |
| `RecordSoldEvent<Currency>` | `listing_id`, `record_id`, `pricing` |

A Listing starts enabled. Sharing is silent, and no-op updates emit nothing.
`RecordSoldEvent` is emitted after the mint and payment forwarding; the amount
paid, number, and Pressing are in the same transaction's `RecordPurchasedEvent`,
and the Release and edition join from `PressingCreatedEvent`.

The sale event's phantom `Currency` parameter identifies the payment currency.
The distributor is always this package's `witness::Witness`, so neither type name
is duplicated in the event payload.

## Authority

`PressingAdminCap` is the only Listing administration capability. Creation calls
the Pressing's cap-gated `uid_mut`; updates compare the capability's bound Pressing
ID to the Listing's stored Pressing ID.

The Record Shop does not hold mint authority as an object. A Pressing instead
authorizes the type `record_shop::witness::Witness`. `purchase` creates the
drop-only package witness after all sale checks and passes it directly to
`pressing::mint`.

## Purchase ordering

`purchase` performs these checks and effects atomically:

1. require the exact bound Pressing;
2. require the Pressing's Release;
3. require enabled state;
4. require the buyer's complete expected `Pricing` enum to equal the current rule;
5. validate exact Fixed payment or minimum Floor payment;
6. mint the next Record through the authorized witness;
7. add the actual payment to the Listing's total proceeds;
8. forward the entire Balance with `release_revenue_forwarder::forward`, which
   sends `payment / n` to each track's royalty pool address and the remainder to
   the Release;
9. emit `RecordSoldEvent<Currency>` with the Listing, Record, and accepted pricing;
10. return the Record for PTB composition.

Move transaction atomicity rolls back the sequence increment, Record derivation,
payment forwarding, and events if any later command aborts.

## Immutability

The package is intended to be made immutable when published. Future Record Shop
designs ship as separate packages with explicit migration paths, so Listings do
not carry package-upgrade versions. Its `UpgradeCap` must be consumed before any
Pressing authorizes the package Witness.

## Edition supply

All currencies and distributors share the Pressing lifetime issuance ceiling.
The Pressing's `max_supply` is always positive; there is no optional cap or zero
sentinel. The Pressing enforces exhaustion atomically before payment is sent.
Listing enabled state is independent of sold-out status. Sequential edition
creation is enforced by Record using the previous derived claim on the Release.
