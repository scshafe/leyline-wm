# Independent regression oracles

These frozen scene/model answers keep their original bytes; `fixtures.sha256.json`
pins every file. They are test inputs, never runtime authority. Each check runs
the production model code through the developer runner (`bin/leylined-tests`).

`model-tests.sh` runs each fixture's `.fn` (grid cells/validity, display bags,
recursive targets, tileability, display assignment, minimum learning and
even-reclaim prune) and compares the frozen `.expect`. `navigation-tests.sh`
ranks the frozen scenes in every direction. `test_largest_first_insertion.py`
checks insertion geometry, conservation, batch/single equality, refusals and
managed overload of newcomers with no feasible cut.

The prune expectations were frozen from the retired jq reference engine before
it was removed. All checks fail on a missing corpus or runner.
