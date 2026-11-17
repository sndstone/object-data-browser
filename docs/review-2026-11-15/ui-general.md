## Summary

The app has a substantial shared component layer, responsive layouts and explicit recovery handling. The highest priorities are two remaining asynchronous targeting bugs: delayed share links can attach to another object, and uploads can acquire a different destination during preparation. Unrelated settings changes also overwrite custom benchmark configuration, while cancelling profile export still writes a file. Other worthwhile fixes concern breadcrumb fidelity, form submission behavior, action discoverability and provider-specific validation. This was a static, read-only review; no files changed, tests ran or remote state changed.

## Findings

1. **Delayed share links can attach to another selected object** — severity `high`, effort `S`, confidence `confirmed`
   - Where: [controllers/app_controller.dart:2071](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:2071), [controllers/app_controller.dart:2093](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:2093)
   - **Now:** Generate a link for A, then select B before the request finishes. The completion copies A’s URL into the current `selectedObjectDetails` and switches the inspector to Share without checking selection identity.
   - **Impact:** The UI can present a link to A while the user believes they are sharing B.
   - **Change:** Capture engine/profile/bucket/key and a request generation before dispatch. Apply the result only when that complete identity remains current, following `_loadSelectionArtifacts`’ existing pattern.

2. **Upload destinations are captured after asynchronous preparation** — severity `high`, effort `M`, confidence `confirmed`
   - Where: [browser/browser_workspace.dart:186](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:186), [browser/browser_workspace.dart:240](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:240), [controllers/app_controller.dart:1590](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:1590)
   - **Now:** Folder enumeration and dropped-directory traversal finish before `startSampleUpload` captures the destination. Single-file uploads additionally read `currentPrefix` after awaiting file sizing.
   - **Impact:** Navigating during preparation can send files into a different prefix or destination from the one where upload began.
   - **Change:** Capture an immutable upload target before opening the picker or traversing files. Pass it through sizing and dispatch; show the exact destination during preparation and reject changed targets when appropriate.

3. **Changing appearance or inspector settings overwrites benchmark drafts** — severity `medium`, effort `M`, confidence `confirmed`
   - Where: [controllers/app_controller.dart:2596](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:2596), [app/s3_browser_app.dart:910](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/app/s3_browser_app.dart:910)
   - **Now:** Every `updateSettings` call replaces benchmark threads, timeouts, attempts, pool size, cache and output paths with application defaults. Switching theme invokes this path.
   - **Impact:** A configured benchmark silently changes after an unrelated UI action.
   - **Change:** Update benchmark defaults only when their corresponding settings change. Preserve explicit draft overrides, preferably through a dedicated benchmark draft/defaults model.

4. **Cancelling profile export still writes the default export** — severity `medium`, effort `S`, confidence `confirmed`
   - Where: [settings/settings_workspace.dart:170](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/settings/settings_workspace.dart:170), [services/app_state_repository.dart:148](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/app_state_repository.dart:148)
   - **Now:** A null desktop `saveFile` result falls back to `defaultPath`, followed by an unconditional export.
   - **Impact:** Cancel creates or overwrites `s3-browser-profiles.json` without the user completing the save action.
   - **Change:** Return immediately when the desktop picker returns null. Keep the mobile default-path flow separate.

5. **Profile import/export failures bypass normal UI error handling** — severity `medium`, effort `S`, confidence `confirmed`
   - Where: [settings/settings_workspace.dart:181](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/settings/settings_workspace.dart:181), [settings/settings_workspace.dart:226](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/settings/settings_workspace.dart:226), [controllers/app_controller.dart:2992](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:2992)
   - **Now:** File operations are awaited without a surrounding UI/controller error boundary. Malformed JSON and filesystem failures propagate directly from the repository.
   - **Impact:** Importing a broken file or exporting to an unwritable location can fail without actionable feedback. The buttons also remain available during these operations.
   - **Change:** Add tracked import/export actions with disabled busy controls and sanitized error banners explaining the next step. Preserve the existing credential-import recovery boundary.

6. **Breadcrumb navigation changes prefixes containing repeated slashes** — severity `medium`, effort `S`, confidence `confirmed`
   - Where: [browser/object_panel.dart:646](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_panel.dart:646), [browser/object_panel.dart:680](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_panel.dart:680)
   - **Now:** Breadcrumb construction removes empty segments and reconstructs destinations with `join('/')`. From `a//b/c/`, clicking `b` requests `a/b/`.
   - **Impact:** Breadcrumbs navigate to a different object namespace.
   - **Change:** Retain exact substring offsets into `currentPrefix`. Display friendly segment labels while using untouched prefix substrings as navigation targets.

7. **Bucket copy closes after failures and declined reviews** — severity `medium`, effort `M`, confidence `confirmed`
   - Where: [browser/bucket_copy_dialog.dart:280](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/bucket_copy_dialog.dart:280), [controllers/app_controller.dart:4783](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:4783), [controllers/app_controller.dart:4833](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:4833)
   - **Now:** The dialog pops whenever `copyBucketContents` returns. That includes validation rejection, guarded failures and cancelling a configuration/history review.
   - **Impact:** Users lose the entered destination and options when they need to correct or retry them.
   - **Change:** Return an explicit completed/cancelled/failed outcome. Close only on completion; otherwise retain the form, reset `copying` and show the outcome inline. Freeze request fields while copying.

8. **Busy forms remain editable from the keyboard** — severity `medium`, effort `S`, confidence `confirmed`
   - Where: [widgets/app_form_dialog.dart:71](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/widgets/app_form_dialog.dart:71), [widgets/app_form_dialog.dart:146](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/widgets/app_form_dialog.dart:146)
   - **Now:** `_submit` snapshots the value, but busy protection uses only `AbsorbPointer`. A field focused when Ctrl/Cmd+Enter submits can still receive keyboard edits.
   - **Impact:** Users can type changes that are discarded when the earlier snapshot finishes saving and closes the dialog.
   - **Change:** Unfocus and exclude descendant focus while saving, or propagate a busy state that makes fields read-only. Apply the same protection to extra actions.

9. **Benchmark fields silently substitute or discard invalid input** — severity `medium`, effort `M`, confidence `confirmed`
   - Where: [benchmark/benchmark_workspace.dart:548](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:548), [benchmark/benchmark_workspace.dart:3061](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:3061), [benchmark/benchmark_workspace.dart:3145](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:3145)
   - **Now:** Invalid integer text keeps the previous draft value; invalid size-list tokens are dropped. Start remains enabled and flushes with fallback values.
   - **Impact:** A benchmark can run with parameters different from the visible input, making results misleading.
   - **Change:** Extract a validated benchmark form. Reject the entire malformed size list, show field errors and block Start until valid. Reuse `SettingNumberField` behavior where applicable.

10. **“Current object” version actions can operate on a batch selection** — severity `medium`, effort `S`, confidence `confirmed`
    - Where: [browser/browser_workspace.dart:1664](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:1664), [browser/browser_workspace.dart:843](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:843), [controllers/app_controller.dart:1775](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/controllers/app_controller.dart:1775)
    - **Now:** “Download current object” and “Delete current object” delegate to selection-aware actions. Checked keys take precedence over the inspected object.
    - **Impact:** The action label promises one object while the operation targets multiple checked objects.
    - **Change:** Pass explicit keys for these inspector actions. Keep batch actions in the object-list selection toolbar and retain the shared deletion confirmation.

11. **Desktop select fields lack reliable focus feedback and explicit control semantics** — severity `medium`, effort `S`, confidence `likely`
    - Where: [widgets/app_select_field.dart:448](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/widgets/app_select_field.dart:448), [widgets/app_select_field.dart:467](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/widgets/app_select_field.dart:467)
    - **Now:** The custom desktop control reads `_focusNode.hasFocus` without a focus-change rebuild listener. Its closed surface has no explicit button/expanded/value semantics wrapper.
    - **Impact:** Keyboard focus may remain visually indistinguishable; assistive technology receives a weaker control description than the mobile dropdown.
    - **Change:** Use `FocusableActionDetector` or a focus listener that rebuilds, plus explicit label/value/enabled/expanded semantics. Verify desktop screen-reader announcements and Tab focus before considering this confirmed at runtime.

12. **Selecting an object removes every visible row action menu** — severity `medium`, effort `S`, confidence `confirmed`
    - Where: [browser/object_table.dart:97](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_table.dart:97), [browser/object_table.dart:232](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_table.dart:232), [browser/object_panel.dart:557](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_panel.dart:557)
    - **Now:** `showActions` requires both an empty batch selection and no inspected object. Selecting one object therefore hides all ellipsis buttons. The replacement toolbar exposes only download/share/delete.
    - **Impact:** Rename, Copy key and other object actions become dependent on discovering right-click, long-press or Shift+F10.
    - **Change:** Keep the inspected row’s menu available, or add a selection-toolbar More menu. Add scoped F2 rename and Cmd/Ctrl+A selection shortcuts while preserving text-field editing shortcuts.

13. **Azure actions and labels disagree across surfaces** — severity `medium`, effort `M`, confidence `confirmed`
    - Where: [browser/browser_workspace.dart:625](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:625), [browser/browser_workspace.dart:644](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:644), [browser/object_panel.dart:571](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/object_panel.dart:571), [services/mobile_azure_storage.dart:48](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/mobile_azure_storage.dart:48)
    - **Now:** Azure objects receive “Copy s3:// URI” and an unconditional Generate presigned URL menu item, while the toolbar hides sharing for every Azure profile. The Azure adapter advertises sharing conditionally by authentication mode.
    - **Impact:** Users encounter misleading identifiers and inconsistent access to supported actions.
    - **Change:** Derive toolbar, context-menu and inspector actions from the same capability model. Use provider-correct resource identifiers and bucket/container terminology.

14. **Bucket inspector values bypass the responsive metadata component** — severity `medium`, effort `S`, confidence `likely`
    - Where: [browser/browser_workspace.dart:1287](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:1287), [browser/browser_workspace.dart:1310](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:1310)
    - **Now:** Bucket tags place unrestricted values in `ListTile.trailing`; lifecycle cards put unrestricted rule IDs beside a `Spacer` and status chip.
    - **Impact:** Long values or rule IDs can consume the narrow inspector’s width, truncate other content or overflow at enlarged text sizes.
    - **Change:** Render tags with `CopyableValue`/`LabeledValue`. Give lifecycle titles flexible width and move status below the title at narrow widths. Runtime overflow reproduction remains unverified.

15. **The shared tag editor accepts values rejected by its Azure caller** — severity `medium`, effort `S`, confidence `confirmed`
    - Where: [browser/tag_editor_dialog.dart:28](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/tag_editor_dialog.dart:28), [browser/storage_admin_dialog.dart:139](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/storage_admin_dialog.dart:139), [services/mobile_azure_storage.dart:263](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/services/mobile_azure_storage.dart:263)
    - **Now:** `TagEditorDialog` permits 50 entries for all callers, including Azure object tags. The mobile Azure adapter rejects more than 10.
    - **Impact:** The form presents an invalid configuration as saveable and fails only after submission.
    - **Change:** Pass a validation specification containing resource type, entry limit and key/value rules. Give metadata editing its own labels and constraints instead of inheriting tag-specific validation.

16. **Administration forms bypass shared selectors and switches** — severity `low`, effort `M`, confidence `confirmed`
    - Where: [browser/bucket_copy_dialog.dart:140](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/bucket_copy_dialog.dart:140), [browser/storage_admin_dialog.dart:358](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/storage_admin_dialog.dart:358), [browser/storage_preset_dialog.dart:258](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/storage_preset_dialog.dart:258), [browser/storage_preset_dialog.dart:326](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/storage_preset_dialog.dart:326)
    - **Now:** These forms use raw dropdowns and `SwitchListTile` despite existing `AppSelectField` and `AppSwitchTile` components. Some dropdowns also omit expanded/ellipsized handling.
    - **Impact:** Administration controls diverge in geometry, long-label behavior and keyboard interaction.
    - **Change:** Replace these controls with the shared components, preserving their mobile route-backed behavior and existing validation.

17. **Background transfer visibility depends on one dismissible banner** — severity `low`, effort `M`, confidence `confirmed`
    - Where: [app/s3_browser_app.dart:472](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/app/s3_browser_app.dart:472), [app/s3_browser_app.dart:527](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/app/s3_browser_app.dart:527), [app/s3_browser_app.dart:1376](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/app/s3_browser_app.dart:1376)
    - **Now:** Jobs navigation has no running/failed badge. Dismissing the banner removes the visible transfer entry point while another workspace remains open.
    - **Impact:** Long transfers and failures are easy to lose track of during browsing.
    - **Change:** Add persistent running/failed counts to Jobs destinations on rail, tabs and bottom navigation. Make activation open the relevant job/filter.

18. **Benchmark failure status receives neutral styling** — severity `low`, effort `S`, confidence `confirmed`
    - Where: [benchmark/benchmark_workspace.dart:1327](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:1327), [tasks/tasks_workspace.dart:440](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/tasks/tasks_workspace.dart:440)
    - **Now:** Benchmark `_statusChip` has no `failed` case, so failures receive the neutral fallback icon/color. Jobs uses error styling for the same status.
    - **Impact:** Failed benchmarks are less conspicuous and status meaning changes between workspaces.
    - **Change:** Extract a shared status presentation mapping with explicit failed/transitional states and theme-derived colors. Reuse it in benchmark and Jobs pills.

19. **Several concrete presentation boundaries remain embedded in large workspaces** — severity `low`, effort `L`, confidence `confirmed`
    - Where: [browser/browser_workspace.dart:941](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/browser/browser_workspace.dart:941), [benchmark/benchmark_workspace.dart:380](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:380), [benchmark/benchmark_workspace.dart:1560](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/benchmark/benchmark_workspace.dart:1560), [settings/settings_workspace.dart:82](/Users/sndstone/Documents/Object-browser/apps/flutter_app/lib/settings/settings_workspace.dart:82)
    - **Now:** Inspector composition, benchmark form/controller bookkeeping, results-window layout and settings section factories each live inside their parent workspace.
    - **Impact:** Shared fixes require editing large, coupled files, encouraging the inconsistent form and status behavior above.
    - **Change:** Extract `BrowserInspector` with preview/version/share sections; `BenchmarkConfigurationForm` owning validation/controllers; `BenchmarkResultsDialog` owning chart options/export state; and individual settings section widgets plus `ProfileEditorCard`. Keep targeting and secure-persistence decisions in controller/domain APIs.

## Checked and fine

- Existing object-list loading, empty, failed-listing and Retry paths distinguish failures from empty buckets.
- Ordinary detail/version loading uses request-generation and target-identity checks; the separate share-link path is the exception reported above.
- Main shell uses `SafeArea`; compact selectors and shared sliders contain touch-target and keyboard handling.
- Object names are bounded with ellipsis/tooltips; object rows build lazily.
- Profile drafts, secure-save progress, session-only warnings and the Settings exit prompt remain implemented.
- Expanded previews retain captured identity, bounded content, selectable source, pan/zoom and static HTML rendering.
- Prior review documents and relevant regression tests were inspected statically.
- No files changed or artifacts were created. Cleanup freed **0 bytes**; existing untracked review directories were preserved.

## Not covered

- Runtime reproduction, rendered layouts, native keyboard/focus behavior and screen-reader testing.
- Builds, analysis, tests, installs and network operations, as prohibited.
- Motion/transitions, engine implementation correctness and a complete audit of the controller.
- Physical-device Keychain, local-network, backgrounding and platform permission flows.