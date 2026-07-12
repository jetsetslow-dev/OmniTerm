# OmniTerm R8 rules. Most dependencies (Compose, Room, WorkManager, Retrofit, Moshi, OkHttp,
# Billing, Play Services Ads) ship their own consumer rules; only the libraries below need help.

# Keep release stack traces readable; the per-build mapping.txt de-obfuscates the rest.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# JSch instantiates ciphers/KEX/signature backends reflectively from session-config class-name
# strings (com.jcraft.jsch.jce.*, com.jcraft.jsch.bc.*, jgss, jzlib). Nearly the whole library is
# reachable only via Class.forName, so shrinking it breaks connections at runtime only.
-keep class com.jcraft.jsch.** { *; }
-dontwarn com.jcraft.jsch.**

# Bouncy Castle's EdDSA classes are reached via JSch's bc backend and the JCA provider mechanism.
# Shrinking it silently breaks ed25519 public-key auth (the modern ssh-keygen default).
-keep class org.bouncycastle.** { *; }
-dontwarn org.bouncycastle.**

# smbj resolves SMB message/cipher factories and its mbassador event-bus handlers reflectively,
# and logs through slf4j (no binding at runtime is fine, but R8 must not warn the build red).
-keep class com.hierynomus.** { *; }
-dontwarn com.hierynomus.**
-keep class net.engio.mbassy.** { *; }
-dontwarn net.engio.mbassy.**
-dontwarn org.slf4j.**

# smbj-rpc (SRVSVC share enumeration for the LAN scanner) marshals DCE-RPC stubs; keep it whole
# like its smbj host library so R8 can't strip request/response classes reached via generics.
-keep class com.rapid7.client.dcerpc.** { *; }
-dontwarn com.rapid7.client.dcerpc.**

# OkHttp probes optional desktop/JVM TLS providers that are not shipped on Android.
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
