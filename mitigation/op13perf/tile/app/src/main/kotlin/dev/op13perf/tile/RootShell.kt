package dev.op13perf.tile

import java.io.File
import java.io.IOException
import java.io.InputStreamReader
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit

internal enum class RootError {
    TIMEOUT,
    DENIED,
    NOT_FOUND,
    NO_MODULE,
    UNKNOWN
}

internal data class TileSnapshot(
    val level: Int? = null,
    val name: String? = null,
    val held: String? = null,
    val junc: String? = null,
    val error: RootError? = null
) {
    val displayName: String
        get() {
            if (!name.isNullOrBlank()) return name.trim()
            val lv = level ?: return ""
            return fallbackLevelName(lv)
        }
}

/**
 * 档位名的唯一生成处是模块里的 desc.sh（lvlname）。
 * 这里的中文名只在 su 读不到 desc.sh 时回退使用，避免再手写第四份
 * 且与 desc.sh 漂移（本项目已经为此付出过代价）。
 * 若 desc.sh 改名，这里不会跟着变——这是回退，不是第二真相源。
 */
internal fun fallbackLevelName(level: Int): String = when (level) {
    1 -> "日常档"
    2 -> "高性能档"
    3 -> "极限档"
    else -> "已关闭"
}

/**
 * 通过 su -c 读写 /data/adb/op13perf。
 * 必须在后台线程调用：su 在等 Magisk 授权窗时会阻塞。
 */
internal object RootShell {

    /**
     * Magisk 首次弹窗时用户可能还在读；过短会把还在等授权的 su 杀掉。
     * 切档脚本自己还要 sleep 2.5 s 等 daemon 刷新 status，也算在这里面。
     */
    const val TIMEOUT_MS = 12_000L

    fun readState(): TileSnapshot = interpret(runSu(READ_SCRIPT))

    fun cycle(): TileSnapshot = interpret(runSu(CYCLE_SCRIPT))

    private sealed class SuOutcome {
        data class Ok(val output: String) : SuOutcome()
        data class Failed(val error: RootError, val output: String = "") : SuOutcome()
    }

    private fun interpret(outcome: SuOutcome): TileSnapshot {
        return when (outcome) {
            is SuOutcome.Failed -> {
                val parsed = parse(outcome.output)
                if (parsed.error == RootError.NO_MODULE) parsed
                else TileSnapshot(error = outcome.error)
            }
            is SuOutcome.Ok -> parse(outcome.output)
        }
    }

    private fun parse(output: String): TileSnapshot {
        var level: Int? = null
        var name: String? = null
        var held: String? = null
        var junc: String? = null
        var error: RootError? = null
        for (raw in output.lineSequence()) {
            val line = raw.trim()
            val eq = line.indexOf('=')
            if (eq <= 0) continue
            val k = line.substring(0, eq)
            val v = line.substring(eq + 1)
            when (k) {
                "level" -> level = v.toIntOrNull()
                "name" -> name = v.ifBlank { null }
                "held" -> held = v.ifBlank { null }
                "junc" -> junc = v.ifBlank { null }
                "error" -> if (v == "no_module") error = RootError.NO_MODULE
            }
        }
        if (error != null) return TileSnapshot(error = error)
        if (level == null) return TileSnapshot(error = RootError.UNKNOWN)
        return TileSnapshot(level = level, name = name, held = held, junc = junc)
    }

    private fun runSu(command: String): SuOutcome {
        val proc = try {
            startSu(command)
        } catch (_: IOException) {
            return SuOutcome.Failed(RootError.NOT_FOUND)
        }

        val buf = StringBuilder()
        val reader = Thread {
            InputStreamReader(proc.inputStream, StandardCharsets.UTF_8).use { r ->
                val cbuf = CharArray(4096)
                while (true) {
                    val n = try {
                        r.read(cbuf)
                    } catch (_: IOException) {
                        break
                    }
                    if (n <= 0) break
                    buf.append(cbuf, 0, n)
                }
            }
        }.apply {
            isDaemon = true
            start()
        }

        val finished = try {
            proc.waitFor(TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: InterruptedException) {
            proc.destroyForcibly()
            Thread.currentThread().interrupt()
            return SuOutcome.Failed(RootError.TIMEOUT)
        }

        if (!finished) {
            proc.destroyForcibly()
            try {
                reader.join(500)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            return SuOutcome.Failed(RootError.TIMEOUT)
        }
        try {
            reader.join(1000)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        val code = proc.exitValue()
        val out = buf.toString()
        if (code != 0) return SuOutcome.Failed(RootError.DENIED, out)
        return SuOutcome.Ok(out)
    }

    /**
     * 先走 PATH 上的 su（Magisk 通常拦这个），失败再试真机实测路径。
     * 只有「进程根本起不来」才试下一个；超时或拒绝不再连试，避免每个都卡满 12 秒。
     */
    private fun startSu(command: String): Process {
        var last: IOException? = null
        for (bin in SU_CANDIDATES) {
            if (bin.startsWith("/") && !File(bin).exists()) continue
            try {
                return ProcessBuilder(bin, "-c", command)
                    .redirectErrorStream(true)
                    .start()
            } catch (e: IOException) {
                last = e
            }
        }
        throw last ?: IOException("su not found")
    }

    private val SU_CANDIDATES = arrayOf(
        "su",
        "/product/bin/su",
        "/system/bin/su",
        "/system/xbin/su"
    )

    // Kotlin 会插值 $，所有 shell 变量写成 ${'$'}，运行时才是 $VAR。
    private val READ_SCRIPT = """
        STATEDIR=/data/adb/op13perf
        MODDIR=/data/adb/modules/op13perf
        STATE=${'$'}STATEDIR/state
        STATUS=${'$'}STATEDIR/status
        CONF=${'$'}STATEDIR/conf

        # 结温直接读传感器，不从 daemon 的 status 里取：status 只有开着档时才写，
        # 0 档就没有温度可显示了。索引跨重启会变，所以按 type 找。
        read_junc() {
          for z in /sys/class/thermal/thermal_zone*; do
            read t < "${'$'}z/type" 2>/dev/null || continue
            if [ "${'$'}t" = "cpu-1-1-1" ]; then
              echo "${'$'}(( ${'$'}(cat "${'$'}z/temp") / 1000 ))C"
              return 0
            fi
          done
        }

        if [ ! -d "${'$'}STATEDIR" ] && [ ! -d "${'$'}MODDIR" ]; then
          printf 'error=no_module\n'
          exit 0
        fi

        read cur < "${'$'}STATE" 2>/dev/null || cur=0
        case "${'$'}cur" in 1|2|3) : ;; *) cur=0 ;; esac

        name=
        [ -f "${'$'}CONF" ] && . "${'$'}CONF"
        if [ -f "${'$'}MODDIR/desc.sh" ]; then
          . "${'$'}MODDIR/desc.sh"
          name=${'$'}(lvlname "${'$'}cur")
        fi

        held=
        if [ -f "${'$'}STATUS" ]; then
          for w in ${'$'}(cat "${'$'}STATUS"); do
            case "${'$'}w" in
              held=*) held=${'$'}{w#held=} ;;
            esac
          done
        fi

        junc=${'$'}(read_junc)

        printf 'level=%s\nname=%s\nheld=%s\njunc=%s\n' "${'$'}cur" "${'$'}name" "${'$'}held" "${'$'}junc"
    """.trimIndent()

    private val CYCLE_SCRIPT = """
        STATEDIR=/data/adb/op13perf
        MODDIR=/data/adb/modules/op13perf
        STATE=${'$'}STATEDIR/state
        STATUS=${'$'}STATEDIR/status
        CONF=${'$'}STATEDIR/conf
        PIDF=${'$'}STATEDIR/pid

        # 结温直接读传感器，不从 daemon 的 status 里取：status 只有开着档时才写，
        # 0 档就没有温度可显示了。索引跨重启会变，所以按 type 找。
        read_junc() {
          for z in /sys/class/thermal/thermal_zone*; do
            read t < "${'$'}z/type" 2>/dev/null || continue
            if [ "${'$'}t" = "cpu-1-1-1" ]; then
              echo "${'$'}(( ${'$'}(cat "${'$'}z/temp") / 1000 ))C"
              return 0
            fi
          done
        }

        if [ ! -d "${'$'}MODDIR" ]; then
          printf 'error=no_module\n'
          exit 0
        fi

        mkdir -p "${'$'}STATEDIR"

        alive() {
          [ -f "${'$'}PIDF" ] || return 1
          read p < "${'$'}PIDF" 2>/dev/null || return 1
          [ -d "/proc/${'$'}p" ] || return 1
          tr '\0' ' ' < "/proc/${'$'}p/cmdline" 2>/dev/null | grep -q perfd.sh
        }
        if ! alive; then
          if [ -x "${'$'}MODDIR/perfd.sh" ]; then
            nohup "${'$'}MODDIR/perfd.sh" >/dev/null 2>&1 &
            echo ${'$'}! > "${'$'}PIDF"
          fi
        fi

        read cur < "${'$'}STATE" 2>/dev/null || cur=0
        case "${'$'}cur" in 1|2|3) : ;; *) cur=0 ;; esac
        next=${'$'}(( (cur + 1) % 4 ))
        echo "${'$'}next" > "${'$'}STATE"

        name=
        [ -f "${'$'}CONF" ] && . "${'$'}CONF"
        if [ -f "${'$'}MODDIR/desc.sh" ]; then
          . "${'$'}MODDIR/desc.sh"
          name=${'$'}(lvlname "${'$'}next")
        fi

        # daemon 每约 2 秒才刷新一次 status，写完 state 立刻读到的 held 属于上一档。
        # 等一轮再读，否则磁贴显示的状态永远滞后一次切换。
        sleep 2.5

        held=
        if [ -f "${'$'}STATUS" ]; then
          for w in ${'$'}(cat "${'$'}STATUS"); do
            case "${'$'}w" in
              held=*) held=${'$'}{w#held=} ;;
            esac
          done
        fi

        junc=${'$'}(read_junc)

        printf 'level=%s\nname=%s\nheld=%s\njunc=%s\n' "${'$'}next" "${'$'}name" "${'$'}held" "${'$'}junc"
    """.trimIndent()
}
