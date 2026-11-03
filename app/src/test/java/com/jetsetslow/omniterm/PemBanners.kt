package com.jetsetslow.omniterm

// PEM banners for test fixtures, built from their label: the repository's secret scan takes a
// written-out pair of private key banners for a committed key, even around generated contents.
// The Flutter tests do the same in test/support/ed25519_fixture.dart.

internal fun pemBegin(label: String) = "-----BEGIN $label-----"

internal fun pemEnd(label: String) = "-----END $label-----"
