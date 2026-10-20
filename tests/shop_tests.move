// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

#[test_only]
module record_shop::shop_tests;

use std::{type_name, u64, unit_test::{assert_eq, destroy}};
use sui::{
    balance::{Self, Balance},
    clock::{Self, Clock},
    dynamic_field,
    event,
    test_scenario as ts,
};
use musicos::release::{Self, Release, ReleaseAdminCap};
use record::{pressing::{Self, Pressing, PressingAdminCap}, record::{Self, Record}};
use release_revenue_forwarder::release_revenue_forwarder::{Self, ReleaseRevenueForwardedEvent};
use record_shop::{shop, witness::Witness};

const PURCHASED_AT_MS: u64 = 1_726_000_123;

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

/// An authorized Pressing for `release` with the Record Shop on sale in USD.
fun a_shop(
    release: &Release,
    max_supply: u32,
    pricing: shop::Pricing,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    let (mut pressing, cap) = a_pressing(object::id(release), max_supply, ctx);
    pressing.authorize_distributor<Witness>(&cap);
    shop::set_pricing<USD>(&mut pressing, &cap, pricing);
    (pressing, cap)
}

fun a_pressing(
    release_id: ID,
    max_supply: u32,
    ctx: &mut TxContext,
): (Pressing, PressingAdminCap) {
    pressing::new_for_testing(release_id, 1, max_supply, ctx)
}

fun a_clock(ctx: &mut TxContext): Clock {
    let mut clock = clock::create_for_testing(ctx);
    clock.set_for_testing(PURCHASED_AT_MS);
    clock
}

/// The amount each forward reported, in order.
fun forwarded<Currency>(): vector<u64> {
    event::events_by_type<ReleaseRevenueForwardedEvent<Currency>>().map!(|event| {
        let (_, amount) = release_revenue_forwarder::forwarded_event_fields(&event);
        amount
    })
}

fun payment<Currency>(value: u64): Balance<Currency> {
    balance::create_for_testing(value)
}

fun assert_record_purchase<Currency>(
    purchased: &pressing::RecordPurchasedEvent<Witness, Currency>,
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

fun set_pricings<Currency>(): vector<shop::Pricing> {
    event::events_by_type<shop::PricingSetEvent<Currency>>().map_ref!(|event| {
        let (_, pricing) = shop::set_event_fields(event);
        pricing
    })
}

fun cleanup(
    pressing: Pressing,
    cap: PressingAdminCap,
    release: Release,
    release_cap: ReleaseAdminCap,
    clock: Clock,
) {
    destroy(pressing);
    destroy(cap);
    destroy(release);
    destroy(release_cap);
    clock.destroy_for_testing();
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
    let (mut pressing, pressing_cap) = pressing::new(&mut release, &release_cap, 1, 1);
    let pressing_id = object::id(&pressing);
    pressing.authorize_distributor<Witness>(&pressing_cap);
    shop::set_pricing<USD>(&mut pressing, &pressing_cap, shop::fixed(price));
    assert_eq!(pressing_id.to_address(), pressing::derive_address(release_id, 1));

    release.publish(&release_cap);
    pressing.share();
    transfer::public_transfer(release_cap, seller);
    transfer::public_transfer(pressing_cap, seller);

    scenario.next_tx(buyer);
    let mut pressing = scenario.take_shared<Pressing>();
    let release = scenario.take_shared<Release>();
    let clock = a_clock(scenario.ctx());
    let record = shop::purchase(&mut pressing, &release, payment<USD>(price), &clock);
    let record_id = object::id(&record);

    assert_eq!(record.release_id(), release_id);
    assert_eq!(record.pressing_id(), pressing_id);
    assert_eq!(record.edition(), 1);
    assert_eq!(record.number(), 1);
    assert_eq!(record.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(record.purchase_price(), price);
    assert_eq!(record.purchased_at_ms(), PURCHASED_AT_MS);
    assert_eq!(object::id_address(&record), record::derive_address(pressing_id, 1));
    assert_eq!(pressing.supply(), 1);
    // Two tracks take 12 each; the remainder of 1 goes back to the Release.
    assert_eq!(forwarded<USD>(), vector[24]);

    let purchased = event::events_by_type<pressing::RecordPurchasedEvent<Witness, USD>>();
    assert_eq!(purchased.length(), 1);
    assert_record_purchase(&purchased[0], record_id, pressing_id, 1, price);

    ts::return_shared(pressing);
    ts::return_shared(release);
    clock.destroy_for_testing();
    transfer::public_transfer(record, final_recipient);

    scenario.next_tx(final_recipient);
    let owned_record = scenario.take_from_sender<Record>();
    assert_eq!(object::id(&owned_record), record_id);
    owned_record.destroy();

    scenario.next_tx(seller);
    destroy(scenario.take_from_sender<ReleaseAdminCap>());
    destroy(scenario.take_from_sender<PressingAdminCap>());
    scenario.end();
}

#[test]
fun two_currencies_are_priced_separately_and_share_one_pressing_sequence() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(5), &mut ctx);
    shop::set_pricing<EUR>(&mut pressing, &cap, shop::floor(7));
    let pressing_id = object::id(&pressing);
    let clock = a_clock(&mut ctx);
    assert_eq!(shop::pricing<USD>(&pressing), option::some(shop::fixed(5)));
    assert_eq!(shop::pricing<EUR>(&pressing), option::some(shop::floor(7)));

    let first = shop::purchase(&mut pressing, &release, payment<USD>(5), &clock);
    let second = shop::purchase(&mut pressing, &release, payment<EUR>(9), &clock);
    assert_eq!(first.number(), 1);
    assert_eq!(second.number(), 2);
    assert_eq!(first.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(first.purchase_price(), 5);
    assert_eq!(second.purchase_currency(), type_name::with_defining_ids<EUR>());
    assert_eq!(second.purchase_price(), 9);
    assert_eq!(pressing.supply(), 2);

    let usd_purchased = event::events_by_type<pressing::RecordPurchasedEvent<Witness, USD>>();
    let eur_purchased = event::events_by_type<pressing::RecordPurchasedEvent<Witness, EUR>>();
    assert_eq!(usd_purchased.length(), 1);
    assert_eq!(eur_purchased.length(), 1);
    assert_record_purchase(&usd_purchased[0], object::id(&first), pressing_id, 1, 5);
    assert_record_purchase(&eur_purchased[0], object::id(&second), pressing_id, 2, 9);

    // Each payment is split across the two tracks in its own currency.
    assert_eq!(forwarded<USD>(), vector[4]);
    assert_eq!(forwarded<EUR>(), vector[8]);

    first.destroy();
    second.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun floor_overpayments_are_forwarded_in_full() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::floor(7), &mut ctx);
    let clock = a_clock(&mut ctx);

    let first = shop::purchase(&mut pressing, &release, payment<USD>(9), &clock);
    let second = shop::purchase(&mut pressing, &release, payment<USD>(12), &clock);

    // Floor overpayments are forwarded in full, less each rounding remainder.
    assert_eq!(forwarded<USD>(), vector[8, 12]);

    first.destroy();
    second.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun pricing_is_cap_gated_and_observable() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    assert_eq!(shop::pricing<USD>(&pressing), option::none());

    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    assert_eq!(shop::pricing<USD>(&pressing), option::some(shop::fixed(10)));
    assert_eq!(shop::fixed(10).amount(), 10);
    assert_eq!(shop::floor(12).amount(), 12);

    shop::set_pricing<USD>(&mut pressing, &cap, shop::floor(12));
    assert_eq!(shop::pricing<USD>(&pressing), option::some(shop::floor(12)));
    assert_eq!(shop::pricing<EUR>(&pressing), option::none());

    shop::remove_pricing<USD>(&mut pressing, &cap);
    assert_eq!(shop::pricing<USD>(&pressing), option::none());

    destroy(pressing);
    destroy(cap);
}

#[test]
fun pricing_events_capture_only_real_changes() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let pressing_id = object::id(&pressing);

    shop::remove_pricing<USD>(&mut pressing, &cap);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    shop::set_pricing<USD>(&mut pressing, &cap, shop::floor(10));
    shop::set_pricing<USD>(&mut pressing, &cap, shop::floor(5));
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(7));
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(7));
    shop::remove_pricing<USD>(&mut pressing, &cap);
    shop::remove_pricing<USD>(&mut pressing, &cap);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(7));

    let set = event::events_by_type<shop::PricingSetEvent<USD>>();
    let (event_pressing_id, _) = shop::set_event_fields(&set[0]);
    assert_eq!(event_pressing_id, pressing_id);
    assert_eq!(
        set_pricings<USD>(),
        vector[shop::fixed(10), shop::floor(10), shop::floor(5), shop::fixed(7), shop::fixed(7)],
    );
    let removed = event::events_by_type<shop::PricingRemovedEvent<USD>>();
    assert_eq!(removed.length(), 1);
    assert_eq!(shop::removed_event_fields(&removed[0]), pressing_id);
    assert_eq!(event::events_by_type<shop::PricingSetEvent<EUR>>().length(), 0);

    destroy(pressing);
    destroy(cap);
}

#[test, expected_failure(abort_code = pressing::EDistributorNotAuthorized)]
fun unauthorized_record_shop_cannot_press() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_pressing(object::id(&release), 100, &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = pressing::EDistributorNotAuthorized)]
fun revoked_record_shop_cannot_press() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    pressing.revoke_distributor<Witness>(&cap);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongRelease)]
fun purchase_rejects_a_different_release() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (other, other_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &other, payment<USD>(10), &clock);
    record.destroy();
    destroy(other);
    destroy(other_cap);
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = dynamic_field::EFieldDoesNotExist)]
fun purchase_rejects_a_currency_not_on_sale() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<EUR>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = dynamic_field::EFieldDoesNotExist)]
fun removed_pricing_rejects_purchase() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    shop::remove_pricing<USD>(&mut pressing, &cap);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun set_pricing_rejects_a_foreign_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let (other, other_cap) = a_pressing(id(@0xB), 100, &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &other_cap, shop::fixed(10));
    destroy(pressing);
    destroy(cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun remove_pricing_rejects_a_foreign_pressing_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let (other, other_cap) = a_pressing(id(@0xB), 100, &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    shop::remove_pricing<USD>(&mut pressing, &other_cap);
    destroy(pressing);
    destroy(cap);
    destroy(other);
    destroy(other_cap);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun fixed_pricing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(9), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun fixed_pricing_rejects_overpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(11), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun repricing_up_rejects_the_signed_payment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(12));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun repricing_down_rejects_the_signed_payment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(8));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun floor_pricing_rejects_underpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::floor(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(9), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached)]
fun maximum_supply_boundary_rejects_the_next_purchase() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 2, shop::fixed(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    shop::purchase(&mut pressing, &release, payment<USD>(10), &clock).destroy();
    shop::purchase(&mut pressing, &release, payment<USD>(10), &clock).destroy();
    shop::purchase(&mut pressing, &release, payment<USD>(10), &clock).destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun free_pricing_presses_a_zero_price_record_and_forwards_nothing() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(0), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, balance::zero<USD>(), &clock);
    assert_eq!(record.purchase_currency(), type_name::with_defining_ids<USD>());
    assert_eq!(record.purchase_price(), 0);
    assert_eq!(forwarded<USD>(), vector[]);
    let events = event::events_by_type<pressing::RecordPurchasedEvent<Witness, USD>>();
    assert_record_purchase(&events[0], object::id(&record), object::id(&pressing), 1, 0);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = shop::EWrongPayment)]
fun free_pricing_rejects_payment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(0), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(1), &clock);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun pay_what_you_want_accepts_nothing_or_more() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::floor(0), &mut ctx);
    let clock = a_clock(&mut ctx);
    let free = shop::purchase(&mut pressing, &release, balance::zero<USD>(), &clock);
    let paid = shop::purchase(&mut pressing, &release, payment<USD>(7), &clock);
    assert_eq!(free.purchase_price(), 0);
    assert_eq!(paid.purchase_price(), 7);
    // Only the paid sale forwards: two tracks take 3 each.
    assert_eq!(forwarded<USD>(), vector[6]);
    free.destroy();
    paid.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = pressing::EMaxSupplyReached)]
fun currencies_share_the_same_supply_cap() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 1, shop::fixed(10), &mut ctx);
    shop::set_pricing<EUR>(&mut pressing, &cap, shop::fixed(20));
    let clock = a_clock(&mut ctx);
    shop::purchase(&mut pressing, &release, payment<USD>(10), &clock).destroy();
    shop::purchase(&mut pressing, &release, payment<EUR>(20), &clock).destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun sale_supports_the_u16_maximum_edition() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) =
        pressing::new_for_testing(object::id(&release), 65_535, 1, &mut ctx);
    pressing.authorize_distributor<Witness>(&cap);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    assert_eq!(record.edition(), 65_535);
    let events = event::events_by_type<pressing::RecordPurchasedEvent<Witness, USD>>();
    assert_record_purchase(&events[0], object::id(&record), object::id(&pressing), 1, 10);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun floor_pricing_accepts_the_exact_price() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::floor(10), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    assert_eq!(record.purchase_price(), 10);
    assert_eq!(forwarded<USD>(), vector[10]);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun pricing_can_be_removed_and_set_again() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(10), &mut ctx);
    shop::remove_pricing<USD>(&mut pressing, &cap);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(4));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(4), &clock);
    assert_eq!(record.purchase_price(), 4);
    assert_eq!(record.number(), 1);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun fixed_pricing_accepts_the_maximum_price() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let max = u64::max_value!();
    let (mut pressing, cap) = a_shop(&release, 100, shop::fixed(max), &mut ctx);
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(max), &clock);
    assert_eq!(record.purchase_price(), max);
    // Two tracks take half each; the remainder of 1 goes back to the Release.
    assert_eq!(forwarded<USD>(), vector[max - 1]);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test]
fun floor_repriced_down_keeps_the_overpayment() {
    let mut ctx = tx_context::dummy();
    let (release, release_cap) = a_release(&mut ctx);
    let (mut pressing, cap) = a_shop(&release, 100, shop::floor(10), &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::floor(6));
    let clock = a_clock(&mut ctx);
    let record = shop::purchase(&mut pressing, &release, payment<USD>(10), &clock);
    assert_eq!(record.purchase_price(), 10);
    assert_eq!(forwarded<USD>(), vector[10]);
    record.destroy();
    cleanup(pressing, cap, release, release_cap, clock);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun set_pricing_rejects_a_foreign_admin_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &foreign, shop::fixed(10));
    destroy(pressing);
    destroy(cap);
    destroy(foreign);
}

#[test, expected_failure(abort_code = pressing::EUnauthorized)]
fun remove_pricing_rejects_a_foreign_admin_cap() {
    let mut ctx = tx_context::dummy();
    let (mut pressing, cap) = a_pressing(id(@0xA), 100, &mut ctx);
    shop::set_pricing<USD>(&mut pressing, &cap, shop::fixed(10));
    let foreign = pressing::foreign_admin_cap_for_testing(id(@0xDEAD), &mut ctx);
    shop::remove_pricing<USD>(&mut pressing, &foreign);
    destroy(pressing);
    destroy(cap);
    destroy(foreign);
}

#[test]
fun is_fixed_distinguishes_fixed_from_floor() {
    assert!(shop::fixed(10).is_fixed());
    assert!(shop::fixed(0).is_fixed());
    assert!(!shop::floor(10).is_fixed());
    assert!(!shop::floor(0).is_fixed());
}
