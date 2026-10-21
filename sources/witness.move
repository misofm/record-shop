// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: FSL-1.1-ALv2

module record_shop::witness;

// === Structs ===

public struct Witness() has drop;

// === Private Functions ===

public(package) fun new(): Witness {
    Witness()
}
