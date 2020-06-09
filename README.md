MSD D-100 Floppy Controller
===========================

This repository contains work related to the MSD D-100 floppy controller. There is currently little information available online about this controller. Basic specs:

* S-100 bus interface
* Uses WD FD1771 single-density controller
* Polled I/O, no automatic wait generator
* May have onboard vectored interrupt capability
* Designed for use with Shugart SA-400 5.25" disk drives

### MSDEXER

This utility is a disk/controller exerciser for the D-100. It allows drive selection, stepping, track formatting, and sector read/write capability. It, along with the FD1771 manual, provide a good starting place for understanding the D-100 controller.

`MSDEXER` was developed using our version of the [a85 assember](https://github.com/glitchwrks/a85). It should assemble with little effort on most other 8080-compatible assemblers. `MSDEXER` has been tested on a 2 MHz 8080 system with 5.25" 40-track floppies.

`MSDEXER` is based on P. Linstruth's `TFEXER`, which is based on Mike Douglas's `AFEXER`. See source header for copyright/license information.

Default disk format is: 40 tracks, 18 sectors per track, 128-byte sectors. This is the "CP/M minidisk standard" and is also compatible with Cromemco CDOS 5.25" SSSD disks.
