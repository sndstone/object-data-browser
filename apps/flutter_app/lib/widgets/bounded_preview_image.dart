import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/preview_image_loader.dart';

class BoundedPreviewImage extends StatefulWidget {
  const BoundedPreviewImage(
      {super.key,
      required this.url,
      this.etag,
      this.expanded = false,
      this.loader,
      this.maximumMegapixels = 32});
  final String url;
  final String? etag;
  final bool expanded;
  final PreviewImageLoader? loader;
  final int maximumMegapixels;
  @override
  State<BoundedPreviewImage> createState() => _BoundedPreviewImageState();
}

class _BoundedPreviewImageState extends State<BoundedPreviewImage> {
  late PreviewImageLoader _loader;
  late Future<PreviewImageData> _image;
  void _load() {
    _loader = widget.loader ?? PreviewImageLoader();
    _image = _loader.load(widget.url,
        etag: widget.etag, cache: widget.loader == null);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BoundedPreviewImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.etag != widget.etag ||
        old.loader != widget.loader) {
      if (old.loader == null) _loader.close();
      _load();
    }
  }

  @override
  void dispose() {
    if (widget.loader == null) _loader.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PreviewImageData>(
      future: _image,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(child: Text('Could not load image preview.'));
        }
        final image = snapshot.data;
        if (image == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return LayoutBuilder(builder: (context, constraints) {
          final pixelRatio = MediaQuery.devicePixelRatioOf(context);
          var scale = math.min(
              1.0,
              math.sqrt(widget.maximumMegapixels.clamp(4, 64) *
                  1024 *
                  1024 /
                  (image.width * image.height)));
          scale = math.min(scale, 8192 / math.max(image.width, image.height));
          if (!widget.expanded) {
            if (constraints.maxWidth.isFinite) {
              scale = math.min(
                  scale, constraints.maxWidth * pixelRatio / image.width);
            }
            if (constraints.maxHeight.isFinite) {
              scale = math.min(
                  scale, constraints.maxHeight * pixelRatio / image.height);
            }
          }
          return Image.memory(image.bytes,
              fit: BoxFit.contain,
              cacheWidth: math.max(1, (image.width * scale).floor()),
              cacheHeight: math.max(1, (image.height * scale).floor()),
              errorBuilder: (_, __, ___) =>
                  const Center(child: Text('Could not load image preview.')));
        });
      });
}
