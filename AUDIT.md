# Security Audit — `record_shop`

Audited at `e3fbb48237cbc131f8a66d332409a8cc1093954f` (2026-10-21). Covers `record_shop::shop` and `record_shop::witness`, the privacy fixtures under `fixtures/privacy/`, and the money path through the pinned `release_revenue_forwarder` (rev `89e7a52`), `royalty_pool::pool::derive_address` and `miso_music::release` (rev `1538d77`).

## What it does

Fixed- or floor-price sales of Records. The only state is a `Pricing` dynamic field per currency on each Pressing at `PricingKey<Currency>()`. `purchase` validates the payment against that pricing, presses the Record through the package witness, and forwards the whole payment to the Release's tracks' royalty-pool addresses. See [README](./README.md) and [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md).

## Trust model

- **Pressing admin** (`PressingAdminCap`): `set_pricing` and `remove_pricing` go through `pressing::uid_mut(cap)` (`shop.move:97,107`), so the cap check is `record`'s. The same cap authorizes or revokes `record_shop::witness::Witness` on the Pressing. Cannot touch proceeds: none are held.
- **Buyer** (anyone): `purchase<Currency>(&mut Pressing, &Release, Balance<Currency>, &Clock)` (`shop.move:51-66`). Chooses only the currency and amount; the pricing, the Record number, the `Currency` provenance and the destination of funds are fixed by state.
- **Recording admins**: receive proceeds in their recordings' `Currency` pools; they alone can create those pools (`pool::new_recording_pool` needs `RecordingAdminCap`).
- **Release admin** (`ReleaseAdminCap`): receives the rounding remainder at the Release address and redeems it with `release_revenue_forwarder::redeem_and_forward`.
- **Nobody** outside this package can construct `Witness` (`witness.move:8,12-14`; both fixtures fail to compile with the expected diagnostics) or `PricingKey` (module-private constructor; probe failed with `EC04001`). No function of this package holds, stores or returns funds.

## Findings

**RS-01 · Low · Accepted — Proceeds for a currency without a pool are stranded until the pool exists.** `forward` sends `payment / n` to `pool::derive_address<Currency>(recording_id)` for every track (`release_revenue_forwarder.move:31-35`) whether or not a `RoyaltyPool<_, Currency>` has been created there. `set_pricing<Currency>` performs no such check (`shop.move:92-104`), so a Pressing admin can sell in a currency for which some recording has no pool; those funds sit at the derived address until that recording's admin calls `new_recording_pool<_, Currency>` and the pool redeems them. Documented in SECURITY.md; by design, setup order is left to tooling.

**RS-02 · Low · Open — Pool addresses are bound to the royalty-pool package the forwarder links.** `derive_address` hashes `RoyaltyPoolKey<Currency>` including its defining package address. `Move.lock` pins `royalty-pool` at `0a53de7` through the forwarder; if the pools that tooling creates on mainnet come from a different publication of `royalty-pool`, every sale's proceeds go to addresses no object can ever claim, with no abort. Suggested fix: at publish time, before authorizing the Witness on any Pressing, verify that the linked forwarder's `pool::derive_address<Currency>(recording_id)` equals the ID of an existing shared pool; keep the `royalty-pool` pin identical across `release-revenue-forwarder`, the pool-creation tooling and this package.

**RS-03 · Info · Accepted — A payment smaller than the track count pays only the Release.** With `paid < n`, `value_per_track` is 0, no `ReleaseRevenueForwardedEvent` is emitted and the whole amount goes to the Release address (`release_revenue_forwarder.move:31-43`). Reachable under `floor(0)` or a tiny floor on a long release. Probe: 3-track release, payment 2 → no event, Record stores price 2; payment 10 → `3/3/3` and remainder 1.

**RS-04 · Info · Accepted — `fixed(0)` and `floor(0)` let any address take Records up to `max_supply` for gas.** No per-buyer limit (`shop.move:59-63`). Documented in SECURITY.md.

**RS-05 · Info · Accepted — Each purchase performs one `send_funds` per track.** A 1,000-track Release (the `MAX_TRACKS` of `release`) means 1,000 accumulator writes per sale; PTBs that batch many such purchases may hit per-transaction limits and should keep batches small.

**RS-06 · Info · Accepted — No sale event of its own.** Sales are indexed from `RecordPurchasedEvent<Witness, Currency>` and `ReleaseRevenueForwardedEvent<Currency>` (ARCHITECTURE.md); the remainder dust at the Release needs the Release admin and the `AccumulatorRoot` to redeem.

## Checked, no finding

- **Payment validation and conservation.** `paid` is read once (`shop.move:58`); `Fixed` requires equality, `Floor` requires `>=` (`shop.move:59-62`), so under- and overpayment on `Fixed` and underpayment on `Floor` abort with `EWrongPayment`. The full `Balance` is forwarded (`shop.move:64`): `n · ⌊paid/n⌋ + remainder = paid`; a zero remainder is `destroy_zero`'d, a zero payment forwards nothing. No arithmetic can overflow; `n ≥ 1` because `release::new` rejects empty tracklists (`ENoTracks`), so no division by zero. Tests: `fixed_pricing_rejects_underpayment/overpayment`, `floor_pricing_rejects_underpayment`, `floor_overpayments_are_forwarded_in_full`, `free_pricing_*`, `pay_what_you_want_accepts_nothing_or_more`, `fixed_pricing_accepts_the_maximum_price`.
- **Repricing races.** The signed payment amount cannot be made to pay more; a changed `Fixed` price or a raised `Floor` aborts. Tests: `repricing_up/down_rejects_the_signed_payment`, `floor_repriced_down_keeps_the_overpayment`.
- **Currency binding.** The pricing is keyed by the `Currency` type of the `Balance` (`shop.move:59`), so a pricing in one currency cannot be satisfied with another; an unpriced currency aborts in `sui::dynamic_field` (`EFieldDoesNotExist`). Test: `purchase_rejects_a_currency_not_on_sale`, `two_currencies_are_priced_separately_and_share_one_pressing_sequence`.
- **Release binding.** `object::id(release) == pressing.release_id()` (`shop.move:57`) ties the forwarding tracklist to the Pressing's Release; `Release.recording_ids` has no setter, and a Release is only ever shared by `release::publish`, so any Release a buyer can pass is published. Test: `purchase_rejects_a_different_release`.
- **Authorization and abort order.** `EWrongRelease` → missing pricing → `EWrongPayment` → `record`'s `EDistributorNotAuthorized`/`EMaxSupplyReached` → forward. The witness is created after all shop checks and consumed by `press` (`shop.move:63`). Revocation stops sales immediately. Tests: `unauthorized_record_shop_cannot_press`, `revoked_record_shop_cannot_press`, `maximum_supply_boundary_rejects_the_next_purchase`, `currencies_share_the_same_supply_cap`.
- **Witness privacy.** `Witness` has only `drop`; `new` is `public(package)`; `scripts/check-witness-privacy.sh` confirms both fixtures fail with the expected diagnostics. The remaining exposure is a package upgrade, hence the immutability requirement below.
- **Dynamic-field namespace.** `PricingKey<Currency>` cannot be constructed outside `shop` (probe), and `df::hash_type_and_key` includes the key type, so other Pressing extensions sharing `uid_mut` cannot read-modify or collide with pricings. Admin paths: cap-gated by `record` (`set_pricing_rejects_a_foreign_*`, `remove_pricing_rejects_a_foreign_*`).
- **Events.** `PricingSetEvent` carries the full enum (41 bytes) after the field is written; `Fixed(x)` vs `Floor(x)` is a change; no-ops emit nothing (`pricing_events_capture_only_real_changes`). `PricingRemovedEvent` 32 bytes.
- **Object lifecycle.** The package creates no objects of its own; `Pricing` is `copy + drop + store` and lives only as a dynamic field; `remove_pricing` deletes it. The Record is returned, never transferred by this package.
- **Static linkage.** Calls go to the exact forwarder, `record` and `miso_music` versions in `Move.lock`; later upgrades of those packages cannot redirect this package's calls.
- **README and SECURITY claims** match the code, including the join keys, byte sizes, `EWrongPayment`/`EWrongRelease` semantics, and the dynamic-field abort for unpriced currencies.

## Operational requirements

- Publish, then `package::make_immutable` and confirm the `UpgradeCap` is gone, before any Pressing authorizes `record_shop::witness::Witness`.
- Before authorizing the Witness, verify the linked forwarder derives the live pools' addresses (RS-02), and create the `Currency` pool for every track before pricing in that currency (RS-01).
- Keep `PressingAdminCap` and `ReleaseAdminCap` address-owned or in trusted custody; never share or freeze them.
- PTBs must consume the returned Record, normally with `transfer::public_transfer`.
- Frontends must present `Floor` overpayment as non-refundable and free pricings as unlimited per buyer.

## Verification

- `sui move test --coverage`: 30/30 passed; `sui move coverage summary`: 100.00% for `shop` and `witness` (Sui 1.82.1).
- `sui move build -e mainnet` and `-e testnet`: both succeed.
- `scripts/check-witness-privacy.sh`: both fixtures rejected for the expected reasons.
- Throwaway probes (not committed): external `PricingKey` construction fails to compile; sub-track-count payment and `10 / 3` remainder distribution.
