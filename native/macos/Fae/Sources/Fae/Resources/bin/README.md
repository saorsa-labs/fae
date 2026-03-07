# Resources/bin

This directory is reserved for future bundled binaries if needed.

## Current Approach: Auto-Install

We chose **automatic installation** over bundling binaries:

- **Fae takes care of her users** - when uv (or other tools) are needed, Fae asks permission once and installs automatically
- **Always up-to-date** - users get the latest, most secure versions
- **Smaller app** - no 15MB+ binaries bundled
- **Fae can update independently** - no app release needed to update dependencies

See `DependencyInstaller.swift` for the implementation.

## If Bundling Becomes Necessary

If offline-first or air-gapped deployment becomes a requirement, binaries can be placed here and `UVRuntime` will detect them automatically (it checks this directory first).

```
Resources/bin/
└── uv          # Universal binary (arm64 + x86_64)
```

But for now, **auto-install is the way**.
