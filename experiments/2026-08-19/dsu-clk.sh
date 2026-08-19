#!/system/bin/sh
# Locate the DSU / cluster clocks in clk_summary. Get the column layout first
# instead of guessing which field is the rate.
S=/sys/kernel/debug/clk/clk_summary

echo "=== header + first rows ==="
head -4 $S

echo
echo "=== clock names (col 1), any containing cpu, cpuss, apss, dsu, gold, prime ==="
awk '{n=$1; l=tolower(n); if (l ~ /cpu/ || l ~ /apss/ || l ~ /dsu/ || l ~ /gold/ || l ~ /prime/ || l ~ /silver/) print}' $S | head -25

echo
echo "=== all clock dirs under /sys/kernel/debug/clk matching those names ==="
ls /sys/kernel/debug/clk/ | grep -iE 'cpu|apss|dsu|gold|prime|silver' | head -25

echo
echo "=== osm / epss (where Qualcomm puts cluster+DSU DCVS) ==="
ls /sys/kernel/debug/clk/ | grep -iE 'osm|epss|lut' | head -20
find /sys/kernel/debug -maxdepth 2 -iname '*epss*' -o -maxdepth 2 -iname '*osm*' 2>/dev/null | head -10

echo
echo "=== total clocks listed ==="
wc -l < $S
echo "=== DONE ==="
