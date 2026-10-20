// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// A fixed- or floor-price Record Shop listing for one Pressing and currency.
///
/// Each `Listing<Currency>` derives from its Pressing at `ListingKey<Currency>()`;
/// there is no Record Shop singleton. `purchase` mints through the Pressing with
/// `witness::Witness` and forwards the whole payment to the Release's tracks.
module record_shop::listing;

// === Imports ===

use musicos::release::Release;
use record::{pressing::{Pressing, PressingAdminCap}, record::Record};
use record_shop::witness;
use release_revenue_forwarder::release_revenue_forwarder;
use sui::{balance::Balance, derived_object, event::emit};

// === Errors ===

const EUnauthorized: u64 = 0;
const EInvalidPrice: u64 = 1;
const EDisabled: u64 = 2;
const EWrongPressing: u64 = 3;
const EWrongPayment: u64 = 4;
const EWrongRelease: u64 = 5;

// === Structs ===

/// The sale configuration for one Pressing and currency.
public struct Listing<phantom Currency> has key {
    id: UID,
    pressing_id: ID,
    pricing: Pricing,
    enabled: bool,
}

public struct ListingKey<phantom Currency>() has copy, drop, store;

// === Enums ===

public enum Pricing has copy, drop, store {
    /// Payment must equal the price.
    Fixed(u64),
    /// Payment must be at least the price; overpayment is kept.
    Floor(u64),
}

// === Events ===

public struct ListingCreatedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pressing_id: ID,
    pricing: Pricing,
}

public struct ListingPriceChangedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    pricing: Pricing,
}

public struct ListingEnabledChangedEvent<phantom Currency> has copy, drop {
    listing_id: ID,
    enabled: bool,
}

// === Public Functions ===

public fun fixed(price: u64): Pricing {
    Pricing::Fixed(price)
}

public fun floor(price: u64): Pricing {
    Pricing::Floor(price)
}

/// Creates the one enabled Listing for `Currency` under this Pressing,
/// unshared so setup can continue before `share`.
public fun new<Currency>(
    pressing: &mut Pressing,
    cap: &PressingAdminCap,
    pricing: Pricing,
): Listing<Currency> {
    assert!(pricing.amount() > 0, EInvalidPrice);
    let pressing_id = object::id(pressing);
    let listing = Listing {
        id: derived_object::claim(pressing.uid_mut(cap), ListingKey<Currency>()),
        pressing_id,
        pricing,
        enabled: true,
    };
    emit(ListingCreatedEvent<Currency> { listing_id: object::id(&listing), pressing_id, pricing });
    listing
}

public fun share<Currency>(self: Listing<Currency>) {
    transfer::share_object(self);
}

/// Mints the next Record and forwards the whole payment, including any Floor
/// overpayment, to the Release's tracks' royalty pools. Reads the Listing only,
/// so sales don't write it. The caller transfers or composes the Record.
public fun purchase<Currency>(
    self: &Listing<Currency>,
    pressing: &mut Pressing,
    release: &Release,
    payment: Balance<Currency>,
): Record {
    assert!(object::id(pressing) == self.pressing_id, EWrongPressing);
    assert!(object::id(release) == pressing.release_id(), EWrongRelease);
    assert!(self.enabled, EDisabled);
    let paid = payment.value();
    match (self.pricing) {
        Pricing::Fixed(price) => assert!(paid == price, EWrongPayment),
        Pricing::Floor(price) => assert!(paid >= price, EWrongPayment),
    };

    let record = pressing.mint<witness::Witness, Currency>(witness::new(), paid);
    release_revenue_forwarder::forward(release, payment);
    record
}

// === View Functions ===

public fun pressing_id<Currency>(self: &Listing<Currency>): ID {
    self.pressing_id
}

public fun pricing<Currency>(self: &Listing<Currency>): Pricing {
    self.pricing
}

/// The configured amount of the current rule.
public fun price<Currency>(self: &Listing<Currency>): u64 {
    self.pricing.amount()
}

public fun is_enabled<Currency>(self: &Listing<Currency>): bool {
    self.enabled
}

/// The address of the one Listing for `(pressing_id, Currency)`.
public fun derive_address<Currency>(pressing_id: ID): address {
    derived_object::derive_address(pressing_id, ListingKey<Currency>())
}

// === Admin Functions ===

/// Replaces the pricing rule. A no-op if unchanged.
public fun set_price<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    pricing: Pricing,
) {
    self.authorize(cap);
    assert!(pricing.amount() > 0, EInvalidPrice);
    if (self.pricing == pricing) return;
    self.pricing = pricing;
    emit(ListingPriceChangedEvent<Currency> { listing_id: object::id(self), pricing });
}

/// Enables or disables purchases. A no-op if unchanged.
public fun set_enabled<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    enabled: bool,
) {
    self.authorize(cap);
    if (self.enabled == enabled) return;
    self.enabled = enabled;
    emit(ListingEnabledChangedEvent<Currency> { listing_id: object::id(self), enabled });
}

// === Private Functions ===

fun authorize<Currency>(self: &Listing<Currency>, cap: &PressingAdminCap) {
    assert!(cap.pressing_id() == self.pressing_id, EUnauthorized);
}

fun amount(pricing: &Pricing): u64 {
    match (pricing) {
        Pricing::Fixed(price) | Pricing::Floor(price) => *price,
    }
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<Currency>(
    event: &ListingCreatedEvent<Currency>,
): (ID, ID, Pricing) {
    (event.listing_id, event.pressing_id, event.pricing)
}

#[test_only]
public fun price_changed_event_fields<Currency>(
    event: &ListingPriceChangedEvent<Currency>,
): (ID, Pricing) {
    (event.listing_id, event.pricing)
}

#[test_only]
public fun enabled_changed_event_fields<Currency>(
    event: &ListingEnabledChangedEvent<Currency>,
): (ID, bool) {
    (event.listing_id, event.enabled)
}
