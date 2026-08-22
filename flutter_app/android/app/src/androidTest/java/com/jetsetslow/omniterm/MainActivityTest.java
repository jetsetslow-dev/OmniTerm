package com.jetsetslow.omniterm;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

/**
 * The instrumentation entry point Patrol drives.
 *
 * Patrol's native half runs as an ordinary Android instrumentation test; the Dart half runs inside
 * the app. This class is the seam, and exists so flows can drive things the widget tests cannot
 * reach at all — the notification-permission dialog, the biometric prompt, the foreground-service
 * notification and the system file picker.
 *
 * Every Dart test is enumerated into its own JUnit case rather than one case running them all.
 * That is what makes `clearPackageData` mean anything: each flow starts from a fresh install
 * instead of inheriting whatever the last one left behind — the trap that cost session 52 several
 * device runs.
 */
@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    private final String dartTestName;

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}
