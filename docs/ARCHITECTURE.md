# Architecture

## State and identity

The Record Shop's only state is a `Pricing` dynamic field on each Pressing, one
per currency, at `PricingKey<Currency>()`:

- `Pricing::Fixed(u64)` or `Pricing::Floor(u64)`, where a price of 0 is free or
  pay what you want.

Holding a pricing is what puts the Pressing on sale in that currency; removing it
stops sales. There is no listing object, enabled flag or stored Pressing ID: the
pricing lives on the Pressing it prices. The Release is not stored; `purchase`
checks it against the Pressing's `release_id`.

A purchase reads the pricing from the Pressing it already mutates, so a sale takes
no shared input besides the Pressing and the Release. Every press mutates the
Pressing because it owns the edition-local sequence and supply cap.

## Events

Events are currency-typed and carry only facts that cannot be derived:

| Event | Fields |
|---|---|
| `PricingSetEvent<Currency>` | `pressing_id`, `pricing` |
| `PricingRemovedEvent<Currency>` | `pressing_id` |

No-op updates emit nothing. A sale emits no event of its own: `pressing::press`
emits `RecordPurchasedEvent<witness::Witness, Currency>` with the Record,
Pressing, number, and amount paid. Its type names the distributor and currency,
the pricing follows from the pricing events, and the Release and edition join
from `PressingCreatedEvent`.

## Authority

`PressingAdminCap` is the only pricing capability: `set_pricing` and
`remove_pricing` go through the Pressing's cap-gated `uid_mut`.

The Record Shop does not hold press authority as an object. A Pressing instead
authorizes the type `record_shop::witness::Witness`. `purchase` creates the
drop-only package witness after all sale checks and passes it directly to
`pressing::press`.

## Purchase ordering

`purchase` performs these checks and effects atomically:

1. require the Pressing's Release;
2. read the Pressing's `Currency` pricing, aborting if there is none;
3. validate exact Fixed payment or minimum Floor payment;
4. press the next Record through the authorized witness, stamped with the
   `Clock` time;
5. forward the entire Balance with `release_revenue_forwarder::forward`, which
   sends `payment / n` to each track's royalty pool address and the remainder to
   the Release;
6. return the Record for PTB composition.

Move transaction atomicity rolls back the sequence increment, Record derivation,
payment forwarding, and events if any later command aborts.

## Immutability

The package is intended to be made immutable when published. Future Record Shop
designs ship as separate packages with explicit migration paths, so pricings do
not carry package-upgrade versions. Its `UpgradeCap` must be consumed before any
Pressing authorizes the package Witness.

## Edition supply

All currencies and distributors share the Pressing lifetime issuance ceiling.
The Pressing's `max_supply` is always positive; there is no optional cap or zero
sentinel. The Pressing enforces exhaustion atomically before payment is sent.
Whether a Pressing is priced is independent of sold-out status. Sequential
edition creation is enforced by Record using the previous derived claim on the
Release.
