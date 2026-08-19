package dev.op13perf.tile

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class PerfTileService : TileService() {

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val generation = AtomicInteger(0)
    private var lastGood: TileSnapshot? = null

    override fun onDestroy() {
        io.shutdownNow()
        super.onDestroy()
    }

    override fun onStartListening() {
        super.onStartListening()
        // 每次下拉都现读设备，不用内存缓存当真相：
        // 用户可能刚从 Magisk Action 或 Termux 快捷方式切过档。
        runOp { RootShell.readState() }
    }

    override fun onClick() {
        super.onClick()
        runOp {
            val snap = RootShell.cycle()
            if (shouldOpenHelp(snap)) {
                main.post { openHelp() }
            }
            snap
        }
    }

    private fun runOp(op: () -> TileSnapshot) {
        val id = generation.incrementAndGet()
        io.execute {
            val snap = try {
                op()
            } catch (_: InterruptedException) {
                return@execute
            } catch (_: Exception) {
                TileSnapshot(error = RootError.UNKNOWN)
            }
            main.post {
                if (id != generation.get()) return@post
                applySnapshot(snap)
            }
        }
    }

    private fun applySnapshot(snap: TileSnapshot) {
        val tile = qsTile ?: return
        if (snap.error == null && snap.level != null) {
            lastGood = snap
        }

        val label = snap.displayName.ifBlank {
            lastGood?.displayName?.ifBlank { null } ?: getString(R.string.tile_label)
        }
        val subtitle = subtitleOf(snap)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.label = label
            tile.subtitle = subtitle
        } else {
            tile.label = if (subtitle.isNullOrBlank()) label else "$label · $subtitle"
        }

        val shownLevel = snap.level ?: lastGood?.level ?: 0
        tile.state = if (shownLevel == 0) Tile.STATE_INACTIVE else Tile.STATE_ACTIVE
        tile.updateTile()
    }

    private fun subtitleOf(snap: TileSnapshot): String? {
        snap.error?.let { return errorText(it) }
        val junc = snap.junc
        val held = snap.held
        return when {
            !junc.isNullOrBlank() && !held.isNullOrBlank() -> "$junc · held=$held"
            !junc.isNullOrBlank() -> junc
            !held.isNullOrBlank() -> "held=$held"
            else -> null
        }
    }

    private fun errorText(err: RootError): String = when (err) {
        RootError.TIMEOUT -> getString(R.string.err_timeout)
        RootError.DENIED -> getString(R.string.err_denied)
        RootError.NOT_FOUND -> getString(R.string.err_not_found)
        RootError.NO_MODULE -> getString(R.string.err_no_module)
        RootError.UNKNOWN -> getString(R.string.err_unknown)
    }

    /**
     * 超时多半是 Magisk 授权窗还在前台，再开 Activity 会盖住它。
     * 拒绝会被 Magisk 记住、之后不再弹窗，必须给人一条可执行的路。
     */
    private fun shouldOpenHelp(snap: TileSnapshot): Boolean {
        val e = snap.error ?: return false
        return e == RootError.DENIED || e == RootError.NOT_FOUND
    }

    private fun openHelp() {
        val intent = Intent(this, RootHelpActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                val pi = PendingIntent.getActivity(
                    this,
                    0,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                startActivityAndCollapse(pi)
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        } catch (_: Exception) {
            // 服务已停就放弃，用户下次再点。
        }
    }
}
