// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

/// Module-controlled authority used by the Miso Record Shop to press Records.
module record_shop::witness;

// === Structs ===

/// The exact witness type a Pressing authorizes for Record Shop purchases.
///
/// It cannot be copied or stored. Its constructor is package-restricted, so an
/// external package cannot press by manufacturing Record Shop authority.
public struct Witness() has drop;

// === Private Functions ===

/// Construct Record Shop press authority. Production code consumes it
/// immediately in `shop::purchase` and never exposes it to callers.
public(package) fun new(): Witness {
    Witness()
}
