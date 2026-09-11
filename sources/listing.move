// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A fixed-price or minimum-price Record Shop listing for one Pressing.
///
/// There is no Record Shop singleton. Each `Listing<Currency>` derives directly
/// from its Pressing and is independently shared, so currencies and Pressings
/// remain separate consensus lanes except for their common edition sequence.
module record_shop::listing;

use record::pressing::{Pressing, PressingAdminCap};
use record::record::{Self, Record};
use record_shop::witness;
use std::type_name;
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
    listing_id: address,
    /// The release that receives Listing payments.
    release_id: address,
    /// The Pressing sold by the Listing.
    pressing_id: address,
    /// The admin capability used to create the Listing.
    pressing_admin_cap_id: address,
    /// Whether the Listing's initial payment rule requires exact payment.
    pricing_is_fixed: bool,
    /// The Listing's initial configured amount.
    price: u64,
    /// Whether the Listing initially accepts purchases.
    enabled: bool,
}

/// Emitted when a newly-created Listing is shared.
public struct ListingSharedEvent<phantom Currency> has copy, drop {
    /// The shared Listing.
    listing_id: address,
    /// The release that receives Listing payments.
    release_id: address,
    /// The Pressing sold by the Listing.
    pressing_id: address,
    /// Whether the Listing's payment rule requires exact payment.
    pricing_is_fixed: bool,
    /// The Listing's configured amount.
    price: u64,
    /// Whether the Listing accepts purchases.
    enabled: bool,
}

/// Emitted when an artist changes a Listing's payment rule.
public struct ListingPriceChangedEvent<phantom Currency> has copy, drop {
    /// The updated Listing.
    listing_id: address,
    /// The release that receives Listing payments.
    release_id: address,
    /// The Pressing sold by the Listing.
    pressing_id: address,
    /// The admin capability used to change the Listing.
    pressing_admin_cap_id: address,
    /// Whether the prior payment rule required exact payment.
    pricing_is_fixed_before: bool,
    /// The prior configured amount.
    price_before: u64,
    /// Whether the new payment rule requires exact payment.
    pricing_is_fixed_after: bool,
    /// The new configured amount.
    price_after: u64,
    /// Whether the Listing accepts purchases.
    enabled: bool,
}

/// Emitted when an artist enables or disables a Listing.
public struct ListingStateChangedEvent<phantom Currency> has copy, drop {
    /// The updated Listing.
    listing_id: address,
    /// The release that receives Listing payments.
    release_id: address,
    /// The Pressing sold by the Listing.
    pressing_id: address,
    /// The admin capability used to change the Listing.
    pressing_admin_cap_id: address,
    /// Whether the current payment rule requires exact payment.
    pricing_is_fixed: bool,
    /// The current configured amount.
    price: u64,
    /// Whether the Listing accepted purchases before the change.
    enabled_before: bool,
    /// Whether the Listing accepts purchases after the change.
    enabled_after: bool,
}

/// Emitted after a Listing completes a Record sale.
public struct RecordSoldEvent<phantom Currency> has copy, drop {
    /// The Listing that completed the sale.
    listing_id: address,
    /// The purchased Record.
    record_id: address,
    /// The release that received payment.
    release_id: address,
    /// The Pressing that issued the Record.
    pressing_id: address,
    /// The edition represented by the Pressing.
    edition: u16,
    /// The Record's number within its edition.
    number: u32,
    /// The defining type of the purchase currency, as raw UTF-8 bytes.
    purchase_currency: vector<u8>,
    /// The amount paid for the Record.
    purchase_price: u64,
    /// The transaction sender who purchased the Record.
    purchased_by: address,
    /// The purchase time in Unix milliseconds from Sui's Clock.
    purchased_timestamp_ms: u64,
    /// Whether the accepted payment rule required exact payment.
    pricing_is_fixed: bool,
    /// The configured amount of the accepted payment rule.
    price: u64,
    /// Whether the Listing accepted purchases.
    enabled: bool,
    /// The defining type of the distributor that authorized the mint.
    distributor: vector<u8>,
    /// Supply immediately before this mint.
    supply_before: u32,
    /// Supply delta applied by this mint.
    supply_delta: u32,
    /// Supply immediately after this mint.
    supply_after: u32,
    /// Whether the Pressing has a maximum supply.
    has_max_supply: bool,
    /// The maximum supply, or zero when uncapped.
    max_supply: u32,
    /// The Release address receiving payment.
    payment_recipient: address,
    /// The complete amount paid, including accepted Floor overpayment.
    proceeds_amount: u64,
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
        listing_id: object::id(&listing).to_address(),
        release_id: release_id.to_address(),
        pressing_id: pressing_id.to_address(),
        pressing_admin_cap_id: object::id_address(cap),
        pricing_is_fixed: is_fixed(pricing),
        price: pricing_amount(pricing),
        enabled: true,
    });

    listing
}

/// Share a newly created Listing.
public fun share<Currency>(self: Listing<Currency>) {
    let listing_id = object::id(&self).to_address();
    let release_id = self.release_id.to_address();
    let pressing_id = self.pressing_id.to_address();
    let pricing = self.pricing;
    let enabled = self.state == State::Enabled;

    transfer::share_object(self);

    emit(ListingSharedEvent<Currency> {
        listing_id,
        release_id,
        pressing_id,
        pricing_is_fixed: pricing.is_fixed(),
        price: pricing_amount(pricing),
        enabled,
    });
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
        let pricing_before = self.pricing;
        self.pricing = pricing;
        emit(ListingPriceChangedEvent<Currency> {
            listing_id: object::id(self).to_address(),
            release_id: self.release_id.to_address(),
            pressing_id: self.pressing_id.to_address(),
            pressing_admin_cap_id: object::id_address(cap),
            pricing_is_fixed_before: pricing_before.is_fixed(),
            price_before: pricing_amount(pricing_before),
            pricing_is_fixed_after: pricing.is_fixed(),
            price_after: pricing_amount(pricing),
            enabled: self.state == State::Enabled,
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
        let state_before = self.state;
        self.state = state;
        emit(ListingStateChangedEvent<Currency> {
            listing_id: object::id(self).to_address(),
            release_id: self.release_id.to_address(),
            pressing_id: self.pressing_id.to_address(),
            pressing_admin_cap_id: object::id_address(cap),
            pricing_is_fixed: self.pricing.is_fixed(),
            price: pricing_amount(self.pricing),
            enabled_before: state_before == State::Enabled,
            enabled_after: self.state == State::Enabled,
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

    let supply_before = pressing.supply();
    let max_supply_option = pressing.max_supply();
    let has_max_supply = max_supply_option.is_some();
    let max_supply = option::destroy_with_default(max_supply_option, 0);
    let sold = pressing.mint<witness::Witness, Currency>(witness::new(), paid, clock, ctx);
    let payment_recipient = self.release_id.to_address();
    payment.send_funds(payment_recipient);

    emit(RecordSoldEvent<Currency> {
        listing_id: object::id(self).to_address(),
        record_id: object::id(&sold).to_address(),
        release_id: sold.release_id().to_address(),
        pressing_id: sold.pressing_id().to_address(),
        edition: sold.edition(),
        number: sold.number(),
        purchase_currency: sold.purchase_currency().into_string().into_bytes(),
        purchase_price: sold.purchase_price(),
        purchased_by: sold.purchased_by(),
        purchased_timestamp_ms: sold.purchased_timestamp_ms(),
        pricing_is_fixed: pricing.is_fixed(),
        price: pricing_amount(pricing),
        enabled: self.state == State::Enabled,
        distributor: type_name::with_defining_ids<witness::Witness>().into_string().into_bytes(),
        supply_before,
        supply_delta: 1,
        supply_after: pressing.supply(),
        has_max_supply,
        max_supply,
        payment_recipient,
        proceeds_amount: paid,
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

fun pricing_amount(pricing: Pricing): u64 {
    match (pricing) {
        Pricing::Fixed(value) => value,
        Pricing::Floor(value) => value,
    }
}

// === Test Functions ===

#[test_only]
public fun created_event_fields<Currency>(
    event: ListingCreatedEvent<Currency>,
): (address, address, address, address, bool, u64, bool) {
    let ListingCreatedEvent {
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed,
        price,
        enabled,
    } = event;
    (
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed,
        price,
        enabled,
    )
}

#[test_only]
public fun shared_event_fields<Currency>(
    event: ListingSharedEvent<Currency>,
): (address, address, address, bool, u64, bool) {
    let ListingSharedEvent {
        listing_id,
        release_id,
        pressing_id,
        pricing_is_fixed,
        price,
        enabled,
    } = event;
    (listing_id, release_id, pressing_id, pricing_is_fixed, price, enabled)
}

#[test_only]
public fun price_changed_event_fields<Currency>(
    event: ListingPriceChangedEvent<Currency>,
): (address, address, address, address, bool, u64, bool, u64, bool) {
    let ListingPriceChangedEvent {
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed_before,
        price_before,
        pricing_is_fixed_after,
        price_after,
        enabled,
    } = event;
    (
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed_before,
        price_before,
        pricing_is_fixed_after,
        price_after,
        enabled,
    )
}

#[test_only]
public fun state_changed_event_fields<Currency>(
    event: ListingStateChangedEvent<Currency>,
): (address, address, address, address, bool, u64, bool, bool) {
    let ListingStateChangedEvent {
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed,
        price,
        enabled_before,
        enabled_after,
    } = event;
    (
        listing_id,
        release_id,
        pressing_id,
        pressing_admin_cap_id,
        pricing_is_fixed,
        price,
        enabled_before,
        enabled_after,
    )
}

#[test_only]
public fun sold_event_fields<Currency>(
    event: RecordSoldEvent<Currency>,
): (address, address, address, address, u16, u32, vector<u8>, u64, address, u64, bool, u64, bool, vector<u8>, u32, u32, u32, bool, u32, address, u64) {
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
        pricing_is_fixed,
        price,
        enabled,
        distributor,
        supply_before,
        supply_delta,
        supply_after,
        has_max_supply,
        max_supply,
        payment_recipient,
        proceeds_amount,
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
        pricing_is_fixed,
        price,
        enabled,
        distributor,
        supply_before,
        supply_delta,
        supply_after,
        has_max_supply,
        max_supply,
        payment_recipient,
        proceeds_amount,
    )
}
