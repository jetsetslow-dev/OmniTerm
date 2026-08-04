package com.jetsetslow.omniterm;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.runner.RunWith;
import pl.leancode.patrol.PatrolJUnitRunner;

/**
 * The instrumentation entry point Patrol drives.
 *
 * Patrol's native half runs as an ordinary Android instrumentation test; the Dart half runs inside
 * the app. This class is the seam, and exists so flows can drive things the widget tests cannot
 * reach at all — the notification-permission dialog, the biometric prompt, the foreground-service
 * notification and the system file picker.
 */
@RunWith(PatrolJUnitRunner.class)
public class MainActivityTest {
    @org.junit.BeforeClass
    public static void setUp() {
        PatrolJUnitRunner instrumentation =
                (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
    }
}
