package com.jetsetslow.omniterm.ui

import android.app.Activity

/** Open-source flavor: no Play Services, so the in-app review nudge is a no-op. */
fun flavorRequestInAppReview(activity: Activity) {
    // Intentionally empty — there is no store to review on outside Google Play.
}
