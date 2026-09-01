// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module miso_record_shop::listing_tests;

use miso::release::{Self, Release, ReleaseAdminCap};
use miso_record::pressing::{Self, Pressing, PressingAdminCap};
use miso_record::record::{Self, Record};
use miso_record_shop::listing::{Self, Listing};
use miso_record_shop::witness::Witness;
use std::type_name;
use std::unit_test::{assert_eq, destroy};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::derived_object;
use sui::event;
use sui::test_scenario as ts;

public struct USD() has drop;
public struct EUR() has drop;

fun id(address: address): ID {
    object::id_from_address(address)
}

fun a_release(ctx: &mut TxContext): (Release, ReleaseAdminCap) {
    release::new_for_testing("Test Release", vector[], ctx)
}

fun a_pressing(
    release_id: ID,
    max_supply: Option<u32>,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    pressing::new_for_testing(release_id, 1, max_supply, ctx)
}

fun clock_at(timestamp_ms: u64, ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(timestamp_ms);
    clock
}

fun payment<Currency>(value: u64): Balance<Currency> {
    balance::create_for_testing(value)
}

fun purchase_at<Currency>(
    listing: &Listing<Currency>,
    pressing: &mut Pressing,
    payment: Balance<Currency>,
    expected_pricing: listing::Pricing,
    timestamp_ms: u64,
    ctx: &mut TxContext,
): Record {
    let clock = clock_at(timestamp_ms, ctx);
    let record = listing.purchase(pressing, payment, expected_pricing, &clock, ctx);
    clock.destroy_for_testing();
    record
}

fun assert_record_created(
    created: record::RecordCreatedEvent,
    record_id: ID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    number: u32,
) {
    let (
        event_record_id,
        event_release_id,
        event_pressing_id,
        event_edition,
        event_number,
    ) = record::created_event_fields(created);
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(event_edition, edition);
    assert_eq!(event_number, number);
}

fun assert_record_purchase(
    purchased: pressing::RecordPurchasedEvent,
    record_id: ID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    number: u32,
    purchase_price: u64,
    purchased_by: address,
    purchased_timestamp_ms: u64,
) {
    let (
        event_record_id,
        event_release_id,
        event_pressing_id,
        event_edition,
        event_number,
        event_purchase_currency,
        event_purchase_price,
        event_purchased_by,
        event_purchased_timestamp_ms,
        distributor,
    ) = pressing::purchased_event_fields(purchased);
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(event_edition, edition);
    assert_eq!(event_number, number);
    assert_eq!(event_purchase_currency, type_name::with_defining_ids<USD>());
    assert_eq!(event_purchase_price, purchase_price);
    assert_eq!(event_purchased_by, purchased_by);
    assert_eq!(event_purchased_timestamp_ms, purchased_timestamp_ms);
    assert_eq!(distributor, type_name::with_defining_ids<Witness>());
}

fun assert_record_sale(
    sold: listing::RecordSoldEvent<USD>,
    listing_id: ID,
    record_id: ID,
    release_id: ID,
    pressing_id: ID,
    edition: u16,
    number: u32,
    purchase_price: u64,
    purchased_by: address,
    purchased_timestamp_ms: u64,
    pricing: listing::Pricing,
) {
    let (
        event_listing_id,
        event_record_id,
        event_release_id,
        event_pressing_id,
        event_edition,
        event_number,
        event_purchase_currency,
        event_purchase_price,
        event_purchased_by,
        event_purchased_timestamp_ms,
        event_pricing,
    ) = listing::sold_event_fields(sold);
    assert_eq!(event_listing_id, listing_id);
    assert_eq!(event_record_id, record_id);
    assert_eq!(event_release_id, release_id);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(event_edition, edition);
    assert_eq!(event_number, number);
    assert_eq!(event_purchase_currency, type_name::with_defining_ids<USD>());
    assert_eq!(event_purchase_price, purchase_price);
    assert_eq!(event_purchased_by, purchased_by);
    assert_eq!(event_purchased_timestamp_ms, purchased_timestamp_ms);
    assert_eq!(event_pricing, pricing);
}

#[test]
fun complete_sale_delivers_record_and_release_owner_withdraws_exact_proceeds() {
    let seller = @0xA;
    let buyer = @0xB;
    let price = 25;
    let timestamp_ms = 1_726_000_123;
    let mut scenario = ts::begin(seller);

    let (mut release, release_cap) = a_release(scenario.ctx());
    let release_id = object::id(&release);
    let (mut pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 7, option::some(1));
    let pressing_id = object::id(&pressing);
    pressing.authorize_distributor<Witness>(&pressing_cap);
    let listing = listing::new<USD>(&mut pressing, &pressing_cap, listing::fixed(price));
    let listing_id = object::id(&listing);
    assert_eq!(pressing_id.to_address(), pressing::derive_address(release_id, 7));
    assert_eq!(listing_id.to_address(), listing::derive_address<USD>(pressing_id));

    let clock = clock_at(timestamp_ms, scenario.ctx());
    release.publish(&release_cap, &clock);
    pressing.share();
    listing.share();
    transfer::public_transfer(release_cap, seller);
    transfer::public_transfer(pressing_cap, seller);
    clock::share_for_testing(clock);

    scenario.next_tx(buyer);
    let listing = scenario.take_shared<Listing<USD>>();
    let mut pressing = scenario.take_shared<Pressing>();
    let clock = scenario.take_shared<Clock>();
    let record = listing.purchase(
        &mut pressing,
        payment(price),
        listing::fixed(price),
        &clock,
        scenario.ctx(),
    );
    let record_id = object::id(&record);

    assert_eq!(record.release_id(), release_id);
    assert_eq!(record.pressing_id(), pressing_id);
    assert_eq!(record.edition(), 7);
    assert_eq!(record.number(), 1);
    assert_eq!(record.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(record.purchase_price(), price);
    assert_eq!(record.purchased_by(), buyer);
    assert_eq!(record.purchased_timestamp_ms(), timestamp_ms);
    assert_eq!(object::id_address(&record), record::derive_address(pressing_id, 1));
    assert_eq!(pressing.supply(), 1);
    assert_eq!(pressing.max_supply(), option::some(1));

    let mut created = event::events_by_type<record::RecordCreatedEvent>();
    assert_eq!(created.length(), 1);
    assert_record_created(
        created.pop_back(),
        record_id,
        release_id,
        pressing_id,
        7,
        1,
    );

    let mut purchased = event::events_by_type<pressing::RecordPurchasedEvent>();
    assert_eq!(purchased.length(), 1);
    assert_record_purchase(
        purchased.pop_back(),
        record_id,
        release_id,
        pressing_id,
        7,
        1,
        price,
        buyer,
        timestamp_ms,
    );

    let mut sold = event::events_by_type<listing::RecordSoldEvent<USD>>();
    assert_eq!(sold.length(), 1);
    assert_record_sale(
        sold.pop_back(),
        listing_id,
        record_id,
        release_id,
        pressing_id,
        7,
        1,
        price,
        buyer,
        timestamp_ms,
        listing::fixed(price),
    );

    ts::return_shared(listing);
    ts::return_shared(pressing);
    ts::return_shared(clock);
    transfer::public_transfer(record, buyer);

    scenario.next_tx(buyer);
    let owned_record = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&owned_record), record_id);
    owned_record.destroy();

    scenario.next_tx(seller);
    let mut release = scenario.take_shared<Release>();
    let release_cap = scenario.take_from_sender<ReleaseAdminCap>();
    let pressing_cap = scenario.take_from_sender<PressingAdminCap>();
    let withdrawal = balance::withdraw_funds_from_object<USD>(
        release.uid_mut(&release_cap),
        price,
    );
    let proceeds = balance::redeem_funds(withdrawal);
    assert_eq!(proceeds.value(), price);
    assert_eq!(proceeds.destroy_for_testing(), price);
    ts::return_shared(release);
    destroy(release_cap);
    destroy(pressing_cap);

    scenario.end();
}

#[test]
fun two_currencies_have_distinct_listings_and_share_one_pressing_sequence() {
    let mut ctx = tx_context::dummy();
    let (mut release, release_cap) = a_release(&mut ctx);
    let (mut pressing, pressing_cap) =
        pressing::new(&mut release, &release_cap, 1, option::none());
    pressing.authorize_distributor<Witness>(&pressing_cap);
    let pressing_id = object::id(&pressing);
    let usd = listing::new<USD>(&mut pressing, &pressing_cap, listing::fixed(5));
    let eur = listing::new<EUR>(&mut pressing, &pressing_cap, listing::floor(7));

    assert_eq!(object::id_address(&usd), listing::derive_address<USD>(pressing_id));
    assert_eq!(object::id_address(&eur), listing::derive_address<EUR>(pressing_id));
    assert!(object::id(&usd) != object::id(&eur));

    let first = purchase_at(
        &usd,
        &mut pressing,
        payment(5),
        listing::fixed(5),
        10,
        &mut ctx,
    );
    let second = purchase_at(
        &eur,
        &mut pressing,
        payment(9),
        listing::floor(7),
        11,
        &mut ctx,
    );
    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(first.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(first.purchase_price(), 5);
    assert_eq!(second.purchase_currency(), type_name::with_defining_ids<EUR>());
    assert_eq!(second.purchase_price(), 9);
    assert_eq!(pressing.supply(), 2);
    assert_eq!(object::id_address(&first), record::derive_address(pressing_id, 1));
    assert_eq!(object::id_address(&second), record::derive_address(pressing_id, 2));

    let usd_proceeds = balance::redeem_funds(
        balance::withdraw_funds_from_object<USD>(release.uid_mut(&release_cap), 5),
    );
    let eur_proceeds = balance::redeem_funds(
        balance::withdraw_funds_from_object<EUR>(release.uid_mut(&release_cap), 9),
    );
    assert_eq!(usd_proceeds.destroy_for_testing(), 5);
    assert_eq!(eur_proceeds.destroy_for_testing(), 9);

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
fun listing_configuration_is_cap_gated_and_observable() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    assert_eq!(listing.release_id(), id(@0xA));
    assert_eq!(listing.pressing_id(), object::id(&pressing));
    assert!(listing::is_fixed(listing.pricing()));
    assert!(!listing::is_floor(listing.pricing()));
    assert_eq!(listing.price(), 10);
    assert_eq!(listing.state(), listing::enabled());
    assert!(listing.is_enabled());
    assert!(!listing.is_disabled());

    listing.set_price(&cap, listing::fixed(10));
    listing.set_state(&cap, listing::enabled());
    listing.set_price(&cap, listing::floor(12));
    listing.set_state(&cap, listing::disabled());
    listing.set_price(&cap, listing::floor(12));
    listing.set_state(&cap, listing::disabled());
    assert!(!listing::is_fixed(listing.pricing()));
    assert!(listing::is_floor(listing.pricing()));
    assert_eq!(listing.price(), 12);
    assert!(listing.is_disabled());

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
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(
    abort_code = pressing::EDistributorNotAuthorized,
    location = pressing,
)]
fun revoked_record_shop_cannot_mint() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    pressing.revoke_distributor<Witness>(&cap);
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EWrongPressing, location = listing)]
fun listing_rejects_a_different_pressing() {
    let mut ctx = tx_context::dummy();
    let (mut first, first_cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    let (mut second, second_cap) = a_pressing(id(@0xB), option::none(), &mut ctx);
    first.authorize_distributor<Witness>(&first_cap);
    second.authorize_distributor<Witness>(&second_cap);
    let listing = listing::new<USD>(&mut first, &first_cap, listing::fixed(10));
    let record = purchase_at(
        &listing,
        &mut second,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(first);
    destroy(first_cap);
    destroy(second);
    destroy(second_cap);
}

#[test, expected_failure(
    abort_code = derived_object::EObjectAlreadyExists,
    location = derived_object,
)]
fun pressing_cannot_create_the_same_currency_listing_twice() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
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
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
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
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
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
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_state(&cap, listing::disabled());
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun fixed_listing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(9),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun fixed_listing_rejects_overpayment() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(11),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EPriceChanged, location = listing)]
fun expected_pricing_rejects_stale_repricing() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&cap, listing::fixed(11));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(11),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EPriceChanged, location = listing)]
fun expected_fixed_rule_rejects_equal_amount_floor_repricing() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    listing.set_price(&cap, listing::floor(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EPriceChanged, location = listing)]
fun expected_floor_rule_rejects_equal_amount_fixed_repricing() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let mut listing = listing::new<USD>(&mut pressing, &cap, listing::floor(10));
    listing.set_price(&cap, listing::fixed(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::floor(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EWrongPayment, location = listing)]
fun floor_listing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::floor(10));
    let record = purchase_at(
        &listing,
        &mut pressing,
        payment(9),
        listing::floor(10),
        0,
        &mut ctx,
    );
    record.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached, location = pressing)]
fun maximum_supply_boundary_rejects_the_next_purchase() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::some(1), &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(10));
    let first = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        0,
        &mut ctx,
    );
    first.destroy();
    let second = purchase_at(
        &listing,
        &mut pressing,
        payment(10),
        listing::fixed(10),
        1,
        &mut ctx,
    );
    second.destroy();
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = listing::EInvalidPrice, location = listing)]
fun listing_rejects_zero_price() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), option::none(), &mut ctx);
    let listing = listing::new<USD>(&mut pressing, &cap, listing::fixed(0));
    destroy(listing);
    destroy(pressing);
    destroy(cap);
}
