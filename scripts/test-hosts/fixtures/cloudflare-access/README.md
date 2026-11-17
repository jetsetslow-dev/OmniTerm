# Cloudflare Access TCP contract fake

Run `scripts/test-hosts.sh cloudflare-access` while holding the relay machine lock. It builds
`tunnel/cmd/accesslab` with the repository Go toolchain, starts only `cloudflare-access`, and
uses the existing `direct:2222` SSH fixture without changing it. TLS CA, server key and
random service-token values stay in ignored `.cloudflare-access/` and `.env`.

The server checks both service-token headers, accepts a binary WebSocket at `/` for
`ssh.access.test`, and bridges its byte stream to direct. `reject.access.test` returns 403,
`login.access.test` returns the Access login redirect, and `ordinary.access.test` returns 200.
The host endpoint is 127.0.0.1:8447. These names are not public DNS entries.

The opt-in API 35 suite uses a separately compiled AAR with `omniterm_access_fixture` added to
its existing build tags. Only that build exposes `CloudflareFixture`, which injects this CA
and maps only these four fixture names to the endpoint; chain and hostname verification remain
on. Normal builds exclude the seam entirely. Build and use it with:

    OMNITUNNEL_TARGETS=android/amd64 scripts/build-tunnel.sh --access-fixture
    ./gradlew -Pomniterm.tunnelAar="$PWD/tunnel/build/fixture/omnitunnel-access-fixture.aar" \
      :app:assembleOpenSourceDebug :app:assembleOpenSourceDebugAndroidTest

The fixture library goes to its own file and never to `tunnel/build/omnitunnel.aar`, which
every other build uses; Gradle refuses the property for a release task.
`scripts/check-tunnel-seam.py` checks every library `build-tunnel.sh` writes, and the gate
(`scripts/local-pr-check.sh`) checks the library and the apps it built: a fixture app left in
`app/build/outputs` fails it, so build the app again without the property afterwards.

Install those two APKs, then run

    ./scripts/test-hosts.sh suite E2eCloudflareAccessTunnelTest omniterm_e2e_access=yes \
      access_config access_ca user pass

It reverses tcp:8447 with the other fixture ports, copies `phone.json` and `ca.crt` into the
app's private files on adb's standard input (the suite reads and removes them), and keeps every
secret off the command line. The suite checks the editor, saved credentials, SSH, that nothing
but SSH is sent through the tunnel, an SSH connection left idle past the fake's idle limit,
rejection messages and Wi-Fi.

The fake closes a WebSocket that carries no data, ping or pong for 100 seconds
(`tunnel/internal/accessfake`), as Cloudflare closes idle WebSockets. Cloudflare does not publish
the time; 100 seconds is our assumption. The app pings every 54 seconds, the period cloudflared's
origin side pings at (`websocket/connection.go`); cloudflared's client side sends no pings.

This proves our client against our interpretation of cloudflared's protocol. It does not prove
interoperability with the Cloudflare service. Never use this fixture build as a published APK.
