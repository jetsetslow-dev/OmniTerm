package com.jetsetslow.omniterm.data

import androidx.room.testing.MigrationTestHelper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppDatabaseMigrationTest {
    @get:Rule
    val helper = MigrationTestHelper(
        InstrumentationRegistry.getInstrumentation(),
        AppDatabase::class.java,
    )

    @Test
    fun everyExportedSchemaFromVersionEightMigratesToCurrent() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        for (startVersion in 8 until 18) {
            val databaseName = "migration-$startVersion-to-18"
            context.deleteDatabase(databaseName)
            helper.createDatabase(databaseName, startVersion).close()
            helper.runMigrationsAndValidate(
                databaseName,
                18,
                true,
                *AppDatabase.ALL_MIGRATIONS,
            ).close()
            context.deleteDatabase(databaseName)
        }
    }
}
