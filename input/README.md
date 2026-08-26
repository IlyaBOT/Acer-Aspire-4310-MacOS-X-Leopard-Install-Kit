# User-provided inputs

Place legally obtained retail images here using one of these names:

```text
Leopard-Retail.dmg
Leopard-Retail.iso
SnowLeopard-Retail.dmg
SnowLeopard-Retail.iso
```

Optional custom kernels belong under `kernels/<profile>/`, user-provided ACPI tables under
`acpi/`, and a manually sourced Chameleon archive under `chameleon/`.

The project trace-release workflow can populate `kernels/leopard/kernel` from Apple's pinned
XNU source with `./prepare_aspire4310_macos.sh --build-xnu-trace`; the generated binary stays
ignored by Git.

Retail images, kernels, ACPI tables and third-party archives are ignored by Git. The main
script also accepts an existing image or mounted retail DVD path via `--retail`.

Do not use unofficial or pirated Mac OS X distributions.
