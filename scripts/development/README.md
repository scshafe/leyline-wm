# Developer tool setup

`setup-oracle-jq.sh` explicitly downloads an official, checksum-bound jq 1.8.1
binary for trusted regression inputs. It supports macOS arm64 and x86_64, writes
only the ignored `.release-build/oracle-jq` cache, and prints the tool directory.

```sh
scripts/development/setup-oracle-jq.sh
scripts/development/setup-oracle-jq.sh --verify
```

`--verify` is offline and fails if the cached binary is absent, replaced or no
longer executable. `--directory ABSOLUTE_PATH` or `LEYLINE_ORACLE_JQ_DIR` selects
an alternate cache root. Existing invalid cache contents are rejected, never
executed or silently replaced. Setup must be run explicitly before oracle tests;
tests never download tools.

`ley test oracles` gives this verified compiler a scoped PATH only for the frozen
oracle suite. General CLI commands and their tests use the system/current jq.
This isolates jq 1.8.2's transitive module compiler regression while preserving all
frozen reference bytes; see [development](../../docs/development.md).
