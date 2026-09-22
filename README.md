\# make-win11-usb



A bash script for creating a bootable (UEFI/GPT + FAT32) Windows 11 USB stick from an ISO file. Works on both `apt`-based distros (Debian, Ubuntu) and `dnf`-based ones (Fedora, RHEL-like).



\## Why `dd` alone doesn't work



Official Windows ISOs are not hybrid images, so `dd` or other raw-copy tools (Fedora Media Writer, Rufus in DD mode) won't produce a bootable stick. On top of that, `sources/install.wim` inside the ISO is often larger than 4 GiB, and FAT32 — required for UEFI boot — can't hold files bigger than that.



This script handles it by:

\- formatting the USB stick as GPT + FAT32, with the partition marked ESP (`set 1 esp on`);

\- copying the ISO contents with `rsync`;

\- splitting `install.wim` into pieces under 4 GiB (`install.swm`, `install2.swm`, ...);

\- if the ISO ships `install.esd` instead of `install.wim` (happens with some Microsoft downloads), all editions inside are automatically converted to WIM before splitting.



\## Requirements



\- Linux with `bash`, root access (`sudo`).

\- A valid Windows 11 ISO, downloaded from \[microsoft.com/software-download/windows11](https://www.microsoft.com/software-download/windows11).

\- A USB stick (its contents will be \*\*completely erased\*\*).



Package dependencies (`wimlib-imagex`/`wimtools`, `rsync`, `parted`, `dosfstools`, `util-linux`) are checked and installed automatically if missing.



\## Usage



```bash

chmod +x make-win11-usb.sh

sudo ./make-win11-usb.sh <path-to-iso> </dev/sdX>

```



Example:



```bash

sudo ./make-win11-usb.sh ./Win11\_24H2\_English\_x64.iso /dev/sdc

```



> The second argument must be the whole disk (`/dev/sdc`), not a partition (`/dev/sdc1`). The script explicitly refuses partitions.



\## Identifying the right USB stick



Before running the script, check which device is your USB stick:



```bash

lsblk -o NAME,SIZE,TRAN,RM,MODEL,SERIAL,MOUNTPOINTS

```



Look for the device with `TRAN=usb` and `RM=1`, matching your stick's size and model. The script performs the same check automatically and asks for an explicit written confirmation (`YES`) if the device doesn't look like a removable USB drive — but it's worth double-checking manually too, especially if you have multiple disks connected.



\## What the script does, step by step



1\. Validates arguments, requires `sudo`, checks the ISO exists and the device is a valid whole disk.

2\. Detects the package manager (`apt` or `dnf`) and installs missing dependencies.

3\. Prints info about the target disk (`lsblk`) and requires explicit confirmation before erasing anything.

4\. Mounts the ISO and checks:

&#x20;  - the presence of `EFI/BOOT/BOOTX64.EFI` (a valid UEFI ISO);

&#x20;  - the presence and integrity of `install.wim` or `install.esd`.

5\. Unmounts any existing partitions on the stick, wipes the partition table, creates a GPT with a single FAT32 partition marked ESP.

6\. Copies all ISO contents to the stick, except `install.wim`/`install.esd`.

7\. Splits `install.wim` into `.swm` files under 4 GiB. If the source was `install.esd`, it first converts all editions to WIM (using `/var/tmp` for the intermediate file, not `/tmp`, to avoid tmpfs/RAM).

8\. Verifies the result: presence of `EFI/BOOT/BOOTX64.EFI` on the stick, integrity of the `.swm` files (`wimlib-imagex info` + `wimlib-imagex verify`).

9\. Syncs (`sync`) and prints a summary.



\## After the script finishes



Only remove the USB stick after you see the final success message. At boot time, enter your motherboard's boot menu (usually `F12`, `F11`, or `Esc`) and pick the \*\*UEFI\*\* entry for the stick — not the "Legacy"/"CSM" one, if it shows up.



\## Known limitations



\- The script does not bypass Windows 11's TPM/Secure Boot checks during installation; that's a separate step (registry edit during setup, or a bypass script).

\- It does not create a multi-boot stick (multiple ISOs on the same drive); for that, use \[Ventoy](https://www.ventoy.net/) instead.

\- Tested for `/dev/sdX`, `/dev/nvmeXnY`, and `/dev/mmcblkX`; other device naming schemes may need adjustments.



\## License



Use and modify freely, no warranty provided.

