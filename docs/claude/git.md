# Git branching

Overrides the base-branch part of the global branching policy for this repo.

- The default branch here is `main` (there is no `master`). Cut every new branch from it: `git checkout main && git pull && git checkout -b <new-branch>`.
- A repo with `master` instead is handled the same way: the base is whichever of `main` or `master` exists. Do not stop to ask which one.
- Everything else in the global policy is unchanged: a new branch for every change, squash on merge, merge only after the user approves, hotfixes merge into the base branch and are then merged down into `develop`.
