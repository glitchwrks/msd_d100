MSD D-100 Floppy Controller
===========================

This repository contains work related to the MSD D-100 floppy controller. There is currently little information available online about this controller. Basic specs:

* S-100 bus interface
* Uses WD FD1771 single-density controller
* Polled I/O, no automatic wait generator
* May have onboard vectored interrupt capability
* Designed for use with Shugart SA-400 5.25" disk drives

The D-100 by default derives its base clock from the system clock line on S-100 pin 49. By the IEEE-696 spec, this line should be at 2 MHz regardless of CPU speed, but this may not be the case with some CPU boards. There's space on the board for a crystal oscillator, but that portion has not been reverse-engineered yet as it was not populated.

### MSDEXER

This utility is a disk/controller exerciser for the D-100. It allows drive selection, stepping, track formatting, and sector read/write capability. It, along with the FD1771 manual, provide a good starting place for understanding the D-100 controller.

`MSDEXER` was developed using our version of the [a85 assember](https://github.com/glitchwrks/a85). It should assemble with little effort on most other 8080-compatible assemblers. `MSDEXER` has been tested on a 2 MHz 8080 system with 5.25" 40-track floppies. It can be loaded "bare metal" into a system, or run from CP/M. In both cases, it assumes the system console is Channel 0 of a MITS 88-2SIO. Future versions will use CP/M console I/O when loaded under CP/M.

`MSDEXER` is based on P. Linstruth's `TFEXER`, which is based on Mike Douglas's `AFEXER`. See source header for copyright/license information.

Default disk format is: 40 tracks, 18 sectors per track, 128-byte sectors. This is the "CP/M minidisk standard" and is also compatible with Cromemco CDOS 5.25" SSSD disks.

### Schematics

The `schematics` subdirectory contains a KiCAD project in which a partial schematic of the D-100 has been captured. **THIS IS A WORK IN PROGRESS** and should not be used as an absolute reference! In particular, the interrupt circuitry is not fully documented or understood. The schematic should be reasonable enough to get started in the right direction on a nonworking D-100 board.

Register mapping and the board-specific control/status ports were figured out using this schematic, and `MSDEXER` written once a complete enough understanding was obtained.

### notes.txt

This is a textfile containing notes typed up during the reverse engineering process. They are free-form and not particularly organized, but presented here since they may help answer questions not made obvious in the schematic or `MSDEXER` source.
