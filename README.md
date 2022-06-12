# ahciwrap.sys
A DOS CD-ROM driver to augment (and fix) functionality of Intel's `ahci.sys`, available from http://ftp.hp.com/pub/softpaq/sp39501-40000/sp39596.exe*.

The `ahci.sys` driver is great, because it allows the use from DOS of CD-ROM drives attached to modern SATA controllers in AHCI mode.
Many motherboards from the latter half of the 2010s can boot DOS (non-UEFI boot), but don't allow the SATA controller to be set to IDE mode, so this is the only option to get CD support with such a setup.

However, there are a few bugs with this driver, and several functions (audio playback, raw reading, and use of controllers at PCI addresses other than 00:1f.2) are not supported.
This is what this project sets out to solve!

\* Note that if that link ever disappears, it is still available on the Wayback Machine: http://web.archive.org/web/20171016094536/http://whp-hou4.cold.extweb.hp.com/pub/softpaq/sp39501-40000/sp39596.exe

## Building

Assemble it as a binary file using JWASM or similar, e.g. as done in the `DOSBUILD.BAT`.

## Usage

Load it as a device from `CONFIG.SYS`, specifying the number of the SATA controller in your system you want to use, and then the file path of the original `AHCI.SYS`, followed by any options you want to pass to it.

For example, to use the second AHCI-mode SATA controller in your system:
```
DEVICE=C:\AHCIWRAP\AHCIWRAP.SYS /s1 C:\SP39596\FILES\AHCI.SYS /d:AHCICD
```
The `/sN` option selects the `N+1`th AHCI-mode SATA controller found on the PCI bus.
For RAID-mode SATA controllers, use `/rN` instead.

If neither switch is specified, it tries the first AHCI-mode SATA controller, then the first RAID-mode one.
I.e. specifying neither switch is equivalent to specifying `/s0 /r0`.
