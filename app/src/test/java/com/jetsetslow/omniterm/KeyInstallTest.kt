package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import com.jetsetslow.omniterm.data.KeyInstall
import com.jetsetslow.omniterm.data.RemoteCommands
import com.jetsetslow.omniterm.data.SshKeyEntity
import com.jetsetslow.omniterm.data.ssh.SshCredentials
import com.jetsetslow.omniterm.data.ssh.preferredAuthentications
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.util.Base64

/** A public key line of [type] whose contents name [named], for tests that need a well-formed key. */
internal fun fixturePublicKey(type: String, comment: String = "", named: String = type, seed: Int = 1): String {
    val name = named.toByteArray()
    val body = ByteArray(32) { (it * 7 + seed).toByte() }
    val blob = ByteBuffer.allocate(8 + name.size + body.size).putInt(name.size).put(name).putInt(body.size).put(body).array()
    return listOf(type, Base64.getEncoder().encodeToString(blob), comment).filter { it.isNotEmpty() }.joinToString(" ")
}

/**
 * Installing a key's public half on a host: the line OmniTerm sends, what it makes of the host's
 * answer, and the command itself, run in each POSIX shell this machine has against a scratch home.
 */
class KeyInstallTest {
    @get:Rule val temp = TemporaryFolder()

    private val key = fixturePublicKey("ssh-ed25519", "me@laptop")
    private val blob = key.split(" ")[1]

    // ── The line ──

    @Test
    fun aKeyBecomesOneLineWithAPlainComment() {
        assertThat(KeyInstall.line(key, "Laptop")).isEqualTo(key)
        // The comment can only ever be text: nothing in it is shell, and it cannot start a new line.
        assertThat(KeyInstall.line("ssh-ed25519 $blob it's mine; rm -rf ~ `id` \$(id)\nssh-rsa AAAA", "x"))
            .isEqualTo("ssh-ed25519 $blob its-mine-rm--rf--id-id-ssh-rsa-AAAA")
        // Without its own comment the key's name in OmniTerm is used, made plain the same way.
        assertThat(KeyInstall.line("ssh-ed25519 $blob", "Work laptop (2026)")).isEqualTo("ssh-ed25519 $blob Work-laptop-2026")
        assertThat(KeyInstall.line("ssh-ed25519 $blob", "&&&")).isEqualTo("ssh-ed25519 $blob")
        assertThat(KeyInstall.line("  ssh-ed25519   $blob  ", "a")).isEqualTo("ssh-ed25519 $blob a")
        assertThat(KeyInstall.line("ssh-ed25519 $blob " + "c".repeat(100), "a")).isEqualTo("ssh-ed25519 $blob " + "c".repeat(64))
    }

    @Test
    fun everyTypeOmniTermMakesOrImportsIsAccepted() {
        KeyInstall.TYPES.forEach { type ->
            val line = fixturePublicKey(type, "c")
            assertThat(KeyInstall.line(line, "a")).isEqualTo(line)
        }
    }

    @Test
    fun aKeyOmniTermCannotVouchForGivesNoLine() {
        listOf(
            "",
            "ssh-ed25519",
            fixturePublicKey("ssh-dss"),
            "ssh-ed25519 AAAA\$(id)",
            "ssh-ed25519 AAAA",
            // Its contents say it is another kind of key than its type says.
            fixturePublicKey("ssh-rsa", named = "ssh-ed25519"),
            fixturePublicKey("ssh-ed25519", named = "ssh-ed25519x"),
            "ssh-ed25519 " + Base64.getEncoder().encodeToString(byteArrayOf(0, 0, 0, 99, 1, 2)),
        ).forEach { assertWithMessage(it).that(KeyInstall.line(it, "a")).isNull() }
    }

    @Test
    fun onlySecurityKeysNeedATouch() {
        fun saved(type: String) = SshKeyEntity(alias = "a", keyType = type, privateKey = "", publicKey = "", fingerprint = "")
        assertThat(KeyInstall.onSecurityKey(saved("ED25519-SK"))).isTrue()
        assertThat(KeyInstall.onSecurityKey(saved("ECDSA-SK"))).isTrue()
        assertThat(KeyInstall.onSecurityKey(saved("ED25519"))).isFalse()
        assertThat(KeyInstall.onSecurityKey(saved("RSA"))).isFalse()
    }

    // ── The host's answer ──

    @Test
    fun theAnswerSaysWhatHappened() {
        assertThat(KeyInstall.outcome("${KeyInstall.ADDED}\n")).isEqualTo(KeyInstall.Outcome.Added)
        assertThat(KeyInstall.outcome("motd line\n${KeyInstall.PRESENT}\n")).isEqualTo(KeyInstall.Outcome.AlreadyThere)
        assertThat(KeyInstall.outcome("SSH Error: command failed (1): mkdir: cannot create directory '.ssh': Permission denied\n"))
            .isEqualTo(KeyInstall.Outcome.Failed("mkdir: cannot create directory '.ssh': Permission denied"))
        assertThat(KeyInstall.outcome("SSH Error: command failed (2): Command exited with status 2"))
            .isEqualTo(KeyInstall.Outcome.Failed("exit 2"))
        assertThat(KeyInstall.outcome("SSH Error: Auth fail")).isEqualTo(KeyInstall.Outcome.NotReached("Auth fail"))
        // Exit 0 without either marker is not a success: something else answered.
        assertThat(KeyInstall.outcome("hello\n")).isEqualTo(KeyInstall.Outcome.Failed("hello"))
        assertThat(KeyInstall.outcome("")).isEqualTo(KeyInstall.Outcome.Failed("exit 0"))
    }

    // ── Signing in by key only ──

    @Test
    fun aKeyOnlySignInOffersTheKeyAndNothingElse() {
        val base = SshCredentials("h", 22, "u", password = "pw")
        assertThat(preferredAuthentications(base)).isEqualTo("keyboard-interactive,password")
        assertThat(preferredAuthentications(base.copy(privateKeyPem = "k"))).isEqualTo("publickey,keyboard-interactive,password")
        assertThat(preferredAuthentications(base.copy(privateKeyPem = "k", keyOnly = true))).isEqualTo("publickey")
        // Without a key it still never falls back to the password.
        assertThat(preferredAuthentications(base.copy(keyOnly = true))).isEqualTo("publickey")
    }

    // ── The command, in a real shell ──

    /** Each POSIX shell here, as `[program] [flags]`: hosts run the command in their `sh`. */
    private val shells: List<Pair<File, List<String>>> =
        listOfNotNull(TestShell.sh, TestShell.find("dash"), TestShell.find("bash")).distinct().map { it to emptyList<String>() } +
            listOfNotNull(TestShell.find("busybox")).map { it to listOf("sh") }

    private fun install(home: File, line: String, shell: Pair<File, List<String>> = shells.first()): TestShell.Result =
        TestShell.run(KeyInstall.COMMAND, stdin = line, env = mapOf("HOME" to home.path, "PATH" to "/usr/bin:/bin"), clean = true, shell = shell.first, flags = shell.second)

    private fun mode(file: File) = PosixFilePermissions.toString(Files.getPosixFilePermissions(file.toPath()))

    @Test
    fun theKeyIsAddedOnceAndNewFilesArePrivate() {
        assumeTrue("needs a POSIX sh", shells.isNotEmpty())
        shells.forEach { shell ->
            val home = temp.newFolder()
            val name = shell.first.name
            val first = install(home, key, shell)
            assertWithMessage(name).that(first.exit).isEqualTo(0)
            assertWithMessage(name).that(KeyInstall.outcome(first.output)).isEqualTo(KeyInstall.Outcome.Added)
            val file = File(home, ".ssh/authorized_keys")
            assertWithMessage(name).that(file.readText()).isEqualTo("$key\n")
            assertWithMessage(name).that(mode(File(home, ".ssh"))).isEqualTo("rwx------")
            assertWithMessage(name).that(mode(file)).isEqualTo("rw-------")

            val again = install(home, key, shell)
            assertWithMessage(name).that(KeyInstall.outcome(again.output)).isEqualTo(KeyInstall.Outcome.AlreadyThere)
            assertWithMessage(name).that(file.readText()).isEqualTo("$key\n")
        }
    }

    /** sshd hands the command to the login shell; wrapped for `sh`, it works from csh or fish too. */
    @Test
    fun theWrappedCommandWorksFromAnyLoginShell() {
        val logins = listOf("bash", "zsh", "ksh", "mksh", "tcsh", "csh", "fish").mapNotNull { TestShell.find(it) }
        assumeTrue("needs a login shell other than sh", logins.isNotEmpty() && TestShell.sh != null)
        logins.forEach { login ->
            val home = temp.newFolder()
            val run = TestShell.run(RemoteCommands.inPosixShell(KeyInstall.COMMAND), stdin = key, env = mapOf("HOME" to home.path, "PATH" to "/usr/bin:/bin"), clean = true, shell = login)
            assertWithMessage(login.name).that(KeyInstall.outcome(run.output)).isEqualTo(KeyInstall.Outcome.Added)
            assertWithMessage(login.name).that(File(home, ".ssh/authorized_keys").readText()).isEqualTo("$key\n")
        }
    }

    @Test
    fun theKeyIsFoundWhateverItsCommentOrOptions() {
        assumeTrue("needs a POSIX sh", shells.isNotEmpty())
        val home = temp.newFolder()
        val existing = "ssh-rsa AAAAother first\nfrom=\"10.0.0.1\",no-pty ssh-ed25519 $blob old-name\n"
        File(home, ".ssh").mkdirs()
        val file = File(home, ".ssh/authorized_keys").apply { writeText(existing) }
        assertThat(KeyInstall.outcome(install(home, key).output)).isEqualTo(KeyInstall.Outcome.AlreadyThere)
        assertThat(file.readText()).isEqualTo(existing)
    }

    @Test
    fun aLastLineWithoutABreakIsEndedFirstAndNothingElseChanges() {
        assumeTrue("needs a POSIX sh", shells.isNotEmpty())
        val home = temp.newFolder()
        val ssh = File(home, ".ssh").apply { mkdirs() }
        val file = File(ssh, "authorized_keys").apply { writeText("ssh-rsa AAAAother first") }
        Files.setPosixFilePermissions(ssh.toPath(), PosixFilePermissions.fromString("rwxr-xr-x"))
        Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-r--r--"))
        assertThat(KeyInstall.outcome(install(home, key).output)).isEqualTo(KeyInstall.Outcome.Added)
        assertThat(file.readText()).isEqualTo("ssh-rsa AAAAother first\n$key\n")
        // Existing folders and files keep their permissions, as ssh-copy-id leaves them.
        assertThat(mode(ssh)).isEqualTo("rwxr-xr-x")
        assertThat(mode(file)).isEqualTo("rw-r--r--")
    }

    @Test
    fun nothingToInstallChangesNothing() {
        assumeTrue("needs a POSIX sh", shells.isNotEmpty())
        val home = temp.newFolder()
        val run = install(home, "")
        assertThat(run.exit).isEqualTo(2)
        assertThat(File(home, ".ssh/authorized_keys").exists()).isFalse()
    }

    @Test
    fun aFolderItCannotWriteToFailsAndSaysWhy() {
        assumeTrue("needs a POSIX sh", shells.isNotEmpty())
        val home = temp.newFolder()
        val ssh = File(home, ".ssh").apply { mkdirs() }
        Files.setPosixFilePermissions(ssh.toPath(), PosixFilePermissions.fromString("r-x------"))
        try {
            assumeTrue("permissions are not enforced for this user", !File(ssh, "probe").let { runCatching { it.createNewFile() }.getOrDefault(false) })
            val run = install(home, key)
            assertThat(run.exit).isNotEqualTo(0)
            val outcome = KeyInstall.outcome("SSH Error: command failed (${run.exit}): ${run.output}")
            assertThat(outcome).isInstanceOf(KeyInstall.Outcome.Failed::class.java)
            assertThat((outcome as KeyInstall.Outcome.Failed).reason).contains("Permission denied")
        } finally {
            Files.setPosixFilePermissions(ssh.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }
}
