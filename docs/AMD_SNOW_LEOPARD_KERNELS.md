# AMD Snow Leopard kernels used by the D640 target

This target uses historical third-party XNU kernels. The project does not ship
or redistribute them in Git; the helper downloads the original release archive
at build time.

## 10.6.3

Expected kernel metadata:

- OS X 10.6.3
- Darwin 10.3.0
- XNU 1504.3.12
- i386 slice required
- historical qoopz/nawcom `legacy_kernel-10.3.0.pkg.zip`

The original release notes state that this build is i386-only and recommend
`arch=i386` for systems that immediately reboot. The package also contained AMD
CPUID userland patching support used by contemporary AMD Snow Leopard installs.

## 10.6.8

Expected kernel metadata:

- OS X 10.6.8
- Darwin 10.8.0
- XNU 1504.15.3
- historical nawcom `legacy_kernel-10.6.8.v2.pkg.zip`

For the 10.6.3 -> 10.6.8 path, install the Combo Update first and install the
matching 10.8.0 legacy kernel **before the first reboot**.

## Download verification

The historical release hosts are no longer reliable. The downloader therefore:

1. tries known original nawcom URLs;
2. if unavailable, queries the Internet Archive CDX API for a captured copy of
   the same URL;
3. requires a valid ZIP archive;
4. expands the legacy package on Linux with `xar` or `bsdtar`/`cpio`;
5. requires an i386 Mach-O kernel;
6. requires the expected Darwin or XNU version string;
7. records local SHA-256 values and the source URL used.

There are no project-maintained trusted reference hashes for these old binaries,
so the generated SHA-256 values are provenance records, not cryptographic proof
that a mirror is identical to the original historical release.
