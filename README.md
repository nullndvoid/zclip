# zclip

A tool to manage and sync your clipboard between devices.

# TODOs

- Access clipboard on ~~Wayland~~ and Windows.
  - Works on Wayland.
- Establish an encrypted connection between them. (Pairing)
  - Maybe use ed25519 or something like that.
- CLI interface for listing clipboard items
- Support images and files?
- Nice GUI <-- Possibly as a separate app anyway? Qt perhaps or something Zig-native.
- System tray icon

Maybe something like this already exists but this would be a nice tool to have :)

In fact, you could probably use KDE Connect but I have had my issues with it, and it has many
features I am less worried about.

# Notes

When developing you should check changes compile on various platforms with `zig build check -Dtarget=x86_64-os-abi`.

ZLS should do this for us since there is a `check` step defined.

# Authors

- J. Hinchliffe
