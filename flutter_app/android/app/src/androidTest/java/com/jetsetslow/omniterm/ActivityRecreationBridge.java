package com.jetsetslow.omniterm;

import android.app.Activity;
import android.app.NotificationManager;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.WindowManager;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.runner.lifecycle.ActivityLifecycleCallback;
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry;
import androidx.test.runner.lifecycle.Stage;
import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/** Instrumentation-only control: recreate while Dart still owns a live fixture shell. */
final class ActivityRecreationBridge implements AutoCloseable {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final MethodChannel channel;
    private ActivityLifecycleCallback callback;
    private Runnable timeout;

    ActivityRecreationBridge() throws ReflectiveOperationException {
        if (Build.VERSION.SDK_INT >= 33) {
            InstrumentationRegistry.getInstrumentation().getUiAutomation().grantRuntimePermission(
                    resumed().getPackageName(), android.Manifest.permission.POST_NOTIFICATIONS);
        }
        channel = new MethodChannel(engine(resumed()), "omniterm/test/activity_lifecycle");
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "captureKeyBar":
                        // Only the opted-in disposable fixture disables its secure window. Keep
                        // captures in app-private cache; no production screenshot channel exists.
                        String name = call.argument("name");
                        if (name == null || !name.matches("[a-z-]+") || secure(resumed())) {
                            throw new IllegalArgumentException("Invalid or protected fixture capture");
                        }
                        java.io.File directory = new java.io.File(resumed().getCacheDir(), "parity");
                        if (!directory.isDirectory() && !directory.mkdirs()) {
                            throw new java.io.IOException("Cannot create fixture capture directory");
                        }
                        android.graphics.Bitmap screenshot = InstrumentationRegistry
                                .getInstrumentation().getUiAutomation().takeScreenshot();
                        if (screenshot == null) throw new java.io.IOException("No screenshot");
                        try (java.io.FileOutputStream output = new java.io.FileOutputStream(
                                new java.io.File(directory, name + ".png"))) {
                            result.success(screenshot.compress(
                                    android.graphics.Bitmap.CompressFormat.PNG, 100, output));
                        } finally {
                            screenshot.recycle();
                        }
                        break;
                    case "biometricRequestId":
                        // The system prompt is capture-protected. Observe the currently active
                        // hardware operation, not stale history or the application's pending flag.
                        try (android.os.ParcelFileDescriptor.AutoCloseInputStream input =
                                new android.os.ParcelFileDescriptor.AutoCloseInputStream(
                                        InstrumentationRegistry.getInstrumentation().getUiAutomation()
                                                .executeShellCommand("dumpsys fingerprint"))) {
                            String state = new String(input.readAllBytes(), StandardCharsets.UTF_8);
                            java.util.regex.Matcher match = Pattern.compile(
                                    "Current operation:.*FingerprintAuthenticationClient.*owner=" +
                                    Pattern.quote(resumed().getPackageName()) + ",.*requestId=(\\d+)")
                                    .matcher(state);
                            result.success(match.find() ? Integer.parseInt(match.group(1)) : null);
                        }
                        break;
                    case "biometricBranding":
                        android.content.pm.PackageManager packages = resumed().getPackageManager();
                        result.success(resumed().getApplicationInfo().icon == R.mipmap.ic_system_brand &&
                                packages.getActivityInfo(resumed().getComponentName(), 0).icon == R.mipmap.ic_launcher &&
                                packages.getApplicationIcon(resumed().getApplicationInfo())
                                        instanceof android.graphics.drawable.BitmapDrawable);
                        break;
                    case "recreate":
                        recreate(result, false);
                        break;
                    case "finishAndRelaunch":
                        recreate(result, true);
                        break;
                    case "externalIntent":
                        resumed().onNewIntent(new Intent(Intent.ACTION_VIEW,
                                Uri.parse("omniterm://notification/network")));
                        result.success(null);
                        break;
                    case "resumeSession":
                    case "disconnectSession":
                        String title = call.argument("title");
                        android.app.PendingIntent resume = null;
                        for (android.service.notification.StatusBarNotification notification :
                                resumed().getSystemService(NotificationManager.class)
                                        .getActiveNotifications()) {
                            if (title.contentEquals(notification.getNotification().extras
                                    .getCharSequence(android.app.Notification.EXTRA_TITLE, ""))) {
                                if (resume != null) throw new IllegalStateException(
                                        "More than one fixture session notification");
                                if (call.method.equals("resumeSession")) {
                                    resume = notification.getNotification().contentIntent;
                                } else {
                                    for (android.app.Notification.Action action :
                                            notification.getNotification().actions) {
                                        if ("Disconnect".contentEquals(action.title)) {
                                            resume = action.actionIntent;
                                        }
                                    }
                                }
                            }
                        }
                        if (resume == null) throw new IllegalStateException(
                                "No notification for the live fixture session");
                        // Send the actual PendingIntent the service posted. Reconstructing one
                        // here could conceal a mismatch between its payload and the consumer.
                        resume.send();
                        result.success(true);
                        break;
                    default:
                        result.notImplemented();
                }
            } catch (Exception error) {
                result.error("lifecycle_control", error.toString(), null);
            }
        });
    }

    private void recreate(MethodChannel.Result result, boolean finishAndRelaunch)
            throws ReflectiveOperationException {
        if (callback != null) throw new IllegalStateException("Recreation already in progress");
        MainActivity original = resumed();
        FlutterEngine before = flutterEngine(original);
        boolean secureBefore = secure(original);
        boolean[] destroyed = {false};
        callback = (activity, stage) -> {
            if (activity == original && stage == Stage.DESTROYED) {
                destroyed[0] = true;
                if (finishAndRelaunch) {
                    original.getApplicationContext().startActivity(
                            new Intent(original, MainActivity.class)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                }
            }
            if (!(activity instanceof MainActivity) || activity == original
                    || stage != Stage.RESUMED) return;
            // Reply after onResume finishes, when the replacement is ready to receive input.
            main.post(() -> {
                if (callback == null) return;
                clearPending();
                try {
                    Map<String, Object> evidence = new HashMap<>();
                    evidence.put("destroyed", destroyed[0]);
                    evidence.put("sameEngine", before == flutterEngine((MainActivity) activity));
                    evidence.put("secureBefore", secureBefore);
                    evidence.put("secureAfter", secure(activity));
                    evidence.put("transition", finishAndRelaunch ? "finish/relaunch" : "recreate");
                    android.util.Log.i("OmniTermRecreation", evidence.toString());
                    result.success(evidence);
                } catch (Exception error) {
                    result.error("lifecycle_control", error.toString(), null);
                }
            });
        };
        ActivityLifecycleMonitorRegistry.getInstance().addLifecycleCallback(callback);
        timeout = () -> {
            clearPending();
            result.error("lifecycle_timeout", "No replacement Activity resumed after recreate", null);
        };
        main.postDelayed(timeout, 10_000L);
        if (finishAndRelaunch) original.finish();
        else original.recreate();
    }

    private static boolean secure(Activity activity) {
        return (activity.getWindow().getAttributes().flags
                & WindowManager.LayoutParams.FLAG_SECURE) != 0;
    }

    private static MainActivity resumed() {
        for (Activity activity : ActivityLifecycleMonitorRegistry.getInstance()
                .getActivitiesInStage(Stage.RESUMED)) {
            if (activity instanceof MainActivity) return (MainActivity) activity;
        }
        throw new IllegalStateException("The fixture app must be resumed");
    }

    private static FlutterEngine flutterEngine(MainActivity activity)
            throws ReflectiveOperationException {
        Method getter = FlutterFragmentActivity.class.getDeclaredMethod("getFlutterEngine");
        getter.setAccessible(true);
        return (FlutterEngine) getter.invoke(activity);
    }

    private static io.flutter.plugin.common.BinaryMessenger engine(MainActivity activity)
            throws ReflectiveOperationException {
        return flutterEngine(activity).getDartExecutor().getBinaryMessenger();
    }

    private void clearPending() {
        if (callback != null) {
            ActivityLifecycleMonitorRegistry.getInstance().removeLifecycleCallback(callback);
            callback = null;
        }
        if (timeout != null) main.removeCallbacks(timeout);
        timeout = null;
    }

    @Override
    public void close() {
        clearPending();
        channel.setMethodCallHandler(null);
    }
}
