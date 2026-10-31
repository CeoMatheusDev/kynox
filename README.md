# Kynox

Kynox is an experimental x86-64 operating system written in Zig. It boots through
a UEFI native boot loader, runs a freestanding nucleus kernel, exposes a small
user-mode ABI, and includes a VirtIO block storage stack with persistence across
reboots.

## Build

Requires Zig 0.17.0.

```sh
zig build
```

This produces:

- `zig-out/bin/kynox-boot.efi` — UEFI boot loader
- `zig-out/bin/kynox-kernel` — freestanding kernel ELF
- `zig-out/bin/kynox.img` — bootable EFI system partition image

## Tests

Host unit tests:

```sh
zig build test
```

Automated QEMU boot, storage persistence, and interactive checks:

```sh
zig build check
```

Individual steps:

```sh
zig build qemu-test
zig build qemu-storage-test
zig build qemu-interactive-test
```

## License

GPL-3.0-only
```