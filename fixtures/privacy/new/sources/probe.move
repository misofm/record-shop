module witness_new_probe::probe;

use miso_record_shop::witness::{Self, Witness};

/// This must not compile: `new` is visible only inside `miso_record_shop`.
public fun forge(): Witness {
    witness::new()
}
