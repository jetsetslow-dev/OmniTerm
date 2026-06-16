package com.jetsetslow.omniterm

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ExampleRobolectricTest {

  @Test
  fun `read string from context`() {
    assumeFalse("Robolectric native runtime is not available on Linux aarch64 hosts.", isLinuxAarch64())
    val context = ApplicationProvider.getApplicationContext<Context>()
    val appName = context.getString(R.string.app_name)
    assertEquals("OmniTerm", appName)
  }

  private fun isLinuxAarch64(): Boolean =
    System.getProperty("os.name").equals("Linux", ignoreCase = true) &&
      System.getProperty("os.arch").equals("aarch64", ignoreCase = true)
}
