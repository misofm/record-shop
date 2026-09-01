# miso-record-shop

`miso_record_shop` is the first-party fixed/floor-price sales package for Miso
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
for one Pressing. Different currencies receive different Listing IDs.

## Sale flow

The release administrator creates a Pressing, authorizes the exact witness type,
creates a Listing, and shares the two independently:

```move
pressing.authorize_distributor<miso_record_shop::witness::Witness>(&pressing_cap);

let listing = miso_record_shop::listing::new<SUI>(
    &mut pressing,
    &pressing_cap,
    miso_record_shop::listing::fixed(1_000_000_000),
);

pressing.share();
listing.share();
```

Buyers pass an immutable Listing, its mutable Pressing, a `Balance<Currency>`,
their expected current pricing rule, Sui's Clock, and the transaction context. `purchase`
returns the Record; the PTB must transfer or otherwise consume it.

```move
let record = listing.purchase(
    &mut pressing,
    payment,
    expected_pricing,
    clock,
    ctx,
);
transfer::public_transfer(record, recipient);
```

- `fixed(price)` accepts exactly `price`.
- `floor(price)` accepts at least `price` and forwards the entire payment.
- `expected_pricing` compares the complete pricing rule, so a stale amount or a
  same-amount change between Fixed and Floor aborts instead of silently accepting
  new terms.
- `set_price` and `set_state` require the matching `PressingAdminCap`.
- The returned Record stores the concrete currency type, actual amount paid,
  transaction sender, and Clock timestamp as immutable purchase provenance.

All proceeds go to the Release object's native Sui funds accumulator. The Release
administrator can withdraw through `release.uid_mut(&release_cap)` and
`balance::withdraw_funds_from_object`.

## Witness authority

The authorized identity is exactly:

```text
miso_record_shop::witness::Witness
```

`Witness` has only `drop`; its constructor is `public(package)`. Production code
constructs and immediately consumes it only inside `listing::purchase`. The privacy
fixtures prove that an external package can neither pack `Witness()` nor call
`witness::new()`.

## Publication

The package must be made immutable before any Pressing authorizes its Witness.
Publish the package, consume its `UpgradeCap` with `package::make_immutable`, verify
that the capability is gone, and only then authorize
`miso_record_shop::witness::Witness`.

## Verify

Requires Sui CLI 1.78 or a compatible toolchain:

```bash
make verify
```

This runs the 18 Move tests, including the complete ownership and proceeds flow,
then confirms both external witness-construction probes fail for the expected
privacy diagnostics.

See [architecture](docs/ARCHITECTURE.md) and [security](SECURITY.md) for the
invariants and trust boundaries.

License: Apache-2.0.
