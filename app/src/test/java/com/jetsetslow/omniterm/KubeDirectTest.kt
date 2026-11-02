package com.jetsetslow.omniterm

import com.google.common.truth.Truth.assertThat
import com.jetsetslow.omniterm.data.Kube
import com.jetsetslow.omniterm.data.KubeApi
import com.jetsetslow.omniterm.data.KubeClusterEntity
import com.jetsetslow.omniterm.data.KubeConfigFile
import com.jetsetslow.omniterm.data.KubeExecSession
import com.jetsetslow.omniterm.data.KubeHealth
import com.jetsetslow.omniterm.data.KubePem
import com.squareup.moshi.Moshi
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.pkcs.PrivateKeyInfo
import org.bouncycastle.util.encoders.Base64
import org.junit.Assert.assertThrows
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.interfaces.ECPrivateKey
import java.security.spec.ECGenParameterSpec

class KubeDirectTest {
    private fun b64(text: String) = Base64.toBase64String(text.toByteArray())

    /** A kubeconfig as kubectl writes one: lists at their key's indentation, {} for empty maps. */
    private val kubectlStyle = """
        apiVersion: v1
        clusters:
        - cluster:
            certificate-authority-data: ${b64("test-ca")}
            server: https://192.168.1.10:6443
          name: lab
        # A cluster reached through a cloud CLI.
        - cluster:
            server: https://eks.example.com
          name: eks
        - cluster:
            certificate-authority: /home/me/.minikube/ca.crt
            server: https://192.168.49.2:8443
          name: minikube
        contexts:
        - context:
            cluster: lab
            namespace: shop
            user: lab-admin
          name: lab
        - context:
            cluster: eks
            user: eks-user
          name: "prod: eu"
        - context:
            cluster: minikube
            user: minikube
          name: minikube
        - name: ghost
          context:
            cluster: nowhere
            user: lab-admin
        current-context: lab
        kind: Config
        preferences: {}
        users:
        - name: lab-admin
          user:
            client-certificate-data: ${b64("test-cert")}
            client-key-data: ${b64("test-key")}
        - name: eks-user
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              command: aws
              args: ["eks", "get-token"]
        - name: minikube
          user:
            client-certificate: /home/me/.minikube/profiles/minikube/client.crt
            client-key: /home/me/.minikube/profiles/minikube/client.key
    """.trimIndent()

    @Test
    fun aKubectlWrittenConfigGivesEachContextOrWhyItCannotBeUsed() {
        val contexts = KubeConfigFile.parse(kubectlStyle)
        assertThat(contexts.map { it.name }).containsExactly("lab", "prod: eu", "minikube", "ghost").inOrder()

        val lab = contexts[0]
        assertThat(lab.unsupported).isNull()
        assertThat(lab.server).isEqualTo("https://192.168.1.10:6443")
        assertThat(lab.caPem).isEqualTo("test-ca")
        assertThat(lab.clientCertPem).isEqualTo("test-cert")
        assertThat(lab.clientKeyPem).isEqualTo("test-key")
        assertThat(lab.namespace).isEqualTo("shop")

        assertThat(contexts[1].unsupported).contains("from a program")
        assertThat(contexts[2].unsupported).contains("kubectl config view --raw --flatten")
        assertThat(contexts[3].unsupported).contains("a cluster the file does not define")
    }

    @Test
    fun tokensJsonAndUnsafeOrPlainClustersAreRead() {
        val json = """
            {"apiVersion":"v1","kind":"Config",
             "clusters":[{"name":"c","cluster":{"server":"https://k.example.com:443"}},
                         {"name":"insecure","cluster":{"server":"https://10.0.0.9:6443","insecure-skip-tls-verify":true}},
                         {"name":"plain","cluster":{"server":"http://10.0.0.9:8080"}}],
             "users":[{"name":"sa","user":{"token":"abc.def"}}],
             "contexts":[{"name":"ci","context":{"cluster":"c","user":"sa"}},
                         {"name":"skip","context":{"cluster":"insecure","user":"sa"}},
                         {"name":"http","context":{"cluster":"plain","user":"sa"}}]}
        """.trimIndent()
        val contexts = KubeConfigFile.parse(json)
        assertThat(contexts[0].unsupported).isNull()
        assertThat(contexts[0].token).isEqualTo("abc.def")
        // No CA in the config: the phone's own trusted CAs check the cluster.
        assertThat(contexts[0].caPem).isNull()
        assertThat(contexts[1].unsupported).contains("skips checking the cluster's certificate")
        assertThat(contexts[2].unsupported).contains("HTTPS only")
    }

    @Test
    fun quotedScalarsCommentsAndLiteralBlocksParse() {
        val yaml = """
            # written by hand
            clusters:
              - name: 'it''s'
                cluster:
                  server: "https://10.0.0.1:6443"   # the API
            users:
              - name: u
                user:
                  token: |
                    line-token
            contexts:
              - name: home
                context: {cluster: "ignored"}
              - name: real
                context:
                  cluster: it's
                  user: u
        """.trimIndent()
        val contexts = KubeConfigFile.parse(yaml)
        val real = contexts.single { it.name == "real" }
        assertThat(real.server).isEqualTo("https://10.0.0.1:6443")
        assertThat(real.token).isEqualTo("line-token\n")
        assertThat(real.unsupported).isNull()
        // A flow map other than {} is not read; that context just has no cluster.
        assertThat(contexts.single { it.name == "home" }.unsupported).isNotNull()
    }

    @Test
    fun filesThatAreNoKubeconfigSaySo() {
        assertThrows(KubeConfigFile.Invalid::class.java) { KubeConfigFile.parse("just some text") }
        assertThrows(KubeConfigFile.Invalid::class.java) { KubeConfigFile.parse("clusters: []\ncontexts: []\n") }
        assertThrows(KubeConfigFile.Invalid::class.java) { KubeConfigFile.parse("contexts:\n\t- name: x\n") }
        assertThrows(KubeConfigFile.Invalid::class.java) { KubeConfigFile.parse("{not json") }
    }

    private fun pem(type: String, der: ByteArray) =
        "-----BEGIN $type-----\n" + Base64.toBase64String(der).chunked(64).joinToString("\n") + "\n-----END $type-----\n"

    @Test
    fun privateKeysReadInEachEncodingKubeconfigsUse() {
        val rsa = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair().private
        val rsaPkcs1 = PrivateKeyInfo.getInstance(rsa.encoded).parsePrivateKey().toASN1Primitive().encoded
        assertThat(KubePem.privateKey(pem("PRIVATE KEY", rsa.encoded)).encoded).isEqualTo(rsa.encoded)
        assertThat(KubePem.privateKey(pem("RSA PRIVATE KEY", rsaPkcs1)).encoded).isEqualTo(rsa.encoded)

        val ec = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair().private as ECPrivateKey
        // What k3s and openssl write: SEC 1, with the curve named inside the key, after its parameters.
        val sec1 = org.bouncycastle.asn1.sec.ECPrivateKey(256, ec.s, ASN1ObjectIdentifier("1.2.840.10045.3.1.7")).encoded
        val read = KubePem.privateKey(pem("EC PARAMETERS", ASN1ObjectIdentifier("1.2.840.10045.3.1.7").encoded) + pem("EC PRIVATE KEY", sec1))
        assertThat((read as ECPrivateKey).s).isEqualTo(ec.s)

        assertThrows(IllegalArgumentException::class.java) { KubePem.privateKey(pem("ENCRYPTED PRIVATE KEY", byteArrayOf(1))) }
        assertThrows(IllegalArgumentException::class.java) { KubePem.privateKey("no key here") }
    }

    @Test
    fun aClusterWithItsOwnCaBuildsAClient() {
        assertThat(KubePem.certificates(TEST_CA).single().subjectX500Principal.name).isEqualTo("CN=omniterm-test-ca")
        KubeApi(KubeClusterEntity(name = "lab", server = "https://10.0.0.1:6443", caPem = TEST_CA, token = "t"))
        assertThrows(IllegalArgumentException::class.java) { KubePem.certificates("not a certificate") }
    }

    private val json = Moshi.Builder().build().adapter(Any::class.java)

    @Test
    fun apiObjectsGiveTheRowsKubectlsJsonpathPrints() {
        val pod = json.fromJson(
            """
            {"metadata":{"namespace":"shop","name":"web-1","creationTimestamp":"2026-11-01T10:00:00Z"},
             "spec":{"nodeName":"n1","containers":[{"name":"web"},{"name":"log"}]},
             "status":{"phase":"Running","podIP":"10.42.0.9","startTime":"2026-11-01T10:00:01Z",
               "containerStatuses":[{"name":"web","ready":true,"restartCount":2,"state":{"running":{}}},
                                    {"name":"log","ready":false,"restartCount":5,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}
            """.trimIndent(),
        )
        val row = KubeApi.podRow(pod)
        assertThat(row).containsExactly(
            "shop", "web-1", "Running", "", "", "n1", "10.42.0.9", "2026-11-01T10:00:01Z", "2026-11-01T10:00:00Z",
            "web log", "true false", "2 5", "CrashLoopBackOff", "", "",
        ).inOrder()
        val parsed = Kube.podFromRow(row)!!
        assertThat(parsed.status).isEqualTo("CrashLoopBackOff")
        assertThat(parsed.restarts).isEqualTo(7)
        assertThat(parsed.health).isEqualTo(KubeHealth.Failed)

        val service = json.fromJson(
            """{"metadata":{"namespace":"shop","name":"web","creationTimestamp":"2026-11-01T10:00:00Z"},
                "spec":{"type":"NodePort","clusterIP":"10.43.1.2","ports":[{"port":80,"nodePort":30080,"protocol":"TCP"},{"port":9090,"protocol":"TCP"}]}}""",
        )
        assertThat(Kube.serviceFromRow(KubeApi.serviceRow(service))!!.ports).containsExactly("80:30080/TCP", "9090/TCP").inOrder()

        val node = json.fromJson(
            """{"metadata":{"name":"n1","creationTimestamp":"2026-10-01T00:00:00Z","labels":{"node-role.kubernetes.io/control-plane":"true"}},
                "spec":{"unschedulable":true},
                "status":{"conditions":[{"type":"MemoryPressure","status":"False"},{"type":"Ready","status":"True"}],
                  "addresses":[{"type":"Hostname","address":"n1"},{"type":"InternalIP","address":"192.168.1.10"}],
                  "nodeInfo":{"kubeletVersion":"v1.31.0","osImage":"Debian"},"allocatable":{"cpu":"4","memory":"8Gi"}}}""",
        )
        val parsedNode = Kube.nodeFromRow(KubeApi.nodeRow(node))!!
        assertThat(parsedNode.roles).containsExactly("control-plane")
        assertThat(parsedNode.internalIp).isEqualTo("192.168.1.10")
        assertThat(parsedNode.schedulable).isFalse()
        assertThat(parsedNode.memory).isEqualTo("8 GiB")

        val deployment = json.fromJson(
            """{"metadata":{"namespace":"shop","name":"web","creationTimestamp":"2026-11-01T10:00:00Z"},
                "spec":{"template":{"spec":{"containers":[{"image":"nginx:alpine"}]}}},"status":{}}""",
        )
        val parsedDeployment = Kube.deploymentFromRow(KubeApi.deploymentRow(deployment))!!
        // No replica count means one, and no status yet means none ready.
        assertThat(parsedDeployment.desired).isEqualTo(1)
        assertThat(parsedDeployment.ready).isEqualTo(0)
    }

    @Test
    fun aShellsExitIsSaidPlainly() {
        assertThat(KubeExecSession.exitReason("""{"metadata":{},"status":"Success"}""")).isNull()
        assertThat(
            KubeExecSession.exitReason(
                """{"metadata":{},"status":"Failure","message":"command terminated with non-zero exit code: error executing command [sh -c x], exit code 3",
                    "reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"3"}]}}""",
            ),
        ).isEqualTo("The shell in the pod exited with status 3")
        assertThat(KubeExecSession.exitReason("""{"status":"Failure","message":"container not found"}""")).isEqualTo("container not found")
    }

    private companion object {
        /** A self-signed CA certificate made for this test; its private key was never kept. */
        val TEST_CA = """
            -----BEGIN CERTIFICATE-----
            MIIBjTCCATOgAwIBAgIUeGs1QE7Hwbp0SY95KTLTmAUdmWcwCgYIKoZIzj0EAwIw
            GzEZMBcGA1UEAwwQb21uaXRlcm0tdGVzdC1jYTAgFw0yNjExMDIxNTA3NDVaGA8y
            MTI2MTAwOTE1MDc0NVowGzEZMBcGA1UEAwwQb21uaXRlcm0tdGVzdC1jYTBZMBMG
            ByqGSM49AgEGCCqGSM49AwEHA0IABGIIqpf80+Z7qPhKlHJzywWeTrtB4b0Wa8gn
            YpMlp6mb7zvYRgHcOZAAGtq0yXRJCJbsMDpTjKDkJTptIcV2zNSjUzBRMB0GA1Ud
            DgQWBBRDBsl6qkFHgg0fmkOcTgos+f6b/zAfBgNVHSMEGDAWgBRDBsl6qkFHgg0f
            mkOcTgos+f6b/zAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIQCj
            7QSpyxlk7a6bXY9Oz3mx9hIOYVXv5SLkOqLd6DKMmQIgXvAUr/JmowZ/dXS3lCcl
            3TTjcxzPH/VlFRtEEP25i8o=
            -----END CERTIFICATE-----
        """.trimIndent()
    }
}
