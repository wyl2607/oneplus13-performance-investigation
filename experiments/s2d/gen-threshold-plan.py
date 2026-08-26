#!/usr/bin/env python3
"""Generate experiments/s2d/threshold-plan.csv: randomized complete block,
7 arms (uclamp.min in {0,448,464,480,496,504,512}) x 4 blocks, one fixed
seed for the whole plan, each block independently shuffled off the same
seeded RNG stream -- same method as experiments/s2c/ladder-plan.csv.
"""
import csv
import random

SEED = 20260826
ARMS = [0, 448, 464, 480, 496, 504, 512]
BLOCKS = 4

def main():
    rng = random.Random(SEED)
    rows = []
    for block in range(1, BLOCKS + 1):
        order = ARMS[:]
        rng.shuffle(order)
        for i, umin in enumerate(order, start=1):
            rows.append((block, i, umin, SEED))
    with open("experiments/s2d/threshold-plan.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["block", "order", "uclamp_min", "seed"])
        w.writerows(rows)

if __name__ == "__main__":
    main()
