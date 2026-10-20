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

Buyers pass the Listing (read only), its mutable Pressing, the Pressing's Release, a
and a `Balance<Currency>`. `purchase` returns the Record; the PTB must transfer
or otherwise consume it.

```move
let record = listing.purchase(&mut pressing, &release, payment);
transfer::public_transfer(record, recipient);
```

- `fixed(price)` accepts exactly `price`.
- `floor(price)` accepts at least `price` and forwards the entire payment.
- The payment amount is fixed when the buyer signs, so a repricing can't
  charge more: a Fixed price that no longer matches, or a Floor above the
  payment, aborts with `EWrongPayment`.
- `set_price` and `set_enabled` require the matching `PressingAdminCap`.
- The returned Record stores the concrete currency type and actual amount paid as
  immutable purchase provenance. It does not store the buyer or the time; indexers
  read them as the sale event's transaction sender and timestamp.

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

`pricing` is the `Pricing` enum value. Sharing is silent and no-op updates emit
nothing; changes made before sharing still emit. A sale emits only
`record::pressing::RecordPurchasedEvent<record_shop::witness::Witness, Currency>`
with the Record, Pressing, number and amount paid; the Listing is
`listing::derive_address<Currency>(pressing_id)`.

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

## License

[Functional Source License 1.1, ALv2 Future License](./LICENSE.md)
(FSL-1.1-ALv2). Any use except a Competing Use is permitted, and each version
becomes Apache-2.0 two years after its release.
