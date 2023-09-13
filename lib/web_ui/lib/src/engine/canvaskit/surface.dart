// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:js_interop';

import 'package:ui/ui.dart' as ui;

import '../browser_detection.dart';
import '../configuration.dart';
import '../dom.dart';
import '../platform_dispatcher.dart';
import '../util.dart';
import 'canvas.dart';
import 'canvaskit_api.dart';
import 'picture.dart';
import 'render_canvas.dart';
import 'util.dart';

// Only supported in profile/release mode. Allows Flutter to use MSAA but
// removes the ability for disabling AA on Paint objects.
const bool _kUsingMSAA = bool.fromEnvironment('flutter.canvaskit.msaa');

typedef SubmitCallback = bool Function(SurfaceFrame, CkCanvas);

/// A frame which contains a canvas to be drawn into.
class SurfaceFrame {
  SurfaceFrame(this.skiaSurface, this.submitCallback) : _submitted = false;

  final CkSurface skiaSurface;
  final SubmitCallback submitCallback;
  final bool _submitted;

  /// Submit this frame to be drawn.
  bool submit() {
    if (_submitted) {
      return false;
    }
    return submitCallback(this, skiaCanvas);
  }

  CkCanvas get skiaCanvas => skiaSurface.getCanvas();
}

/// A surface which can be drawn into by the compositor.
///
/// The underlying representation is a [CkSurface], which can be reused by
/// successive frames if they are the same size. Otherwise, a new [CkSurface] is
/// created.
class Surface {
  Surface();

  CkSurface? _surface;

  /// If true, forces a new WebGL context to be created, even if the window
  /// size is the same. This is used to restore the UI after the browser tab
  /// goes dormant and loses the GL context.
  bool _forceNewContext = true;
  bool get debugForceNewContext => _forceNewContext;

  bool _contextLost = false;
  bool get debugContextLost => _contextLost;

  /// A cached copy of the most recently created `webglcontextlost` listener.
  ///
  /// We must cache this function because each time we access the tear-off it
  /// creates a new object, meaning we won't be able to remove this listener
  /// later.
  DomEventListener? _cachedContextLostListener;

  /// A cached copy of the most recently created `webglcontextrestored`
  /// listener.
  ///
  /// We must cache this function because each time we access the tear-off it
  /// creates a new object, meaning we won't be able to remove this listener
  /// later.
  DomEventListener? _cachedContextRestoredListener;

  SkGrContext? _grContext;
  int? _glContext;
  int? _skiaCacheBytes;

  /// The underlying OffscreenCanvas element used for this surface.
  DomOffscreenCanvas? _offscreenCanvas;

  /// Returns the underlying OffscreenCanvas. Should only be used in tests.
  DomOffscreenCanvas? get debugOffscreenCanvas => _offscreenCanvas;

  /// The <canvas> backing this Surface in the case that OffscreenCanvas isn't
  /// supported.
  DomCanvasElement? _canvasElement;

  int _pixelWidth = -1;
  int _pixelHeight = -1;
  int _sampleCount = -1;
  int _stencilBits = -1;

  /// Specify the GPU resource cache limits.
  void setSkiaResourceCacheMaxBytes(int bytes) {
    _skiaCacheBytes = bytes;
    _syncCacheBytes();
  }

  void _syncCacheBytes() {
    if (_skiaCacheBytes != null) {
      _grContext?.setResourceCacheLimitBytes(_skiaCacheBytes!.toDouble());
    }
  }

  Future<void> rasterizeToCanvas(
      ui.Size frameSize, RenderCanvas canvas, List<CkPicture> pictures) async {
    final CkCanvas skCanvas = _surface!.getCanvas();
    skCanvas.clear(const ui.Color(0x00000000));
    pictures.forEach(skCanvas.drawPicture);
    _surface!.flush();

    DomImageBitmap bitmap;
    if (Surface.offscreenCanvasSupported) {
      bitmap = (await createSizedOffscreenImageBitmap(
        _offscreenCanvas!,
        0,
        _pixelHeight - frameSize.height.toInt(),
        frameSize.width.toInt(),
        frameSize.height.toInt(),
      ))!;
    } else {
      bitmap = (await createSizedImageBitmap(
        _canvasElement!,
        0,
        _pixelHeight - frameSize.height.toInt(),
        frameSize.width.toInt(),
        frameSize.height.toInt(),
      ))!;
    }
    canvas.render(bitmap);
  }

  /// Acquire a frame of the given [size] containing a drawable canvas.
  ///
  /// The given [size] is in physical pixels.
  SurfaceFrame acquireFrame(ui.Size size) {
    final CkSurface surface = createOrUpdateSurface(size);

    // ignore: prefer_function_declarations_over_variables
    final SubmitCallback submitCallback =
        (SurfaceFrame surfaceFrame, CkCanvas canvas) {
      return _presentSurface();
    };

    return SurfaceFrame(surface, submitCallback);
  }

  ui.Size? _currentCanvasPhysicalSize;
  ui.Size? _currentSurfaceSize;

  /// This is only valid after the first frame or if [ensureSurface] has been
  /// called
  bool get usingSoftwareBackend =>
      _glContext == null ||
      _grContext == null ||
      webGLVersion == -1 ||
      configuration.canvasKitForceCpuOnly;

  /// Ensure that the initial surface exists and has a size of at least [size].
  ///
  /// If not provided, [size] defaults to 1x1.
  ///
  /// This also ensures that the gl/grcontext have been populated so
  /// that software rendering can be detected.
  void ensureSurface([ui.Size size = const ui.Size(1, 1)]) {
    // If the GrContext hasn't been setup yet then we need to force initialization
    // of the canvas and initial surface.
    if (_surface != null) {
      return;
    }
    // TODO(jonahwilliams): this is somewhat wasteful. We should probably
    // eagerly setup this surface instead of delaying until the first frame?
    // Or at least cache the estimated window sizeThis is the first frame we have rendered with this canvas.
    createOrUpdateSurface(size);
  }

  /// Creates a <canvas> and SkSurface for the given [size].
  CkSurface createOrUpdateSurface(ui.Size size) {
    if (size.isEmpty) {
      throw CanvasKitError('Cannot create surfaces of empty size.');
    }

    if (!_forceNewContext) {
      // Check if the window is the same size as before, and if so, don't allocate
      // a new canvas as the previous canvas is big enough to fit everything.
      final ui.Size? previousSurfaceSize = _currentSurfaceSize;
      if (previousSurfaceSize != null &&
          size.width == previousSurfaceSize.width &&
          size.height == previousSurfaceSize.height) {
        return _surface!;
      }

      final ui.Size? previousCanvasSize = _currentCanvasPhysicalSize;
      // Initialize a new, larger, canvas. If the size is growing, then make the
      // new canvas larger than required to avoid many canvas creations.
      if (previousCanvasSize != null &&
          (size.width > previousCanvasSize.width ||
              size.height > previousCanvasSize.height)) {
        final ui.Size newSize = size * 1.4;
        _surface?.dispose();
        _surface = null;
        if (Surface.offscreenCanvasSupported) {
          _offscreenCanvas!.width = newSize.width;
          _offscreenCanvas!.height = newSize.height;
        } else {
          _canvasElement!.width = newSize.width;
          _canvasElement!.height = newSize.height;
        }
        _currentCanvasPhysicalSize = newSize;
        _pixelWidth = newSize.width.ceil();
        _pixelHeight = newSize.height.ceil();
      }
    }

    // Either a new context is being forced or we've never had one.
    if (_forceNewContext || _currentCanvasPhysicalSize == null) {
      _surface?.dispose();
      _surface = null;
      _grContext?.releaseResourcesAndAbandonContext();
      _grContext?.delete();
      _grContext = null;

      _createNewCanvas(size);
      _currentCanvasPhysicalSize = size;
    }

    _currentSurfaceSize = size;
    _surface?.dispose();
    _surface = _createNewSurface(size);
    return _surface!;
  }

  JSVoid _contextRestoredListener(DomEvent event) {
    assert(
        _contextLost,
        'Received "webglcontextrestored" event but never received '
        'a "webglcontextlost" event.');
    _contextLost = false;
    // Force the framework to rerender the frame.
    EnginePlatformDispatcher.instance.invokeOnMetricsChanged();
    event.stopPropagation();
    event.preventDefault();
  }

  JSVoid _contextLostListener(DomEvent event) {
    assert(event.target == _offscreenCanvas || event.target == _canvasElement,
        'Received a context lost event for a disposed canvas');
    _contextLost = true;
    _forceNewContext = true;
    event.preventDefault();
  }

  /// This function is expensive.
  ///
  /// It's better to reuse canvas if possible.
  void _createNewCanvas(ui.Size physicalSize) {
    // Clear the container, if it's not empty. We're going to create a new <canvas>.
    if (_offscreenCanvas != null) {
      _offscreenCanvas!.removeEventListener(
        'webglcontextrestored',
        _cachedContextRestoredListener,
        false,
      );
      _offscreenCanvas!.removeEventListener(
        'webglcontextlost',
        _cachedContextLostListener,
        false,
      );
      _offscreenCanvas = null;
      _cachedContextRestoredListener = null;
      _cachedContextLostListener = null;
    } else if (_canvasElement != null) {
      _canvasElement!.removeEventListener(
        'webglcontextrestored',
        _cachedContextRestoredListener,
        false,
      );
      _canvasElement!.removeEventListener(
        'webglcontextlost',
        _cachedContextLostListener,
        false,
      );
      _canvasElement = null;
      _cachedContextRestoredListener = null;
      _cachedContextLostListener = null;
    }

    // If `physicalSize` is not precise, use a slightly bigger canvas. This way
    // we ensure that the rendred picture covers the entire browser window.
    _pixelWidth = physicalSize.width.ceil();
    _pixelHeight = physicalSize.height.ceil();
    DomEventTarget htmlCanvas;
    if (Surface.offscreenCanvasSupported) {
      final DomOffscreenCanvas offscreenCanvas = createDomOffscreenCanvas(
        _pixelWidth,
        _pixelHeight,
      );
      htmlCanvas = offscreenCanvas;
      _offscreenCanvas = offscreenCanvas;
      _canvasElement = null;
    } else {
      final DomCanvasElement canvas =
          createDomCanvasElement(width: _pixelWidth, height: _pixelHeight);
      htmlCanvas = canvas;
      _canvasElement = canvas;
      _offscreenCanvas = null;
    }

    // When the browser tab using WebGL goes dormant the browser and/or OS may
    // decide to clear GPU resources to let other tabs/programs use the GPU.
    // When this happens, the browser sends the "webglcontextlost" event as a
    // notification. When we receive this notification we force a new context.
    //
    // See also: https://www.khronos.org/webgl/wiki/HandlingContextLost
    _cachedContextRestoredListener =
        createDomEventListener(_contextRestoredListener);
    _cachedContextLostListener = createDomEventListener(_contextLostListener);
    htmlCanvas.addEventListener(
      'webglcontextlost',
      _cachedContextLostListener,
      false,
    );
    htmlCanvas.addEventListener(
      'webglcontextrestored',
      _cachedContextRestoredListener,
      false,
    );
    _forceNewContext = false;
    _contextLost = false;

    if (webGLVersion != -1 && !configuration.canvasKitForceCpuOnly) {
      int glContext = 0;
      final SkWebGLContextOptions options = SkWebGLContextOptions(
        // Default to no anti-aliasing. Paint commands can be explicitly
        // anti-aliased by setting their `Paint` object's `antialias` property.
        antialias: _kUsingMSAA ? 1 : 0,
        majorVersion: webGLVersion.toDouble(),
      );
      if (Surface.offscreenCanvasSupported) {
        glContext = canvasKit.GetOffscreenWebGLContext(
          _offscreenCanvas!,
          options,
        ).toInt();
      } else {
        glContext = canvasKit.GetWebGLContext(
          _canvasElement!,
          options,
        ).toInt();
      }

      _glContext = glContext;

      if (_glContext != 0) {
        _grContext = canvasKit.MakeGrContext(glContext.toDouble());
        if (_grContext == null) {
          throw CanvasKitError('Failed to initialize CanvasKit. '
              'CanvasKit.MakeGrContext returned null.');
        }
        if (_sampleCount == -1 || _stencilBits == -1) {
          _initWebglParams();
        }
        // Set the cache byte limit for this grContext, if not specified it will
        // use CanvasKit's default.
        _syncCacheBytes();
      }
    }
  }

  void _initWebglParams() {
    WebGLContext gl;
    if (Surface.offscreenCanvasSupported) {
      gl = _offscreenCanvas!.getGlContext(webGLVersion);
    } else {
      gl = _canvasElement!.getGlContext(webGLVersion);
    }
    _sampleCount = gl.getParameter(gl.samples);
    _stencilBits = gl.getParameter(gl.stencilBits);
  }

  CkSurface _createNewSurface(ui.Size size) {
    assert(_offscreenCanvas != null || _canvasElement != null);
    if (webGLVersion == -1) {
      return _makeSoftwareCanvasSurface('WebGL support not detected');
    } else if (configuration.canvasKitForceCpuOnly) {
      return _makeSoftwareCanvasSurface('CPU rendering forced by application');
    } else if (_glContext == 0) {
      return _makeSoftwareCanvasSurface('Failed to initialize WebGL context');
    } else {
      final SkSurface? skSurface = canvasKit.MakeOnScreenGLSurface(
          _grContext!,
          size.width.roundToDouble(),
          size.height.roundToDouble(),
          SkColorSpaceSRGB,
          _sampleCount,
          _stencilBits);

      if (skSurface == null) {
        return _makeSoftwareCanvasSurface('Failed to initialize WebGL surface');
      }

      return CkSurface(skSurface, _glContext);
    }
  }

  static bool _didWarnAboutWebGlInitializationFailure = false;

  CkSurface _makeSoftwareCanvasSurface(String reason) {
    if (!_didWarnAboutWebGlInitializationFailure) {
      printWarning('WARNING: Falling back to CPU-only rendering. $reason.');
      _didWarnAboutWebGlInitializationFailure = true;
    }

    SkSurface surface;
    if (Surface.offscreenCanvasSupported) {
      surface = canvasKit.MakeOffscreenSWCanvasSurface(_offscreenCanvas!);
    } else {
      surface = canvasKit.MakeSWCanvasSurface(_canvasElement!);
    }
    return CkSurface(
      surface,
      null,
    );
  }

  bool _presentSurface() {
    _surface!.flush();
    return true;
  }

  void dispose() {
    _offscreenCanvas?.removeEventListener(
        'webglcontextlost', _cachedContextLostListener, false);
    _offscreenCanvas?.removeEventListener(
        'webglcontextrestored', _cachedContextRestoredListener, false);
    _cachedContextLostListener = null;
    _cachedContextRestoredListener = null;
    _surface?.dispose();
  }

  /// Safari 15 doesn't support OffscreenCanvas at all. Safari 16 supports
  /// OffscreenCanvas, but only with the context2d API, not WebGL.
  static bool get offscreenCanvasSupported =>
      browserSupportsOffscreenCanvas && !isSafari;
}

/// A Dart wrapper around Skia's CkSurface.
class CkSurface {
  CkSurface(this.surface, this._glContext);

  CkCanvas getCanvas() {
    assert(!_isDisposed, 'Attempting to use the canvas of a disposed surface');
    return CkCanvas(surface.getCanvas());
  }

  /// The underlying CanvasKit surface object.
  ///
  /// Only borrow this value temporarily. Do not store it as it may be deleted
  /// at any moment. Storing it may lead to dangling pointer bugs.
  final SkSurface surface;

  final int? _glContext;

  /// Flushes the graphics to be rendered on screen.
  void flush() {
    surface.flush();
  }

  int? get context => _glContext;

  int width() => surface.width().round();
  int height() => surface.height().round();

  void dispose() {
    if (_isDisposed) {
      return;
    }
    surface.dispose();
    _isDisposed = true;
  }

  bool _isDisposed = false;
}
