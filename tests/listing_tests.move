// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

#[test_only]
module record_shop::listing_tests;

use musicos::release::{Self, Release, ReleaseAdminCap};
use record::pressing::{Self, Pressing, PressingAdminCap};
use record::record::{Self, Record};
use record_shop::listing::{Self, Listing};
use record_shop::witness::Witness;
use release_revenue_forwarder::release_revenue_forwarder::{Self, ReleaseRevenueForwardedEvent};
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::derived_object;
use sui::event;
use sui::test_scenario as ts;

public struct USD() has drop;
public struct EUR() has drop;

fun id(address: address): ID {
    object::id_from_address(address)
}

/// A release with two tracks, so forwarded payments split across them.
fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    let release_id = id(ctx.fresh_object_address());
    let consents = vector::tabulate!(2, |_| {
        release::consent_for_testing(id(ctx.fresh_object_address()), release_id)
    });
    release::new_for_testing(consents, ctx)
}

/// The amount each forward reported, in order.
fun forwarded<Currency>(): vector<u64> {
    event::events_by_type<ReleaseRevenueForwardedEvent<Currency>>().map!(|event| {
        let (_, amount) = release_revenue_forwarder::forwarded_event_fields(&event);
        amount
    })
}

fun a_pressing(
    release_id: ID,
    max_supply: u32,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    pressing::new_for_testing(release_id, 1, max_supply, ctx)
}

fun payment<Currency>(value: u64): Balance<Currency> {
    balance::create_for_testing(value)
}

fun assert_record_purchase(
    purchased: &pressing::RecordPurchasedEvent<Witness, USD>,
    record_id: ID,
    pressing_id: ID,
    number: u32,
    purchase_price: u64,
) {
    let (event_record_id, event_pressing_id, event_number, event_purchase_price) =
        pressing::purchased_event_fields(purchased);
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(event_number, number);
    assert_eq!(event_purchase_price, purchase_price);
}

fun assert_record_sale<Currency>(
    sold: &listing::RecordSoldEvent<Currency>,
    listing_id: ID,
    record_id: ID,
    pricing: listing::Pricing,
) {
    let (event_listing_id, event_record_id, event_pricing) = listing::sold_event_fields(sold);
    assert_eq!(event_listing_id, listing_id);
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_pricing, pricing);
}

#[test]
fun complete_sale_delivers_record_and_forwards_proceeds_to_the_tracks() {
    let seller = @0xA;
    let buyer = @0xB;
    let final_recipient = @0xC;
    let price = 25;
    let mut scenario = ts::begin(seller);

    let (mut release, release_cap) = a_release(scenario.ctx());
    let release_id = object::id(&release);
    let (mut pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 1, 1);
    let pressing_id = object::id(&pressing);
    pressing.authorize_distributor<Witness>(&pressing_cap);
    let listing = listing::new<USD>(&mut pressing, &pressing_cap, listing::fixed(price));
    let listing_id = object::id(&listing);
    assert_eq!(pressing_id.to_address(), pressing::derive_address(release_id, 1));
    assert_eq!(listing_id.to_address(), listing::derive_address<USD>(pressing_id));

    release.publish(&release_cap);
    pressing.share();
    listing.share();
    transfer::public_transfer(release_cap, seller);
    transfer::public_transfer(pressing_cap, seller);

    scenario.next_tx(buyer);
    let listing = scenario.take_shared<Listing<USD>>();
    let mut pressing = scenario.take_shared<Pressing>();
    let release = scenario.take_shared<Release>();
    let record = listing.purchase(&mut pressing, &release, payment(price));
    let record_id = object::id(&record);

    assert_eq!(record.release_id(), release_id);
    assert_eq!(record.pressing_id(), pressing_id);
    assert_eq!(record.edition(), 1);
    assert_eq!(record.number(), 1);
    assert_eq!(record.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(record.purchase_price(), price);
    assert_eq!(object::id_address(&record), record::derive_address(pressing_id, 1));
    assert_eq!(pressing.supply(), 1);
    assert_eq!(pressing.max_supply(), 1);
    // Two tracks take 12 each; the remainder of 1 goes back to the Release.
    assert_eq!(forwarded<USD>(), vector[24]);

    let purchased = event::events_by_type<pressing::RecordPurchasedEvent<Witness, USD>>();
    assert_eq!(purchased.length(), 1);
    assert_record_purchase(&purchased[0], record_id, pressing_id, 1, price);

    let sold = event::events_by_type<listing::RecordSoldEvent<USD>>();
    assert_eq!(sold.length(), 1);
    assert_record_sale(&sold[0], listing_id, record_id, listing::fixed(price));

    ts::return_shared(listing);
    ts::return_shared(pressing);
    ts::return_shared(release);
    transfer::public_transfer(record, final_recipient);

    scenario.next_tx(final_recipient);
    let owned_record = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&owned_record), record_id);
    owned_record.destroy();

    scenario.next_tx(seller);
    let release_cap = scenario.take_from_sender<ReleaseAdminCap>();
    let pressing_cap = scenario.take_from_sender<PressingAdminCap>();
    destroy(release_cap);
    destroy(pressing_cap);

    scenario.end();
}

#[test]
fun two_currencies_have_distinct_listings_and_share_one_pressing_sequence() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (mut pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 1, 100);
    pressing.authorize_distributor<Witness>(&pressing_cap);
    let pressing_id = object::id(&pressing);
    let mut usd = listing::new<USD>(&mut pressing, &pressing_cap, listing::fixed(5));
    let mut eur = listing::new<EUR>(&mut pressing, &pressing_cap, listing::floor(7));

    assert_eq!(object::id_address(&usd), listing::derive_address<USD>(pressing_id));
    assert_eq!(object::id_address(&eur), listing::derive_address<EUR>(pressing_id));
    assert!(object::id(&usd) != object::id(&eur));

    let first = usd.purchase(&mut pressing, &release, payment(5));
    let second = eur.purchase(&mut pressing, &release, payment(9));
    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(first.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(first.purchase_price(), 5);
    assert_eq!(second.purchase_currency(), type_name::with_defining_ids<EUR>());
    assert_eq!(second.purchase_price(), 9);
    assert_eq!(pressing.supply(), 2);
    assert_eq!(object::id_address(&first), record::derive_address(pressing_id, 1));
    assert_eq!(object::id_address(&second), record::derive_address(pressing_id, 2));

    let usd_sold = event::events_by_type<listing::RecordSoldEvent<USD>>();
    let eur_sold = event::events_by_type<listing::RecordSoldEvent<EUR>>();
    assert_eq!(usd_sold.length(), 1);
    assert_eq!(eur_sold.length(), 1);
    assert_record_sale(&usd_sold[0], object::id(&usd), object::id(&first), listing::fixed(5));
    assert_record_sale(&eur_sold[0], object::id(&eur), object::id(&second), listing::floor(7));
    let eur_purchased = event::events_by_type<pressing::RecordPurchasedEvent<Witness, EUR>>();
    let (_, _, number, paid) = pressing::purchased_event_fields(&eur_purchased[0]);
    assert_eq!(number, 2);
    assert_eq!(paid, 9);

    // Each payment is split across the two tracks in its own currency.
    assert_eq!(forwarded<USD>(), vector[4]);
    assert_eq!(forwarded<EUR>(), vector[8]);

    first.destroy();
    second.destroy();
    destroy(usd);
    destroy(eur);
    destroy(pressing);
    destroy(pressing_cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun floor_overpayments_are_forwarded_in_full() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (mut pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 1, 100);
    pressing.authorize_distributor<Witness>(&pressing_cap);
    let mut listing = listing::new<USD>(&mut pressing, &pressing_cap, listing::floor(7));

    let first = listing.purchase(&mut pressing, &release, payment(9));
    let second = listing.purchase(&mut pressing, &release, payment(12));

    // Floor overpayments are forwarded in full, less each rounding remainder.
    assert_eq!(forwarded<USD>(), vector[8, 12]);

    first.destroy();
    second.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(pressing_cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun listing_configuration_is_cap_gated_and_observable() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    assert_eq!(listing.pressing_id(), object::id(&pressing));
    assert_eq!(listing.pricing(), listing::fixed(10));
    assert_eq!(listing.price(), 10);
    assert!(listing.is_enabled());

    listing.set_price(&cap, listing::fixed(10));
    listing.set_enabled(&cap, true);
    listing.set_price(&cap, listing::floor(12));
    listing.set_enabled(&cap, false);
    listing.set_price(&cap, listing::floor(12));
    listing.set_enabled(&cap, false);
    assert_eq!(listing.pricing(), listing::floor(12));
    assert_eq!(listing.price(), 12);
    assert!(!listing.is_enabled());

    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test]
fun listing_events_capture_only_real_changes() {
    let mut scenario = ts::begin(@0xA);
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, scenario.ctx());
    let pressing_id = object::id(&pressing);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let listing_id = object::id(&listing);

    let created = event::events_by_type<listing::ListingCreatedEvent<USD>>();
    assert_eq!(created.length(), 1);
    let (event_listing_id, event_pressing_id, event_pricing) =
        listing::created_event_fields(&created[0]);
    assert_eq!(event_listing_id, listing_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(event_pricing, listing::fixed(10));

    listing.set_price(&cap, listing::floor(12));
    listing.set_price(&cap, listing::floor(12));
    listing.set_enabled(&cap, false);
    listing.set_enabled(&cap, false);

    let price_changed = event::events_by_type<listing::ListingPriceChangedEvent<USD>>();
    assert_eq!(price_changed.length(), 1);
    let (event_listing_id, pricing) = listing::price_changed_event_fields(&price_changed[0]);
    assert_eq!(event_listing_id, listing_id);
    assert_eq!(pricing, listing::floor(12));

    let enabled_changed = event::events_by_type<listing::ListingEnabledChangedEvent<USD>>();
    assert_eq!(enabled_changed.length(), 1);
    let (event_listing_id, enabled) = listing::enabled_changed_event_fields(&enabled_changed[0]);
    assert_eq!(event_listing_id, listing_id);
    assert!(!enabled);

    let event_count = event::num_events();
    listing.share();
    assert_eq!(event::num_events(), event_count);

    scenario.next_tx(@0xB);
    let listing = scenario.take_shared<Listing<USD>>();
    assert_eq!(object::id(&listing), listing_id);
    assert_eq!(listing.pressing_id(), pressing_id);
    assert_eq!(listing.pricing(), listing::floor(12));
    assert!(!listing.is_enabled());
    ts::return_shared(listing);

    destroy(pressing);
    destroy(cap);
    scenario.end();
}

#[test]
fun price_events_distinguish_pricing_variants_and_amount_changes() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&cap, listing::floor(10));
    listing.set_price(&cap, listing::floor(5));
    listing.set_price(&cap, listing::fixed(7));
    listing.set_price(&cap, listing::fixed(7));
    listing.set_price(&cap, listing::fixed(12));

    let changed = event::events_by_type<listing::ListingPriceChangedEvent<USD>>();
    assert_eq!(
        changed.map_ref!(|event| {
            let (_, pricing) = listing::price_changed_event_fields(event);
            pricing
        }),
        vector[listing::floor(10), listing::floor(5), listing::fixed(7), listing::fixed(12)],
    );

    listing.set_enabled(&cap, false);
    listing.set_enabled(&cap, false);
    listing.set_enabled(&cap, true);
    listing.set_enabled(&cap, true);
    let states = event::events_by_type<listing::ListingEnabledChangedEvent<USD>>();
    assert_eq!(
        states.map_ref!(|event| {
            let (_, enabled) = listing::enabled_changed_event_fields(event);
            enabled
        }),
        vector[false, true],
    );

    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(
    abort_code = pressing::EDistributorNotAuthorized,
    location = pressing,
)]
fun unauthorized_record_shop_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = listing.purchase(&mut pressing, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(
    abort_code = pressing::EDistributorNotAuthorized,
    location = pressing,
)]
fun revoked_record_shop_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    pressing.revoke_distributor<Witness>(&cap);
    let record = listing.purchase(&mut pressing, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongPressing, location = listing)]
fun listing_rejects_a_different_pressing() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut first, first_cap) = a_pressing(object::id(&release), 100, &mut ctx);
    let (mut second, second_cap) = a_pressing(id(@0xB), 100, &mut ctx);
    first.authorize_distributor<Witness>(&first_cap);
    second.authorize_distributor<Witness>(&second_cap);
    let mut listing = listing::new<USD>(&mut first, &first_cap, listing::fixed(10));
    let record = listing.purchase(&mut second, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongRelease, location = listing)]
fun listing_rejects_a_different_release() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (other, other_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = listing.purchase(&mut pressing, &other, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(
    abort_code = derived_object::EObjectAlreadyExists,
    location = derived_object,
)]
fun pressing_cannot_create_the_same_currency_listing_twice() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let first = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let second = listing::new<USD>(&mut pressing, &cap, listing::floor(10));
    destroy(first);
    destroy(second);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized, location = pressing)]
fun listing_creation_rejects_a_foreign_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xBAD), &mut ctx);
    let listing = listing::new<USD>(&mut pressing, &foreign, listing::fixed(10));
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(foreign);
}

#[test, expected_failure(abort_code = listing::EUnauthorized, location = listing)]
fun listing_update_rejects_a_foreign_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xBAD), &mut ctx);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&foreign, listing::fixed(11));
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(foreign);
}

#[test, expected_failure(abort_code = listing::EDisabled, location = listing)]
fun disabled_listing_rejects_purchase() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_enabled(&cap, false);
    let record = listing.purchase(&mut pressing, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun fixed_listing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = listing.purchase(&mut pressing, &release, payment(9));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun fixed_listing_rejects_overpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = listing.purchase(&mut pressing, &release, payment(11));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

/// A payment signed for the old price aborts after a repricing, so a buyer
/// is never charged a price they didn't sign.
#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun repricing_up_rejects_the_signed_payment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&cap, listing::fixed(11));
    let record = listing.purchase(&mut pressing, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun repricing_down_rejects_the_signed_payment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&cap, listing::fixed(9));
    let record = listing.purchase(&mut pressing, &release, payment(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun floor_listing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::floor(10));
    let record = listing.purchase(&mut pressing, &release, payment(9));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun maximum_supply_boundary_rejects_the_next_purchase() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 1, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let first = listing.purchase(&mut pressing, &release, payment(10));
    first.destroy();
    let second = listing.purchase(&mut pressing, &release, payment(10));
    second.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test, expected_failure(abort_code = listing::EInvalidPrice, location = listing)]
fun listing_rejects_zero_price() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(0));
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun currencies_share_the_same_supply_cap() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 1, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut usd = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let mut eur = listing::new<EUR>(&mut pressing, &cap, listing::fixed(20));
    let usd_record = usd.purchase(&mut pressing, &release, payment(10));
    usd_record.destroy();
    let eur_record = eur.purchase(&mut pressing, &release, payment(20));
    eur_record.destroy();
    destroy(usd);
    destroy(eur);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}

#[test]
fun sale_supports_the_u16_maximum_edition() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = pressing::new_for_testing(object::id(&release), 65_535, 1, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = listing.purchase(&mut pressing, &release, payment(10));
    assert_eq!(record.edition(), 65_535);
    let events = event::events_by_type<listing::RecordSoldEvent<USD>>();
    assert_record_sale(&events[0], object::id(&listing), object::id(&record), listing::fixed(10));
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
}
