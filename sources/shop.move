// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

module record_shop::shop;

// === Imports ===

use sui::{balance::Balance, clock::Clock, dynamic_field as df, event::emit};
use miso_music::release::Release;
use record::{pressing::{Pressing, PressingAdminCap}, record::Record};
use release_revenue_forwarder::release_revenue_forwarder;
use record_shop::witness;

// === Errors ===

const EWrongRelease: u64 = 0;
const EWrongPayment: u64 = 1;

// === Structs ===

public struct PricingKey<phantom Currency>() has copy, drop, store;

// === Enums ===

public enum Pricing has copy, drop, store {
    Fixed(u64),
    Floor(u64),
}

// === Events ===

public struct PricingSetEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
    pricing: Pricing,
}

public struct PricingRemovedEvent<phantom Currency> has copy, drop {
    pressing_id: ID,
}

// === Public Functions ===

public fun fixed(price: u64): Pricing {
    Pricing::Fixed(price)
}

public fun floor(price: u64): Pricing {
    Pricing::Floor(price)
}

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

public fun pricing<Currency>(pressing: &Pressing): Option<Pricing> {
    let uid = pressing.uid();
    if (df::exists(uid, PricingKey<Currency>())) {
        option::some(*df::borrow(uid, PricingKey<Currency>()))
    } else option::none()
}

public fun amount(self: &Pricing): u64 {
    match (self) {
        Pricing::Fixed(price) | Pricing::Floor(price) => *price,
    }
}

public fun is_fixed(self: &Pricing): bool {
    match (self) {
        Pricing::Fixed(_) => true,
        Pricing::Floor(_) => false,
    }
}

// === Admin Functions ===

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
