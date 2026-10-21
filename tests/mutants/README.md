# Mutants

One file per deliberate breakage of a guard, run by
`.github/scripts/mutation-check.py` (`just mutate`, the weekly
`mutation.yml`, and `--check` in lint on every pull request). Each names
the file, the text to replace (`old`, exactly once in the file), the
replacement (`new`) and the command that must then fail (`must_fail`, run
from the repository root with the system PATH first). A mutant that
survives is a guard no test covers: add the assertion, never drop the
mutant. A mutant that no longer applies (the guard moved) is updated with
the guard.
