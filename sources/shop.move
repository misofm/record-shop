// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// Fixed- and floor-price sales of a Pressing's Records.
///
/// A Pressing is for sale in `Currency` while it holds a `Pricing` at
/// `PricingKey<Currency>()`. There is no Record Shop singleton or listing object:
/// `purchase` reads the pricing from the Pressing it presses through with
/// `witness::Witness`, and forwards the whole payment to the Release's tracks.
module record_shop::shop;

// === Imports ===

use sui::{balance::Balance, clock::Clock, dynamic_field as df, event::emit};
use musicos::release::Release;
use record::{pressing::{Pressing, PressingAdminCap}, record::Record};
use release_revenue_forwarder::release_revenue_forwarder;
use record_shop::witness;

// === Errors ===

const EWrongRelease: u64 = 0;
const EWrongPayment: u64 = 1;

// === Structs ===

/// Stores a Pressing's `Pricing` in `Currency`.
public struct PricingKey<phantom Currency>() has copy, drop, store;

// === Enums ===

/// How a Pressing is priced in one currency.
public enum Pricing has copy, drop, store {
    /// Payment must equal the price. `Fixed(0)` is free.
    Fixed(u64),
    /// Payment must be at least the price; overpayment is kept. `Floor(0)` is
    /// pay what you want.
    Floor(u64),
}

// === Events ===

/// Emitted when a Pressing goes on sale in `Currency` or its pricing changes.
public struct PricingSetEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
    pricing: Pricing,
}

/// Emitted when a Pressing stops selling in `Currency`.
public struct PricingRemovedEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
}

// === Public Functions ===

/// Pricing where payment must equal `price`.
public fun fixed(price: u64): Pricing {
    Pricing::Fixed(price)
}

/// Pricing where payment must be at least `price`.
public fun floor(price: u64): Pricing {
    Pricing::Floor(price)
}

/// Presses the next Record and forwards the whole payment, including any Floor
/// overpayment, to the Release's tracks' royalty pools. Aborts in
/// `dynamic_field` if the Pressing is not for sale in `Currency`. The caller
/// transfers or composes the Record.
public fun purchase<Currency>(
    pressing: &mut Pressing,
    release: &Release,
    payment: Balance<Currency>,
    clock: &Clock,
): Record {
    assert!(object::id(release) == pressing.release_id(), EWrongRelease);
    let paid = payment.value();
    match (df::borrow<PricingKey<Currency>, Pricing>(pressing.uid(), PricingKey())) {
        Pricing::Fixed(price) => assert!(paid == *price, EWrongPayment),
        Pricing::Floor(price) => assert!(paid >= *price, EWrongPayment),
    };
    let record = pressing.press<witness::Witness, Currency>(witness::new(), paid, clock);
    release_revenue_forwarder::forward(release, payment);
    record
}

// === View Functions ===

/// The Pressing's pricing in `Currency`, or none if it is not on sale in it.
public fun pricing<Currency>(pressing: &Pressing): Option<Pricing> {
    let uid = pressing.uid();
    if (df::exists(uid, PricingKey<Currency>())) {
        option::some(*df::borrow(uid, PricingKey<Currency>()))
    } else option::none()
}

/// The configured amount: the exact price for Fixed, the minimum for Floor.
public fun amount(self: &Pricing): u64 {
    match (self) {
        Pricing::Fixed(price) | Pricing::Floor(price) => *price,
    }
}

/// Whether payment must equal the amount (Fixed) rather than meet it (Floor).
public fun is_fixed(self: &Pricing): bool {
    match (self) {
        Pricing::Fixed(_) => true,
        Pricing::Floor(_) => false,
    }
}

// === Admin Functions ===

/// Puts the Pressing on sale in `Currency` at `pricing`, or reprices it. A
/// no-op if unchanged.
public fun set_pricing<Currency>(
    pressing: &mut Pressing,
    cap: &PressingAdminCap,
    pricing: Pricing,
) {
    let uid = pressing.uid_mut(cap);
    if (df::exists(uid, PricingKey<Currency>())) {
        let current: &mut Pricing = df::borrow_mut(uid, PricingKey<Currency>());
        if (*current == pricing) return;
        *current = pricing;
    } else df::add(uid, PricingKey<Currency>(), pricing);
    emit(PricingSetEvent<Currency> { pressing_id: uid.to_inner(), pricing });
}

/// Stops selling the Pressing in `Currency`. A no-op if not on sale.
public fun remove_pricing<Currency>(pressing: &mut Pressing, cap: &PressingAdminCap) {
    let uid = pressing.uid_mut(cap);
    if (!df::exists(uid, PricingKey<Currency>())) return;
    let _: Pricing = df::remove(uid, PricingKey<Currency>());
    emit(PricingRemovedEvent<Currency> { pressing_id: uid.to_inner() });
}

// === Test Functions ===

#[test_only]
public fun set_event_fields<Currency>(event: &PricingSetEvent<Currency>): (ID, Pricing) {
    (event.pressing_id, event.pricing)
}

#[test_only]
public fun removed_event_fields<Currency>(event: &PricingRemovedEvent<Currency>): ID {
    event.pressing_id
}
