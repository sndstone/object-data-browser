## Summary

The main workspace, settings, inspector, HTML preview, and banner transitions already use the shared motion model. The largest remaining gaps are framework-owned dialog, sheet, disclosure, dropdown, and tab animations that do not enforce the app’s zero-duration preference. Mid-flight review found that changing an `AnimatedSwitcher` duration to zero does not settle existing entries, and the trace-tile indicator can jump when interrupted. Empty-state changes and several responsive layouts still replace content abruptly. This was a read-only audit: no files changed, no remote actions occurred, and no builds or tests ran.

## Findings

Paths below are relative to `apps/flutter_app/`. Confidence describes source verification; visual behavior was not reproduced during this review.

1. **Modal routes bypass the motion preference** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/browser/browser_workspace.dart:573`, `lib/browser/browser_workspace.dart:274`, `lib/app/s3_browser_app.dart:979`, `lib/theme/app_motion.dart:6`.
   - Now: Every `showDialog` call omits `animationStyle`; both bottom sheets omit `sheetAnimationStyle`. The checked-in Flutter SDK supplies 150 ms dialog fades and 250/200 ms sheet transitions.
   - Why: The propagated `MediaQuery.disableAnimations` flag does not make these route durations zero. The SDK controller’s platform accessibility adjustment is also not equivalent to enforcing the app preference.
   - Proposed change: Add `AppMotion.dialogStyle(context)` and `sheetStyle(context)`, exposed through `showAppDialog` and `showAppBottomSheet`. Resolve both entrance and exit durations through the policy and settle already-open routes when motion becomes disabled. All dialogs currently share a fade; I found no inconsistent fade-versus-scale dialog implementations.

2. **Disclosure tiles retain uncontrolled expansion animations** — severity **medium**, effort **S**, confidence **confirmed**
   - Where: `lib/browser/browser_workspace.dart:1422`, `lib/settings/settings_workspace.dart:1484`, `lib/widgets/connection_options_editor.dart:98`, `lib/logs/structured_log_list.dart:189`.
   - Now: None of the app’s `ExpansionTile` sites supplies `expansionAnimationStyle`, and the theme supplies none. The SDK defaults to 200 ms with `easeIn`.
   - Why: Profile editors, inspector metadata, administration sections, and upload logs continue expanding with motion disabled; their easing also differs from other size reveals.
   - Proposed change: Supply a preference-aware `ExpansionTileThemeData.expansionAnimationStyle` using a shared disclosure style. Include preference changes during an expansion in verification.

3. **Route-backed dropdowns escape the shared menu contract** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/widgets/app_select_field.dart:375`, `lib/widgets/app_select_field.dart:381`, `lib/browser/storage_admin_dialog.dart:360`, `lib/browser/azure_admin_dialog.dart:379`.
   - Now: The mobile `AppSelectField` branch and administration dropdowns use `DropdownButtonFormField`. Its private route uses a 300 ms staged fade/grow/item-reveal sequence; keyboard focus can additionally scroll items over 100 ms.
   - Why: These menus differ from the desktop selector’s 180/120 ms anchored reveal and ignore the app’s zero-duration policy.
   - Proposed change: Introduce a **route-backed** shared menu implementation with policy-controlled animation and scrolling. Preserve the mobile route-backed safeguard documented at line 375; replacing it with the desktop `OverlayPortal` would reintroduce the clipping/invisible-barrier risk.

4. **Zero-duration updates do not settle active implicit transitions** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/theme/app_motion.dart:43`, `lib/app/s3_browser_app.dart:1289`, `lib/browser/object_panel.dart:420`, `lib/browser/browser_workspace.dart:458`.
   - Now: Preference changes rebuild these widgets with `Duration.zero`. Flutter’s `AnimatedSwitcher` retains the controllers and durations of existing entries. Implicit animations also retain their running simulation when only duration changes and the target remains unchanged.
   - Why: Motion can continue after the user disables it, including retained outgoing content. `DirectionalSwitcher` explicitly handles this at `lib/theme/app_motion.dart:170`; these other paths do not.
   - Proposed change: Add policy-aware presence/reveal helpers that settle active animation and remove outgoing entries immediately while preserving the current child’s state. Cover banner fades, responsive fades, inspector extent, and control animations.

5. **Benchmark result tabs retain default navigation and scroll motion** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/benchmark/benchmark_workspace.dart:1576`, `lib/benchmark/benchmark_workspace.dart:1647`, `lib/benchmark/benchmark_workspace.dart:1662`.
   - Now: `DefaultTabController`, scrollable `TabBar`, and `TabBarView` use framework defaults: 300 ms tab/page movement with `ease`, plus automatic tab-strip scrolling.
   - Why: This navigation continues with app motion disabled and uses a different transition from the app’s ordered destinations.
   - Proposed change: Use a shared motion-aware tab/page helper, retaining direct swipe interaction. A zero `DefaultTabController.animationDuration` alone is insufficient: the checked SDK’s tab-strip auto-scroll has its own fixed duration.

6. **Phone navigation uses a separate 500 ms animation** — severity **medium**, effort **S**, confidence **confirmed**
   - Where: `lib/app/s3_browser_app.dart:518`.
   - Now: `NavigationBar.animationDuration` is unspecified. The SDK uses 500 ms and emphasized cubic easing, with additional internal label styling.
   - Why: The destination highlight outlasts the 300 ms workspace push and ignores the app’s duration policy.
   - Proposed change: Pass a policy-resolved navigation duration. Account for the internal label transition through a shared navigation wrapper if strict zero-motion behavior is required.

7. **Trace-tile interruption reconstructs a nominal previous frame** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/widgets/banner_activity/trace_tile_indicator.dart:49`, `lib/widgets/banner_activity/trace_tile_indicator.dart:65`, `lib/widgets/banner_activity/trace_tile_indicator.dart:249`.
   - Now: Each phase change stores the previous specification and restarts the clock from zero. During working → succeeded → failed, the second transition treats the partly drawn succeeded state as fully terminal: `wasTerminal` makes the fill start at 1.
   - Why: An interrupted result can jump from a partial fill to a full tile. Returning to working also discards the composite immediately.
   - Proposed change: Capture and blend from the visible composite, following `LivingGlyphIndicator`’s snapshot approach at `lib/widgets/banner_activity/living_glyph_indicator.dart:65`. The existing continuity test covers that glyph, not the trace tile.

8. **Benchmark bars have a hard-coded animation duration** — severity **medium**, effort **S**, confidence **confirmed**
   - Where: `lib/benchmark/benchmark_workspace.dart:2836`.
   - Now: `_bar` always animates height for 250 ms using `easeOutCubic`.
   - Why: Updated benchmark data still animates when motion is disabled. The curve has no overshoot; the defect is preference enforcement and an isolated duration.
   - Proposed change: Resolve duration through `AppMotion` using a progress-update token.

9. **An in-flight navigation does not adapt to an axis change** — severity **medium**, effort **M**, confidence **confirmed**
   - Where: `lib/theme/app_motion.dart:189`, `lib/theme/app_motion.dart:205`, `lib/app/s3_browser_app.dart:245`.
   - Now: With the same current child, `DirectionalSwitcher.didUpdateWidget` returns before handling changed geometry. Existing offsets retain their original axis when a window crosses from vertical rail navigation to horizontal navigation.
   - Why: The active transition continues in the previous direction; another navigation can retarget it diagonally.
   - Proposed change: Handle axis and directionality changes explicitly. Either settle the current transition or reproject its visible trajectory before continuing. Existing tests verify responsive axes after settling, rather than during a push.

10. **Several responsive structural changes have no continuity treatment** — severity **medium**, effort **M**, confidence **confirmed**
    - Where: `lib/browser/object_preview_dialog.dart:112`, `lib/tasks/tasks_workspace.dart:25`, `lib/benchmark/benchmark_workspace.dart:223`, `lib/browser/browser_workspace.dart:452`.
    - Now: Preview details switch directly between `Column` and `Row`; Tasks adds/removes its split detail pane; Benchmark replaces single/split compositions; inspector docking changes `Flex.direction` immediately. The browser’s responsive key only distinguishes phone from non-phone at `lib/browser/browser_workspace.dart:563`.
    - Why: Crossing those breakpoints abruptly moves or replaces content despite the stated resize-continuity model.
    - Proposed change: Apply `ResponsiveLayoutTransition` at structural mode boundaries, retaining preview transforms, editor state, and scroller identity. For docking, explicitly settle or transition the axis change without laying out a wide outgoing panel under narrow constraints.

11. **Empty states bypass the surrounding destination transitions** — severity **medium**, effort **S**, confidence **confirmed**
    - Where: `lib/tasks/tasks_workspace.dart:63`, `lib/browser/object_panel.dart:225`, `lib/event_log/event_log_workspace.dart:201`, `lib/browser/browser_workspace.dart:2626`.
    - Now: Lists and empty/error states are direct conditional branches. In Tasks, selecting an empty category removes the `DirectionalSwitcher` entirely.
    - Why: An otherwise animated category change snaps when its destination is empty; listing completion and clearing logs also replace large surfaces abruptly.
    - Proposed change: Keep the destination switcher outside the empty/non-empty branch in Tasks. Use a keyed, quiet presence transition for list/empty/error modes elsewhere; do not animate individual data rows or each progress notification.

12. **Benchmark chart-category navigation swaps content immediately** — severity **low**, effort **S**, confidence **confirmed**
    - Where: `lib/benchmark/benchmark_workspace.dart:1754`, `lib/benchmark/benchmark_workspace.dart:1797`, `lib/benchmark/benchmark_workspace.dart:1542`.
    - Now: Selecting Latency, Operations, Throughput, Sizes, or Checksums updates an enum and directly replaces the chart subtree.
    - Why: This ordered navigation lacks the orientation treatment used by neighboring benchmark sections.
    - Proposed change: Wrap the chart viewport in a keyed `DirectionalSwitcher`, using the category index and shared navigation timing. Preserve the chart export boundary and ensure export captures settled content.

13. **Inspector identity changes are treated as forward tab navigation** — severity **low**, effort **S**, confidence **confirmed**
    - Where: `lib/browser/browser_workspace.dart:997`, `lib/browser/browser_workspace.dart:1005`, `lib/theme/app_motion.dart:193`.
    - Now: The child key includes the selected object, but position contains only the inspector-tab index. Selecting another object in the same tab therefore starts a full push with equal positions; the helper chooses the positive direction.
    - Why: Moving to either an earlier or later object produces the same directional movement, without an ordered destination change.
    - Proposed change: Distinguish tab navigation from same-tab object replacement. Use actual row ordering when meaningful, or a quiet content-replacement helper for identity changes at the same position.

14. **Outgoing banner and navigation children remain interactive** — severity **low**, effort **S**, confidence **confirmed**
    - Where: `lib/app/s3_browser_app.dart:310`, `lib/app/s3_browser_app.dart:383`, `lib/app/s3_browser_app.dart:1296`.
    - Now: These switchers retain outgoing children without the pointer, focus, and semantics exclusions used by `DirectionalSwitcher`. Banner children contain live regions and actions.
    - Why: During replacement, an outgoing larger banner can retain reachable controls outside the incoming banner’s bounds, and outgoing content can remain exposed to accessibility.
    - Proposed change: Centralize outgoing-child isolation in the proposed presence helper: `IgnorePointer`, `ExcludeFocus`, and `ExcludeSemantics`. Reuse an outgoing child on reversal where continuity requires it.

15. **Shared menu timing does not produce a shared menu shape** — severity **low**, effort **M**, confidence **confirmed**
    - Where: `lib/widgets/app_menu.dart:175`, `lib/widgets/app_select_field.dart:507`, `lib/widgets/app_select_field.dart:524`, `lib/widgets/underline_tabs.dart:67`.
    - Now: Popup menus share `AppMenuStyle` timing, but retain Flutter’s width/height growth and item-opacity intervals. The custom selector fades while revealing height at a fixed width.
    - Why: Equivalent anchored panels still open differently even with identical 180/120 ms styles.
    - Proposed change: Share an anchored-panel transition implementation across custom and route-backed menus, rather than sharing only `AnimationStyle`.

16. **Theme and control feedback lack a complete policy adapter** — severity **low**, effort **M**, confidence **confirmed**
    - Where: `lib/app/s3_browser_app.dart:203`, `lib/theme/app_theme.dart:385`, `lib/widgets/app_slider.dart:115`, `lib/widgets/compact_selector.dart:92`, `lib/widgets/app_select_field.dart:464`.
    - Now: Theme interpolation, tooltips, stock sliders/checkboxes/chips, button/ink feedback, and input decorations retain framework timing. `MaterialApp`’s animated theme also sits outside the media override supplied by its builder.
    - Why: A global media flag does not establish the promised zero-duration behavior across these controls.
    - Proposed change: Add a policy-resolved theme animation style and shared control/tooltip adapters. `RawTooltip.animationStyle`, button animation durations, and ink configuration offer direct hooks; some private input/control animations require a custom composition or an explicitly documented policy exception.

**Complete animation inventory**

“Yes” means the site resolves both app and accessibility preferences, directly or through the banner’s resolved `animate` flag. “No” means the strict zero-duration contract is not enforced; the framework may still shorten animations for a platform accessibility flag. Codes: **a** preference bypass, **b** separate timing/easing, **c** different equivalent-surface shape, **d** intentional activity/progress choreography. Related sites with identical behavior are grouped.

Curve abbreviations: **out/in** = `easeOutCubic`/`easeInCubic`; **smooth** = `easeInOutCubic`; **push** = `Cubic(.65, 0, .35, 1)`.

| File:line | Widget/API | Current duration / curve | Honors preference? | Classification; recommended token/helper |
|---|---|---|---|---|
| `lib/theme/app_motion.dart:13` | `AppMotion.transition` | Caller animation; out/in; fade + .025 fractional slide | Caller-dependent | Unused helper; require a policy-owned route/transition |
| `lib/theme/app_motion.dart:43` | Responsive `AnimatedSwitcher` | Caller duration; out; .65→1 fade | Yes for new entries | Active-entry settling gap; responsive/presence helper |
| `lib/theme/app_motion.dart:117` | Per-panel controllers | Caller duration; smooth/push and opacity intervals | Yes | Navigation helper; axis-change gap |
| `lib/theme/app_motion.dart:315` | `AnimatedSize` | Caller duration/curve; default linear | Yes | Correct direct layout path at zero |
| `lib/app/s3_browser_app.dart:203` | `MaterialApp` theme interpolation | SDK 200 ms / linear | No | a,b; theme style |
| `lib/app/s3_browser_app.dart:240` | Workspace `DirectionalSwitcher` | 300 ms / push | Yes | `navigation` |
| `lib/app/s3_browser_app.dart:310` | Bottom-nav presence switch | 220 ms / out; size + fade | Yes for new entries | `surface`; settling/isolation helper |
| `lib/app/s3_browser_app.dart:339` | Rail `AnimatedContainer` | 220 ms / out | Yes for new motion | `surface`; settle on preference change |
| `lib/app/s3_browser_app.dart:377`, `:383` | Top-nav size/fade | 220 ms / out,in | Yes for new motion | `surface`; presence helper |
| `lib/app/s3_browser_app.dart:518` | `NavigationBar` | SDK 500 ms / emphasized cubic; internal 100 ms label style | No | a,b; navigation adapter |
| `lib/app/s3_browser_app.dart:687` | Header responsive layout | 240 ms / out | Yes for new entries | `layout` |
| `lib/app/s3_browser_app.dart:1289` | Banner switch | 220/160 ms / out,in; fade + 8 px vertical travel | Yes for new entries | `surface`/`control`; presence helper |
| `lib/app/s3_browser_app.dart:1317`, `:1323` | Banner size/Material | 220 ms / smooth; Material framework curve | Yes for new motion | `surface` |
| `lib/browser/browser_workspace.dart:392` | Mobile browser destinations | 260 ms / push | Yes | b; `navigation` |
| `lib/browser/browser_workspace.dart:458` | Inspector extent tween | 220 ms / smooth | Yes for new motion | `surface`; settle/reorient helper |
| `lib/browser/browser_workspace.dart:507` | Workspace padding | 220 ms / out | Yes for new motion | `surface` |
| `lib/browser/browser_workspace.dart:562` | Phone/non-phone responsive fade | 240 ms / out | Yes for new entries | `layout`; additional structural modes missing |
| `lib/browser/browser_workspace.dart:992` | Inspector destinations | 300 ms / push | Yes | `navigation`; distinguish identity changes |
| `lib/browser/browser_workspace.dart:1514` | Preview loading/content stages | 260 ms / smooth and phased opacity | Yes | `surface` or explicit content-reveal token |
| `lib/browser/object_panel.dart:151` | Tools tray tween | 240 ms / smooth | Yes for new motion | `layout`; preserve close behavior |
| `lib/browser/object_panel.dart:420` | Browse/selection toolbar | 180 ms / out intervals .45–1, .55–1 | Yes for new entries | `control`; shared sequential replacement |
| `lib/browser/object_preview_dialog.dart:317` | HTML source/render switch | 220 ms / smooth and phased opacity | Yes | `surface`; retain horizontal fade requirement |
| `lib/benchmark/benchmark_workspace.dart:294` | Benchmark sections | 200 ms / push | Yes | b; `navigation` |
| `lib/benchmark/benchmark_workspace.dart:1576`, `:1647`, `:1662` | Tab controller/bar/view | SDK 300 ms / ease; independent strip scrolling | No | a,b,c; motion-aware tabs |
| `lib/benchmark/benchmark_workspace.dart:2836` | Bar height | 250 ms / out | No | a,b; `progress` |
| `lib/settings/settings_workspace.dart:860` | Settings sections | 300 ms / push | Yes | `navigation` |
| `lib/tasks/tasks_workspace.dart:81`, `:110` | Task categories/details | 180 ms / push | Yes | b; `navigation`; empty branch bypasses category switch |
| `lib/tasks/tasks_workspace.dart:263` | Embedded task detail size | 180 ms / linear | Yes | `control`; consider shared reveal curve |
| `lib/widgets/app_switch.dart:57`, `:73`, `:89`, `:101`, `:107` | Track, labels, thumb | 170 ms / out | Yes for new motion | b; `control` |
| `lib/widgets/app_slider.dart:301` | Block-slider fill | 110 ms / linear | Yes for new motion | b; `fast` |
| `lib/widgets/copyable_value.dart:93` | Copy-button opacity | 120 ms / out | Yes for new motion | `fast` |
| `lib/widgets/app_form_dialog.dart:111` | Dialog keyboard inset | 180 ms / default decelerate | Yes for new motion | `control`; standardize inset curve |
| `lib/widgets/app_select_field.dart:91` | Selector controller/reveal | Initially 180/120 ms; policy-resolved in dependencies; out/in | Yes | Correct settling/reversal; shared menu helper |
| `lib/widgets/app_menu.dart:20` | Constant animation style | 180/120 ms / out,in | No if used | Dormant: no active references found; remove or privatize |
| `lib/widgets/app_menu.dart:27`, `:175` | Menu style and `showMenu` | 180/120 ms / out,in plus SDK growth/item intervals | Yes when opened | c; shared anchored-panel transition |
| `lib/widgets/underline_tabs.dart:62`, `lib/browser/object_panel.dart:747` | `PopupMenuButton` | Shared 180/120 ms style plus SDK shape | Yes when opened | c; same anchored-panel helper |
| `lib/widgets/banner_activity/living_glyph_indicator.dart:28`, `:29` | Glyph loop/result controllers | 440 ms morph; kind loops 1000–1600 ms, stopping ×1.6 | Yes via resolved spec | d; retain domain tempo, `activityMorph` |
| `lib/widgets/banner_activity/living_glyph_indicator.dart:132`, `:202` | Progress/count tweens | 320 ms / out | Yes via resolved spec | d; `progress` |
| `lib/widgets/banner_activity/trace_tile_indicator.dart:26` | Trace clock/painter | 1200/1450/1800 ms working; 1600 ms stopping; 340 ms result; smooth/out | Yes via resolved spec | d; fix visible-frame interruption; `activityMorph` |
| `lib/widgets/transfer_status/file_scan_indicator.dart:24` | Scan controller/painter | 1050/1900 ms; sine-shaped scan | Yes via resolved spec | d; retain domain tempo |
| `lib/widgets/transfer_status/file_scan_indicator.dart:95`, `:118` | Progress/handoff tweens | 320 ms / out,smooth | Yes via resolved spec | d; `progress`/handoff |
| `lib/widgets/transfer_status/file_scan_indicator.dart:125`, `:151` | Document/caption switchers | 320 ms; linear document fade; .5–1 easeOut/easeIn caption intervals | Yes for new entries | d; presence settling still applies |
| `lib/widgets/transfer_status/segments_indicator.dart:39` | Shared loop/result controller | 1300/1700 ms loops; 720 ms terminal sequence | Yes via resolved spec | d; retain domain choreography |
| `lib/widgets/transfer_status/segments_indicator.dart:160`, `:184` | Glyph/row switchers | 200 ms; out/in glyph fade-scale, linear row fade | Yes for new entries | d; `control`; settling helper |
| `lib/widgets/transfer_status/segments_indicator.dart:207` | Percentage reveal | 460 or 200 ms / smooth | Yes via resolved spec | d; `activityMorph`/`control` |
| `lib/widgets/transfer_status/segments_indicator.dart:233` | Progress tween | 360 ms / out | Yes via resolved spec | d; `progress` |
| `lib/widgets/transfer_status/segments_indicator.dart:635` | Failure-crack painter easing | `easeOutBack` within terminal sequence | Yes via resolved spec | d; pictogram choreography, not table/progress overshoot |

**Modal route inventory**

All listed `showDialog` sites use the same uncontrolled SDK **150 ms / easeOut fade**: **No**, classification **a,b**, recommendation `showAppDialog`. Both sheet sites use **250/200 ms / legacyDecelerate**: **No**, classification **a,b**, recommendation `showAppBottomSheet`.

| File:line | Widget/API and surface |
|---|---|
| `lib/app/app_shortcuts.dart:46` | `showDialog`: shortcut reference |
| `lib/app/s3_browser_app.dart:107` | `showDialog`: unsaved profile changes |
| `lib/app/s3_browser_app.dart:979` | `showModalBottomSheet`: connection/engine controls |
| `lib/benchmark/benchmark_workspace.dart:1566` | `showDialog`: results workspace |
| `lib/browser/azure_admin_dialog.dart:116`, `:306` | `showDialog`: confirmation, rename |
| `lib/browser/browser_workspace.dart:274` | `showModalBottomSheet`: upload source |
| `lib/browser/browser_workspace.dart:573`, `:682`, `:739` | `showDialog`: prefix, rename, inspector |
| `lib/browser/browser_workspace.dart:854`, `:889` | `showDialog`: selected-object/all-object deletion |
| `lib/browser/browser_workspace.dart:1148`, `:1154`, `:1160` | `showDialog`: access/lifecycle presets, administration |
| `lib/browser/browser_workspace.dart:1410`, `:1632`, `:1799` | `showDialog`: object administration, preview, version administration |
| `lib/browser/browser_workspace.dart:2251`, `:2278`, `:2328` | `showDialog`: create/delete/copy bucket |
| `lib/browser/browser_workspace.dart:2343`, `:2365` | `showDialog`: JSON and tags |
| `lib/browser/bucket_copy_dialog.dart:36`, `:90` | `showDialog`: copy review and uncertain-copy inspection |
| `lib/browser/object_panel.dart:110` | `showDialog`: list-all confirmation |
| `lib/browser/storage_admin_dialog.dart:120`, `:139`, `:161`, `:275`, `:398` | `showDialog`: confirmation, tags, headers, recovery, Azure administration |
| `lib/event_log/event_log_workspace.dart:47` | `showDialog`: clear log |
| `lib/settings/settings_workspace.dart:1998` | `showDialog`: delete profile |
| `lib/widgets/app_form_dialog.dart:49` | `showDialog`: discard changes |

The following dialog bodies separately retain SDK **100 ms / decelerate keyboard-inset animation**: **No**, classification **a,b**; use a shared inset policy. `AppFormDialog:111` is the migrated exception, already listed above.

| File:line | Widget/API |
|---|---|
| `lib/app/app_shortcuts.dart:48`, `lib/app/s3_browser_app.dart:109` | `AlertDialog` |
| `lib/benchmark/benchmark_workspace.dart:1569` | `Dialog` |
| `lib/browser/azure_admin_dialog.dart:118`, `:444` | `AlertDialog` |
| `lib/browser/browser_workspace.dart:741`, `:856`, `:892`, `:2281` | `Dialog` / `AlertDialog` |
| `lib/browser/bucket_copy_dialog.dart:38`, `:92`, `:131` | `AlertDialog` |
| `lib/browser/object_panel.dart:112` | `AlertDialog` |
| `lib/browser/object_preview_dialog.dart:49` | `Dialog` |
| `lib/browser/storage_admin_dialog.dart:122`, `:278`, `:373` | `AlertDialog` |
| `lib/browser/storage_preset_dialog.dart:243` | `AlertDialog` |
| `lib/event_log/event_log_workspace.dart:49` | `AlertDialog` |
| `lib/settings/settings_workspace.dart:2000`, `lib/widgets/app_form_dialog.dart:51` | `AlertDialog` |

**Other implicit surface animations**

| File:line | Widget/API | Current duration / curve | Honors preference? | Classification; helper |
|---|---|---|---|---|
| `lib/browser/azure_admin_dialog.dart:472`, `:505`, `:513`, `:546` | `ExpansionTile` | 200 ms / easeIn | No | a,b; disclosure style |
| `lib/browser/browser_workspace.dart:1422` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/browser/object_preview_dialog.dart:206` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/browser/storage_admin_dialog.dart:473`, `:480`, `:526`, `:589`, `:691`, `:791` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/browser/storage_preset_dialog.dart:346`, `:381`, `:409` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/logs/structured_log_list.dart:189`, `:201` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/settings/settings_workspace.dart:1484`, `:1803` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/widgets/connection_options_editor.dart:98` | `ExpansionTile` | Same | No | a,b; disclosure style |
| `lib/widgets/app_select_field.dart:381` | Mobile `DropdownButtonFormField` | 300 ms staged reveal; 100 ms focus scroll/easeInOut | No | a,b,c; route-backed menu helper |
| `lib/browser/azure_admin_dialog.dart:379`, `:481` | Dropdowns | Same | No | a,b,c; route-backed menu helper |
| `lib/browser/bucket_copy_dialog.dart:140`, `:180` | Dropdowns | Same | No | a,b,c; route-backed menu helper |
| `lib/browser/storage_admin_dialog.dart:290`, `:360` | Dropdowns | Same | No | a,b,c; route-backed menu helper |
| `lib/browser/storage_preset_dialog.dart:258`, `:303` | Dropdowns | Same | No | a,b,c; route-backed menu helper |
| `lib/widgets/app_slider.dart:115` | Stock `Slider` | 75 ms enable/position; 100 ms reaction/value indicator | No | a,b; control adapter |
| `lib/browser/object_table.dart:169`, `lib/browser/azure_admin_dialog.dart:418`, `:431` | `Checkbox` | 200 ms toggle/easeIn,easeOut; 50 ms hover/focus | No | a,b; control adapter |
| `lib/browser/bucket_copy_dialog.dart:168`, `:233` | `ActionChip`, `FilterChip` | SDK selection 195 ms; check 150/50; drawers 150/100; enable/press 75 | No | a,b; chip style |
| `lib/benchmark/benchmark_workspace.dart:2143`, `:2153`, `:2933`, `:2940` | Filter/choice chips | Same | No | a,b; chip style |
| `lib/benchmark/benchmark_workspace.dart:886`, `:1339` | `Chip` | SDK chip feedback/style timings | No | a,b; chip style |
| `lib/browser/browser_workspace.dart:1317`, `:1806`, `:2175` | `Chip` | Same | No | a,b; chip style |
| `lib/settings/settings_workspace.dart:1515`, `:1517`, `:1526`, `:1540`, `:1543` | `Chip` | Same | No | a,b; chip style |
| `lib/tasks/tasks_workspace.dart:454` | `Chip` | Same | No | a,b; chip style |

**Tooltip inventory**

Every site below, including tooltips created through control properties, ultimately uses the SDK tooltip fade: **150/75 ms / fastOutSlowIn**, **No**, classification **a,b**. Recommended helper: `AppTooltip` using policy-resolved `RawTooltip.animationStyle`. The explicit **550 ms** selector and **600 ms** bucket delays are hover waits, not animation durations.

| File:line | Widget/API |
|---|---|
| `lib/app/s3_browser_app.dart:533`, `:599`, `:850`, `:909`, `:1377` | Destination tooltips, explicit `Tooltip`, button tooltips |
| `lib/benchmark/benchmark_workspace.dart:901`, `:1036`, `:1056`, `:1134`, `:1639`, `:2909`, `:2936`, `:2943` | Explicit/control tooltips |
| `lib/browser/azure_admin_dialog.dart:412` | Button tooltip |
| `lib/browser/browser_workspace.dart:1049`, `:1053`, `:1477`, `:1599`, `:2204`, `:2692`, `:2712`, `:2738`, `:2799`, `:2803`, `:2809`, `:2878` | Explicit/control/status tooltips |
| `lib/browser/object_panel.dart:332`, `:342`, `:353`, `:446`, `:545`, `:581`, `:620`, `:627`, `:633`, `:659`, `:721`, `:749` | Explicit/control tooltips |
| `lib/browser/object_preview_dialog.dart:89`, `:105`, `:260`, `:266`, `:270` | Preview tooltips |
| `lib/browser/object_table.dart:193`, `:203`, `:245`, `:279` | Row/header/action tooltips |
| `lib/browser/storage_admin_dialog.dart:719`, `:750`, `:816`, `:868` | Administration tooltips |
| `lib/browser/tag_editor_dialog.dart:89` | Remove-tag tooltip |
| `lib/event_log/event_log_workspace.dart:138` | Help tooltip |
| `lib/logs/structured_log_list.dart:520` | Timestamp tooltip |
| `lib/settings/settings_workspace.dart:1522`, `:1728`, `:1764`, `:1790` | Status/secret-control tooltips |
| `lib/widgets/app_form_dialog.dart:133` | Close tooltip |
| `lib/widgets/compact_selector.dart:92` | Selector tooltip |
| `lib/widgets/copyable_value.dart:28`, `:100`, `:133` | Value/copy tooltips |
| `lib/widgets/underline_tabs.dart:63` | Overflow-control tooltip |

**Stock progress indicators**

These are classification **d**, legitimate activity feedback rather than navigation. They do not enforce the app preference themselves. Their indeterminate periods remain SDK-owned; determinate values are direct updates. If the strict static-on-disabled behavior of custom banner indicators is intended globally, provide a shared static fallback.

| File:line | Widget/API | Honors preference? | Recommended helper |
|---|---|---|---|
| `lib/widgets/app_form_dialog.dart:181` | Circular progress | No | Activity adapter |
| `lib/widgets/bounded_preview_image.dart:59`, `:66` | Circular progress | No | Activity adapter |
| `lib/browser/azure_admin_dialog.dart:454`, `lib/browser/storage_admin_dialog.dart:385`, `lib/browser/storage_preset_dialog.dart:256` | Linear progress | No | Activity adapter |
| `lib/browser/object_panel.dart:224` | Linear progress | No | Activity adapter |
| `lib/browser/browser_workspace.dart:1362`, `:1496`, `:1541`, `:2216` | Circular/linear progress | No | Activity adapter |
| `lib/benchmark/benchmark_workspace.dart:339`, `:831`, `:861` | Circular/linear progress | No | Activity adapter |
| `lib/tasks/tasks_workspace.dart:227` | Linear progress | No | Activity adapter |

**Framework microfeedback inventory**

These are lower-priority **a,b** sites, rather than additional navigation defects. To avoid repeating identical timing text, the following table uses:

- **B**: button feedback, SDK style animation normally 200 ms, plus ink.
- **I**: ink feedback; SDK activation 100 ms, hover normally 50 ms, focus/pressed fade 200 ms; splash choreography is framework/platform-owned.
- **F**: input decoration; SDK 167 ms / fastOutSlowIn, hint fade 20 ms, hover 15 ms.
- **M**: `Material` shape/elevation styling, normally 200 ms / fastOutSlowIn when those properties change. Merely constructing a `Material` does not imply an active animation.

All use framework defaults rather than a policy adapter: **No**. Recommended helpers are the control-theme, field, ink, and material adapters described in finding 16. Static styling factory calls are excluded.

| File | Widget/API sites, by line |
|---|---|
| `lib/app/app_shortcuts.dart` | B:54 |
| `lib/app/s3_browser_app.dart` | B:114,117,120,908,964,1008,1365,1371,1376; I:604,860,1357; M:601,852. Banner M:1323 is policy-controlled |
| `lib/benchmark/benchmark_workspace.dart` | B:324,343,348,353,358,903,929,939,1367,1372,1378,1638,1722,1731,1739,1852,2908; I:2878; F:3050,3071 |
| `lib/benchmark/operation_mix_bar.dart` | B:237 |
| `lib/browser/azure_admin_dialog.dart` | B:122,130,140,405,614,619; F:147,396 |
| `lib/browser/browser_workspace.dart` | B:862,909,1048,1052,1147,1153,1159,1164,1170,1176,1381,1409,1479,1598,1647,1659,1664,1670,1778,1838,1946,2074,2108,2119,2203,2303,2634,2737,2796,2802,2807; I:2668; F:902,1717,2293,2414,2820; M:2653 |
| `lib/browser/bucket_copy_dialog.dart` | B:74,77,109,112,266,275; F:103,158,175 |
| `lib/browser/content_headers_dialog.dart` | F:53 |
| `lib/browser/create_bucket_dialog.dart` | F:57 |
| `lib/browser/empty_bucket_state.dart` | B:60 |
| `lib/browser/json_editor_dialog.dart` | B:73; F:83 |
| `lib/browser/object_panel.dart` | B:117,120,236,271,340,351,361,399,445,529,537,544,580,596,604,612,619,626,632,661,675,719; F:695 |
| `lib/browser/object_preview_dialog.dart` | B:104,259,265,269,291 |
| `lib/browser/object_table.dart` | B:244,282; I:143; M:108 |
| `lib/browser/rename_dialog.dart` | F:64 |
| `lib/browser/storage_admin_dialog.dart` | B:126,129,190,321,324,718,749,815,867,908,911; F:285,493,544,614,619 |
| `lib/browser/storage_preset_dialog.dart` | B:426,429; F:153,290,297,316,349 |
| `lib/browser/tag_editor_dialog.dart` | B:88,99; F:110 |
| `lib/event_log/event_log_workspace.dart` | B:54,143,149,207; F:189 |
| `lib/logs/structured_log_list.dart` | I:616 |
| `lib/settings/settings_workspace.dart` | B:166,201,232,263,788,897,1562,1727,1763,1789,1939,1965,1978,1993,2006; F:1566,1596,1617,1622,1695,1708,1717,1742,1753,1780,1871,1883,1899,1913,1929; M:911,972 |
| `lib/tasks/tasks_workspace.dart` | B:56,72,287,292,297,303,310,315,320; I:194 |
| `lib/widgets/app_form_dialog.dart` | B:56,59,132,171,174 |
| `lib/widgets/app_select_field.dart` | F:464; M:544,577; I:583 |
| `lib/widgets/app_slider.dart` | B:527 |
| `lib/widgets/compact_selector.dart` | M:95; I:98 |
| `lib/widgets/connection_options_editor.dart` | F:24 |
| `lib/widgets/copyable_value.dart` | B:99 |
| `lib/widgets/danger_button.dart` | B:8 |
| `lib/widgets/setting_fields.dart` | F:102 |
| `lib/widgets/underline_tabs.dart` | I:106 |

`lib/main.dart:24` is a static fatal-error `Material`, with no changing target. `lib/theme/app_motion.dart:242` explicitly disables its wrapper’s Material animation. Neither is an active bypass.

**Duration and curve consolidation**

App-authored motion uses these distinct nonzero millisecond values:

`110, 120, 160, 170, 180, 200, 220, 240, 250, 260, 300, 320, 340, 360, 440, 460, 720, 1000, 1050, 1200, 1300, 1400, 1450, 1500, 1600, 1700, 1800, 1900`.

Living-glyph stopping loops additionally multiply their base period by 1.6. Hover waits, debounce timers, message lifetimes, timeouts, and polling intervals are not animation tokens.

A proposed seven-duration set is:

| Token | Value | Call-site mapping |
|---|---:|---|
| `fast` | 120 ms | Copy affordance; block slider 110→120; menu exit |
| `control` | 180 ms | Menu entrance; switch 170→180; toolbar replacement; task disclosure; dialog inset; banner exit 160→180 |
| `surface` | 220 ms | Banner entrance/size; rail/top/bottom-nav presence; inspector extent; HTML mode; preview-stage reveal 260→220 |
| `layout` | 240 ms | Responsive layout changes; tools tray |
| `navigation` | 300 ms | Workspace/settings/inspector; mobile browser 260→300; benchmark sections 200→300; task destinations 180→300; result tabs and phone navigation |
| `progress` | 320 ms | Existing file/glyph progress; segments 360→320; benchmark bar 250→320 |
| `activityMorph` | 440 ms | Existing glyph morph; trace result 340→440; segment handoff 460→440, subject to visual review |

Keep the indicator loops and 720 ms terminal choreography as named domain timings rather than forcing them into navigation tokens.

The distinct app-authored curves are `linear`, `easeIn`, `easeOut`, `easeInCubic`, `easeOutCubic`, `easeInOutCubic`, `easeInQuad`, `easeInOutSine`, `easeOutBack`, and `Cubic(.65,0,.35,1)`. Composed opacity intervals include `.25/.35→1`, `0→.35`, `.45→1`, `.55→1`, and `.5→1`.

Expose named `enter`, `exit`, `resize`, and `push` curves plus a shared sequential-replacement builder. Keep sine, quadratic, and back curves inside indicator choreography. The sole `easeOutBack` use is a failure-crack pictogram, not overshoot on data tables or progress values.

`AppMotion` currently accepts arbitrary integers, requires callers to carry resolved durations, and offers no route, disclosure, presence, tooltip, or controller-settling adapter. Add typed duration/style resolution and an `enabledOf(context)` predicate; the banner currently derives a boolean by comparing a resolved duration against zero at `lib/app/s3_browser_app.dart:1280`.

## Checked and fine

- `DirectionalSwitcher` reuses returning panels, samples visible offset/opacity before retargeting, excludes outgoing interaction, and disposes its controllers. The ordinary interrupted reversal path is covered by existing tests.
- `MotionSize` has a direct non-animated layout path.
- The collapsed inspector’s `TickerMode` fix remains present at `lib/browser/browser_workspace.dart:467`; it is not an outstanding resource-review finding.
- Desktop selector menus dispose their controller/curve, preserve progress on reopening, and explicitly settle when reduced motion becomes enabled.
- Living-glyph result interruption captures the visible composite and releases snapshots/controllers.
- App-owned animation controllers use appropriate ticker-provider mixins; no missing controller disposal was found.
- HTML source/render switching already animates horizontally with a fade. Static HTML rendering, bounded previews, selectable source, and image pan/zoom remain intact.
- Immediate underline and compact-selector highlights are intentional; `test/surface_motion_test.dart:41` expressly requires immediate underline selection.
- No app-authored `Hero`, `PageRouteBuilder`, `MaterialPageRoute`, `showGeneralDialog`, `SnackBar`, `Drawer`, `NavigationRail`, or `animateTo` call was found. Framework-internal scrolling is identified above.
- Prior resource-review fixes, motion tests, release verification notes, and the motion design specification were consulted.
- No files or disposable artifacts were created or removed; space freed: **0 bytes**. Existing review assets and build/dependency directories were left untouched.

## Not covered

- Runtime visual reproduction, frame timings, hidden/minimized-window scheduling, or physical-device behavior.
- Builds, analysis, tests, installs, network access, and remote repository operations, as prohibited by this task.
- Browser playback of the motion-review galleries; source specifications were inspected.
- Whether every framework-private control animation can be suppressed without a custom replacement. Their defaults and missing policy hooks are confirmed; replacement feasibility needs implementation review.