# =============================================================================
# package_ip.tcl
#
# Packages the Verilog design of the "imageProcessing" project as the
# imageProcess IP (user.org:user:imageProcess:1.0) in hw/ip_repo/, with the
# AXI4-Stream interfaces s_axis / m_axis, the clock, the reset and o_intr.
#
# Usage (Vivado Tcl Console, with the imageProcessing project OPEN):
#   source <repo>/tools/package_ip.tcl
# =============================================================================

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
set proj_dir [get_property DIRECTORY [current_project]]
set ip_dir   [file normalize [file join $proj_dir .. .. ip_repo]]
puts "INFO: IP will be packaged in $ip_dir"

if {[get_property NAME [current_project]] ne "imageProcessing"} {
    error "Open the project 'imageProcessing' before running this script."
}

# Files left over from the wrong package (imageProcessTop)
file delete -force [file join $ip_dir xgui imageProcessTop_v1_0.tcl]

# ---------------------------------------------------------------------------
# Package the current project
# ---------------------------------------------------------------------------
ipx::package_project -root_dir $ip_dir -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true -force
set core [ipx::current_core]

# Identification (must match what the block design expects)
set_property name          imageProcess      $core
set_property display_name  imageProcess_v1_0 $core
set_property description   "Sobel Filter. IP for neighborhood image processing." $core
set_property version       1.0               $core
set_property core_revision 10                $core

# ---------------------------------------------------------------------------
# Helper: get a bus parameter, creating it if it does not exist
# ---------------------------------------------------------------------------
proc set_bus_param {bus name value} {
    set p [ipx::get_bus_parameters $name -of_objects $bus]
    if {$p eq ""} { set p [ipx::add_bus_parameter $name $bus] }
    set_property value $value $p
}

# ---------------------------------------------------------------------------
# AXI4-Stream interfaces
#   s_axis (slave) : TDATA=i_data  TVALID=i_data_valid  TREADY=o_data_ready
#   m_axis (master): TDATA=o_data  TVALID=o_data_valid  TREADY=i_data_ready
# ---------------------------------------------------------------------------
proc add_axis {core name mode tdata tvalid tready} {
    set old [ipx::get_bus_interfaces $name -of_objects $core]
    if {$old ne ""} { ipx::remove_bus_interface $name $core }

    set bi [ipx::add_bus_interface $name $core]
    set_property abstraction_type_vlnv xilinx.com:interface:axis_rtl:1.0 $bi
    set_property bus_type_vlnv         xilinx.com:interface:axis:1.0     $bi
    set_property interface_mode        $mode                             $bi

    set_property physical_name $tdata  [ipx::add_port_map TDATA  $bi]
    set_property physical_name $tvalid [ipx::add_port_map TVALID $bi]
    set_property physical_name $tready [ipx::add_port_map TREADY $bi]
    puts "INFO: interface $name ($mode) created"
}

add_axis $core s_axis slave  i_data i_data_valid o_data_ready
add_axis $core m_axis master o_data o_data_valid i_data_ready

# ---------------------------------------------------------------------------
# Reset (active low)
# ---------------------------------------------------------------------------
set rst [ipx::get_bus_interfaces axi_reset_n -of_objects $core]
if {$rst eq ""} {
    set rst [ipx::add_bus_interface axi_reset_n $core]
    set_property abstraction_type_vlnv xilinx.com:signal:reset_rtl:1.0 $rst
    set_property bus_type_vlnv         xilinx.com:signal:reset:1.0     $rst
    set_property interface_mode        slave                           $rst
    set_property physical_name axi_reset_n [ipx::add_port_map RST $rst]
}
set_bus_param $rst POLARITY ACTIVE_LOW

# ---------------------------------------------------------------------------
# Clock: associate it with both streams and the reset
# ---------------------------------------------------------------------------
set clk [ipx::get_bus_interfaces axi_clk -of_objects $core]
if {$clk eq ""} {
    set clk [ipx::add_bus_interface axi_clk $core]
    set_property abstraction_type_vlnv xilinx.com:signal:clock_rtl:1.0 $clk
    set_property bus_type_vlnv         xilinx.com:signal:clock:1.0     $clk
    set_property interface_mode        slave                           $clk
    set_property physical_name axi_clk [ipx::add_port_map CLK $clk]
}
set_bus_param $clk ASSOCIATED_BUSIF m_axis:s_axis
set_bus_param $clk ASSOCIATED_RESET axi_reset_n

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
ipx::create_xgui_files $core
ipx::update_checksums  $core
ipx::check_integrity   $core
ipx::save_core         $core
update_ip_catalog -rebuild -repo_path $ip_dir

puts ""
puts "================================================================"
puts " IP packaged: user.org:user:imageProcess:1.0 (revision 10)"
puts " Interfaces : [join [lsort [get_property NAME [ipx::get_bus_interfaces -of_objects $core]]] {, }]"
puts "================================================================"
