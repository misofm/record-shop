// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// Module-controlled authority used by the Miso Record Shop to press Records.
module record_shop::witness;

// === Structs ===

/// The exact witness type a Pressing authorizes for Record Shop purchases.
public struct Witness() has drop;

// === Private Functions ===

/// Consumed immediately in `shop::purchase`; never exposed to callers.
public(package) fun new(): Witness {
    Witness()
}
