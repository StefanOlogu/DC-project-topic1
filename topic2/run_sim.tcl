# add all SystemVerilog source files, separated by spaces
# (Note: mem_data.txt is excluded here because it is a data file, not code)
set sourcefiles {memory.sv cache_controller.sv cache_controller_tb.sv}

# set name of the top module
set topmodule cache_controller_tb

###################################################
#####DO NOT MODIFY THE SCRIPT BELLOW THIS LINE#####
###################################################

# quit current simulation if any
quit -sim

# empty the work library if present
if [file exists "work"] {vdel -all}
#create a new work library
vlib work

# run the compiler (adding -sv to ensure SystemVerilog mode is forced)
if [catch "eval vlog -sv $sourcefiles"] {
    puts "correct the compilation errors"
    return
}

# start the simulation
vsim -voptargs=+acc $topmodule

# automatically add all signals to the wave window
add wave -r /*

# run the simulation to completion
run -all

# automatically zoom the wave window to fit everything
wave zoom full