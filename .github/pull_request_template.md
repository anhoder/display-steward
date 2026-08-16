## Summary

<!-- What does this change do, and why? Link the issue it fixes, if any. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor
- [ ] Documentation
- [ ] Other (describe below)

## Verification

- [ ] `./test-all.sh` passes
- [ ] `./install.sh --smoke-test` passes
- [ ] `plutil -lint Info.plist com.anhoder.display-steward.plist` passes (if plists changed)
- [ ] No real display operations were performed unless explicitly authorized

## Safety

<!-- Any change that touches display actions must prove it preserves at least one active usable display, journals disables before commit, verifies the global postcondition afterward, and keeps committed uncertainty recoverable. State that here, or note "no display-action path changed." -->

## Notes

<!-- Behavior changes, migration impact, README/CHANGELOG updates, or anything reviewers should know. -->
