# Independent regression oracles

These frozen scene/model answers retain their original bytes. `fixtures.sha256.json`
pins every relocated fixture. They are test inputs, never runtime authority.

`frozen-models.sh` evaluates pure JQ fixtures; `arrangement-model-tests.sh` compares
native targets, bridge, author, prune, adopt and function seams against JQ and frozen
goldens; `navigation-tests.sh` compares native/JQ navigation to frozen scenes;
`landed-equiv.sh` catches write-echo false convergence; `test_largest_first_insertion.py`
checks geometry, conservation and native/JQ equality. All required checks fail on
missing corpus or binary. The JQ module closure is private to these tests.
