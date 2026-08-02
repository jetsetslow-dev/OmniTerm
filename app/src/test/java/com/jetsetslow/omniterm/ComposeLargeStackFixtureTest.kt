package com.jetsetslow.omniterm

import com.jetsetslow.omniterm.ui.parseDockerComposeYaml
import com.jetsetslow.omniterm.ui.renderComposeYaml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test

/**
 * Guards the committed large-stack fixture.
 *
 * The fixture is an input to a device stress test that is expensive and opt-in, so a silent drift
 * would surface as a confusing instrumentation failure hours later, on one machine. These checks are
 * plain JVM tests: they run in the default gate, on every push, in milliseconds.
 *
 * To intentionally change the fixture, edit [ComposeLargeStackFixture] and regenerate:
 *
 *   ./gradlew :app:testPlayStoreDebugUnitTest --tests '*ComposeLargeStackFixtureTest*' \
 *     -Domniterm.regenerateFixture=true
 *
 * then commit the regenerated file. Without that flag the fixture is read-only to the build.
 */
class ComposeLargeStackFixtureTest {

    companion object {
        // Regeneration has to happen before ANY test in this class reads the file, and JUnit does
        // not guarantee method order, so it cannot live inside one of the test methods.
        @BeforeClass
        @JvmStatic
        fun regenerateIfRequested() {
            if (System.getProperty("omniterm.regenerateFixture") != "true") return
            val expected = ComposeLargeStackFixture.render()
            val file = ComposeLargeStackFixture.repoFile()
            file.parentFile?.mkdirs()
            file.writeText(expected)
            println("Regenerated ${file.path}: ${expected.length} chars, sha256=${ComposeLargeStackFixture.sha256(expected)}")
        }
    }

    @Test
    fun committedFixtureMatchesTheGenerator() {
        val expected = ComposeLargeStackFixture.render()
        val actual = ComposeLargeStackFixture.repoFile().readText()
        // Compare the digest first: a 380 KB mismatch printed as a JUnit diff is unreadable, and the
        // line report below is what actually tells you where the drift is.
        if (ComposeLargeStackFixture.sha256(actual) != ComposeLargeStackFixture.sha256(expected)) {
            val a = actual.lines()
            val e = expected.lines()
            val firstDiff = (0 until minOf(a.size, e.size)).firstOrNull { a[it] != e[it] }
            error(
                "Committed fixture no longer matches ComposeLargeStackFixture.\n" +
                    "  committed: ${actual.length} chars, ${a.size} lines\n" +
                    "  generated: ${expected.length} chars, ${e.size} lines\n" +
                    (firstDiff?.let { "  first differing line ${it + 1}:\n    committed: ${a[it]}\n    generated: ${e[it]}\n" } ?: "") +
                    "Regenerate with -Domniterm.regenerateFixture=true and commit the result.",
            )
        }
    }

    @Test
    fun fixtureMeetsTheStressTestPreconditions() {
        val yaml = ComposeLargeStackFixture.repoFile().readText()
        // The device test asserts both of these before it starts; failing here names the cause.
        assertTrue(
            "fixture must cross the highlighter cutoff, was ${yaml.length}",
            yaml.length > 300_000,
        )
        val draft = parseDockerComposeYaml(
            yaml = yaml,
            projectName = "omniterm-large-stack",
            workingDir = ComposeLargeStackFixture.CONTAINER_PATH.substringBeforeLast('/'),
            fileName = "compose.yml",
            composeFilePath = ComposeLargeStackFixture.CONTAINER_PATH,
            composeConfigFiles = ComposeLargeStackFixture.CONTAINER_PATH,
            runtime = "docker",
        )
        assertEquals(ComposeLargeStackFixture.SERVICE_COUNT, draft.services.size)
        assertEquals("service-000", draft.services.first().serviceName)
    }

    @Test
    fun fixtureSurvivesAnUneditedSaveUnchanged() {
        val yaml = ComposeLargeStackFixture.repoFile().readText()
        val draft = parseDockerComposeYaml(
            yaml = yaml,
            projectName = "omniterm-large-stack",
            workingDir = ComposeLargeStackFixture.CONTAINER_PATH.substringBeforeLast('/'),
            fileName = "compose.yml",
            composeFilePath = ComposeLargeStackFixture.CONTAINER_PATH,
            composeConfigFiles = ComposeLargeStackFixture.CONTAINER_PATH,
            runtime = "docker",
        )
        // Same invariant the device test spends minutes reaching, checked here in milliseconds.
        assertEquals(yaml.trimEnd(), renderComposeYaml(draft, draft).trimEnd())
    }
}
