# fix_pio_thermal_direction.tcl
# add_pio_thermal.tcl set pio_thermal's "direction" parameter to
# "Bidirectional", but altera_avalon_pio 25.1 only accepts: Bidir, Input,
# InOut, Output (qsys-generate caught this: "out of range"). Fixes the value
# in place, no other changes.
#
# Run from hdl/qsys:
#   qsys-script --script=fix_pio_thermal_direction.tcl --search-path="<this dir>,$"

package require -exact qsys 25.1

load_system {soc_system.qsys}

set_instance_parameter_value pio_thermal {direction} {Bidir}

save_system {soc_system.qsys}
