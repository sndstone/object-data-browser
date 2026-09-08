# CI failure audit and preflight

Reviewed recent Actions history on 2026-09-08.

- Repeated Pages failures were environment admission rejections: the workflow
  deploys from main, while the github-pages environment allowed only gh-pages.
  Added main to the selected branch allowlist, retaining the existing policy
  and gh-pages entry. This is repository configuration, not a YAML setting.
- Older Flutter analyzer/test and Windows ARM64 JNI build failures were already
  corrected before the successful 2.2.7 matrix run (34200399506). Keep analysis,
  the full Flutter suite, and all four engine contract suites as release gates.
- Older Linux builds lacked GTK development packages. The Ubuntu 20.04 container
  now installs dependencies; an explicit tool/pkg-config preflight checks them
  before bootstrapping and compiling. Existing ELF and startup checks remain.
- Verification now runs pinned actionlint 1.7.12 and bash syntax checks before
  Flutter/engine jobs. Desktop builds have a 90-minute timeout; verification
  jobs have explicit timeouts too.

Before the next release, run actionlint and bash syntax checks, then the required
Flutter analysis/tests for app changes. Wait for Verification and Release Matrix
on the intended source revision before publishing packages. Check Pages separately:
its environment branch rules live on GitHub and cannot be validated by actionlint.

These checks catch known configuration and prerequisite mistakes. They cannot
prevent hosted-runner outages, network failures, or all future dependency changes.
