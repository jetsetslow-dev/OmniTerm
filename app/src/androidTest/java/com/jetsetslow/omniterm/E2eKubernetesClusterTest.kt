package com.jetsetslow.omniterm

import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import com.jetsetslow.omniterm.data.KubeConfigFile
import com.jetsetslow.omniterm.data.ServerEntity
import com.jetsetslow.omniterm.ui.AppViewModel
import com.jetsetslow.omniterm.ui.INFRA_TAB_KUBERNETES
import com.jetsetslow.omniterm.ui.Screen
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test

/**
 * The Kubernetes tab on a saved cluster, opened on the device: the real screen and the app's own
 * API client (`KubeApi`, reading JSON through `JsonTree`), against [E2eKubeApiServer], a small HTTPS
 * server inside this test that answers as a Kubernetes API server does. Its objects are samples in
 * the shapes the Kubernetes API documents, not recorded from a cluster; no cluster is involved. The
 * cluster is saved from a kubeconfig, as the import dialog's Save does, and the tab sits on a lab
 * host saved from the repository's fixtures. Run with `./scripts/test-hosts.sh suite
 * E2eKubernetesClusterTest omniterm_e2e_kube=yes host port user pass`.
 */
class E2eKubernetesClusterTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun aSavedClustersPodsDeploymentsServicesAndNodesAreReadOverTheApi() = runBlocking {
        assumeTrue(E2eArgs.on("omniterm_e2e_kube"))
        val vm = ViewModelProvider(composeRule.activity)[AppViewModel::class.java]
        composeRule.runOnUiThread { vm.isAppLocked = false }
        val host = E2eLabHosts.save(
            vm,
            ServerEntity(
                name = HOST, host = E2eArgs.require("host"), port = E2eArgs.get("port")?.toIntOrNull() ?: 2205,
                username = E2eArgs.require("user"), authPassword = E2eArgs.require("pass"),
            ),
        ).also { E2eLabHosts.connectOnce(vm, it) }
        // One object a page, so every list with more than one is read in pages, as a large cluster's is.
        val api = E2eKubeApiServer(UUID.randomUUID().toString(), SAMPLES, pageSize = 1)
        try {
            composeRule.runOnUiThread {
                vm.selectedServerId = host.id
                vm.activeInfraTab = INFRA_TAB_KUBERNETES
                vm.navigateTo(Screen.Infra)
            }
            vm.saveKubeClusters(host.id, KubeConfigFile.parse(api.kubeconfig(CONTEXT)))

            // Pods, across namespaces, the second from the list's second page.
            card("kube.pod.shop.web-7d9f8c-x2k4p", "Running", "Ready 2/2 · Restarts 4 · Age 2h", "shop · lab-node-1 · 10.42.0.9")
            card("kube.pod.kube-system.coredns-6799fbcd5-q8wzx", "Running", "Ready 1/1 · Restarts 0")
            composeRule.onNodeWithTag("kube.source", useUnmergedTree = true).assert(hasAnyDescendant(hasText(CONTEXT)))
            composeRule.onNodeWithTag("kube.view.Pods", useUnmergedTree = true).assert(hasAnyDescendant(hasText("Pods 2")))
            assertTrue("pods read in pages: ${api.requests}", api.requests.any { it.startsWith("/api/v1/pods?") && "continue=page-1" in it })

            composeRule.onNodeWithTag("kube.view.Deployments").performClick()
            card("kube.deployment.shop.web", "2/3", "Up to date 3 · Available 2 · Age 2h", "nginx:1.27")
            card("kube.deployment.kube-system.coredns", "1/1")

            composeRule.onNodeWithTag("kube.view.Services").performClick()
            card("kube.service.shop.web", "NodePort", "80:30080/TCP", "10.43.12.7")
            card("kube.service.kube-system.kube-dns", "ClusterIP", "53/UDP, 53/TCP, 9153/TCP")

            composeRule.onNodeWithTag("kube.view.Nodes").performClick()
            card("kube.node.lab-node-1", "Ready", "192.168.50.10 · v1.31.4+k3s1", "control-plane", "Debian GNU/Linux 12 (bookworm) · 4 CPU · 7.7 GiB · Age 2h")

            // One namespace: its own lists, from the namespaced paths.
            composeRule.onNodeWithTag("kube.view.Pods").performClick()
            composeRule.onNodeWithTag("kube.namespace").performClick()
            composeRule.onNodeWithTag("kube.namespace.option.shop").performClick()
            composeRule.waitUntil(15_000) { api.requests.any { it.startsWith("/api/v1/namespaces/shop/pods?") } }
            card("kube.pod.shop.web-7d9f8c-x2k4p", "Running")
            composeRule.waitUntil(15_000) {
                composeRule.onAllNodes(hasTestTag("kube.pod.kube-system.coredns-6799fbcd5-q8wzx"), useUnmergedTree = true).fetchSemanticsNodes().isEmpty()
            }
            assertTrue("only reads: ${api.requests}", api.requests.none { it.contains("/exec") || it.contains("/log") })
        } finally {
            api.close()
            composeRule.runOnUiThread { vm.activeInfraTab = 0 }
            vm.kubeClusters.value.filter { it.name == CONTEXT }.forEach { vm.deleteKubeCluster(it.id) }
            E2eLabHosts.remove(vm, HOST)
        }
    }

    /** Waits for the card tagged [tag] and checks it shows each of [texts]. */
    private fun card(tag: String, vararg texts: String) {
        composeRule.waitUntil(15_000) { composeRule.onAllNodes(hasTestTag(tag), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
        texts.forEach { text ->
            composeRule.onNodeWithTag(tag, useUnmergedTree = true).assert(hasAnyDescendant(hasText(text, substring = true)))
        }
    }

    private companion object {
        const val HOST = "E2E Kubernetes host"
        const val CONTEXT = "e2e-lab"

        private val twoHoursAgo: String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date(System.currentTimeMillis() - 2 * 3_600_000L - 60_000L))

        private fun item(namespace: String, json: String) = E2eKubeApiServer.Item(namespace, json.trimIndent().replace("\n", ""))

        val SAMPLES = mapOf(
            "namespaces" to listOf("default", "kube-system", "shop").map {
                item("", """{"metadata":{"name":"$it","creationTimestamp":"$twoHoursAgo"},"status":{"phase":"Active"}}""")
            },
            "pods" to listOf(
                item(
                    "shop",
                    """
                    {"metadata":{"name":"web-7d9f8c-x2k4p","namespace":"shop","creationTimestamp":"$twoHoursAgo","labels":{"app":"web"}},
                    "spec":{"nodeName":"lab-node-1","containers":[{"name":"web","image":"nginx:1.27"},{"name":"log","image":"busybox:1.36"}]},
                    "status":{"phase":"Running","podIP":"10.42.0.9","startTime":"$twoHoursAgo",
                    "containerStatuses":[{"name":"web","ready":true,"restartCount":3,"state":{"running":{"startedAt":"$twoHoursAgo"}}},
                    {"name":"log","ready":true,"restartCount":1,"state":{"running":{"startedAt":"$twoHoursAgo"}}}]}}
                    """,
                ),
                item(
                    "kube-system",
                    """
                    {"metadata":{"name":"coredns-6799fbcd5-q8wzx","namespace":"kube-system","creationTimestamp":"$twoHoursAgo"},
                    "spec":{"nodeName":"lab-node-1","containers":[{"name":"coredns","image":"rancher/mirrored-coredns-coredns:1.11.3"}]},
                    "status":{"phase":"Running","podIP":"10.42.0.3","startTime":"$twoHoursAgo",
                    "containerStatuses":[{"name":"coredns","ready":true,"restartCount":0,"state":{"running":{"startedAt":"$twoHoursAgo"}}}]}}
                    """,
                ),
            ),
            "deployments" to listOf(
                item(
                    "shop",
                    """
                    {"metadata":{"name":"web","namespace":"shop","creationTimestamp":"$twoHoursAgo"},
                    "spec":{"replicas":3,"selector":{"matchLabels":{"app":"web"}},"template":{"spec":{"containers":[{"name":"web","image":"nginx:1.27"}]}}},
                    "status":{"replicas":3,"readyReplicas":2,"updatedReplicas":3,"availableReplicas":2}}
                    """,
                ),
                item(
                    "kube-system",
                    """
                    {"metadata":{"name":"coredns","namespace":"kube-system","creationTimestamp":"$twoHoursAgo"},
                    "spec":{"replicas":1,"template":{"spec":{"containers":[{"name":"coredns","image":"rancher/mirrored-coredns-coredns:1.11.3"}]}}},
                    "status":{"replicas":1,"readyReplicas":1,"updatedReplicas":1,"availableReplicas":1}}
                    """,
                ),
            ),
            "services" to listOf(
                item(
                    "shop",
                    """
                    {"metadata":{"name":"web","namespace":"shop","creationTimestamp":"$twoHoursAgo"},
                    "spec":{"type":"NodePort","clusterIP":"10.43.12.7","ports":[{"port":80,"targetPort":8080,"nodePort":30080,"protocol":"TCP"}]},
                    "status":{"loadBalancer":{}}}
                    """,
                ),
                item(
                    "kube-system",
                    """
                    {"metadata":{"name":"kube-dns","namespace":"kube-system","creationTimestamp":"$twoHoursAgo"},
                    "spec":{"type":"ClusterIP","clusterIP":"10.43.0.10","ports":[{"name":"dns","port":53,"protocol":"UDP"},
                    {"name":"dns-tcp","port":53,"protocol":"TCP"},{"name":"metrics","port":9153,"protocol":"TCP"}]},
                    "status":{"loadBalancer":{}}}
                    """,
                ),
            ),
            "nodes" to listOf(
                item(
                    "",
                    """
                    {"metadata":{"name":"lab-node-1","creationTimestamp":"$twoHoursAgo",
                    "labels":{"kubernetes.io/hostname":"lab-node-1","node-role.kubernetes.io/control-plane":"true"}},
                    "spec":{},
                    "status":{"conditions":[{"type":"MemoryPressure","status":"False"},{"type":"Ready","status":"True"}],
                    "addresses":[{"type":"InternalIP","address":"192.168.50.10"},{"type":"Hostname","address":"lab-node-1"}],
                    "nodeInfo":{"kubeletVersion":"v1.31.4+k3s1","osImage":"Debian GNU/Linux 12 (bookworm)"},
                    "allocatable":{"cpu":"4","memory":"8029308Ki","pods":"110"}}}
                    """,
                ),
            ),
        )
    }
}
