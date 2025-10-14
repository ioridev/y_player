import 'dart:convert';
import 'dart:io'; // Add for HTTP requests
import 'dart:math'; // For min/max

import 'package:flutter/foundation.dart'; // For kReleaseMode
import 'package:media_kit/media_kit.dart';
import 'package:y_player/y_player.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as exp;

/// Controller for managing the YouTube player.
///
/// This class handles the initialization, playback control, and state management
/// of the YouTube video player. It uses the youtube_explode_dart package to fetch
/// video information and the media_kit package for playback.
class YPlayerController {
  /// YouTube API client for fetching video information.
  final exp.YoutubeExplode _yt = exp.YoutubeExplode();

  /// Media player instance from media_kit.
  late final Player _player;

  /// Current status of the player.
  YPlayerStatus _status = YPlayerStatus.initial;

  /// Callback function triggered when the player's status changes.
  final YPlayerStateCallback? onStateChanged;

  /// Callback function triggered when the player's progress changes.
  final YPlayerProgressCallback? onProgressChanged;

  /// The URL of the last successfully initialized video.
  String? _lastInitializedUrl;

  /// Store the current manifest for quality changes
  exp.StreamManifest? _currentManifest;

  /// Store the current video ID
  String? _currentVideoId;

  /// Current selected quality (resolution height)
  int _currentQuality = 0; // 0 means auto (highest)

  /// Whether the current playback uses muxed streams (video+audio combined)
  bool _usingMuxedStreams = false;

  /// Whether the current muxed playback is HLS-based
  bool _usingHlsMuxedStreams = false;

  /// Whether to force the original audio track
  bool _forceOriginalAudio = false;

  /// Add this ValueNotifier to track status changes
  final ValueNotifier<YPlayerStatus> statusNotifier;

  /// LRU cache for manifests (max 20 entries)
  static final Map<String, exp.StreamManifest> _manifestCache = {};
  static final List<String> _manifestCacheOrder = [];

  void _cacheManifest(String videoId, exp.StreamManifest manifest) {
    _manifestCache[videoId] = manifest;
    _manifestCacheOrder.remove(videoId);
    _manifestCacheOrder.add(videoId);
    if (_manifestCacheOrder.length > 20) {
      final oldest = _manifestCacheOrder.removeAt(0);
      _manifestCache.remove(oldest);
    }
  }

  /// Constructs a YPlayerController with optional callback functions.
  YPlayerController({this.onStateChanged, this.onProgressChanged})
    : statusNotifier = ValueNotifier<YPlayerStatus>(YPlayerStatus.loading) {
    _player = Player();
    _setupPlayerListeners();
  }

  /// Checks if the player has been initialized with media.
  bool get isInitialized => _player.state.playlist.medias.isNotEmpty;

  /// Gets the current status of the player.
  YPlayerStatus get status => _status;

  /// Gets the underlying media_kit Player instance.
  Player get player => _player;

  /// Get the current selected quality
  int get currentQuality => _currentQuality;

  /// Get list of available quality options
  List<QualityOption> getAvailableQualities() {
    if (_currentManifest == null) {
      return [];
    }

    // Always include automatic option
    final List<QualityOption> qualities = [
      QualityOption(height: 0, label: "Auto"),
    ];

    Iterable<exp.VideoStreamInfo> streams;
    if (_usingMuxedStreams) {
      if (_usingHlsMuxedStreams) {
        streams = _getHlsMuxedStreams(
          _currentManifest!,
        ).cast<exp.VideoStreamInfo>();
      } else {
        streams = _currentManifest!.muxed.cast<exp.VideoStreamInfo>();
      }
    } else {
      streams = _currentManifest!.videoOnly.cast<exp.VideoStreamInfo>();
    }

    // Add available video qualities
    for (final stream in streams) {
      final height = stream.videoResolution.height;

      if (height > 0 && !qualities.any((q) => q.height == height)) {
        qualities.add(QualityOption(height: height, label: "${height}p"));
      }
    }

    // Sort by height (highest first, but keep Auto at top)
    qualities.sublist(1).sort((a, b) => b.height.compareTo(a.height));

    return qualities;
  }

  /// Change video quality
  Future<void> setQuality(int height) async {
    if (_currentManifest == null || _currentVideoId == null) {
      if (!kReleaseMode) {
        debugPrint(
          'YPlayerController: Cannot change quality - no manifest available',
        );
      }
      return;
    }
    if (_status == YPlayerStatus.loading) return;
    if (_currentQuality == height) return; // No-op if already at this quality

    _currentQuality = height;
    final currentPosition = _player.state.position;
    final wasPlaying = _player.state.playing;

    _setStatus(YPlayerStatus.loading);
    try {
      if (_usingMuxedStreams) {
        final exp.VideoStreamInfo stream = _usingHlsMuxedStreams
            ? _selectHlsMuxedStream(height)
            : _selectMuxedStream(height);

        final currentUrl = _player.state.playlist.medias.isNotEmpty
            ? _player.state.playlist.medias.first.uri.toString()
            : '';
        if (currentUrl == stream.url.toString()) {
          _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
          return;
        }

        if (!kReleaseMode) {
          debugPrint(
            'YPlayerController: Changing muxed quality to ${stream.videoResolution.height}p',
          );
        }

        await _player.stop();
        await _player.open(
          Media(stream.url.toString(), start: currentPosition),
          play: false,
        );
        if (wasPlaying) {
          play();
        }
        _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Muxed quality change complete');
        }
        return;
      }

      exp.VideoStreamInfo videoStreamInfo;
      if (height == 0) {
        videoStreamInfo = _currentManifest!.videoOnly.withHighestBitrate();
      } else {
        final candidates = _currentManifest!.videoOnly
            .where((s) => s.videoResolution.height == height)
            .toList();
        if (candidates.isEmpty) {
          videoStreamInfo = _currentManifest!.videoOnly.withHighestBitrate();
        } else {
          videoStreamInfo = candidates.withHighestBitrate();
        }
      }

      exp.AudioStreamInfo audioStreamInfo;
      if (_forceOriginalAudio) {
        try {
          audioStreamInfo = _currentManifest!.audioOnly.firstWhere((stream) {
            if (stream.audioTrack != null) {
              try {
                dynamic track = stream.audioTrack;
                String displayName = track.displayName?.toString() ?? '';
                return displayName.toLowerCase().contains('original');
              } catch (e) {
                final trackString = stream.audioTrack.toString().toLowerCase();
                return trackString.contains('original');
              }
            }
            return false;
          });
        } catch (_) {
          audioStreamInfo = _currentManifest!.audioOnly.withHighestBitrate();
        }
      } else {
        audioStreamInfo = _currentManifest!.audioOnly.withHighestBitrate();
      }

      final currentUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.first.uri.toString()
          : '';
      if (currentUrl == videoStreamInfo.url.toString()) {
        _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
        return;
      }

      if (!kReleaseMode) {
        debugPrint(
          'YPlayerController: Changing quality to ${videoStreamInfo.videoResolution.height}p',
        );
      }
      await _player.stop();
      await _player.open(
        Media(videoStreamInfo.url.toString(), start: currentPosition),
        play: false,
      );
      await Future.delayed(const Duration(milliseconds: 100));
      await _player.setAudioTrack(
        AudioTrack.uri(audioStreamInfo.url.toString()),
      );
      if (wasPlaying) {
        play();
      }
      _setStatus(wasPlaying ? YPlayerStatus.playing : YPlayerStatus.paused);
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Quality change complete');
      }
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Error changing quality: $e');
      }
      _setStatus(YPlayerStatus.error);
    }
  }

  /// Estimate network speed (in bits per second) by downloading a small chunk of the video.
  Future<int?> _estimateNetworkSpeed(String testUrl) async {
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(testUrl));
      // Only download the first 512KB
      request.headers.add('Range', 'bytes=0-524287');
      final stopwatch = Stopwatch()..start();
      final response = await request.close();
      int totalBytes = 0;
      await for (var chunk in response) {
        totalBytes += chunk.length;
      }
      stopwatch.stop();
      client.close();
      if (stopwatch.elapsedMilliseconds == 0) return null;
      // bits per second
      return (totalBytes * 8 * 1000 ~/ stopwatch.elapsedMilliseconds);
    } catch (_) {
      return null;
    }
  }

  /// Select the best quality for the estimated network speed.
  Future<int> chooseBestQualityForInternet(exp.StreamManifest manifest) async {
    final List<exp.VideoStreamInfo> streams;
    if (_usingMuxedStreams) {
      if (_usingHlsMuxedStreams) {
        streams = _getHlsMuxedStreams(
          manifest,
        ).cast<exp.VideoStreamInfo>().toList();
      } else {
        streams = manifest.muxed.toList().cast<exp.VideoStreamInfo>();
      }
    } else {
      streams = manifest.videoOnly.toList().cast<exp.VideoStreamInfo>();
    }
    if (streams.isEmpty) return 0;

    final testStream = streams[streams.length ~/ 2];
    final testUrl = testStream.url.toString();
    final estimatedBps = await _estimateNetworkSpeed(testUrl);

    if (estimatedBps == null) return 0; // fallback to auto

    // Find the highest quality whose bitrate is <= 80% of estimated bandwidth
    final safeBps = (estimatedBps * 0.8).toInt();
    streams.sort((a, b) => a.bitrate.compareTo(b.bitrate));
    int chosenHeight = 0;
    for (final stream in streams) {
      if (stream.bitrate.bitsPerSecond <= safeBps) {
        chosenHeight = max(chosenHeight, stream.videoResolution.height);
      }
    }
    return chosenHeight == 0 ? 0 : chosenHeight;
  }

  /// Initializes the player with the given YouTube URL and settings.
  ///
  /// This method fetches video information, extracts stream URLs, and sets up
  /// the player with the highest quality video and audio streams available.
  Future<void> initialize(
    String youtubeUrl, {
    bool autoPlay = true,
    double? aspectRatio,
    bool allowFullScreen = true,
    bool allowMuting = true,
    bool chooseBestQuality = true,
    bool forceOriginalAudio = false,
  }) async {
    // Avoid re-initialization if the URL hasn't changed
    if (_lastInitializedUrl == youtubeUrl && isInitialized) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Already initialized with this URL');
      }
      return;
    }

    _setStatus(YPlayerStatus.loading);
    try {
      exp.StreamManifest? manifest;
      String videoId;

      debugPrint('YPlayerController: Fetching video info for $youtubeUrl');
      videoId = _extractVideoId(youtubeUrl);
      if (videoId.isEmpty) {
        throw Exception('Unable to parse video ID from $youtubeUrl');
      }

      final cachedManifest = _manifestCache[videoId];
      if (cachedManifest != null) {
        manifest = cachedManifest;
        _manifestCacheOrder.remove(videoId);
        _manifestCacheOrder.add(videoId);
      } else {
        final innertubeStream = await _fetchInnertubeStream(videoId);
        if (innertubeStream != null) {
          if (!kReleaseMode) {
            debugPrint('YPlayerController: Innertube fallback succeeded');
          }
          _prepareForFallback(videoId, youtubeUrl);
          await _openFallbackStream(innertubeStream, autoPlay);
          return;
        }
      }

      if (_manifestCache.containsKey(videoId)) {
        manifest = _manifestCache[videoId]!;
        _manifestCacheOrder.remove(videoId);
        _manifestCacheOrder.add(videoId);
      } else {
        final clientPriority = <List<exp.YoutubeApiClient>>[
          [exp.YoutubeApiClient.android],
          [exp.YoutubeApiClient.ios],
          [exp.YoutubeApiClient.safari],
          [exp.YoutubeApiClient.androidVr],
          [exp.YoutubeApiClient.android, exp.YoutubeApiClient.tv],
        ];

        dynamic lastError;
        for (final clients in clientPriority) {
          try {
            if (!kReleaseMode) {
              debugPrint(
                'YPlayerController: Trying manifest via clients: $clients',
              );
            }
            final candidate = await _yt.videos.streamsClient.getManifest(
              videoId,
              ytClients: clients,
            );
            if (_hasUsableStreams(candidate)) {
              manifest = candidate;
              if (!kReleaseMode) {
                debugPrint(
                  'YPlayerController: Manifest succeeded via $clients',
                );
              }
              break;
            }
            manifest ??= candidate;
          } catch (e) {
            lastError = e;
            if (!kReleaseMode) {
              debugPrint(
                'YPlayerController: Manifest fetch failed for clients $clients. Error: $e',
              );
            }
          }
        }

        if (manifest == null) {
          if (!kReleaseMode) {
            debugPrint(
              'YPlayerController: No manifest via youtube_explode. Attempting fallback.',
            );
          }
          final fallback = await _fetchFallbackStream(videoId);
          if (fallback != null) {
            _prepareForFallback(videoId, youtubeUrl);
            await _openFallbackStream(fallback, autoPlay);
            return;
          }
          if (lastError != null) {
            throw lastError;
          }
          throw Exception('Unable to fetch manifest for video $videoId');
        }

        _cacheManifest(videoId, manifest);
      }

      final resolvedManifest = manifest!;

      if (!kReleaseMode) {
        final hlsCount = _getHlsMuxedStreams(resolvedManifest).length;
        debugPrint(
          'YPlayerController: Manifest counts - videoOnly:${resolvedManifest.videoOnly.length}, audioOnly:${resolvedManifest.audioOnly.length}, muxed:${resolvedManifest.muxed.length}, hls:${hlsCount}',
        );
      }

      _currentManifest = resolvedManifest;
      _currentVideoId = videoId;

      // Store the force original audio preference
      _forceOriginalAudio = forceOriginalAudio;

      // Reset stream mode flags
      _usingMuxedStreams = false;
      _usingHlsMuxedStreams = false;
      _currentQuality = 0;

      final hasDashStreams =
          resolvedManifest.videoOnly.isNotEmpty &&
          resolvedManifest.audioOnly.isNotEmpty;
      final hasMuxedStreams = resolvedManifest.muxed.isNotEmpty;
      final hasHlsMuxedStreams = _getHlsMuxedStreams(
        resolvedManifest,
      ).isNotEmpty;

      if (!hasDashStreams) {
        if (hasMuxedStreams) {
          _usingMuxedStreams = true;
        } else if (hasHlsMuxedStreams) {
          _usingMuxedStreams = true;
          _usingHlsMuxedStreams = true;
        } else {
          throw Exception('No playable streams available for this video.');
        }
      }

      // --- Choose best quality for internet if requested ---
      if (chooseBestQuality) {
        final manifestForQuality = resolvedManifest;
        // Run asynchronously so UI is not blocked
        Future(() async {
          final best = await chooseBestQualityForInternet(manifestForQuality);
          if (best != _currentQuality) {
            await setQuality(best);
          }
        });
      }
      // -----------------------------------------------------

      if (_usingMuxedStreams) {
        if (_usingHlsMuxedStreams) {
          final hlsStreams = _getHlsMuxedStreams(resolvedManifest);
          if (hlsStreams.isEmpty) {
            throw Exception('HLS muxed streams are not available.');
          }
          final stream = hlsStreams.withHighestBitrate();

          if (!kReleaseMode) {
            debugPrint(
              'YPlayerController: Using HLS muxed stream ${stream.videoResolution.height}p',
            );
          }

          if (isInitialized) {
            await _player.stop();
          }

          await _player.open(Media(stream.url.toString()), play: false);
          if (autoPlay) {
            play();
          }

          _lastInitializedUrl = youtubeUrl;
          _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
          if (!kReleaseMode) {
            debugPrint('YPlayerController: HLS muxed initialization complete.');
          }
          return;
        } else {
          final muxedStreams = resolvedManifest.muxed;
          if (muxedStreams.isEmpty) {
            throw Exception('Muxed streams are not available.');
          }

          final stream = muxedStreams.withHighestBitrate();

          if (!kReleaseMode) {
            debugPrint(
              'YPlayerController: Using muxed stream ${stream.videoResolution.height}p',
            );
          }

          if (isInitialized) {
            await _player.stop();
          }

          await _player.open(Media(stream.url.toString()), play: false);
          if (autoPlay) {
            play();
          }

          _lastInitializedUrl = youtubeUrl;
          _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
          if (!kReleaseMode) {
            debugPrint('YPlayerController: Muxed initialization complete.');
          }
          return;
        }
      }

      // Get the appropriate video stream based on quality setting
      final videoStreamInfo = _selectVideoStream(resolvedManifest);
      final audioStreamInfo = _selectAudioStream(resolvedManifest);

      if (!kReleaseMode) {
        debugPrint('YPlayerController: Video URL: ${videoStreamInfo.url}');
        debugPrint('YPlayerController: Audio URL: ${audioStreamInfo.url}');
        debugPrint(
          'YPlayerController: Selected quality: ${videoStreamInfo.videoResolution.height}p',
        );
      }

      if (isInitialized) {
        debugPrint('YPlayerController: Stopping previous playback');
        await _player.stop();
      }

      await _player.open(Media(videoStreamInfo.url.toString()), play: false);
      await _player.setAudioTrack(
        AudioTrack.uri(audioStreamInfo.url.toString()),
      );

      await Future.delayed(const Duration(milliseconds: 200));

      if (autoPlay) {
        play();
      }

      _lastInitializedUrl = youtubeUrl;
      _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
      if (!kReleaseMode) {
        debugPrint(
          'YPlayerController: Initialization complete. Status: $_status',
        );
      }
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Error during initialization: $e');
      }
      _setStatus(YPlayerStatus.error);
    }
  }

  /// Sets up listeners for various player events.
  ///
  /// This method initializes listeners for playback state changes,
  /// completion events, position updates, errors, and more.
  void _setupPlayerListeners() {
    _player.stream.playing.listen((playing) {
      debugPrint('YPlayerController: Playing state changed to $playing');
      _setStatus(playing ? YPlayerStatus.playing : YPlayerStatus.paused);
    });

    _player.stream.completed.listen((completed) {
      debugPrint('YPlayerController: Playback completed: $completed');
      if (completed) _setStatus(YPlayerStatus.stopped);
    });

    _player.stream.position.listen((position) {
      debugPrint('YPlayerController: Position updated: $position');
      onProgressChanged?.call(position, _player.state.duration);
    });

    _player.stream.error.listen((error) {
      debugPrint('YPlayerController: Error occurred: $error');
      _setStatus(YPlayerStatus.error);
    });

    _player.stream.audioParams.listen((params) {
      debugPrint('YPlayerController: Audio params changed: $params');
    });

    _player.stream.audioDevice.listen((device) {
      debugPrint('YPlayerController: Audio device changed: $device');
    });

    _player.stream.track.listen((track) {
      debugPrint('YPlayerController: Track changed: $track');
    });

    _player.stream.tracks.listen((tracks) {
      debugPrint('YPlayerController: Available tracks: $tracks');
    });
  }

  /// Updates the player status and triggers the onStateChanged callback.
  void _setStatus(YPlayerStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      // Remove or comment out debugPrints in production for performance
      // debugPrint('YPlayerController: Status changed to $newStatus');
      onStateChanged?.call(_status);
      statusNotifier.value = newStatus;
    }
  }

  /// Starts or resumes video playback.
  Future<void> play() async {
    // Remove or comment out debugPrints in production for performance
    // debugPrint('YPlayerController: Play requested');
    await _player.play();
  }

  Future<void> speed(double speed) async {
    // Debounce rapid speed changes by checking if already set
    if (_player.state.rate == speed) return;
    await _player.setRate(speed);
  }

  /// Pauses video playback.
  Future<void> pause() async {
    // debugPrint('YPlayerController: Pause requested');
    await _player.pause();
  }

  /// Stops video playback and resets to the beginning.
  Future<void> stop() async {
    // debugPrint('YPlayerController: Stop requested');
    await _player.stop();
  }

  /// Enables background audio playback when screen is closed

  /// Gets the current playback position.
  Duration get position => _player.state.position;

  /// Gets the total duration of the video.
  Duration get duration => _player.state.duration;

  /// Gets whether original audio is being forced
  bool get forceOriginalAudio => _forceOriginalAudio;

  /// Disposes of all resources used by the controller.
  void dispose() {
    debugPrint('YPlayerController: Disposing');
    _player.dispose();
    _yt.close();
  }

  exp.MuxedStreamInfo _selectMuxedStream(int height) {
    final manifest = _currentManifest;
    if (manifest == null || manifest.muxed.isEmpty) {
      throw StateError('No muxed streams available.');
    }

    if (height == 0) {
      return manifest.muxed.withHighestBitrate();
    }

    final candidates = manifest.muxed
        .where((s) => s.videoResolution.height == height)
        .toList();
    if (candidates.isEmpty) {
      return manifest.muxed.withHighestBitrate();
    }
    return candidates.withHighestBitrate();
  }

  exp.HlsMuxedStreamInfo _selectHlsMuxedStream(int height) {
    final manifest = _currentManifest;
    final hlsStreams = manifest == null
        ? <exp.HlsMuxedStreamInfo>[]
        : _getHlsMuxedStreams(manifest);
    if (hlsStreams.isEmpty) {
      throw StateError('No HLS muxed streams available.');
    }

    if (height == 0) {
      return hlsStreams.withHighestBitrate();
    }

    final candidates = hlsStreams
        .where((s) => s.videoResolution.height == height)
        .toList();
    if (candidates.isEmpty) {
      return hlsStreams.withHighestBitrate();
    }
    return candidates.withHighestBitrate();
  }

  String _extractVideoId(String youtubeUrl) {
    try {
      final uri = Uri.parse(youtubeUrl);
      if (uri.queryParameters.containsKey('v')) {
        return uri.queryParameters['v'] ?? '';
      }
      if (uri.host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.last;
      }
      if (uri.pathSegments.contains('shorts') && uri.pathSegments.length >= 2) {
        return uri.pathSegments[1];
      }
      if (uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.last;
      }
    } catch (_) {
      // If parsing fails, assume the input is already a video ID
    }
    // As a final fallback, treat the entire string as the ID (if it looks like one)
    return youtubeUrl.trim();
  }

  bool _hasUsableStreams(exp.StreamManifest manifest) {
    return manifest.videoOnly.isNotEmpty && manifest.audioOnly.isNotEmpty ||
        manifest.muxed.isNotEmpty ||
        _getHlsMuxedStreams(manifest).isNotEmpty;
  }

  exp.VideoStreamInfo _selectVideoStream(exp.StreamManifest manifest) {
    if (_currentQuality == 0) {
      return manifest.videoOnly.withHighestBitrate();
    }
    try {
      return manifest.videoOnly
          .where((s) => s.videoResolution.height == _currentQuality)
          .withHighestBitrate();
    } catch (_) {
      return manifest.videoOnly.withHighestBitrate();
    }
  }

  exp.AudioStreamInfo _selectAudioStream(exp.StreamManifest manifest) {
    if (_forceOriginalAudio) {
      try {
        return manifest.audioOnly.firstWhere((stream) {
          if (stream.audioTrack != null) {
            try {
              final track = stream.audioTrack;
              final displayName = track?.displayName?.toString() ?? '';
              return displayName.toLowerCase().contains('original');
            } catch (_) {
              final trackString =
                  stream.audioTrack?.toString().toLowerCase() ?? '';
              return trackString.contains('original');
            }
          }
          return false;
        });
      } catch (_) {
        try {
          return manifest.audioOnly.firstWhere((stream) {
            if (stream.audioTrack != null) {
              try {
                final track = stream.audioTrack;
                return track?.audioIsDefault == false;
              } catch (_) {
                return false;
              }
            }
            return false;
          });
        } catch (_) {
          return manifest.audioOnly.first;
        }
      }
    }
    return manifest.audioOnly.withHighestBitrate();
  }

  List<exp.HlsMuxedStreamInfo> _getHlsMuxedStreams(
    exp.StreamManifest manifest,
  ) {
    return manifest.hls.whereType<exp.HlsMuxedStreamInfo>().toList();
  }

  void _prepareForFallback(String videoId, String youtubeUrl) {
    _currentManifest = null;
    _currentVideoId = videoId;
    _usingMuxedStreams = true;
    _usingHlsMuxedStreams = false;
    _currentQuality = 0;
    _lastInitializedUrl = youtubeUrl;
  }

  Future<void> _openFallbackStream(
    _FallbackStreamResult result,
    bool autoPlay,
  ) async {
    if (!kReleaseMode) {
      debugPrint(
        'YPlayerController: Fallback stream (${result.isHls ? 'HLS' : 'direct'}) URL: ${result.url}',
      );
    }
    if (isInitialized) {
      await _player.stop();
    }
    await _player.open(
      Media(
        result.url,
        httpHeaders: {
          HttpHeaders.userAgentHeader: _fallbackUserAgent,
          HttpHeaders.acceptLanguageHeader: 'en-US,en;q=0.9',
        },
      ),
      play: false,
    );
    if (result.isHls) {
      _usingHlsMuxedStreams = true;
    }
    if (autoPlay) {
      play();
    }
    _setStatus(autoPlay ? YPlayerStatus.playing : YPlayerStatus.paused);
  }

  Future<_FallbackStreamResult?> _fetchFallbackStream(String videoId) async {
    if (!kReleaseMode) {
      debugPrint('YPlayerController: Fallback - fetching player response');
    }
    try {
      final playerResponse = await _fetchPlayerResponse(videoId);
      if (playerResponse == null) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Fallback - player response is null');
        }
        return null;
      }
      final streamingData = playerResponse['streamingData'];
      if (streamingData is! Map<String, dynamic>) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Fallback - streamingData missing');
        }
        return null;
      }

      final directUrl = _extractDirectUrl(streamingData);
      if (directUrl != null) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Fallback - using direct URL');
        }
        return _FallbackStreamResult(url: directUrl, isHls: false);
      }

      final hlsUrl = streamingData['hlsManifestUrl'];
      if (hlsUrl is String && hlsUrl.isNotEmpty) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Fallback - using HLS URL');
        }
        return _FallbackStreamResult(url: hlsUrl, isHls: true);
      }

      if (!kReleaseMode) {
        debugPrint('YPlayerController: Fallback - no usable URLs found');
      }
    } catch (e) {
      if (!kReleaseMode) {
        debugPrint('YPlayerController: Fallback stream fetch failed: $e');
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchPlayerResponse(String videoId) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://www.youtube.com/watch?v=$videoId&bpctr=9999999999&has_verified=1',
        ),
      );
      request.headers.set(HttpHeaders.userAgentHeader, _fallbackUserAgent);
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      request.headers.set(HttpHeaders.cookieHeader, 'CONSENT=YES+cb');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        if (!kReleaseMode) {
          debugPrint(
            'YPlayerController: Fallback - HTTP status ${response.statusCode}',
          );
        }
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      final regex = RegExp(
        r'ytInitialPlayerResponse\s*=\s*(\{.+?\})\s*;',
        dotAll: true,
      );
      final match = regex.firstMatch(body);
      if (match == null) {
        return null;
      }
      final jsonString = _normalizePlayerResponseJson(match.group(1)!);
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } finally {
      client.close();
    }
  }

  String? _extractDirectUrl(Map<String, dynamic> streamingData) {
    String? pickFromList(List<dynamic>? list) {
      if (list == null) return null;
      for (final element in list) {
        if (element is Map<String, dynamic>) {
          final url = element['url'];
          if (url is String && url.isNotEmpty) {
            return url;
          }
        }
      }
      return null;
    }

    final direct = pickFromList(streamingData['formats'] as List<dynamic>?);
    if (direct != null) {
      return direct;
    }
    return pickFromList(streamingData['adaptiveFormats'] as List<dynamic>?);
  }

  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15';

  String _normalizePlayerResponseJson(String input) {
    return input.replaceAllMapped(RegExp(r'\\x([0-9A-Fa-f]{2})'), (match) {
      final hex = match.group(1)!;
      final code = int.parse(hex, radix: 16);
      return String.fromCharCode(code);
    });
  }

  Future<_FallbackStreamResult?> _fetchInnertubeStream(String videoId) async {
    final clients = <exp.YoutubeApiClient>[
      exp.YoutubeApiClient.android,
      exp.YoutubeApiClient.ios,
      exp.YoutubeApiClient.safari,
      exp.YoutubeApiClient.androidVr,
    ];

    for (final client in clients) {
      try {
        if (!kReleaseMode) {
          debugPrint(
            'YPlayerController: Innertube request via ${client.apiUrl}',
          );
        }
        final result = await _callInnertubePlayer(client, videoId);
        if (result != null) {
          return result;
        }
      } catch (e) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Innertube client failed: $e');
        }
        // Try next client
      }
    }
    return null;
  }

  Future<_FallbackStreamResult?> _callInnertubePlayer(
    exp.YoutubeApiClient client,
    String videoId,
  ) async {
    final httpClient = HttpClient();
    try {
      final uri = Uri.parse(client.apiUrl);
      final request = await httpClient.postUrl(uri);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=UTF-8',
      );
      request.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      request.headers.set(HttpHeaders.userAgentHeader, _fallbackUserAgent);
      client.headers.forEach((key, value) {
        request.headers.set(key, value.toString());
      });

      final payload =
          jsonDecode(jsonEncode(client.payload)) as Map<String, dynamic>;
      payload['videoId'] = videoId;
      payload['contentCheckOk'] = true;
      payload['racyCheckOk'] = true;

      final body = jsonEncode(payload);
      request.write(body);

      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        if (!kReleaseMode) {
          debugPrint(
            'YPlayerController: Innertube HTTP ${response.statusCode} for ${client.apiUrl}',
          );
        }
        return null;
      }

      final responseBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      final streamingData = json['streamingData'];
      if (streamingData is! Map<String, dynamic>) {
        return null;
      }

      final directUrl = _extractDirectUrl(streamingData);
      if (directUrl != null) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Innertube - using direct URL');
        }
        return _FallbackStreamResult(url: directUrl, isHls: false);
      }

      final hlsUrl = streamingData['hlsManifestUrl'];
      if (hlsUrl is String && hlsUrl.isNotEmpty) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Innertube - using HLS URL');
        }
        return _FallbackStreamResult(url: hlsUrl, isHls: true);
      }

      final dashUrl = streamingData['dashManifestUrl'];
      if (dashUrl is String && dashUrl.isNotEmpty) {
        if (!kReleaseMode) {
          debugPrint('YPlayerController: Innertube - using DASH URL');
        }
        return _FallbackStreamResult(url: dashUrl, isHls: true);
      }
    } finally {
      httpClient.close();
    }
    return null;
  }
}

class _FallbackStreamResult {
  final String url;
  final bool isHls;

  const _FallbackStreamResult({required this.url, required this.isHls});
}
