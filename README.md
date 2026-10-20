# miso-record-shop

`record_shop` is the first-party fixed/floor-price sales package for Miso
Records on Sui. A `Listing<Currency>` is the complete Record Shop state. There is
no global Record Shop or Distributor object.

```text
Release
└── PressingKey(edition) → Pressing
    ├── RecordKey(number) → Record
    └── ListingKey<Currency>() → Listing<Currency>
```

Each Listing is permanently bound to one Pressing, one Release, and one currency.
It derives directly from the Pressing, so the same currency cannot be listed twice
for one Pressing. Different currencies receive different Listing IDs, but consume the same mandatory,
immutable Pressing supply cap. Destruction does not replenish this lifetime cap.
An enabled Listing is sold out when its Pressing reaches the cap.
Editions are `u16` values created sequentially from 1 by the Record package.

## Sale flow

The release administrator creates a Pressing, authorizes the exact witness type,
creates a Listing, and shares the two independently:

```move
pressing.authorize_distributor<record_shop::witness::Witness>(&pressing_cap);

let listing = record_shop::listing::new<SUI>(
    &mut pressing,
    &pressing_cap,
    record_shop::listing::fixed(1_000_000_000),
);

pressing.share();
listing.share();
```

Buyers pass a mutable Listing, its mutable Pressing, the Pressing's Release, a
`Balance<Currency>`, their expected current pricing rule, and Sui's Clock. `purchase` returns the Record;
the PTB must transfer or otherwise consume it.

```move
let record = listing.purchase(
    &mut pressing,
    &release,
    payment,
    expected_pricing,
    clock,
);
transfer::public_transfer(record, recipient);
```

- `fixed(price)` accepts exactly `price`.
- `floor(price)` accepts at least `price` and forwards the entire payment.
- `expected_pricing` compares the complete pricing rule, so a stale amount or a
  same-amount change between Fixed and Floor aborts instead of silently accepting
  new terms.
- `set_price` and `set_enabled` require the matching `PressingAdminCap`.
- `total_proceeds` reports the gross sum of actual payments from completed sales,
  including any Floor overpayment.
- The returned Record stores the concrete currency type, actual amount paid, and
  Clock timestamp as immutable purchase provenance. It does not store the buyer;
  indexers read the buyer as the sale event's transaction sender.

All proceeds go straight to the royalty pools of the Release's tracks through
[`release_revenue_forwarder`](https://github.com/misofm/release-revenue-forwarder):
each track's pool address receives `payment / n`, and the rounding remainder goes
to the Release. No crank is needed between a sale and a holder's claim. A
`Release` other than the Pressing's aborts with `EWrongRelease`.

## Witness authority

The authorized identity is exactly:

```text
record_shop::witness::Witness
```

`Witness` has only `drop`; its constructor is `public(package)`. Production code
constructs and immediately consumes it only inside `listing::purchase`. The privacy
fixtures prove that an external package can neither pack `Witness()` nor call
`witness::new()`.

## Publication

The package must be made immutable before any Pressing authorizes its Witness.
Publish the package, consume its `UpgradeCap` with `package::make_immutable`, verify
that the capability is gone, and only then authorize
`record_shop::witness::Witness`.

## Events

| Event | Fields |
|---|---|
| `ListingCreatedEvent<Currency>` | `listing_id`, `pressing_id`, `pricing` |
| `ListingPriceChangedEvent<Currency>` | `listing_id`, `pricing` |
| `ListingEnabledChangedEvent<Currency>` | `listing_id`, `enabled` |
| `RecordSoldEvent<Currency>` | `listing_id`, `record_id`, `pricing` |

`pricing` is the `Pricing` enum value. Sharing is silent and no-op updates emit
nothing; changes made before sharing still emit. The amount paid and Record
number are in the same transaction's `record::pressing::RecordPurchasedEvent`.

## Verify

Requires Sui CLI 1.78 or a compatible toolchain:

```bash
make verify
```

This runs the Move tests, including the complete ownership and proceeds flow,
then confirms both external witness-construction probes fail for the expected
privacy diagnostics.

See [architecture](docs/ARCHITECTURE.md) and [security](SECURITY.md) for the
invariants and trust boundaries.

License: Apache-2.0.
