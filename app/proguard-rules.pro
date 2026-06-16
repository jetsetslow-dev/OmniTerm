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
