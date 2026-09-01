// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Module-controlled authority used by the Miso Record Shop to mint Records.
module miso_record_shop::witness;

/// The exact witness type a Pressing authorizes for Record Shop purchases.
///
/// It cannot be copied or stored. Its constructor is package-restricted, so an
/// external package cannot mint by manufacturing Record Shop authority.
public struct Witness() has drop;

/// Construct Record Shop mint authority. Production code consumes it
/// immediately in `listing::purchase` and never exposes it to callers.
public(package) fun new(): Witness {
    Witness()
}
