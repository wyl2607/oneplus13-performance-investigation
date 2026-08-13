# GROK-REPORT-ZH

Work in `C:\Users\yzwdm\oneplus13-cpufreq-bouncing`. No `adb`, no `gh`, no `git push`.

## Files created

- `README.zh-CN.md` — full translation of `README.md`
- `docs/FOR-USERS.zh-CN.md` — full translation of `docs/FOR-USERS.md`
- `GROK-REPORT-ZH.md` — this file; do not commit

## Files edited (language-switch line only)

- `README.md` — one line at the top: `[English](README.md) · [简体中文](README.zh-CN.md)`
- `docs/FOR-USERS.md` — matching line: `[English](FOR-USERS.md) · [简体中文](FOR-USERS.zh-CN.md)`

Each Chinese file has the same switch line, then one italic note that the English text is authoritative and that only these two files are translated.

Relative links inside the Chinese files point at the Chinese twin where one exists (`FOR-USERS.zh-CN.md`, `README.zh-CN.md`) and at the English original otherwise (`DATA.md`, `METHODOLOGY.md`, `mitigation/README.md`, etc.).

## Terms I was unsure how to render

These are the ones that do not have a single obvious Chinese equivalent. I picked one and stayed with it.

| English | Chosen Chinese | Why / residual doubt |
|---|---|---|
| Snapdragon 8 Elite | 骁龙 8 至尊版 | Official CN product name. The English identifier is not repeated except as SM8750. |
| landing freq | 落地频率 | Engineering slang; “收敛频率 / 最终频率” would also work. Used because the table treats it as a term. |
| spread (2.4% / 11.5% / 31%) | 波幅 | Statistical “离散” felt too academic for the owner-facing page. |
| skin / shell | 外壳温度 | Per the packet. Android’s “skin” and the shell sensor are collapsed into one word. |
| characterised | 刻画 | “定性过 / 摸清过” were alternatives. Researcher-section diction. |
| demotes | 把…地位降了下来 | Awkward. The English is also slightly figurative. |
| per-cycle / duty-cycle | 每周期 / 占空比 | Standard, but 占空比 is more radio/PSU than scheduler. |
| CN→OOS | 国行→OOS | OOS left as the identifier. |
| active cooling | 主动散热 | The DATA.md experiment (fan / external cooling). Not “主动式温控”. |
| lever | 杠杆 | Calque-adjacent, but the sentence is already figurative. |
| PII | 个人身份信息 | Spelled out; the owner audience may not know the acronym. |
| watchdog | 看门狗 | Kept; common enough in this crowd. |
| gold-plus | left in English | It is glossing the identifier `skip_goplus_enabled`. |
| cook the device | 把设备烤熟 | Tone match, not a literal thermal claim. |
| The short version | 先说结论 | Not a calque of “short version”; the function of the section. |
| Your options | 你能怎么做 | Same. |
| Scaled to its rated clock | 按额定频率等比换算 | See ambiguity below. |
| has acted | 已经动手过 | Informal; “已经生效过” is colder. |
| unlock full power | 解锁全部性能 | Avoided 满血, which is more hype than the English. |
| free win | 白捡的便宜 | Tone match. |
| one-shot boot script | 一次性开机脚本 | Fine, slightly stiff. |

HIGHLY LIKELY does not appear in either source file. The nearby hedges that do appear (`almost certainly`, `Expected yes`, `not yet measured`, `Not proven`, `most plausibly`, `very likely`, `plausibly`) were kept as 几乎可以肯定 / 预期会 / 尚未测量 / 尚未证实 / 最说得通 / 也很可能 / 也说得通会覆盖.

## Where the English was ambiguous

- **“Scaled to its rated clock the device measured slightly faster than a healthy comparison unit.”** The English does not say whether the *score* was scaled, or the *clock*, or both. I translated the operation as 按额定频率等比换算 and did not fill in a method. The same sentence appears in both files; same rendering.
- **Question 1 is written as an open question whose body then says the source is identified.** I did not tidy this. The Chinese heading is still “谁把 `uclamp.max = 466` 写到跑分工作线程上？”, and the body still says 来源已确认.
- **“The 2 681 / 8 846 figure underpinning question 1”** still points at question 1 after that question has been answered. Kept.
- **`8.0%` in README vs `8%` in FOR-USERS** for the same measurement. Each file keeps its own form.
- **“p95” vs “95th percentile”.** README keeps `p95` as an identifier (`87 °C p95`). FOR-USERS spells it 95 分位, because the English spells it out.
- **The CFB write-up and the `task_overload` write-up sit next to each other as a historical record**, including the later demotion of the prime-cluster ceiling. I did not reconcile them.
- **“neither figure is a healthy baseline”** refers to the +30% / +19% GB7 pair. The Chinese keeps the same pointer (“这两个数字”) without naming them again.
- **“the residual above”** in the `oiface_fg` paragraph points forward to a residual that is only defined later. Kept as 上文残差, which is slightly wrong in reading order and matches the English.
- **“Setting `enable=0`”** is a noun phrase used as a subject. Rendered 设 `enable=0`, not a paraphrase of the sysfs write.

No number was invented or re-derived. Code fences are byte-identical to the English. The two English files were not otherwise touched.
