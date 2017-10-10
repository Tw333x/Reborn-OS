# Reborn-OS

## Dependencies
- isolinux/syslinux
- arch-install-scripts
- cpio
- dosfstools
- libisoburn
- mkinitcpio-nfs-utils
- make
- opendesktop-fonts
- patch
- squashfs-tools
- lynx
- wget

## Free space

Please check that you have 5GB (or more) of free harddisk space in your root partition:
`df -h /`

## Instructions

1. Install dependencies:
```
sudo pacman -S arch-install-scripts cpio dosfstools libisoburn mkinitcpio-nfs-utils make patch squashfs-tools wget lynx
```
2. Clone this repository using `--recursive` like this:
```
git clone https://github.com/keeganmilsten/Reborn-OS.git --recursive
```
4. Install mkarchiso and createa an `out` folder by running:
```
cd Reborn-OS
sudo make install
sudo mkdir out
```
5. Build it by running this command:
```
sudo ./build.sh -v
```
To rebuild it, simply remove the `build` and `Cnchi <VERSION>` folders in addition to emptying the `out` folder. Next, re-enter the command from step 5.

## Create the Reborn-OS Repo (note for Reborn OS team)

- Run `sudo repo-add /var/lib/pacman/sync/Reborn-OS.db.tar.gz /home/$USER/Dropbox/Linux/antergos-deepin-repo/*.pkg.tar.xz`
