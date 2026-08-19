package dev.op13perf.tile

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

/** 极简说明页。拿不到 root 时从磁贴点开，不进桌面启动器。 */
class RootHelpActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (24 * resources.displayMetrics.density).toInt()
        val text = TextView(this).apply {
            this.text = getString(R.string.root_help_body)
            textSize = 16f
            setPadding(pad, pad, pad, pad)
            setTextIsSelectable(true)
        }
        setContentView(ScrollView(this).apply { addView(text) })
        title = getString(R.string.root_help_title)
    }
}
