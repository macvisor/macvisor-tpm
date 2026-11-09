# Third-party notices

`Artifacts/CTPM.xcframework` (the static library `libCTPM.a` and the libtpms headers) contains code from:

- **libtpms** 0.10.2, https://github.com/stefanberger/libtpms: the library and TPM 1.2 code under the
  BSD-3-Clause licence (Copyright IBM Corporation), the TPM 2.0 reference implementation under the BSD-2-Clause
  licence (Copyright Microsoft Corporation and others) and the Trusted Computing Group's licence and notices.
  Full text: `Artifacts/licenses/libtpms-LICENSE.txt`. (MacVisor builds TPM 2.0 only.)
- **OpenSSL** 3.5.9 (libcrypto), https://www.openssl.org, under the Apache License 2.0.
  Full text: `Artifacts/licenses/openssl-LICENSE.txt`.

Software that ships `libCTPM.a` (linked into its binary) must reproduce these notices and licences with its
distribution, as their licences require.
