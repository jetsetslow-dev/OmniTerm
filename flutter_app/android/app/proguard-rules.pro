# R8 rules for the release build.
#
# Every rule here is a `-dontwarn` for a class that is *deliberately* absent, not a suppression of
# something that should be fixed. R8 reports a reference it cannot resolve as an error and stops;
# these say "that reference is unreachable at runtime, and here is why".

# ── smbj's optional Bouncy Castle security provider ───────────────────────────
#
# smbj ships two crypto backends: one over the JCE, one over Bouncy Castle. `build.gradle.kts`
# excludes smbj's Bouncy Castle artifact on purpose, so that two crypto providers cannot end up on
# the classpath shadowing each other — which means the BC-backed classes are compiled but can never
# be loaded. `SecurityProvider` selects the JCE implementation at runtime.
-dontwarn org.bouncycastle.**

# ── mbassy's optional Expression Language filters ─────────────────────────────
#
# smbj's event bus (mbassy) supports message filters written in Jakarta EL. `javax.el` is not part
# of Android and is not a dependency here; the app subscribes to events directly and never uses an
# EL filter, so the code path that would load these classes is unreachable.
-dontwarn javax.el.**

# ── smbj's Kerberos/SPNEGO authenticator ──────────────────────────────────────
#
# `org.ietf.jgss` is the Java GSS-API, which Android does not ship. `SmbBridge` authenticates with
# `AuthenticationContext(username, password, domain)` or `.guest()` — NTLM either way — so
# `SpnegoAuthenticator` is never selected and its GSS references are never loaded.
-dontwarn org.ietf.jgss.**

# ── smbj itself ───────────────────────────────────────────────────────────────
#
# Reflection-driven: message types are resolved by class name when decoding the wire protocol, so
# renaming them breaks decoding in ways that only appear against a real server.
-keep class com.hierynomus.** { *; }
-keep class net.engio.mbassy.** { *; }
