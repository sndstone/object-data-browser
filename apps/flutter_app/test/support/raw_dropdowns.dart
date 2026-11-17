import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:s3_browser_crossplat/widgets/app_select_field.dart';

/// Stock dropdowns that are not owned by the shared selector. The selector
/// itself builds one on touch layouts, so those do not count as bypasses.
Finder rawDropdowns() => find.byElementPredicate((element) {
      final widget = element.widget;
      if (widget is! DropdownButton && widget is! DropdownButtonFormField) {
        return false;
      }
      var owned = false;
      element.visitAncestorElements((ancestor) {
        if (ancestor.widget is AppSelectField) {
          owned = true;
          return false;
        }
        return true;
      });
      return !owned;
    });
