package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.data.HostChecks
import com.jetsetslow.omniterm.data.ImageUpdates
import com.jetsetslow.omniterm.data.ImageUpdates.Ref
import com.jetsetslow.omniterm.data.ImageUpdates.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

/** Image updates: reading references as Docker does, judging digests, and the registry requests in a real shell. */
class ImageUpdatesTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun referencesAreReadAsDockerReadsThem() {
        assertEquals(Ref("docker.io", "library/nginx", "latest"), ImageUpdates.parse("nginx"))
        assertEquals(Ref("docker.io", "library/nginx", "1.27"), ImageUpdates.parse("nginx:1.27"))
        assertEquals(Ref("docker.io", "linuxserver/sonarr", "latest"), ImageUpdates.parse("linuxserver/sonarr"))
        assertEquals("Podman's full names are the same image", ImageUpdates.parse("nginx:1.27"), ImageUpdates.parse("docker.io/library/nginx:1.27"))
        assertEquals(ImageUpdates.parse("nginx"), ImageUpdates.parse("index.docker.io/library/nginx"))
        assertEquals(Ref("ghcr.io", "owner/app", "v1.2"), ImageUpdates.parse("ghcr.io/owner/app:v1.2"))
        assertEquals("a port makes it a registry", Ref("nas:5000", "media/app", "latest"), ImageUpdates.parse("nas:5000/media/app"))
        assertEquals(Ref("localhost:5000", "app", "dev"), ImageUpdates.parse("localhost:5000/app:dev"))
        assertNull(ImageUpdates.parse("sha256:4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f1234"))
        assertNull("a short image ID", ImageUpdates.parse("4b7d2c1a9e0f"))
        assertNull(ImageUpdates.parse("nginx@sha256:4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f4b7d2c1a9e0f1234"))
        assertNull("upper case is not a repository", ImageUpdates.parse("Team/App"))
        assertNull("nor is shell syntax", ImageUpdates.parse("app;reboot"))
        assertEquals("pinned to a digest", ImageUpdates.skipReason("nginx@sha256:abc"))
        assertEquals("built on this host", ImageUpdates.skipReason("localhost/mine:latest"))
        assertNull(ImageUpdates.skipReason("nginx"))
        val hub = ImageUpdates.parse("nginx:1.27")!!
        assertEquals("https://registry-1.docker.io/v2/library/nginx/manifests/1.27", hub.manifestUrl)
        assertEquals("nginx:1.27", hub.display)
        assertEquals("ghcr.io/owner/app:v1.2", ImageUpdates.parse("ghcr.io/owner/app:v1.2")!!.display)
    }

    private val listingRaw = listOf(
        "!RUNTIME docker",
        "docker\tnginx:1.27\t[\"nginx@sha256:aaa\"]",
        "docker\tregistry:5000/team/app:latest\t[\"registry:5000/team/app@sha256:old\"]",
        "docker\tmine:dev\t[]",
        "docker\t4b7d2c1a9e0f\t[\"nginx@sha256:zzz\"]",
        "docker\tgone:1\t!MISSING",
        "!RUNTIME podman",
        "podman\tdocker.io/library/nginx:1.27\t[\"docker.io/library/nginx@sha256:aaa\",\"docker.io/library/nginx@sha256:arm\"]",
    ).joinToString("\n")

    @Test
    fun aListingNamesEachImageWithItsDigestsAndAskesEachRegistryOnce() {
        val listing = ImageUpdates.parseListing(listingRaw)
        assertEquals(setOf("docker", "podman"), listing.runtimes)
        assertTrue(listing.curl)
        assertEquals(6, listing.images.size)
        assertEquals(setOf("sha256:aaa", "sha256:arm"), listing.images.last().digests)
        assertTrue(listing.images.single { it.reference == "gone:1" }.missing)
        assertFalse(ImageUpdates.parseListing("!RUNTIME docker\ndocker\tnginx\t[\"nginx@sha256:a\"]\n!NOCURL\n").curl)
        // nginx:1.27 is asked once for both runtimes; images built here, IDs and gone ones not at all.
        assertEquals(listOf("docker.io/library/nginx:1.27", "registry:5000/team/app:latest"), ImageUpdates.refsToCheck(listing).map { it.key })
    }

    @Test
    fun anImageHasAnUpdateWhenTheRegistryDigestIsNoneTheHostPulled() {
        val listing = ImageUpdates.parseListing(listingRaw)
        val remote = mapOf(
            "docker.io/library/nginx:1.27" to ImageUpdates.Remote.Digest("sha256:aaa"),
            "registry:5000/team/app:latest" to ImageUpdates.Remote.Digest("sha256:new"),
        )
        val report = ImageUpdates.report(listing, remote, now = 1L)
        fun state(runtime: String, ref: String) = report.images.single { it.runtime == runtime && it.reference == ref }
        assertEquals(State.CURRENT, state("docker", "nginx:1.27").state)
        assertEquals("a multi-arch pull keeps the list's digest", State.CURRENT, state("podman", "docker.io/library/nginx:1.27").state)
        assertEquals(State.UPDATE, state("docker", "registry:5000/team/app:latest").state)
        assertEquals("built on this host", state("docker", "mine:dev").reason)
        assertEquals("the container names no image tag", state("docker", "4b7d2c1a9e0f").reason)
        assertEquals(1f, ImageUpdates.count(report))
        assertEquals(listOf("registry:5000/team/app:latest"), ImageUpdates.names(report))
        assertTrue(report.anyCompared)

        val failed = ImageUpdates.report(listing, mapOf("docker.io/library/nginx:1.27" to ImageUpdates.Remote.Failed("the registry needs a sign-in")), 1L)
        assertEquals("the registry needs a sign-in", failed.images.first().reason)
        // The Images tab finds each row's verdict whatever spelling the runtime shows.
        val nginxRow = report.images.first { it.runtime == "podman" }
        assertTrue(ImageUpdates.matches(nginxRow, "podman", "docker.io/library/nginx", "1.27"))
        assertFalse(ImageUpdates.matches(nginxRow, "docker", "nginx", "1.27"))
        assertEquals("Updates for registry:5000/team/app:latest", HostChecks.alertText(HostChecks.IMAGE_UPDATES, 1f, 0f, ImageUpdates.names(report)))
        assertEquals("2 images with updates", HostChecks.describe(HostChecks.IMAGE_UPDATES, 2f))
    }

    /**
     * The requests, in a real shell against a stand-in curl: a registry that answers at once, one
     * that wants an anonymous Bearer token first, and each kind of failure. The token reaches curl
     * on its input only, never its command line.
     */
    @Test
    fun theRegistryRequestsFollowTheTokenChallengeAndNameEachFailure() {
        val sh = TestShell.sh
        assumeTrue("needs a POSIX shell", sh != null)
        val bin = tmp.newFolder("bin")
        for (tool in listOf("awk", "sed", "tr", "tail", "head", "cat", "timeout")) {
            val real = System.getenv("PATH").orEmpty().split(File.pathSeparator).map { File(it, tool) }.firstOrNull { it.canExecute() }
                ?: continue
            java.nio.file.Files.createSymbolicLink(File(bin, tool).toPath(), real.toPath())
        }
        listOf("awk", "sed", "tr", "tail", "head", "cat").forEach { assumeTrue("needs $it", File(bin, it).exists()) }
        val args = File(tmp.root, "args")
        File(bin, "curl").apply {
            writeText(
                """
                #!/bin/sh
                printf '%s\n' "${'$'}*" >>'${args.path}'
                url=; hdr=; svc=; scope=
                for a in "${'$'}@"; do
                  case "${'$'}a" in
                    @-) hdr=${'$'}(cat) ;;
                    'Authorization: '*) hdr=${'$'}a ;;
                    service=*) svc=${'$'}a ;;
                    scope=*) scope=${'$'}a ;;
                    https://*) url=${'$'}a ;;
                  esac
                done
                case "${'$'}url" in
                  https://open.test/*) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:new\r\n\r\n' ;;
                  https://hub.test/*)
                    if [ "${'$'}hdr" = 'Authorization: Bearer tok123' ]; then printf 'HTTP/2 200\r\ndocker-content-digest: sha256:cur\r\n\r\n'
                    else printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://auth.test/token",service="hub.test",scope="repository:library/nginx:pull"\r\n\r\n'; fi ;;
                  https://auth.test/token)
                    [ "${'$'}svc ${'$'}scope" = 'service=hub.test scope=repository:library/nginx:pull' ] && printf '{"token":"tok123","access_token":"tok123"}' ;;
                  https://basic.test/*) printf 'HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm="Registry"\r\n\r\n' ;;
                  https://gone.test/*) printf 'HTTP/1.1 404 Not Found\r\n\r\n' ;;
                  https://busy.test/*) printf 'HTTP/1.1 429 Too Many Requests\r\n\r\n' ;;
                  https://odd.test/*) printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n' ;;
                  *) echo 'curl: (7) Failed to connect to down.test port 443' >&2; exit 7 ;;
                esac
                """.trimIndent() + "\n"
            )
            setExecutable(true)
        }
        val refs = listOf(
            Ref("open.test", "team/app", "1"), Ref("hub.test", "library/nginx", "latest"), Ref("basic.test", "x/y", "1"),
            Ref("gone.test", "x/y", "1"), Ref("busy.test", "x/y", "1"), Ref("odd.test", "x/y", "1"), Ref("down.test", "x/y", "1"),
        )
        val out = TestShell.run(ImageUpdates.checkCommand(refs), env = mapOf("PATH" to bin.path, "LC_ALL" to "C"), clean = true, shell = sh!!).output
        val answers = ImageUpdates.parseCheck(out)
        assertEquals(out, 7, answers.size)
        assertEquals(ImageUpdates.Remote.Digest("sha256:new"), answers["open.test/team/app:1"])
        assertEquals(ImageUpdates.Remote.Digest("sha256:cur"), answers["hub.test/library/nginx:latest"])
        assertEquals(ImageUpdates.Remote.Failed("the registry needs a sign-in"), answers["basic.test/x/y:1"])
        assertEquals(ImageUpdates.Remote.Failed("not found in the registry"), answers["gone.test/x/y:1"])
        assertEquals(ImageUpdates.Remote.Failed("the registry's rate limit was reached"), answers["busy.test/x/y:1"])
        assertEquals(ImageUpdates.Remote.Failed("the registry answered 500"), answers["odd.test/x/y:1"])
        val down = answers["down.test/x/y:1"] as ImageUpdates.Remote.Failed
        assertTrue(down.reason, down.reason.startsWith("the registry could not be reached (curl: (7)"))
        val recorded = args.readText()
        assertFalse("the token is in no command line", "tok123" in recorded)
        assertTrue("manifests are asked with HEAD", recorded.lines().filter { "/manifests/" in it }.all { it.startsWith("-sSI ") })
    }
}
