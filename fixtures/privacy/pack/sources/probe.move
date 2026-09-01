module witness_pack_probe::probe;

use miso_record_shop::witness::Witness;

/// This must not compile: only `miso_record_shop::witness` may pack Witness.
public fun forge(): Witness {
    Witness()
}
