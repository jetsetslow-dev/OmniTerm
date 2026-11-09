package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.Kube
import com.jetsetslow.omniterm.data.KubeDeployment
import com.jetsetslow.omniterm.data.KubeHealth
import com.jetsetslow.omniterm.data.KubePod
import com.jetsetslow.omniterm.data.KubeSetup
import com.jetsetslow.omniterm.data.KubeView
import com.jetsetslow.omniterm.data.RemoteCommands
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class KubeTest {
    @get:Rule val temp = TemporaryFolder()

    private fun row(vararg fields: String) = fields.joinToString("\t")

    @Test
    fun podRowsBecomePodsWithKubectlsStatus() {
        val output = listOf(
            row("default", "web-7d9f", "Running", "", "", "node-1", "10.42.0.7", "2026-11-01T10:00:00Z", "2026-11-01T09:59:58Z", "web sidecar", "true true", "0 2", "", "", ""),
            row("default", "api-1", "Running", "", "", "node-1", "10.42.0.8", "2026-11-01T10:00:00Z", "", "api", "false", "7", "CrashLoopBackOff", "", ""),
            row("jobs", "backup-29", "Succeeded", "", "", "node-2", "", "2026-11-01T10:00:00Z", "", "backup", "false", "0", "", "Completed", ""),
            row("default", "db-0", "Pending", "", "", "", "", "", "2026-11-01T10:00:00Z", "db", "", "", "", "", "ImagePullBackOff"),
            row("default", "old-1", "Running", "", "2026-11-01T10:05:00Z", "node-1", "", "2026-11-01T10:00:00Z", "", "old", "true", "0", "", "", ""),
            row("default", "gone-1", "Failed", "Evicted", "", "node-1", "", "2026-11-01T10:00:00Z", "", "gone", "", "", "", "", ""),
            // kubectl's stderr comes after its rows; it is no pod.
            "Warning: something is deprecated",
            row("Bad_NS", "x", "Running", "", "", "", "", "", "", "x", "true", "0", "", "", ""),
        ).joinToString("\n")

        val pods = Kube.parsePods(output)

        assertThat(pods.map { it.name }).containsExactly("web-7d9f", "api-1", "backup-29", "db-0", "old-1", "gone-1").inOrder()
        val web = pods[0]
        assertThat(web.status).isEqualTo("Running")
        assertThat(web.ready to web.total).isEqualTo(2 to 2)
        assertThat(web.restarts).isEqualTo(2)
        assertThat(web.containers).containsExactly("web", "sidecar").inOrder()
        assertThat(web.health).isEqualTo(KubeHealth.Ok)
        assertThat(pods[1].status).isEqualTo("CrashLoopBackOff")
        assertThat(pods[1].health).isEqualTo(KubeHealth.Failed)
        assertThat(pods[2].status).isEqualTo("Completed")
        assertThat(pods[2].health).isEqualTo(KubeHealth.Idle)
        assertThat(pods[3].status).isEqualTo("Init:ImagePullBackOff")
        assertThat(pods[3].health).isEqualTo(KubeHealth.Failed)
        // A pending pod with no start time yet is aged from its creation.
        assertThat(pods[3].startedAt).isEqualTo(Kube.parseTime("2026-11-01T10:00:00Z"))
        assertThat(pods[4].status).isEqualTo("Terminating")
        assertThat(pods[4].health).isEqualTo(KubeHealth.Progressing)
        assertThat(pods[5].status).isEqualTo("Evicted")
    }

    @Test
    fun aRunningPodWithAContainerNotReadyIsProgressing() {
        assertThat(Kube.podHealth("Running", 1, 2)).isEqualTo(KubeHealth.Progressing)
        assertThat(Kube.podHealth("ContainerCreating", 0, 1)).isEqualTo(KubeHealth.Progressing)
        assertThat(Kube.podHealth("Init:Error", 0, 1)).isEqualTo(KubeHealth.Failed)
    }

    @Test
    fun deploymentsServicesAndNodesParse() {
        val deployments = Kube.parseDeployments(
            listOf(
                row("default", "web", "3", "2", "3", "2", "2026-10-01T00:00:00Z", "nginx:1.27 busybox:1.36"),
                row("default", "idle", "0", "", "", "", "2026-10-01T00:00:00Z", "nginx:1.27"),
                row("default", "down", "2", "", "2", "", "2026-10-01T00:00:00Z", "nginx:1.27"),
            ).joinToString("\n"),
        )
        assertThat(deployments.map { it.health }).containsExactly(KubeHealth.Progressing, KubeHealth.Idle, KubeHealth.Failed).inOrder()
        assertThat(deployments[0].images).containsExactly("nginx:1.27", "busybox:1.36").inOrder()

        val services = Kube.parseServices(
            listOf(
                row("default", "kubernetes", "ClusterIP", "10.43.0.1", "443:/TCP,", "", "", "", "", "2026-10-01T00:00:00Z"),
                row("default", "web", "LoadBalancer", "10.43.5.9", "80:30080/TCP,443:30443/TCP,", "192.168.1.50", "", "", "", "2026-10-01T00:00:00Z"),
                row("default", "ext", "ExternalName", "", "", "", "", "", "db.example.com", "2026-10-01T00:00:00Z"),
            ).joinToString("\n"),
        )
        assertThat(services[0].ports).containsExactly("443/TCP")
        assertThat(services[1].ports).containsExactly("80:30080/TCP", "443:30443/TCP").inOrder()
        assertThat(services[1].external).containsExactly("192.168.1.50")
        assertThat(services[2].external).containsExactly("db.example.com")

        val labels = "{\"kubernetes.io/hostname\":\"node-1\",\"node-role.kubernetes.io/control-plane\":\"true\",\"node-role.kubernetes.io/master\":\"true\"}"
        val nodes = Kube.parseNodes(
            listOf(
                row("node-1", "True", "", "v1.31.2+k3s1", "192.168.1.10", "Debian GNU/Linux 13 (trixie)", "4", "16318324Ki", "2026-10-01T00:00:00Z", labels),
                row("node-2", "False", "true", "v1.31.2+k3s1", "192.168.1.11 fd00::11", "Debian", "3800m", "512Mi", "2026-10-01T00:00:00Z", "{}"),
            ).joinToString("\n"),
        )
        assertThat(nodes[0].roles).containsExactly("control-plane", "master").inOrder()
        assertThat(nodes[0].cpu).isEqualTo("4 CPU")
        assertThat(nodes[0].memory).isEqualTo("15.6 GiB")
        assertThat(nodes[0].health).isEqualTo(KubeHealth.Ok)
        assertThat(nodes[1].internalIp).isEqualTo("192.168.1.11")
        assertThat(nodes[1].cpu).isEqualTo("3.8 CPU")
        assertThat(nodes[1].memory).isEqualTo("512 MiB")
        assertThat(nodes[1].schedulable).isFalse()
        assertThat(nodes[1].health).isEqualTo(KubeHealth.Failed)
    }

    @Test
    fun setupNamesKubectlItsConfigAndContexts() {
        val setup = Kube.parseSetup(
            "@@kubectl k3s kubectl\n@@kubeconfig /home/u/.kube/config\ndefault\nprod\n@@current\nprod\n@@namespace\nshop\n",
        )!!
        assertThat(setup.kubectl).isEqualTo("k3s kubectl")
        assertThat(setup.kubeconfig).isEqualTo("/home/u/.kube/config")
        assertThat(setup.contexts).containsExactly("default", "prod").inOrder()
        assertThat(setup.currentContext).isEqualTo("prod")
        assertThat(setup.defaultNamespace).isEqualTo("shop")

        val bare = Kube.parseSetup("@@kubectl kubectl\n@@kubeconfig \n@@current\n@@namespace\n\n")!!
        assertThat(bare.kubeconfig).isNull()
        assertThat(bare.contexts).isEmpty()
        assertThat(bare.currentContext).isNull()
        assertThat(Kube.parseSetup("")).isNull()
    }

    @Test
    fun timesAgesAndErrors() {
        val t = Kube.parseTime("2026-11-02T10:00:00Z")!!
        assertThat(Kube.parseTime("2026-11-02T12:00:00.123456+02:00")).isEqualTo(t)
        assertThat(Kube.parseTime("")).isNull()
        assertThat(Kube.age(t, t + 45_000)).isEqualTo("45s")
        assertThat(Kube.age(t, t + 12 * 60_000)).isEqualTo("12m")
        assertThat(Kube.age(t, t + 30 * 3_600_000L)).isEqualTo("30h")
        assertThat(Kube.age(t, t + 9 * 86_400_000L)).isEqualTo("9d")
        assertThat(Kube.age(null, t)).isEqualTo("?")

        assertThat(Kube.errorText("SSH Error: command failed (127): ${Kube.NO_KUBECTL}\n")).isEqualTo(Kube.NO_KUBECTL)
        assertThat(Kube.errorText("SSH Error: command failed (124): Command exited with status 124")).contains("20 seconds")
        val k3s = "error: error loading config file \"/etc/rancher/k3s/k3s.yaml\": open /etc/rancher/k3s/k3s.yaml: permission denied"
        assertThat(Kube.hint(Kube.errorText("SSH Error: command failed (1): $k3s"))).isEqualTo(Kube.Hint.K3sRootOnly)
        assertThat(Kube.hint("The connection to the server localhost:8080 was refused - did you specify the right host or port?"))
            .isEqualTo(Kube.Hint.NoCluster)
    }

    @Test
    fun actionsQuoteWhatTheClusterNamedAndScopeTheirNamespace() {
        val pod = KubePod("shop", "web-1", "Running", 2, 2, 0, "n", "", null, listOf("web", "sidecar"))
        val context = "arn:aws:eks:eu-west-1:1:cluster/it's"
        val logs = Kube.podLogs(context, pod, follow = true, previous = false)
        assertThat(logs).contains("--context='arn:aws:eks:eu-west-1:1:cluster/it'\\''s'")
        assertThat(logs).contains("--namespace='shop' logs 'web-1' --all-containers=true --prefix=true --tail=200 --follow")
        assertThat(Kube.list(KubeView.Pods, null, "")).contains(" get pods --all-namespaces")
        assertThat(Kube.list(KubeView.Nodes, null, "shop")).doesNotContain("--namespace")
        // kubectl reads --all-namespaces only after the command it scopes.
        assertThat(Kube.events(null, "")).contains(" get events --all-namespaces --sort-by=")
        assertThat(Kube.events(null, "shop")).contains(" get events --namespace='shop' --sort-by=")

        val deployment = KubeDeployment("shop", "web", 2, 2, 2, 2, emptyList(), null)
        assertThat(Kube.scale(null, deployment, 5)).contains("scale 'deployment/web' --replicas=5")
        assertThat(runCatching { Kube.scale(null, deployment, Kube.MAX_REPLICAS + 1) }.isFailure).isTrue()

        val setup = KubeSetup("k3s kubectl", "/home/u/.kube/config", listOf("default"), "default", null)
        assertThat(Kube.execShell(setup, null, pod, "sidecar")).isEqualTo(
            "env KUBECONFIG='/home/u/.kube/config' k3s kubectl --namespace='shop' exec -it 'web-1' --container='sidecar' -- " +
                RemoteCommands.CONTAINER_SHELL,
        )
    }

    /** Runs [script] in sh with a kubectl that prints each argument it gets, and KUBECONFIG, a line each. */
    private fun runWithFakeKubectl(script: String, home: File): List<String> {
        val bin = temp.newFolder()
        File(bin, "kubectl").apply {
            writeText("#!/bin/sh\nprintf 'KUBECONFIG=%s\\n' \"\${KUBECONFIG:-}\"\nfor a in \"\$@\"; do printf '%s\\n' \"\$a\"; done\n")
            setExecutable(true)
        }
        val run = TestShell.run(script, env = mapOf("PATH" to "${bin.absolutePath}:/usr/bin:/bin", "HOME" to home.absolutePath), clean = true)
        check(run.exit == 0) { run.output }
        return run.output.lines().filter { it.isNotEmpty() }
    }

    @Test
    fun generatedCommandsReachKubectlWithEveryArgumentIntact() {
        assumeTrue("POSIX sh is required to run the generated commands", TestShell.sh != null)
        val home = temp.newFolder()
        val pod = KubePod("shop", "web-1", "Running", 1, 1, 0, "n", "", null, listOf("web"))

        val args = runWithFakeKubectl(Kube.podLogs("it's a context", pod, follow = false, previous = true), home)
        assertThat(args).containsExactly(
            "KUBECONFIG=", "--context=it's a context", "--request-timeout=15s", "--namespace=shop",
            "logs", "web-1", "--tail=200", "--previous",
        ).inOrder()

        // With ~/.kube/config present it is named outright, for k3s's kubectl's sake.
        File(home, ".kube").mkdirs()
        File(home, ".kube/config").writeText("")
        val listed = runWithFakeKubectl(Kube.list(KubeView.Nodes, null, ""), home)
        assertThat(listed.first()).isEqualTo("KUBECONFIG=${home.absolutePath}/.kube/config")
        assertThat(listed.drop(1).take(3)).containsExactly("--request-timeout=15s", "get", "nodes").inOrder()
        assertThat(listed.last()).startsWith("jsonpath={range .items[*]}{.metadata.name}{\"\\t\"}")

        // Every command parses as sh, including the setup script.
        runWithFakeKubectl(Kube.SETUP, home)
        runWithFakeKubectl(Kube.events(null, "shop"), home)
        runWithFakeKubectl(Kube.cordon("c", com.jetsetslow.omniterm.data.KubeNode("n1", true, true, emptyList(), "", "", "", "", "", null), cordon = true), home)
    }
}
