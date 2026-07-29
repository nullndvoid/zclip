# zclip

A tool to manage and sync your clipboard between devices.

# TODOs

- CLI interface for listing clipboard items
- Nice GUI <-- Possibly as a separate app anyway? Qt perhaps or something Zig-native.
- System tray icon
- For files/large pastes, transmit the file lazily, with type file_preview or something similar.
  Then the data can be a thumbnail if present.
- TUI-style pickers/wizards if you do not specify any positional arguments.

Maybe something like this already exists but this would be a nice tool to have :)

In fact, you could probably use KDE Connect but I have had my issues with it, and it has many
features I am less worried about.

# Notes

When developing you should check changes compile on various platforms with `zig build check -Dtarget=x86_64-os-abi`. _This is less of a concern now that most platform specific stuff lives in [clipboard-zig](https://codeberg.org/nullndvoid/clipboard-zig)_.

ZLS should do this for us since there is a `check` step defined.

# Authors

- J. Hinchliffe (nullndvoid)
