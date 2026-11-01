package com.jetsetslow.omniterm

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import es.antonborri.home_widget.HomeWidgetPlugin

/** Per-widget host picker, matching the Kotlin app's reconfigurable widget. */
class OmniTermWidgetConfigActivity : Activity() {
    private var widgetId = AppWidgetManager.INVALID_APPWIDGET_ID

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId = intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        )
        if (widgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }

        val rows = selectedWidgetRows(this, widgetId, HomeWidgetPlugin.getData(this))
        val allRows = selectedWidgetRows(
            this,
            AppWidgetManager.INVALID_APPWIDGET_ID,
            HomeWidgetPlugin.getData(this),
        )
        val initiallySelected = rows.map { it.optInt("id") }.toSet()
        val checks = mutableMapOf<Int, CheckBox>()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(20), dp(20), dp(20))
            setBackgroundColor(Color.rgb(11, 18, 32))
        }
        root.addView(TextView(this).apply {
            text = "Select servers for widget"
            textSize = 20f
            setTextColor(Color.WHITE)
            setPadding(0, 0, 0, dp(12))
        })

        val list = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        if (allRows.isEmpty()) {
            list.addView(TextView(this).apply {
                text = "No saved hosts yet. Add one in OmniTerm, then reconfigure this widget."
                setTextColor(Color.LTGRAY)
                setPadding(0, dp(20), 0, dp(20))
            })
        } else {
            allRows.forEach { row ->
                val id = row.optInt("id")
                list.addView(CheckBox(this).apply {
                    text = row.optString("name").ifBlank { row.optString("host", "Host") }
                    isChecked = id in initiallySelected
                    setTextColor(Color.WHITE)
                    setPadding(0, dp(6), 0, dp(6))
                    checks[id] = this
                })
            }
        }
        root.addView(
            ScrollView(this).apply { addView(list) },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                1f,
            ),
        )
        root.addView(Button(this).apply {
            text = "Save"
            setOnClickListener {
                val chosen = checks.filterValues { it.isChecked }.keys
                if (checks.isNotEmpty() && chosen.isEmpty()) return@setOnClickListener
                getSharedPreferences("widget_prefs", Context.MODE_PRIVATE)
                    .edit()
                    .putStringSet("widget_$widgetId", chosen.map(Int::toString).toSet())
                    .apply()
                OmniTermWidgetReceiver().onUpdate(
                    this@OmniTermWidgetConfigActivity,
                    AppWidgetManager.getInstance(this@OmniTermWidgetConfigActivity),
                    intArrayOf(widgetId),
                    HomeWidgetPlugin.getData(this@OmniTermWidgetConfigActivity),
                )
                setResult(
                    RESULT_OK,
                    Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId),
                )
                finish()
            }
        })
        setContentView(root)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
