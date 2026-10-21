module witness_pack_probe::probe;

use record_shop::witness::Witness;

public fun forge(): Witness {
    Witness()
}
