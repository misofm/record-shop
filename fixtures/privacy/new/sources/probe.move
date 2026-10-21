module witness_new_probe::probe;

use record_shop::witness::{Self, Witness};

public fun forge(): Witness {
    witness::new()
}
