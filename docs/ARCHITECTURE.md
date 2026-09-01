# Architecture

## State and identity

`Listing<phantom Currency>` is a key-only object. Its stored fields are:

- the Release ID read from the Pressing at creation;
- the exact Pressing ID;
- `Pricing::Fixed(u64)` or `Pricing::Floor(u64)`;
- `State::Enabled` or `State::Disabled`.

The module-private constructor for `ListingKey<Currency>()` is claimed from the
Pressing UID. This gives a deterministic, claim-once ID without a registry:

```move
listing::derive_address<Currency>(pressing_id)
```

Listings are returned address-owned by `new` and shared only by the separate
`share` function. This permits atomic setup before public access. Purchases borrow
the Listing immutably, so reads against one Listing do not mutate it. Every mint
still mutates the bound Pressing because the Pressing owns the edition-local
sequence and supply cap.

## Authority

`PressingAdminCap` is the only Listing administration capability. Creation calls
the Pressing's cap-gated `uid_mut`; updates compare the capability's bound Pressing
ID to the Listing's stored Pressing ID.

The Record Shop does not hold mint authority as an object. A Pressing instead
authorizes the type `miso_record_shop::witness::Witness`. `purchase` creates the
drop-only package witness after all sale checks and passes it directly to
`pressing::mint`.

## Purchase ordering

`purchase` performs these checks and effects atomically:

1. require the exact bound Pressing;
2. require enabled state;
3. require the buyer's complete expected `Pricing` enum to equal the current rule;
4. validate exact Fixed payment or minimum Floor payment;
5. mint the next Record through the authorized witness;
6. send the entire nonzero Balance to the Release funds accumulator;
7. emit `RecordSoldEvent<Currency>` with the accepted Pricing and the returned Record's
   currency, actual price, buyer, and purchase timestamp getters;
8. return the Record for PTB composition.

Move transaction atomicity rolls back the sequence increment, Record derivation,
fund deposit, and events if any later command aborts.

## Immutability

The package is intended to be made immutable when published. Future Record Shop
designs ship as separate packages with explicit migration paths, so Listings do
not carry package-upgrade versions. Its `UpgradeCap` must be consumed before any
Pressing authorizes the package Witness.
