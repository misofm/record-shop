// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A fixed-price or minimum-price Record Shop listing for one Pressing.
///
/// There is no Record Shop singleton. Each `Listing<Currency>` derives directly
/// from its Pressing and is independently shared, so currencies and Pressings
/// remain separate consensus lanes except for their common edition sequence.
module miso_record_shop::listing;

use miso_record::pressing::{Pressing, PressingAdminCap};
use miso_record::record::{Self, Record};
use miso_record_shop::witness;
use std::type_name::TypeName;
use sui::{balance::{Self, Balance}, clock::Clock, derived_object, event::emit};

// === Structs ===

/// Private-constructor key for the permanent `(Pressing, Currency)` listing.
public struct ListingKey<phantom Currency>() has copy, drop, store;

/// One independently shared sale configuration for a Pressing and Currency.
public struct Listing<phantom Currency> has key {
    /// The Listing's derived object identity.
    id: UID,
    /// The release that receives payments from this Listing.
    release_id: ID,
    /// The Pressing from which this Listing purchases Records.
    pressing_id: ID,
    /// The active payment rule.
    pricing: Pricing,
    /// Whether the Listing currently accepts purchases.
    state: State,
}

/// Payment rule for a Listing.
public enum Pricing has copy, drop, store {
    /// Require payment to equal the configured price.
    Fixed(u64),
    /// Require payment to be at least the configured price.
    Floor(u64),
}

/// Whether purchases are accepted.
public enum State has copy, drop, store {
    Enabled,
    Disabled,
}

// === Events ===

/// Emitted when an artist creates a Listing for a Pressing and currency.
public struct ListingCreatedEvent<phantom Currency> has copy, drop {
    /// The newly created Listing.
    listing_id: ID,
    /// The release that receives Listing payments.
    release_id: ID,
    /// The Pressing sold by the Listing.
    pressing_id: ID,
    /// The Listing's initial payment rule.
    pricing: Pricing,
    /// The Listing's initial state.
    state: State,
}

/// Emitted when an artist changes a Listing's payment rule.
public struct ListingPriceChangedEvent<phantom Currency> has copy, drop {
    /// The updated Listing.
    listing_id: ID,
    /// The new payment rule.
    pricing: Pricing,
}

/// Emitted when an artist enables or disables a Listing.
public struct ListingStateChangedEvent<phantom Currency> has copy, drop {
    /// The updated Listing.
    listing_id: ID,
    /// The new Listing state.
    state: State,
}

/// Emitted after a Listing completes a Record sale.
public struct RecordSoldEvent<phantom Currency> has copy, drop {
    /// The Listing that completed the sale.
    listing_id: ID,
    /// The purchased Record.
    record_id: ID,
    /// The release that received payment.
    release_id: ID,
    /// The Pressing that issued the Record.
    pressing_id: ID,
    /// The edition represented by the Pressing.
    edition: u16,
    /// The Record's number within its edition.
    number: u32,
    /// The defining type of the purchase currency.
    purchase_currency: TypeName,
    /// The amount paid for the Record.
    purchase_price: u64,
    /// The transaction sender who purchased the Record.
    purchased_by: address,
    /// The purchase time in Unix milliseconds from Sui's Clock.
    purchased_timestamp_ms: u64,
    /// The payment rule accepted for the sale.
    pricing: Pricing,
}

// === Errors ===

const EUnauthorized: u64 = 0;
const EInvalidPrice: u64 = 1;
const EDisabled: u64 = 2;
const EWrongPressing: u64 = 3;
const EPriceChanged: u64 = 4;
const EWrongPayment: u64 = 5;

// === Public Functions ===

/// Construct an exact-payment pricing rule.
public fun fixed(price: u64): Pricing {
    Pricing::Fixed(price)
}

/// Construct a minimum-payment pricing rule.
public fun floor(price: u64): Pricing {
    Pricing::Floor(price)
}

/// Construct the state that accepts purchases.
public fun enabled(): State {
    State::Enabled
}

/// Construct the state that rejects purchases.
public fun disabled(): State {
    State::Disabled
}

/// Create the permanent Listing for `Currency` under this Pressing.
///
/// The Listing starts enabled and is returned unshared so callers can compose
/// further configuration before calling `share`.
public fun new<Currency>(
    pressing: &mut Pressing,
    cap: &PressingAdminCap,
    pricing: Pricing,
): Listing<Currency> {
    assert_valid_price(pricing);

    let release_id = pressing.release_id();
    let pressing_id = object::id(pressing);
    let listing = Listing {
        id: derived_object::claim(pressing.uid_mut(cap), ListingKey<Currency>()),
        release_id,
        pressing_id,
        pricing,
        state: State::Enabled,
    };

    emit(ListingCreatedEvent<Currency> {
        listing_id: object::id(&listing),
        release_id,
        pressing_id,
        pricing,
        state: State::Enabled,
    });

    listing
}

/// Share a newly created Listing.
public fun share<Currency>(self: Listing<Currency>) {
    transfer::share_object(self);
}

/// Change the payment rule using the capability for the bound Pressing.
public fun set_price<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    pricing: Pricing,
) {
    self.authorize(cap);
    assert_valid_price(pricing);
    if (self.pricing != pricing) {
        self.pricing = pricing;
        emit(ListingPriceChangedEvent<Currency> {
            listing_id: object::id(self),
            pricing,
        });
    };
}

/// Enable or disable purchases using the capability for the bound Pressing.
public fun set_state<Currency>(
    self: &mut Listing<Currency>,
    cap: &PressingAdminCap,
    state: State,
) {
    self.authorize(cap);
    if (self.state != state) {
        self.state = state;
        emit(ListingStateChangedEvent<Currency> {
            listing_id: object::id(self),
            state,
        });
    };
}

/// Purchase and return the next Record from the bound Pressing.
///
/// `expected_pricing` protects the buyer against stale price or pricing-rule
/// changes. The entire payment is deposited into the Release object's funds
/// accumulator; a Floor overpayment is not refunded. The caller decides how to
/// transfer or compose the returned Record.
public fun purchase<Currency>(
    self: &Listing<Currency>,
    pressing: &mut Pressing,
    payment: Balance<Currency>,
    expected_pricing: Pricing,
    clock: &Clock,
    ctx: &mut TxContext,
): Record {
    assert!(object::id(pressing) == self.pressing_id, EWrongPressing);
    assert!(self.state == State::Enabled, EDisabled);

    assert!(expected_pricing == self.pricing, EPriceChanged);
    let pricing = self.pricing;
    let paid = payment.value();
    match (pricing) {
        Pricing::Fixed(fixed) => assert!(paid == fixed, EWrongPayment),
        Pricing::Floor(floor) => assert!(paid >= floor, EWrongPayment),
    };

    let sold = pressing.mint<witness::Witness, Currency>(witness::new(), paid, clock, ctx);
    payment.send_funds(self.release_id.to_address());

    emit(RecordSoldEvent<Currency> {
        listing_id: object::id(self),
        record_id: object::id(&sold),
        release_id: sold.release_id(),
        pressing_id: sold.pressing_id(),
        edition: sold.edition(),
        number: sold.number(),
        purchase_currency: sold.purchase_currency(),
        purchase_price: sold.purchase_price(),
        purchased_by: sold.purchased_by(),
        purchased_timestamp_ms: sold.purchased_timestamp_ms(),
        pricing,
    });

    sold
}

// === View Functions ===

/// Return the release that receives Listing payments.
public fun release_id<Currency>(self: &Listing<Currency>): ID {
    self.release_id
}

/// Return the Pressing sold by this Listing.
public fun pressing_id<Currency>(self: &Listing<Currency>): ID {
    self.pressing_id
}

/// Return this Listing's payment rule.
public fun pricing<Currency>(self: &Listing<Currency>): Pricing {
    self.pricing
}

/// Return the amount configured by this Listing's payment rule.
public fun price<Currency>(self: &Listing<Currency>): u64 {
    match (self.pricing) {
        Pricing::Fixed(value) => value,
        Pricing::Floor(value) => value,
    }
}

/// Return this Listing's current state.
public fun state<Currency>(self: &Listing<Currency>): State {
    self.state
}

/// Return whether this Listing currently accepts purchases.
public fun is_enabled<Currency>(self: &Listing<Currency>): bool {
    self.state == State::Enabled
}

/// Return whether this Listing currently rejects purchases.
public fun is_disabled<Currency>(self: &Listing<Currency>): bool {
    self.state == State::Disabled
}

/// Return whether `pricing` requires an exact payment.
public fun is_fixed(pricing: Pricing): bool {
    match (pricing) {
        Pricing::Fixed(_) => true,
        Pricing::Floor(_) => false,
    }
}

/// Return whether `pricing` permits payment above its configured floor.
public fun is_floor(pricing: Pricing): bool {
    match (pricing) {
        Pricing::Fixed(_) => false,
        Pricing::Floor(_) => true,
    }
}

/// Derive the one Listing address for `(pressing_id, Currency)`.
public fun derive_address<Currency>(pressing_id: ID): address {
    derived_object::derive_address(pressing_id, ListingKey<Currency>())
}

// === Private Functions ===

fun authorize<Currency>(self: &Listing<Currency>, cap: &PressingAdminCap) {
    assert!(cap.pressing_id() == self.pressing_id, EUnauthorized);
}

fun assert_valid_price(pricing: Pricing) {
    let price = match (pricing) {
        Pricing::Fixed(value) => value,
        Pricing::Floor(value) => value,
    };
    assert!(price > 0, EInvalidPrice);
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<Currency>(
    event: ListingCreatedEvent<Currency>,
): (ID, ID, ID, Pricing, State) {
    let ListingCreatedEvent { listing_id, release_id, pressing_id, pricing, state } = event;
    (listing_id, release_id, pressing_id, pricing, state)
}

#[test_only]
public fun sold_event_fields<Currency>(
    event: RecordSoldEvent<Currency>,
): (ID, ID, ID, ID, u16, u32, TypeName, u64, address, u64, Pricing) {
    let RecordSoldEvent {
        listing_id,
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency,
        purchase_price,
        purchased_by,
        purchased_timestamp_ms,
        pricing,
    } = event;
    (
        listing_id,
        record_id,
        release_id,
        pressing_id,
        edition,
        number,
        purchase_currency,
        purchase_price,
        purchased_by,
        purchased_timestamp_ms,
        pricing,
    )
}
