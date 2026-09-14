# Architecture

## State and identity

`Listing<phantom Currency>` is a key-only object. Its stored fields are:

- the Release ID read from the Pressing at creation;
- the exact Pressing ID;
- `Pricing::Fixed(u64)` or `Pricing::Floor(u64)`;
- `State::Enabled` or `State::Disabled`;
- total gross proceeds in the Listing's currency.

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

Listing events are complete, currency-typed snapshots. Creation records the
derived Listing, Release, Pressing, actual Pressing admin capability, initial
pricing kind and amount, and enabled state. Sharing captures the same current
configuration before `share_object` consumes the owned Listing and emits after
sharing. Price and state events include the capability, Release and Pressing
identities plus before/after values; no-op updates emit nothing.

`RecordSoldEvent<Currency>` is emitted after the Pressing mint and Release
funds deposit. It copies provenance from the returned Record, records the
accepted pricing snapshot, captures supply before and after mint (including a flattened
maximum), and reports the exact Release recipient and amount deposited.
Existing dependency events remain unchanged; the Listing adds no duplicate helper events.

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
2. require enabled state;
3. require the buyer's complete expected `Pricing` enum to equal the current rule;
4. validate exact Fixed payment or minimum Floor payment;
5. mint the next Record through the authorized witness;
6. add the actual payment to the Listing's total proceeds;
7. send the entire nonzero Balance to the Release funds accumulator;
8. emit `RecordSoldEvent<Currency>` with the accepted pricing snapshot, the returned
   Record's currency, actual price, buyer, and purchase timestamp, plus supply and
   proceeds snapshots;
9. return the Record for PTB composition.

Move transaction atomicity rolls back the sequence increment, Record derivation,
fund deposit, and events if any later command aborts.

## Immutability

The package is intended to be made immutable when published. Future Record Shop
designs ship as separate packages with explicit migration paths, so Listings do
not carry package-upgrade versions. Its `UpgradeCap` must be consumed before any
Pressing authorizes the package Witness.
