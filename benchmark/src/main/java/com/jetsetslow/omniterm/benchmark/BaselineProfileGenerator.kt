package com.jetsetslow.omniterm.benchmark

import androidx.benchmark.macro.junit4.BaselineProfileRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BaselineProfileGenerator {

    @get:Rule
    val baselineProfileRule = BaselineProfileRule()

    @Test
    fun generate() {
        baselineProfileRule.collect(
            packageName = "com.jetsetslow.omniterm.app",
            profileBlock = {
                // This block defines the critical user journey for the app
                pressHome()
                startActivityAndWait()
                // You can add more UiAutomator interactions here to record
                // the paths executed during scrolling, navigation, etc.
            }
        )
    }
}
