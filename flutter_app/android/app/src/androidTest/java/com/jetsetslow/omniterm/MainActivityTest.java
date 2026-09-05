package com.jetsetslow.omniterm;

import static org.junit.Assert.fail;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry;
import androidx.test.runner.lifecycle.Stage;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import org.junit.After;
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
    /**
     * How long {@link #removeTaskLeftBehindByThisTest()} will wait for the activity task to
     * actually be gone. This is a bound on a condition that is polled, not a settling delay: the
     * common case returns on the first poll.
     */
    private static final long TASK_REMOVAL_TIMEOUT_MS = 10_000L;

    private static final long TASK_REMOVAL_POLL_MS = 50L;

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

    /**
     * Takes the activity task down inside this test instead of leaving it to the next one.
     *
     * Under the Android Test Orchestrator each case gets its own process, and the orchestrator
     * starts the next one as soon as this instrumentation reports finished. The activity Patrol
     * launched does not end there: killing the process only marks its ActivityRecord dead, and the
     * *task* survives until the launcher's close transition finishes and ActivityManager reaps it.
     * That reap kills whatever process currently hosts the package.
     *
     * On the 2026-09-03 API-35 core run those two things overlapped. The close transition for the
     * first test's task was created at 12:53:25.487 and finished 691 ms later; the orchestrator had
     * already started the second test's process at 12:53:26.112, so at 12:53:26.215 the reap killed
     * it — `Killing 32290:com.jetsetslow.omniterm.app.flutter (adj 0): remove task`, 44 ms in,
     * before `newApplication()`. Nothing Dart-side ever ran, and the orchestrator recorded
     * `Test instrumentation process crashed` against `the picker is offered the file name the
     * backup should have`. The third case then ran normally, because by then the task was gone.
     *
     * Finishing the task here moves that transition inside this test's own lifetime, where it is
     * something to wait on rather than something to race. The wait is the point: `finishAndRemoveTask()`
     * is asynchronous, so returning without confirming removal would leave exactly the window this
     * closes.
     */
    @After
    public void removeTaskLeftBehindByThisTest() throws Exception {
        InstrumentationRegistry.getInstrumentation()
                .runOnMainSync(
                        () -> {
                            Collection<Activity> live = new ArrayList<>();
                            for (Stage stage : Stage.values()) {
                                if (stage == Stage.DESTROYED) {
                                    continue;
                                }
                                live.addAll(
                                        ActivityLifecycleMonitorRegistry.getInstance()
                                                .getActivitiesInStage(stage));
                            }
                            for (Activity activity : live) {
                                activity.finishAndRemoveTask();
                            }
                        });

        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        ActivityManager activityManager = context.getSystemService(ActivityManager.class);
        long deadline = System.currentTimeMillis() + TASK_REMOVAL_TIMEOUT_MS;
        List<ActivityManager.AppTask> remaining = activityManager.getAppTasks();
        while (!remaining.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(TASK_REMOVAL_POLL_MS);
            remaining = activityManager.getAppTasks();
        }
        if (!remaining.isEmpty()) {
            fail(
                    "The app still owns "
                            + remaining.size()
                            + " task(s) "
                            + TASK_REMOVAL_TIMEOUT_MS
                            + "ms after finishAndRemoveTask(). Leaving one behind lets"
                            + " ActivityManager reap it during the next test's process start and"
                            + " kill that process before it runs.");
        }
    }
}
