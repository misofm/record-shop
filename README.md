# miso-record-shop

`record_shop` is the first-party fixed/floor-price sales package for Miso
Records on Sui. Its only state is a `Pricing` stored on each Pressing per
currency. There is no global Record Shop, Distributor or listing object.

```text
Release
└── PressingKey(edition) → Pressing
    ├── RecordKey(number) → Record
    └── PricingKey<Currency>() → Pricing   (dynamic field)
```

A Pressing is on sale in `Currency` while it holds a `Pricing` under
`PricingKey<Currency>()`. Each currency has its own pricing, and all of them
consume the same mandatory, immutable Pressing supply cap. Destruction does not
replenish this lifetime cap. Editions are `u16` values created sequentially from
1 by the Record package.

## Sale flow

The release administrator creates a Pressing, authorizes the exact witness type,
prices it in one or more currencies, and shares it:

```move
pressing.authorize_distributor<record_shop::witness::Witness>(&pressing_cap);
record_shop::shop::set_pricing<SUI>(
    &mut pressing,
    &pressing_cap,
    record_shop::shop::fixed(1_000_000_000),
);
pressing.share();
```

Buyers pass the mutable Pressing, its Release, a `Balance<Currency>` and the
`Clock`. `purchase` returns the Record; the PTB must transfer or otherwise
consume it.

```move
let record = record_shop::shop::purchase(&mut pressing, &release, payment, &clock);
transfer::public_transfer(record, recipient);
```

- `fixed(price)` accepts exactly `price`; `fixed(0)` is free, paid with a zero
  `Balance`.
- `floor(price)` accepts at least `price` and forwards the entire payment;
  `floor(0)` is pay what you want.
- A free Record stores the pricing's currency and a price of 0. A zero payment
  forwards nothing.
- The payment amount is fixed when the buyer signs, so a repricing can't
  charge more: a Fixed price that no longer matches, or a Floor above the
  payment, aborts with `EWrongPayment`.
- A currency the Pressing is not on sale in aborts in `sui::dynamic_field`.
- `set_pricing` (add or reprice) and `remove_pricing` (stop selling) require the
  Pressing's `PressingAdminCap`. `pricing<Currency>` returns the current
  pricing, if any.
- The returned Record stores the concrete currency type, actual amount paid and
  purchase time as immutable provenance. It does not store the buyer; indexers
  read it as the sale event's transaction sender.

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
constructs and immediately consumes it only inside `shop::purchase`. The privacy
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
| `PricingSetEvent<Currency>` | `pressing_id`, `pricing` |
| `PricingRemovedEvent<Currency>` | `pressing_id` |

`pricing` is the full `Pricing` enum value (41 BCS bytes with the ID), so
indexers track pricing from events alone. No-op updates emit nothing. A sale
emits no Record Shop event: `record`'s
`RecordPurchasedEvent<record_shop::witness::Witness, Currency>` announces the
Record, and `release_revenue_forwarder`'s `ReleaseRevenueForwardedEvent<Currency>`
the forwarded payment, when it pays the tracks.

## Verify

Requires Sui CLI 1.82.1 or a compatible toolchain:

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
