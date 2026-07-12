package com.jetsetslow.omniterm.ui

import android.app.Activity
import com.google.android.play.core.review.ReviewManagerFactory

/**
 * Play Store flavor: ask Play to show the in-app review sheet. Play itself decides whether the
 * dialog actually appears (the API is quota-managed and gives no signal either way), so this is
 * fire-and-forget — failures are silently ignored rather than surfaced to the user.
 */
fun flavorRequestInAppReview(activity: Activity) {
    val manager = ReviewManagerFactory.create(activity)
    manager.requestReviewFlow().addOnSuccessListener { info ->
        if (!activity.isFinishing && !activity.isDestroyed) {
            manager.launchReviewFlow(activity, info)
        }
    }
}
