import 'package:flutter/widgets.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import '../services/preview_image_loader.dart';
import 'bounded_preview_image.dart';

class BoundedHtmlImageFactory extends WidgetFactory {
  BoundedHtmlImageFactory(this.loader);
  final PreviewImageLoader loader;
  @override
  Widget? buildImageWidget(BuildTree tree, ImageSource src) =>
      BoundedPreviewImage(url: src.url, loader: loader, maximumMegapixels: 4);
}
