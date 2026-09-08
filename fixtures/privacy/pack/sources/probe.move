module witness_pack_probe::probe;

use record_shop::witness::Witness;

/// This must not compile: only `record_shop::witness` may pack Witness.
public fun forge(): Witness {
    Witness()
}
